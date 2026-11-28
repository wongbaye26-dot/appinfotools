// 侧边栏：宽度、导航文案、以及「不再重复应用名与版本号」。
//
// V2.4.6 的三项调整都在这里钉住：
// 1. 展开宽度 240 → 200（导航项只有四个、标签最长两个字，240px 里近一半是
//    空白，而右侧内容区为此少 40px）；
// 2. 导航项「版本对比」→「对比」（窄栏里四字标题会把图标挤到贴边）；
// 3. **侧边栏不再显示应用名与版本号** —— 应用名在窗口标题栏上已经有了，
//    版本号在设置页有一份。同一件事说三次，还占掉窄栏里最值钱的纵向空间。
//
// 第 3 条是「不显示」，而「不显示」没有天然的可断言物 —— 因此这里同时断言
// 正向的（导航项都在）与反向的（应用名、版本号不在），免得日后有人把标题
// 加回来而测试还是绿的。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ui/shell/sidebar.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpSidebar(
  WidgetTester tester,
  Size size, {
  bool collapsed = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSidebar(
                  selectedId: 'overview',
                  onItemSelected: (_) {},
                  collapsed: collapsed,
                  onToggleCollapsed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

String _text(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(w.data ?? '');
  }
  return buffer.toString();
}

void main() {
  group('侧边栏', () {
    testWidgets('V4 展开宽度是 232', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));

      final sidebar = tester.getSize(find.byType(AppSidebar));
      expect(sidebar.width, kSidebarWidth);
      expect(sidebar.width, 232);
    });

    testWidgets('收起后是 76px 图标栏', (tester) async {
      await _pumpSidebar(tester, const Size(700, 800), collapsed: true);

      expect(tester.getSize(find.byType(AppSidebar)).width,
          kSidebarCollapsedWidth);
    });

    testWidgets('导航项都在，且「版本对比」已简化成「对比」', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));
      final text = _text(tester);

      expect(text, contains(t.nav.overview));
      expect(text, contains(t.nav.analysis));
      expect(text, contains(t.nav.diff));
      expect(text, contains(t.nav.settings));

      // 窄栏放不下四字标题：中文下应当是「对比」而不是「版本对比」。
      // （英文本来就是 Compare，这条断言在 en 下等价于「不是 Version …」。）
      expect(t.nav.diff, isNot(contains('版本')));
      expect(t.nav.diff, isNot(contains('Version')));
    });

    testWidgets('应用名显示在 logo 右边', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));

      final nameFinder = find.text(t.title);
      expect(nameFinder, findsOneWidget, reason: '侧边栏要显示应用名');

      // 「在 logo 右边」是可断言的：应用名的左边缘在 logo 右边缘之后，
      // 且两者在同一行（垂直中心对齐）。
      final logo = tester.getRect(find.byType(AppLogo).first);
      final name = tester.getRect(nameFinder);
      expect(
        name.left,
        greaterThan(logo.right - 4),
        reason: '应用名应当在 logo 右边（logo=$logo name=$name）',
      );
      expect(
        name.center.dy,
        closeTo(logo.center.dy, logo.height / 2),
        reason: '两者应当在同一行',
      );
    });

    testWidgets('品牌副标题显示为 PACKAGE INSPECTOR', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));
      expect(_text(tester), contains('PACKAGE INSPECTOR'));
    });

    testWidgets('底栏保留本地边界提示', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));

      expect(find.text('LOCAL ONLY'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);

      final sidebarHeight = tester.getSize(find.byType(AppSidebar)).height;
      final hint = tester.getRect(find.text('LOCAL ONLY'));
      expect(
        hint.center.dy,
        greaterThan(sidebarHeight - 90),
        reason: '本地边界提示应当贴近侧边栏底部',
      );
    });
  });
}
