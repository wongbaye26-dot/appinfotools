import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/utils/cancellable_task.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// `aapt2` 子进程的执行结果。
///
/// 四态分开，因为它们对用户的含义完全不同：
/// - [cancelled]：用户主动取消 —— 不该弹错误提示；
/// - [timedOut]：超时 —— 说明这个包太大或工具卡住了；
/// - [error] 非空：进程根本起不来（工具缺失、无执行权限）；
/// - 其余：真的跑完了，看 [exitCode]。
class Aapt2Result {
  /// 进程退出码。
  ///
  /// - 正常跑完：真实退出码（0 / 非 0）；
  /// - 被终止（取消或超时）：**信号值**，POSIX 上被 SIGKILL 杀掉通常是 `-9`；
  /// - 进程根本没起来（[error] 非空）：`null`。
  ///
  /// 特意把信号值记下来而不是留 `null`：调用方（与测试）据此可以区分
  /// 「真的被终止了」与「我们只是不再等它了」。
  final int? exitCode;

  final String stdout;
  final String stderr;

  final bool cancelled;
  final bool timedOut;

  /// 无法执行的原因（工具缺失、权限不足等）。正常执行时为 `null`。
  final String? error;

  const Aapt2Result({
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.cancelled = false,
    this.timedOut = false,
    this.error,
  });

  /// 是否成功执行且退出码为 0。
  bool get isSuccess =>
      !cancelled && !timedOut && error == null && exitCode == 0;

  /// 是否因被终止而以信号退出。
  ///
  /// 与 [cancelled] / [timedOut] 的区别：那两个是「为什么终止」，
  /// 这个是「确认终止了」。取消与超时之外不会有信号退出。
  bool get wasTerminatedBySignal => exitCode != null && exitCode! < 0;

  /// 供日志与诊断展示的原始输出。
  String get rawOutput => [
        if (stderr.trim().isNotEmpty) stderr.trim(),
        if (stdout.trim().isNotEmpty) stdout.trim(),
      ].join('\n');

  @override
  String toString() => 'Aapt2Result(exitCode: $exitCode, '
      'cancelled: $cancelled, timedOut: $timedOut, error: $error)';
}

/// 一次 `aapt2` 子进程调用，可被取消。
///
/// 替代原来的 `Process.run(...).timeout(...)`。那套写法有两个真实缺陷：
///
/// 1. **超时不会终止子进程**：`Future.timeout` 只是不再等待，aapt2 会继续跑
///    下去占着 CPU 与文件句柄。规范 5.6/5.7 要求「取消后不得残留进程」。
/// 2. **完全无法取消**：UI 上只能不显示取消按钮（本项目此前正是如此），
///    用户面对一个卡住的大包只能等满 120 秒。
///
/// 与 `SignatureAnalyzer` / `IosCodeSignAnalyzer` 的处理方式一致：
/// 参数以数组传入（绝不经 shell），终止后不再等待 stdout/stderr 关闭 ——
/// 那两个流可能被继承了同一批管道的孙进程持有。
class Aapt2Task implements CancellableParseTask {
  final String executable;
  final List<String> arguments;
  final Duration timeout;

  final Completer<Aapt2Result> _completer = Completer<Aapt2Result>();

  /// 发出终止信号后，最多等这么久确认进程退出。
  ///
  /// 取一个很短的值：SIGKILL 之后进程应当立刻消失，等久了只会拖慢取消。
  static const Duration _terminationGrace = Duration(seconds: 2);

  Process? _process;
  bool _finished = false;
  bool _cancelRequested = false;

  Aapt2Task._(this.executable, this.arguments, this.timeout);

  /// 执行结果。只会完成一次。
  Future<Aapt2Result> get result => _completer.future;

  @override
  bool get isFinished => _finished;

  /// 启动并等待执行完成。
  ///
  /// [onStarted] 在进程真正起来之后被调用，UI 据此拿到可取消的句柄。
  /// 进程起不来时不会被调用 —— 也就不会出现「按钮亮着但点了没用」。
  static Future<Aapt2Result> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 120),
    void Function(Aapt2Task task)? onStarted,
  }) async {
    final task = Aapt2Task._(executable, arguments, timeout);

    Process process;
    try {
      process = await Process.start(executable, arguments);
    } on ProcessException catch (e) {
      log.warning('Aapt2Task: 无法执行 $executable: $e');
      task._finished = true;
      final result = Aapt2Result(error: 'cannot execute $executable: $e');
      task._completer.complete(result);
      return result;
    }

    task._process = process;

    // 在 spawn 与这里之间用户可能已经点了取消。
    if (task._cancelRequested) {
      process.kill(ProcessSignal.sigkill);
    } else {
      onStarted?.call(task);
    }

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuffer.write)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write)
        .asFuture<void>();

    int? exitCode;
    var timedOut = false;
    try {
      exitCode = await process.exitCode.timeout(task.timeout);
    } on TimeoutException {
      timedOut = true;
      log.warning('Aapt2Task: aapt2 超时（${task.timeout.inSeconds}s），已终止');
      process.kill(ProcessSignal.sigkill);
    }

    if (exitCode == null) {
      // 被取消或超时：确认进程**真的**退出了。
      //
      // 这一步不是可有可无的 —— 「不再等待」与「已经终止」对用户而言结果
      // 看起来一样，但只有后者不残留进程。规范 5.7 要求的正是后者。
      // 退出码会是信号值（POSIX 上被 SIGKILL 杀掉通常是 -9），
      // 因此把它记下来，而不是留一个 `null` 让调用方无从判断。
      try {
        exitCode = await process.exitCode.timeout(_terminationGrace);
      } on TimeoutException {
        log.warning('Aapt2Task: 进程在终止后 ${_terminationGrace.inSeconds}s '
            '内仍未退出');
      }

      // 不能再等 stdout/stderr 关闭 —— 子进程可能还有继承了同一批管道的
      // 孙进程（aapt2 在部分平台是包装脚本）。直接丢弃。
      stdoutDone.ignore();
      stderrDone.ignore();
    } else {
      await _drain(stdoutDone);
      await _drain(stderrDone);
    }

    task._finished = true;
    final result = Aapt2Result(
      exitCode: exitCode,
      stdout: stdoutBuffer.toString(),
      stderr: stderrBuffer.toString(),
      cancelled: task._cancelRequested,
      timedOut: timedOut,
    );
    task._completer.complete(result);
    return result;
  }

  /// 终止子进程。
  ///
  /// 幂等：重复调用是空操作。已经跑完的任务上调用也是空操作 —— 那种情况下
  /// 结果已经定了，取消不能把它改成「被取消」。
  @override
  void cancel() {
    if (_finished || _cancelRequested) return;
    _cancelRequested = true;
    log.info('Aapt2Task: 用户请求取消');
    _process?.kill(ProcessSignal.sigkill);
  }

  static Future<void> _drain(Future<void> done) async {
    try {
      await done;
    } catch (_) {
      // 流关闭异常不影响结论。
    }
  }
}
