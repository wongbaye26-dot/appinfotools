import 'dart:async';
import 'dart:isolate';

import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:archive_safety/archive_safety.dart' show ArchiveOpenResult;

/// IPA 解析任务发出的事件。
///
/// 与 `ApkParseTask` 的约定一致：事件按顺序到达，且只会以
/// [IpaParseSucceeded]、[IpaParseFailed]、[IpaOpenFailed] 或
/// [IpaParseCancelled] 之一收尾。
sealed class IpaParseEvent {
  const IpaParseEvent();
}

/// 解析推进到了某个阶段。
class IpaStageReached extends IpaParseEvent {
  final IpaParseStage stage;

  const IpaStageReached(this.stage);
}

/// 归档容器打开失败 —— 携带可本地化的具体原因。
class IpaOpenFailed extends IpaParseEvent {
  final ArchiveOpenResult result;

  const IpaOpenFailed(this.result);
}

/// 解析失败，[reason] 面向诊断（英文，直接进日志）。
class IpaParseFailed extends IpaParseEvent {
  final String reason;

  const IpaParseFailed(this.reason);
}

/// 解析成功。
class IpaParseSucceeded extends IpaParseEvent {
  final IpaAnalysis analysis;

  const IpaParseSucceeded(this.analysis);
}

/// 任务被用户取消。取消之后不会再有其它事件。
class IpaParseCancelled extends IpaParseEvent {
  const IpaParseCancelled();
}

/// 一次在独立 isolate 中执行的 IPA 静态解析任务。
///
/// 与 `ApkParseTask` 同样的两条理由：
/// - **不冻结 UI**：`Info.plist`、图标定位、Mach-O 解析都是同步 CPU 计算；
/// - **真能取消**：`Isolate.run` 无法中断，这里持有句柄，[cancel] 是真正的终止。
///
/// **worker 内不做任何需要显式清理的副作用。** [cancel] 用的是
/// `Isolate.immediate`，`finally` 不保证执行 —— 因此解包与 `codesign` 这类
/// 会写磁盘、要删临时目录的工作**不在这个 worker 里做**，由主 isolate 在
/// 本任务完成之后单独执行（见 `IosCodeSignStep`）。
class IpaParseTask {
  final Stream<IpaParseEvent> events;

  final ReceivePort _receive;
  final StreamController<IpaParseEvent> _controller;

  Isolate? _isolate;
  bool _finished = false;

  IpaParseTask._(this._receive, this._controller) : events = _controller.stream;

  /// 启动一次解析。返回后 worker isolate 已在运行。
  static Future<IpaParseTask> start(String filePath) async {
    final receive = ReceivePort();
    final controller = StreamController<IpaParseEvent>();
    final task = IpaParseTask._(receive, controller);

    receive.listen((message) {
      if (message is IpaParseEvent) task._handle(message);
    });

    final isolate = await Isolate.spawn(
      _ipaParseEntryPoint,
      _IpaParseRequest(reply: receive.sendPort, filePath: filePath),
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
  /// 回到事件循环才生效，而 worker 的绝大部分时间耗在一段同步解析里 ——
  /// 那恰恰是用户想取消的时刻。
  void cancel() {
    if (_finished) return;
    _finished = true;
    _isolate?.kill(priority: Isolate.immediate);
    _emitAndClose(const IpaParseCancelled());
    _receive.close();
  }

  void _handle(IpaParseEvent event) {
    if (_finished) return;

    switch (event) {
      case IpaParseSucceeded() || IpaParseFailed() || IpaOpenFailed():
        _finished = true;
        _emitAndClose(event);
        _receive.close();
      case IpaStageReached() || IpaParseCancelled():
        if (!_controller.isClosed) _controller.add(event);
    }
  }

  void _emitAndClose(IpaParseEvent last) {
    if (_controller.isClosed) return;
    _controller.add(last);
    _controller.close();
  }
}

class _IpaParseRequest {
  final SendPort reply;
  final String filePath;

  const _IpaParseRequest({required this.reply, required this.filePath});
}

/// worker isolate 的入口。
///
/// 是 async 函数：`Isolate.spawn` 的入口在第一个 `await` 处返回并不会让
/// isolate 提前结束，它会一直活到异步工作结束。
void _ipaParseEntryPoint(_IpaParseRequest request) async {
  final helper = ZipHelper();
  try {
    request.reply.send(const IpaStageReached(IpaParseStage.openContainer));

    // 复用 ZipHelper.open 的完整安全判定（魔数 / 结构完整性 / 解压预算），
    // 而不是在这里再写一遍。
    final openResult = await helper.open(request.filePath);
    if (!openResult.isOk) {
      request.reply.send(IpaOpenFailed(openResult));
      return;
    }

    final archive = helper.archive;
    if (archive == null) {
      request.reply.send(
        const IpaParseFailed('the archive could not be opened'),
      );
      return;
    }

    final analysis = IpaAnalysisReader.analyze(
      archive,
      onStage: (stage) => request.reply.send(IpaStageReached(stage)),
    );

    request.reply.send(IpaParseSucceeded(analysis));
  } catch (e) {
    log.warning('IpaParseTask: worker failed: $e');
    request.reply.send(IpaParseFailed('$e'));
  } finally {
    helper.close();
  }
}
