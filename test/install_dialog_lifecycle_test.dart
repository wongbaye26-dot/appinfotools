// InstallDialog 生命周期回归测试。
//
// 缺陷背景：`_loadDevices` / `_loadSplitApks` / `_installApk` 都在 `await`
// 之后调用 `setState`，但只有 `_installApk` 的 `finally` 有 `mounted` 守卫。
// 用户在 adb 设备列表返回之前关掉对话框，就会在已销毁的 State 上调用
// `setState`，Flutter 抛 "setState() called after dispose()"。
//
// 这里通过 `InstallDialog.deviceLoader` 注入一个由测试控制完成时机的加载器，
// 从而精确复现「await 未完成 -> 对话框销毁 -> await 才返回」这一时序。
//
// 为什么不用真实 adb：`Process.run` 在 widget 测试的 fake-async 区里会创建
// 一个 FakeTimer，测试结束时仍处于 pending，触发
// "A Timer is still pending even after the widget tree was disposed"；
// 而单靠 `tester.pump(Duration)` 又推进不了真实 I/O，await 之后的 setState
// 根本不会执行 —— 测试会变成空断言。

import 'dart:async';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/install_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) =>
    TranslationProvider(child: MaterialApp(home: child));

void main() {
  testWidgets('对话框在异步加载期间被销毁，不得抛 setState-after-dispose',
      (WidgetTester tester) async {
    // 加载器一直挂起，直到测试显式放行。
    final gate = Completer<void>();
    Future<List<AdbDevice>> loader() async {
      await gate.future;
      return <AdbDevice>[];
    }

    await tester.pumpWidget(
      _host(
        InstallDialog(apkPath: '/nonexistent/x.apk', deviceLoader: loader),
      ),
    );
    await tester.pump(); // initState 已启动 _loadDevices，正挂在 gate 上

    // 模拟用户在设备列表返回前关闭对话框：整棵树被替换，State 被销毁。
    await tester.pumpWidget(_host(const SizedBox.shrink()));

    // 现在才放行加载器 —— 这正是「await 之后 setState」发生的那一刻。
    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  // 覆盖 catch 分支：加载器抛错时，catch 内同样有一条 await 之后的 setState。
  // 若只给 try 里的那次加守卫，这条路径仍然会在已销毁的 State 上 setState
  // （且异常会被外层 catch 吞掉，只在日志里留下一条误导性的 assertion 记录）。
  testWidgets('异步加载抛错且对话框已销毁，不得抛 setState-after-dispose',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    Future<List<AdbDevice>> loader() async {
      await gate.future;
      throw StateError('adb not found');
    }

    await tester.pumpWidget(
      _host(
        InstallDialog(apkPath: '/nonexistent/x.apk', deviceLoader: loader),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(_host(const SizedBox.shrink()));

    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
