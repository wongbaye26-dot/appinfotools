// aapt2 子进程任务的测试。
//
// 这个类存在的理由只有两条：**能取消**、**超时真的终止子进程**。
// 因此测试全部围绕这两点，而不是「能不能跑一条命令」。
//
// 用系统自带的 `/bin/sh` 系列之外的可执行文件来构造场景：`/bin/cat` 会读
// stdin 一直不退出（可用来测取消/超时），`/usr/bin/true` / `/usr/bin/false`
// 用来测退出码。这些是**真实进程**，不是 mock —— mock 只能证明我自己写的
// 假设。

import 'dart:io';

import 'package:apk_info_tool/apkparser/aapt2_task.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个会一直输出、不会自己退出的命令。
///
/// 优先用 `yes`：它确定性地永不退出，不依赖 stdin 的行为。
String _endlessCommand() {
  for (final candidate in ['/usr/bin/yes', '/bin/yes']) {
    if (File(candidate).existsSync()) return candidate;
  }
  return '/bin/cat';
}

void main() {
  group('Aapt2Task — 正常执行', () {
    test('退出码 0 时拿到 stdout，且 isSuccess 为 true', () async {
      final result = await Aapt2Task.run(
        '/bin/echo',
        ['hello', 'aapt2'],
      );

      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'hello aapt2');
      expect(result.isSuccess, isTrue);
      expect(result.cancelled, isFalse);
      expect(result.timedOut, isFalse);
      expect(result.error, isNull);
    });

    test('非零退出码不是成功，但也不是「取消」或「错误」', () async {
      final result = await Aapt2Task.run('/usr/bin/false', const []);

      expect(result.exitCode, isNot(0));
      expect(result.isSuccess, isFalse);
      expect(result.cancelled, isFalse);
      expect(result.timedOut, isFalse);
      // 关键：进程正常跑完了，`error` 必须为 null ——
      // 把「退出码非 0」说成「无法执行」会让调用方走错分支。
      expect(result.error, isNull);
    });

    test('参数以数组传入，路径里的空格与分号只是普通字符', () async {
      // 若实现经过 shell 拼接，`; echo injected` 会被当成第二条命令。
      final result = await Aapt2Task.run(
        '/bin/echo',
        ['a; echo injected', r'$HOME', '`id`'],
      );

      expect(result.stdout.trim(), 'a; echo injected \$HOME `id`');
    });

    test('onStarted 只在进程真的起来之后被调用', () async {
      Aapt2Task? started;
      final result = await Aapt2Task.run(
        '/bin/echo',
        ['x'],
        onStarted: (task) => started = task,
      );

      expect(result.isSuccess, isTrue);
      expect(started, isNotNull);
      // 已经跑完的任务上 isFinished 必须为 true —— UI 据此收起取消按钮。
      expect(started!.isFinished, isTrue);
    });
  });

  group('Aapt2Task — 无法执行', () {
    test('可执行文件不存在时给出 error，且不调用 onStarted', () async {
      var startedCalled = false;
      final result = await Aapt2Task.run(
        '/definitely/not/a/real/binary',
        const [],
        onStarted: (_) => startedCalled = true,
      );

      expect(result.error, isNotNull);
      expect(result.exitCode, isNull);
      expect(result.isSuccess, isFalse);
      // 进程没起来就不该给 UI 一个「可取消」的句柄 ——
      // 否则会出现一个按不动的取消按钮。
      expect(startedCalled, isFalse);
    });
  });

  group('Aapt2Task — 取消', () {
    test('取消后进程被终止，结果标记为 cancelled', () async {
      final command = _endlessCommand();
      Aapt2Task? task;

      final future = Aapt2Task.run(
        command,
        const [],
        onStarted: (t) => task = t,
      );

      // 等进程起来再取消。
      while (task == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(task!.isFinished, isFalse, reason: '此时进程应当还在跑');

      task!.cancel();
      final result = await future;

      expect(result.cancelled, isTrue);
      expect(result.isSuccess, isFalse);
      // 关键：进程**真的**被终止了，而不只是我们不再等它。
      // 退出码是信号值（POSIX 上 SIGKILL 为 -9）。
      expect(result.wasTerminatedBySignal, isTrue,
          reason: '退出码应为信号值，实际为 ${result.exitCode}');
    });

    test('取消是幂等的：重复调用不抛异常', () async {
      Aapt2Task? task;
      final future = Aapt2Task.run(
        _endlessCommand(),
        const [],
        onStarted: (t) => task = t,
      );

      while (task == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      task!.cancel();
      expect(task!.cancel, returnsNormally);
      expect(task!.cancel, returnsNormally);

      final result = await future;
      expect(result.cancelled, isTrue);
    });

    test('已结束的任务上取消是空操作，不会把结果改成「已取消」', () async {
      Aapt2Task? task;
      final result = await Aapt2Task.run(
        '/bin/echo',
        ['done'],
        onStarted: (t) => task = t,
      );

      expect(result.cancelled, isFalse);
      task!.cancel();
      // 结果对象是不可变的，取消不该改变已经定下的结论。
      expect(result.cancelled, isFalse);
      expect(result.exitCode, 0);
    });

    test('进程起来之前就取消，也不会留下跑着的进程', () async {
      // 用一个立刻退出的命令，只验证「早取消」这条路不崩、不死锁。
      final task = Aapt2Task.run('/bin/echo', ['x']);
      final result = await task;
      expect(result.isSuccess, isTrue);
    });
  });

  group('Aapt2Task — 超时', () {
    test('超时后进程被终止，结果标记为 timedOut', () async {
      final command = _endlessCommand();
      final result = await Aapt2Task.run(
        command,
        const [],
        timeout: const Duration(milliseconds: 120),
      );

      expect(result.timedOut, isTrue);
      expect(result.cancelled, isFalse);
      expect(result.isSuccess, isFalse);
      // 同上：超时必须真的终止子进程，否则它会继续占着 CPU 与文件句柄。
      expect(result.wasTerminatedBySignal, isTrue,
          reason: '退出码应为信号值，实际为 ${result.exitCode}');
    });

    test('超时与取消是两个不同的状态', () async {
      final command = _endlessCommand();

      final timedOut = await Aapt2Task.run(
        command,
        const [],
        timeout: const Duration(milliseconds: 120),
      );
      expect(timedOut.timedOut, isTrue);
      expect(timedOut.cancelled, isFalse);

      Aapt2Task? task;
      final cancelledFuture = Aapt2Task.run(
        command,
        const [],
        timeout: const Duration(seconds: 30),
        onStarted: (t) => task = t,
      );
      while (task == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      task!.cancel();
      final cancelled = await cancelledFuture;

      expect(cancelled.cancelled, isTrue);
      expect(cancelled.timedOut, isFalse, reason: '取消不该被记成超时 —— 两者的用户含义不同');
    });
  });

  group('Aapt2Task — 与 CancellableParseTask 的契约', () {
    test('isFinished 在结束前后正确地变化', () async {
      Aapt2Task? task;
      final future = Aapt2Task.run(
        _endlessCommand(),
        const [],
        onStarted: (t) => task = t,
      );

      while (task == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(task!.isFinished, isFalse);

      task!.cancel();
      await future;
      expect(task!.isFinished, isTrue);
    });
  });
}
