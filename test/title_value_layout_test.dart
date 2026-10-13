// `TitleValueLayout` 的高度语义。
//
// 这里钉的是一个**真实缺陷**：`SelectableText` 会把 `maxLines` 当成高度预留，
// 只给 `maxLines` 不给 `minLines` 时，一行内容也按 `maxLines` 行高排版。
// 默认「最大行数」是 6，于是 iOS 详情页上「值只有一行」的卡片高 136px ——
// 实际只需要 36px —— 而标题因为交叉轴居中而飘在卡片正中间。
//
// 断言用**相对高度**而不是写死的像素：字体度量会随 Flutter 版本漂移，但
// 「maxLines=6 与 maxLines=1 应当一样高」这个关系不会。另加一条绝对上限，
// 因为相对断言在两边同时退化时可能一起通过。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/title_value_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一行放得下的短值（15 字符 × 14px ≈ 210px，可用宽度约 450px）。
const _shortValue = 'com.example.app';

/// 明确会折成五行的值。
const _fiveLines = 'a\nb\nc\nd\ne';

Future<void> _pump(
  WidgetTester tester,
  String value, {
  int? minLines,
  int? maxLines,
  bool singleLine = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: TitleValueLayout(
                  title: '文件',
                  value: value,
                  minLines: minLines,
                  maxLines: maxLines,
                  singleLine: singleLine,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<double> _height(
  WidgetTester tester,
  String value, {
  int? minLines,
  int? maxLines,
  bool singleLine = false,
}) async {
  await _pump(tester, value,
      minLines: minLines, maxLines: maxLines, singleLine: singleLine);
  return tester.getSize(find.byType(TitleValueLayout)).height;
}

void main() {
  group('TitleValueLayout — maxLines 不得被当成高度预留', () {
    testWidgets('单行值的卡片高度与 maxLines 无关', (tester) async {
      final withOne = await _height(tester, _shortValue, maxLines: 1);
      final withSix = await _height(tester, _shortValue, maxLines: 6);
      final withNone = await _height(tester, _shortValue);

      expect(withSix, withOne, reason: 'maxLines=6 不该让单行卡片变高 —— 变高就说明它在预留行数');
      expect(withNone, withOne);
    });

    testWidgets('单行卡片的高度在一行正文的量级（绝对上限）', (tester) async {
      final height = await _height(tester, _shortValue, maxLines: 6);

      // 一行 14px 正文的行高约 20px，上下各 8px 内边距 ≈ 36px。
      // 上限取 60px 给字体度量留余量；缺陷版本是 136px，绝无可能误判。
      expect(height, lessThan(60),
          reason: '实测 $height px，若接近 136px 说明 maxLines 又在预留行数');
    });

    testWidgets('五行值的卡片高度跟着内容走，而不是钉在 maxLines 上', (tester) async {
      final height = await _height(tester, _fiveLines, maxLines: 6);
      final unlimited = await _height(tester, _fiveLines);

      expect(height, unlimited, reason: '内容没超过上限时，上限不该影响高度');
      expect(height, greaterThan(60), reason: '五行内容应当明显高于单行卡片');
    });

    testWidgets('显式 minLines 超过 maxLines 时被夹紧，而不是断言崩溃', (tester) async {
      // 设置页允许把「最大行数」调小；调用方写死的 minLines 一旦大于它，
      // SelectableText 的 assert(minLines <= maxLines) 会直接抛异常。
      await _pump(tester, _fiveLines, minLines: 9, maxLines: 2);
      expect(tester.takeException(), isNull);

      final clamped =
          await _height(tester, _fiveLines, minLines: 9, maxLines: 2);
      final twoLines = await _height(tester, _fiveLines, maxLines: 2);
      expect(clamped, twoLines, reason: 'minLines 应当被夹到 maxLines');
    });

    testWidgets('maxLines 仍然裁剪超出的行（既有语义，未被这次改动改变）', (tester) async {
      final clipped = await _height(tester, _fiveLines, maxLines: 2);
      final unlimited = await _height(tester, _fiveLines);

      expect(clipped, lessThan(unlimited),
          reason: 'maxLines 是裁剪而不是溢出滚动 —— 详情页据此决定不给长文本设上限');
    });
  });

  group('TitleValueLayout — 对齐', () {
    testWidgets('值有多行时标题贴第一行，而不是垂直居中', (tester) async {
      await _pump(tester, _fiveLines);

      final titleTop = tester.getTopLeft(find.text('文件')).dy;
      final valueTop = tester.getTopLeft(find.byType(SelectableText)).dy;

      // 居中对齐时，标题会被推下去约 (内容高 - 标题高) / 2 ≈ 40px。
      expect((titleTop - valueTop).abs(), lessThan(4),
          reason: '标题顶端应贴住值的第一行；偏移过大说明又回到了居中对齐');
    });

    testWidgets('singleLine 只占一行，长值改为横向滚动', (tester) async {
      final height = await _height(tester, _fiveLines, singleLine: true);
      expect(height, lessThan(60));

      // 横向滚动容器确实存在 —— 否则长值会被裁掉而不是可滚动。
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });
}
