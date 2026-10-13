import 'dart:async';
import 'dart:isolate';

import 'package:apk_info_tool/utils/cancellable_task.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_parser/apk_parser.dart';

/// APK 解析任务发出的事件。
///
/// 事件按顺序到达，且只会以 [ParseSucceeded]、[ParseFailed]、
/// [ParseOpenFailed] 或 [ParseCancelled] 之一收尾。
sealed class ParseEvent {
  const ParseEvent();
}

/// 解析推进到了某个阶段。
class ParseStageReached extends ParseEvent {
  final ApkParseStage stage;

  const ParseStageReached(this.stage);
}

/// 归档容器打开失败 —— 携带可本地化的具体原因。
class ParseOpenFailed extends ParseEvent {
  final ArchiveOpenResult result;

  const ParseOpenFailed(this.result);
}

/// 解析失败，[reason] 面向诊断（英文，直接进日志）。
class ParseFailed extends ParseEvent {
  final String reason;

  const ParseFailed(this.reason);
}

/// 解析成功。
class ParseSucceeded extends ParseEvent {
  final ParsedApkData data;

  const ParseSucceeded(this.data);
}

/// 任务被用户取消。取消之后不会再有其它事件。
class ParseCancelled extends ParseEvent {
  const ParseCancelled();
}

/// 可跨 isolate 传递的解析结果。
///
/// 只装**可发送**的数据。`ApkInfo` 持有 `dart:ui` 的 `Image`，不能跨 isolate
/// 传递，因此图标渲染留在主 isolate —— worker 只做容器解析与资源表解析这类
/// 纯计算，那也正是真正卡住 UI 的部分。
class ParsedApkData {
  final ApkMeta meta;
  final Map<int, ResourceInfo> arscResources;

  /// 容器结构上观察到的加固线索（只描述事实，不含厂商判定）。
  final List<HardeningObservation> hardeningObservations;

  /// 容器结构概览（DEX / SO / ABI / 目录）。
  final ContainerStructure structure;

  const ParsedApkData({
    required this.meta,
    required this.arscResources,
    this.hardeningObservations = const [],
    this.structure = const ContainerStructure(),
  });
}

/// 一次在独立 isolate 中执行的 APK 解析任务。
///
/// 存在的理由有两条，且缺一不可：
/// - **不冻结 UI**：解析（ZIP 解压 + 完整 `resources.arsc` 遍历）是同步 CPU
///   密集计算，跑在主 isolate 上会让大 APK 冻住整个界面。
/// - **真能取消**：`Isolate.run` 无法中断，只能把结果丢掉。这里持有
///   `Isolate` 句柄，[cancel] 是真正的终止。
class ApkParseTask implements CancellableParseTask {
  /// 解析过程的事件流。
  final Stream<ParseEvent> events;

  final ReceivePort _receive;
  final StreamController<ParseEvent> _controller;

  Isolate? _isolate;
  bool _finished = false;

  ApkParseTask._(this._receive, this._controller) : events = _controller.stream;

  /// 启动一次解析。返回后 worker isolate 已在运行。
  static Future<ApkParseTask> start(String filePath) async {
    final receive = ReceivePort();
    final controller = StreamController<ParseEvent>();
    final task = ApkParseTask._(receive, controller);

    receive.listen((message) {
      if (message is ParseEvent) task._handle(message);
    });

    final isolate = await Isolate.spawn(
      _parseEntryPoint,
      _ParseRequest(reply: receive.sendPort, filePath: filePath),
    );
    task._isolate = isolate;

    // 极小概率：在 spawn 完成之前就被取消了。
    if (task._finished) {
      isolate.kill(priority: Isolate.immediate);
    }
    return task;
  }

  /// 取消解析。
  ///
  /// 用 [Isolate.immediate] 而不是默认的 `beforeNextEvent`：后者要等 worker
  /// 回到事件循环才生效，而 worker 的绝大部分时间都耗在一段同步的
  /// `resources.arsc` 解析里 —— 那恰恰是用户想取消的时刻。
  ///
  /// 代价是立即终止不会执行 `finally`，worker 若正持有文件句柄，该句柄要等
  /// 进程退出才释放。这里可以接受：worker 不创建临时文件，句柄也只在解析
  /// 期间短暂存在。**这也是 worker 内不做任何需要显式清理的副作用的原因。**
  @override
  bool get isFinished => _finished;

  @override
  void cancel() {
    if (_finished) return;
    _finished = true;
    _isolate?.kill(priority: Isolate.immediate);
    _emitAndClose(const ParseCancelled());
    _receive.close();
  }

  void _handle(ParseEvent event) {
    if (_finished) return;

    switch (event) {
      case ParseSucceeded() || ParseFailed() || ParseOpenFailed():
        _finished = true;
        _emitAndClose(event);
        _receive.close();
      case ParseStageReached() || ParseCancelled():
        if (!_controller.isClosed) _controller.add(event);
    }
  }

  void _emitAndClose(ParseEvent last) {
    if (_controller.isClosed) return;
    _controller.add(last);
    _controller.close();
  }
}

class _ParseRequest {
  final SendPort reply;
  final String filePath;

  const _ParseRequest({required this.reply, required this.filePath});
}

/// worker isolate 的入口。
///
/// 是 async 函数：`Isolate.spawn` 的入口在第一个 `await` 处返回并不会让
/// isolate 提前结束，它会一直活到异步工作结束（已用探针测试确认）。
///
/// **不要在这里创建临时文件或持有需要显式释放的资源** —— [ApkParseTask.cancel]
/// 用的是立即终止，`finally` 不保证执行。
void _parseEntryPoint(_ParseRequest request) async {
  final reader = ApkReader();
  try {
    request.reply.send(const ParseStageReached(ApkParseStage.openContainer));

    final openResult = await reader.open(request.filePath);
    if (!openResult.isOk) {
      request.reply.send(ParseOpenFailed(openResult));
      return;
    }

    final meta = await reader.parse(
      onStage: (stage) => request.reply.send(ParseStageReached(stage)),
    );
    if (meta == null) {
      request.reply
          .send(const ParseFailed('AndroidManifest.xml missing or unreadable'));
      return;
    }

    request.reply.send(ParseSucceeded(ParsedApkData(
      meta: meta,
      arscResources: reader.arscParser?.getAllResources() ?? const {},
      hardeningObservations: reader.scanHardeningSignals(),
      structure: reader.collectStructure(),
    )));
  } catch (e) {
    log.warning('ApkParseTask: worker failed: $e');
    request.reply.send(ParseFailed('$e'));
  } finally {
    reader.close();
  }
}
