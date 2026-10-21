// 拖放的归属与高亮状态机。
//
// 两条缺陷在这里被钉住：
//
// 1. **一次拖放触发两次解析。** `AppShell` 用 `IndexedStack` 承载概览页与
//    分析页，两页同时在树里、布局尺寸完全重叠，而 `desktop_drop` 的通道
//    是全局扇出的 —— 每个 `DropTarget` 各自按渲染盒判「是否在界内」，
//    重叠的盒子全都判定为在界内。于是拖一个文件到概览页会同时触发
//    概览页的 `pendingOpenRequest` 和分析页自己的 `openApk`，同一个文件
//    被两条流水线解析两遍。修法是让不可见的那一页把 target 关掉
//    （`desktop_drop` 的文档就是这么要求的）。
//
// 2. **拖拽高亮可能永远擦不掉。** 熄灭原本只依赖 `onDragExited`，而这个
//    回调并不保证送达。现在有看门狗兜底。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/home_page.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/pages/install_page.dart';
import 'package:apk_info_tool/pages/setting_page.dart';
import 'package:apk_info_tool/ui/overview/overview_page.dart';
import 'package:apk_info_tool/ui/shell/app_shell.dart';
import 'package:apk_info_tool/ui/shell/sidebar.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// `DropEventDetails` 的构造器不是 const，因此这里只能 final。
final _zero =
    DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero);

/// 概览页的拖拽高亮载体 —— 它是整页最外层那个 `Container(color:)`。
Color _overlayColor(WidgetTester tester) {
  final boxes = tester.widgetList<ColoredBox>(
    find.descendant(
      of: find.byType(OverviewPage),
      matching: find.byType(ColoredBox),
    ),
  );
  return boxes.first.color;
}

/// 找出 `owner` 子树里的 `DropTarget`，返回它的 `enable`。
/// 找不到时返回 `null`。
bool? _enabledOf(WidgetTester tester, Type owner) {
  final found = find.descendant(
    of: find.byType(owner, skipOffstage: false),
    matching: find.byType(DropTarget, skipOffstage: false),
  );
  final widgets = tester.widgetList<DropTarget>(found);
  return widgets.isEmpty ? null : widgets.first.enable;
}

Future<void> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: const MaterialApp(home: AppShell()),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tapNav(WidgetTester tester, String label) async {
  // 侧栏在展开/收叠两种形态下都会渲染标签，`find.text` 会同时命中两个，
  // `tap` 因此拒绝执行。限定在侧栏里并取第一个。
  await tester.tap(
    find
        .descendant(of: find.byType(AppSidebar), matching: find.text(label))
        .first,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('拖放归属：同一时刻只有一个页面接收拖放', () {
    testWidgets('落地页（概览）只有概览页的 target 开着', (tester) async {
      await _pumpShell(tester);

      expect(_enabledOf(tester, OverviewPage), isTrue);
      expect(
        _enabledOf(tester, APKInfoPage),
        isFalse,
        reason: '分析页被概览页盖住，必须关掉它的 target —— 否则一次拖放会被解析两遍',
      );
      // 安装页也有拖放区（拖入 APK 直接装）。它同样必须默认关着。
      //
      // 这里**不切到安装页**去断言「开着」：切过去会触发一次真实的
      // `adb devices`，而 `Process.start` 在 widget 测试的 fake-async 区里
      // 会留下永不完成的 Timer（详见 install_page 的 `didChangeDependencies`）。
      // 「可见时开着」由 `install_page_lifecycle_test.dart` 单独覆盖。
      expect(
        _enabledOf(tester, InstallPage),
        isFalse,
        reason: '安装页被概览页盖住，同样必须关掉 target',
      );
    });

    testWidgets('切到分析页后只有分析页的 target 开着', (tester) async {
      await _pumpShell(tester);
      await _tapNav(tester, t.nav.analysis);

      expect(_enabledOf(tester, APKInfoPage), isTrue);
      expect(_enabledOf(tester, OverviewPage), isFalse);
    });

    testWidgets('切到设置页后两个 target 都关掉', (tester) async {
      await _pumpShell(tester);
      await _tapNav(tester, t.nav.settings);

      expect(_enabledOf(tester, OverviewPage), isFalse);
      expect(_enabledOf(tester, APKInfoPage), isFalse);
      // 设置页自己没有拖放区 —— 顺带钉住，免得以后误加一个重叠的。
      expect(_enabledOf(tester, SettingPage), isNull);
      // `HomePage` 是分析页的外壳，里面就是 `APKInfoPage`，因此它也有一个
      // target —— 这里要断言的是它同样被关掉了。
      expect(_enabledOf(tester, HomePage), isFalse);
    });

    testWidgets('来回切换后归属仍然正确（不会两边都开着）', (tester) async {
      await _pumpShell(tester);
      await _tapNav(tester, t.nav.analysis);
      await _tapNav(tester, t.nav.overview);
      await _tapNav(tester, t.nav.analysis);

      expect(_enabledOf(tester, APKInfoPage), isTrue);
      expect(_enabledOf(tester, OverviewPage), isFalse);
    });
  });

  group('拖拽高亮', () {
    testWidgets('进入拖拽时高亮，退出后复原', (tester) async {
      await _pumpShell(tester);
      final idle = _overlayColor(tester);

      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      target.onDragEntered!(_zero);
      await tester.pump();
      final highlighted = _overlayColor(tester);
      expect(highlighted, isNot(idle), reason: '进入拖拽应当有可见的高亮');

      target.onDragExited!(_zero);
      await tester.pump();
      expect(_overlayColor(tester), idle);
    });

    testWidgets('拖放完成后高亮必须复原', (tester) async {
      await _pumpShell(tester);
      final idle = _overlayColor(tester);

      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      target.onDragEntered!(_zero);
      await tester.pump();
      expect(_overlayColor(tester), isNot(idle));

      // 拖入不支持的类型：走的是「弹提示 + 复位」这条路，不会碰解析。
      target.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile('/tmp/not-a-package.txt')],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(_overlayColor(tester), idle);
    });

    testWidgets('平台不送 onDragExited 时，看门狗会熄灭高亮', (tester) async {
      await _pumpShell(tester);
      final idle = _overlayColor(tester);

      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      target.onDragEntered!(_zero);
      await tester.pump();
      expect(_overlayColor(tester), isNot(idle));

      // 之后再也不送任何事件 —— 模拟拖放被系统取消、`onDragExited` 丢失。
      // 高亮必须在看门狗超时后自己熄灭，而不是永久留着。
      await tester.pump(const Duration(seconds: 6));
      expect(
        _overlayColor(tester),
        idle,
        reason: '拖拽事件流停止后高亮必须自愈，否则界面上会留一层擦不掉的浮层',
      );
    });

    testWidgets('拖拽期间的心跳会推迟看门狗，不会误熄', (tester) async {
      await _pumpShell(tester);
      final idle = _overlayColor(tester);

      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      target.onDragEntered!(_zero);
      await tester.pump();

      // 持续 3 秒的心跳（真实拖拽期间 macOS 会一直发 draggingUpdated）。
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
        target.onDragUpdated!(_zero);
        await tester.pump();
      }
      expect(
        _overlayColor(tester),
        isNot(idle),
        reason: '有事件流就说明拖拽还在进行，高亮不该熄',
      );

      // 停止心跳后仍能自愈。
      await tester.pump(const Duration(seconds: 6));
      expect(_overlayColor(tester), idle);
    });
  });
}
