// 详情卡片的标题样式：**不换行**、宽度有下限、与设置页预览一致。
//
// 背景（V2.4.8 用户报告）：分析页四个 Tab 里的标题被逐字折断成
// `uiMod` / `e 设备` / `类型`。根因是标题列宽度用的是设置里存的
// `title_width`，而滑块下限只有 40 —— 在那个宽度下，一个 16px 的中文标签
// 连一个字都放不下，Flutter 只能硬折。
//
// 这一组钉三件事：
// 1. 宽度被夹到 `kMinDetailTitleWidth` 以上（旧配置存的是 40 也不会折断）；
// 2. 标题单行（超出就省略号 + tooltip，不再折行）；
// 3. 设置页预览用的是**同一个**样式函数（否则预览是另一套字体）。

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/title_value_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 挂一个单独的 `TitleValueLayout`。
///
/// [configuredWidth] 是「设置里存下来的值」；`null` 表示用默认（100）。
Future<void> _pump(
  WidgetTester tester,
  String title, {
  double? configuredWidth,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (configuredWidth != null) 'title_width': configuredWidth,
  });
  await Config.init();
  await Config.loadConfig();

  final container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: Card(
                child: TitleValueLayout(title: title, value: 'watch'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('标题宽度', () {
    test('下限足以放下一个六字中文标签', () {
      // 12px 的 `bodySmall` × 6 个汉字 ≈ 72px；96 留了余量。
      expect(kMinDetailTitleWidth, greaterThanOrEqualTo(72));
      expect(kMaxDetailTitleWidth, greaterThan(kMinDetailTitleWidth));
    });

    testWidgets('旧配置存的是 40 也不会把标题挤成一条竖线', (tester) async {
      await _pump(tester, 'uiMode 设备类型', configuredWidth: 40);

      final size = tester.getSize(find.text('uiMode 设备类型'));
      expect(
        size.width,
        kMinDetailTitleWidth,
        reason: '宽度应当被夹到下限（实测 ${size.width}）',
      );
    });

    testWidgets('配置值在区间内时按配置走', (tester) async {
      await _pump(tester, 'ABI', configuredWidth: 150);
      expect(tester.getSize(find.text('ABI')).width, 150);
    });

    testWidgets('配置值超过上限时按上限走', (tester) async {
      await _pump(tester, 'ABI', configuredWidth: 400);
      expect(tester.getSize(find.text('ABI')).width, kMaxDetailTitleWidth);
    });
  });

  group('标题不换行', () {
    testWidgets('长标签被省略号截断，仍然只占一行', (tester) async {
      // 故意用一个长到放不下的标题。
      const title = 'uiMode 设备类型（夜间模式资源变体）';
      await _pump(tester, title, configuredWidth: kMinDetailTitleWidth);

      final size = tester.getSize(find.text(title));
      // 单行 `bodySmall` 约 16px；折成两行就会翻倍。
      expect(
        size.height,
        lessThan(30),
        reason: '标题必须单行（实测高 ${size.height}px）',
      );
      expect(size.width, kMinDetailTitleWidth);
    });

    testWidgets('标题给了 tooltip，截断后仍能看到全文', (tester) async {
      const title = 'uiMode 设备类型（夜间模式资源变体）';
      await _pump(tester, title, configuredWidth: kMinDetailTitleWidth);

      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(of: find.text(title), matching: find.byType(Tooltip))
            .first,
      );
      expect(tooltip.message, title);
    });
  });

  testWidgets('标题样式与设置页预览是同一份（淡色小字，不是 16px 正文）', (tester) async {
    await _pump(tester, 'ABI');

    final context = tester.element(find.text('ABI'));
    final expected = detailTitleStyle(context);
    final actual = tester.widget<Text>(find.text('ABI')).style;

    expect(actual?.fontSize, expected.fontSize);
    expect(actual?.color, expected.color);
    expect(actual?.fontWeight, expected.fontWeight);
    // 与值同色同字号是旧版的样子 —— 那样分不出哪个是标签。
    expect(actual?.fontSize, isNot(16));
  });
}
