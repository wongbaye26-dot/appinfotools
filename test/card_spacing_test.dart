// 卡片间距：主题里统一给 12px 垂直节奏。
//
// 以前 `CardThemeData.margin` 是零，而各 Tab 的卡片列表没有分隔条 —— 两张
// 相邻卡片直接贴在一起。间距放在主题里，新增卡片不用再手写 SizedBox；这里
// 钉住「相邻卡片的间距 = 12」，避免以后有人把 margin 改回零。

import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('相邻卡片之间保持 12px 间距', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme:
            buildV4Theme(seed: V4Colors.violet, brightness: Brightness.light),
        home: Scaffold(
          body: ListView(
            children: const [
              Card(child: SizedBox(height: 50)),
              Card(child: SizedBox(height: 50)),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(Card), findsNWidgets(2));

    // 量卡片内容盒：Card 的外边距在主题里，量 Card 本身拿不到那 12px。
    final first = tester.getRect(find.byType(SizedBox).at(0));
    final second = tester.getRect(find.byType(SizedBox).at(1));
    expect(second.top - first.bottom, 12);
  });
}
