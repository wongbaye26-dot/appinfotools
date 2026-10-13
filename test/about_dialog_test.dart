// 关于对话框：**只显示版本号与功能详情**。
//
// 这条要求是「只」—— 因此这里不只用 `showAboutDialog` 的默认外观（它固定带
// 一个「查看开源许可」按钮和一段版权声明的位置），而是逐个断言：
//   1. 版本号在；
//   2. 五条功能说明都在；
//   3. 版权声明与仓库链接**不在**。
//
// 第 3 条是重点：只断言「有」而不断言「没有」，把版权声明删掉这件事就没有
// 任何测试守着，下次有人加回来也不会被发现。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/pages/setting_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 对话框里所有可见文本。
///
/// 版本号用 `SelectableText` 渲染（方便复制），功能说明用 `Text` —— 两种都收，
/// 只收 `Text` 会漏掉版本号，让「版本号在不在」这条断言变成空断言。
String _dialogText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(widget.data ?? '');
  }
  for (final widget
      in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
    buffer.writeln(widget.data ?? '');
  }
  return buffer.toString();
}

Future<void> _openAboutDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(child: const MaterialApp(home: SettingPage())),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text(t.settings.about));
  await tester.pumpAndSettle();

  expect(find.byType(AlertDialog), findsOneWidget, reason: '关于对话框没打开');
}

void main() {
  setUp(() {
    // 生产入口在 `main()` 里调 `PackageInfo.fromPlatform()`；测试直接赋值，
    // 避免依赖平台通道。
    packageInfo = PackageInfo(
      appName: 'APP详情工具',
      packageName: 'com.huanfeng.appinfotool',
      version: '2.0.0',
      buildNumber: '20',
    );
  });

  testWidgets('显示版本号', (tester) async {
    await _openAboutDialog(tester);
    expect(_dialogText(tester), contains('2.0.0'));
  });

  testWidgets('显示全部功能详情', (tester) async {
    await _openAboutDialog(tester);

    final text = _dialogText(tester);
    expect(text, contains(t.settings.features));
    for (final feature in [
      t.about.features.android,
      t.about.features.ios,
      t.about.features.details,
      t.about.features.hash_signature,
      t.about.features.hardening_report,
    ]) {
      expect(text, contains(feature), reason: '缺少功能说明：$feature');
    }
  });

  testWidgets('不再显示版权声明与仓库链接', (tester) async {
    await _openAboutDialog(tester);

    final text = _dialogText(tester);
    expect(text, isNot(contains('github.com')));
    expect(text, isNot(contains('huanfeng')));
    // 版本号以外的装饰性内容也不该有。
    expect(text, isNot(contains('Copyright')));
  });

  testWidgets('只有关闭一个操作', (tester) async {
    await _openAboutDialog(tester);

    // 只看对话框内部 —— 设置页自己也有按钮，不限定范围就会把页面上的算进来。
    final inDialog = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextButton),
    );
    // `showAboutDialog` 会额外挂一个「查看开源许可」按钮；用 AlertDialog
    // 自己搭就不会有。
    expect(inDialog, findsOneWidget);
    expect(find.widgetWithText(TextButton, t.base.close), findsOneWidget);
  });
}
