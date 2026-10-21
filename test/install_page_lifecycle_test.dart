// InstallPage 生命周期回归测试。
//
// 缺陷背景（从 `InstallDialog` 时期延续下来）：`_refreshDevices` /
// `_loadSplits` / `_installOn` 都在 `await` 之后调用 `setState`。若用户在
// adb 设备列表返回之前离开页面（窗口关闭、路由替换），就会在已销毁的 State
// 上调用 `setState`，Flutter 抛 "setState() called after dispose()"。
//
// 这里通过 `InstallPage.deviceLoader` 注入一个由测试控制完成时机的加载器，
// 从而精确复现「await 未完成 -> 页面销毁 -> await 才返回」这一时序。
//
// 为什么不用真实 adb：`Process.run` 在 widget 测试的 fake-async 区里会创建
// 一个 FakeTimer，测试结束时仍处于 pending，触发
// "A Timer is still pending even after the widget tree was disposed"；
// 而单靠 `tester.pump(Duration)` 又推进不了真实 I/O，await 之后的 setState
// 根本不会执行 —— 测试会变成空断言。

import 'dart:async';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/install_page.dart';
import 'package:apk_info_tool/utils/adb_service.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) =>
    TranslationProvider(child: MaterialApp(home: child));

void main() {
  testWidgets('页面在异步加载期间被销毁，不得抛 setState-after-dispose',
      (WidgetTester tester) async {
    // 加载器一直挂起，直到测试显式放行。
    final gate = Completer<void>();
    Future<List<AdbDevice>> loader() async {
      await gate.future;
      return <AdbDevice>[];
    }

    await tester.pumpWidget(_host(InstallPage(deviceLoader: loader)));
    await tester.pump(); // initState 已启动 _refreshDevices，正挂在 gate 上

    // 模拟用户在设备列表返回前离开页面：整棵树被替换，State 被销毁。
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
  testWidgets('异步加载抛错且页面已销毁，不得抛 setState-after-dispose',
      (WidgetTester tester) async {
    final gate = Completer<void>();
    Future<List<AdbDevice>> loader() async {
      await gate.future;
      throw StateError('adb not found');
    }

    await tester.pumpWidget(_host(InstallPage(deviceLoader: loader)));
    await tester.pump();

    await tester.pumpWidget(_host(const SizedBox.shrink()));

    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('没有安装包时按钮不可点，并说明原因', (WidgetTester tester) async {
    await tester.pumpWidget(_host(InstallPage(deviceLoader: () async => [])));
    await tester.pumpAndSettle();

    // 空态文案必须在，否则用户不知道要连设备。
    expect(find.text(t.install.reason_no_file), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('单独渲染（可见）时拖放区是开着的', (WidgetTester tester) async {
    // 与 `drop_target_ownership_test` 配套：那边断言「被 IndexedStack 盖住时
    // 关着」，这里断言「可见时开着」。两半合起来才是完整约束 —— 只测一半的
    // 话，把 `enable` 写死成 false 也能让测试全绿。
    await tester.pumpWidget(_host(InstallPage(deviceLoader: () async => [])));
    await tester.pumpAndSettle();

    final target = tester.widget<DropTarget>(find.byType(DropTarget));
    expect(target.enable, isTrue);
  });

  // `AppShell` 用 `IndexedStack` 承载全部页面，它通过 `Visibility.of` 告诉
  // 子页自己可不可见。这里用一个最小的 IndexedStack 复现同一机制：
  // 不经过 AppShell 就不会真的去调 `adb`（否则会撞上 fake-async 的 Timer）。
  testWidgets('被 IndexedStack 盖住时拖放区关掉，切到前台后打开', (WidgetTester tester) async {
    var index = 0;
    Widget harness() => _host(
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextButton(
                  onPressed: () => setState(() => index = 1),
                  child: const Text('switch'),
                ),
                Expanded(
                  child: IndexedStack(
                    index: index,
                    children: [
                      const SizedBox.shrink(),
                      InstallPage(deviceLoader: () async => []),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final hidden = tester.widget<DropTarget>(
      find.byType(DropTarget, skipOffstage: false),
    );
    expect(hidden.enable, isFalse, reason: '被盖住时必须关掉，否则一次拖放会被两页同时接住');

    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();

    final shown = tester.widget<DropTarget>(find.byType(DropTarget));
    expect(shown.enable, isTrue);
  });

  // 新页面必须在小窗口下也不溢出。`RenderFlex overflowed` 在测试里是一条
  // 异常，`takeException` 能抓到 —— 这比肉眼看截图可靠，且能在 CI 里跑。
  for (final size in const [Size(1100, 700), Size(760, 520)]) {
    testWidgets('窗口 ${size.width.toInt()}x${size.height.toInt()} 下不溢出',
        (WidgetTester tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(InstallPage(deviceLoader: () async => [])));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
