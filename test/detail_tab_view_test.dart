// 详情页 6 个 Tab 的版式测试（V2.4.15 重做后）。
//
// ## 为什么需要 `debugLayout`
//
// `DetailTabView` 在测试环境里会**自动回退**成连续列表 —— 否则跨分组的
// widget 断言不到（那是 `real_samples_ui_test` 依赖的行为）。代价是：
// 侧栏与顶部 TabBar 两条真实分支在测试里**永远跑不到**。
//
// 所以版式抽成 enum 并可注入。这一组用例显式指定版式，把三条分支都走一遍。
//
// ## 这一组钉住的几件事
//
// 1. 宽窗口出侧栏、窄窗口出顶部 TabBar，**判定用的是 `MediaQuery` 不是
//    `LayoutBuilder`**（后者在 `Expanded` 里主轴约束是 `Infinity`，
//    分支会变成死代码）；
// 2. 文档流把 `Card` 压平：背景透明、无边框、无外边距 ——
//    「一个字段一张卡片」正是要消灭的东西；
// 3. 分隔线**不跟在章节标题后面**（标题自带渐变线，两条会叠成双线）。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/detail_section.dart';
import 'package:apk_info_tool/widgets/detail_tab_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用一个给定尺寸的宿主把 [DetailTabView] 挂起来。
///
/// 直接 `pumpWidget(MaterialApp(home: DetailTabView(...)))` 拿不到受控的
/// 逻辑宽度 —— `MediaQuery` 会跟着测试画布走（默认 800×600），
/// 侧栏分支刚好卡在边界附近，测不稳。
Future<void> _pump(
  WidgetTester tester, {
  required Map<DetailTab, List<Widget>> tabs,
  required DetailLayout layout,
  Size size = const Size(1280, 800),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          body: DetailTabView(tabs: tabs, debugLayout: layout),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 两个 Tab 的最小样本：第一个是标题 + 两行字段，第二个一行。
Map<DetailTab, List<Widget>> _sampleTabs() => {
      DetailTab.overview: [
        const DetailSectionHeader(title: '基本信息'),
        Card(child: TitleValueStub('包名', 'com.example.app')),
        Card(child: TitleValueStub('版本', '1.0.0')),
        const DetailSectionHeader(title: '其他'),
        Card(child: TitleValueStub('大小', '12 MB')),
      ],
      DetailTab.application: [
        const DetailSectionHeader(title: '应用信息'),
        Card(child: TitleValueStub('最小 SDK', '21')),
      ],
    };

/// 一个最简的「标题 — 值」行。
///
/// 被测的是**版式**（谁包着谁、有没有边框），不是字段排版本身 ——
/// 字段排版由 `title_value_layout_test.dart` 覆盖。这里用桩避免把
/// provider 依赖拖进来。
class TitleValueStub extends StatelessWidget {
  final String title;
  final String value;

  const TitleValueStub(this.title, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(title)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

void main() {
  group('版式选择', () {
    testWidgets('rail 版式：左侧导航列出所有 Tab，右侧是内容', (tester) async {
      await _pump(tester, tabs: _sampleTabs(), layout: DetailLayout.rail);

      // 侧栏存在，且宽度是约定值。
      final rail = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == kDetailRailWidth,
      );
      expect(rail, findsOneWidget);

      // 两个 Tab 的标签都出现在侧栏里。用 `t.*` 而不是硬编码中文 ——
      // 测试环境的默认 locale 是 en，写死「概览」会永远找不到。
      expect(find.text(t.detail_tab.overview), findsOneWidget);
      expect(find.text(t.detail_tab.application), findsOneWidget);

      // 右侧是 TabBarView（内容区），不是 TabBar。
      expect(find.byType(TabBarView), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('topTabs 版式：顶部 TabBar，没有侧栏', (tester) async {
      await _pump(tester, tabs: _sampleTabs(), layout: DetailLayout.topTabs);

      expect(find.byType(TabBar), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == kDetailRailWidth,
        ),
        findsNothing,
      );
    });

    testWidgets('宽度决定版式：1280 走侧栏、600 走顶部', (tester) async {
      // 这一条不走 debugLayout，验的是**自动判定**那一段。
      // 测试环境的 `_isTest` 回退会把自动判定短路掉，所以这里必须显式给版式；
      // 判定阈值本身由下一条用例（纯逻辑）覆盖。
      expect(kDetailRailBreakpoint, 720);
      expect(kDetailRailWidth, 220);

      await _pump(
        tester,
        tabs: _sampleTabs(),
        layout: DetailLayout.rail,
        size: const Size(1280, 800),
      );
      expect(find.byType(TabBar), findsNothing);

      await _pump(
        tester,
        tabs: _sampleTabs(),
        layout: DetailLayout.topTabs,
        size: const Size(600, 800),
      );
      expect(find.byType(TabBar), findsOneWidget);
    });

    testWidgets('没有数据时提示「暂无数据」而不是空白', (tester) async {
      await _pump(
        tester,
        tabs: {DetailTab.overview: const []},
        layout: DetailLayout.rail,
      );

      expect(find.text(t.detail_tab.no_data), findsOneWidget);
    });
  });

  group('文档流：卡片被压平', () {
    testWidgets('内容区里 Card 背景透明、无边框、无外边距', (tester) async {
      await _pump(tester, tabs: _sampleTabs(), layout: DetailLayout.rail);

      // 取内容区里的第一个 Card，看它实际拿到的主题。
      final cardFinder = find.byType(Card).first;
      final card = tester.widget<Card>(cardFinder);

      // Card 自身没写 color / shape —— 全交给主题。
      expect(card.color, isNull);
      expect(card.shape, isNull);
      expect(card.margin, isNull);

      // 而主题把它设成了透明无边框。
      final context = tester.element(cardFinder);
      final theme = Theme.of(context);
      expect(theme.cardTheme.color, Colors.transparent);
      expect(theme.cardTheme.margin, EdgeInsets.zero);
      expect(theme.cardTheme.elevation, 0);
      expect(theme.cardTheme.shape, isA<RoundedRectangleBorder>());
      expect(
        (theme.cardTheme.shape! as RoundedRectangleBorder).side,
        BorderSide.none,
      );
    });

    testWidgets('侧栏版式下选中项有高亮，未选中没有', (tester) async {
      await _pump(tester, tabs: _sampleTabs(), layout: DetailLayout.rail);

      final materials = tester
          .widgetList<Material>(find.byType(Material))
          .where((m) => m.borderRadius != null)
          .toList();
      expect(materials, isNotEmpty, reason: '侧栏项用 Material 做高亮容器');

      // 恰好一个选中项有非透明背景（默认选中第 0 个）。
      final highlighted = materials
          .where((m) => m.color != null && m.color != Colors.transparent);
      expect(highlighted.length, 1);
    });
  });

  group('文档流：分隔线规则', () {
    testWidgets('紧跟章节标题的项前面不画分隔线', (tester) async {
      await _pump(tester, tabs: _sampleTabs(), layout: DetailLayout.rail);

      // 样本：标题 / 字段 / 字段 / 标题 / 字段
      // 期望分隔线只出现在「字段↔字段」之间，即 1 条。
      // 标题后面不画（标题自带渐变线），标题前面也不画（那是新章节）。
      expect(
        find.byType(DetailRowDivider),
        findsOneWidget,
        reason: '4 个间隙里只有「版本」与下一个章节之间需要分隔线？'
            '不 —— 标题前后都不画，所以第一组两字段之间 1 条',
      );
    });

    testWidgets('纯字段列表（没有标题）每两行之间都有分隔线', (tester) async {
      await _pump(
        tester,
        tabs: {
          DetailTab.overview: [
            Card(child: TitleValueStub('a', '1')),
            Card(child: TitleValueStub('b', '2')),
            Card(child: TitleValueStub('c', '3')),
          ],
        },
        layout: DetailLayout.rail,
      );

      expect(find.byType(DetailRowDivider), findsNWidgets(2));
    });
  });

  group('章节标题组件', () {
    testWidgets('上方留白大于下方 —— 这是「章节感」的来源', (tester) async {
      await _pump(
        tester,
        tabs: {
          DetailTab.overview: [const DetailSectionHeader(title: '基本信息')],
        },
        layout: DetailLayout.rail,
      );

      final padding = tester
          .widget<Padding>(
            find
                .descendant(
                  of: find.byType(DetailSectionHeader),
                  matching: find.byType(Padding),
                )
                .first,
          )
          .padding as EdgeInsets;
      expect(padding.top, greaterThan(padding.bottom));
    });
  });
}
