// Android 详情页的字段状态渲染（缺陷 D5 / B4 的回归测试）。
//
// 背景：Android 详情页此前直读 `ApkInfo` 的裸字段、用空字符串兜底 ——
// 「文件里没有」与「我们没读到」渲染成一模一样的空串，而这两件事的结论
// 完全相反（后者意味着结论不可靠）。修复后走统一模型
// （`PackageAnalysisResult.android` 的 `FieldValue`），两者分开显示。
//
// 最后一组是**约定守卫**：这一轮把剩下 12 个字段也迁进 `FieldValue`
// （B4），验收条件写明「全库 `grep '?? ""'` 在详情页为 0」—— 把这条约定
// 钉成测试，免得以后又有人顺手用空串兜底。

import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 页面上所有可见文本（`Text` + `SelectableText`）。
String visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(w.data ?? '');
  }
  for (final w in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    buffer.writeln(w.data ?? '');
  }
  return buffer.toString();
}

Future<void> pumpAndroidPage(WidgetTester tester, ApkInfo info) async {
  // 详情页是一个长列表，默认 800×600 的视口只构建可见的几张卡。
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentFileStateProvider.notifier).update(
        FileState(filePath: '/tmp/Example.apk', fileSize: 1024, apkInfo: info),
      );
  container.read(currentApkInfoProvider.notifier).update(info);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        // 与真实树一致：`APKInfoPage` 在 `HomePage` 的 Scaffold 里。
        child: const MaterialApp(home: Scaffold(body: APKInfoPage())),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('Android 详情页的字段状态', () {
    testWidgets('来源不报的字段显示状态与原因，而不是空串', (tester) async {
      // `aapt2` 来源**不报** maxSdkVersion / debuggable —— 这属于
      // 「我们没读到」，必须与「文件里没有」区分开。
      final info = ApkInfo()
        ..packageName = 'com.example'
        ..label = '示例'
        ..manifestSource = FieldSource.aapt2;

      await pumpAndroidPage(tester, info);
      final text = visibleText(tester);

      expect(
        text,
        contains('[unsupported]'),
        reason: 'aapt2 不报的字段应显示 [unsupported] 并带原因，而不是留空',
      );
      expect(
        text,
        contains(t.apk_info.max_sdk),
        reason: '「我们没读到」的字段必须显示出来 —— 不显示就等于说文件里没有',
      );
    });

    testWidgets('字段确实有值时正常显示数值', (tester) async {
      final info = ApkInfo()
        ..packageName = 'com.example'
        ..label = '示例'
        ..sdkVersion = 21
        ..targetSdkVersion = 34
        ..manifestSource = FieldSource.builtinParser;

      await pumpAndroidPage(tester, info);
      final text = visibleText(tester);

      expect(text, contains('21'));
      expect(text, contains('34'));
      expect(text, isNot(contains('[unsupported]')));
    });

    testWidgets('这一轮新迁的字段在来源不报时也显示状态，而不是空串', (tester) async {
      // `unknown` 来源对**所有**字段都不在能力表里 —— 因此这一轮迁过来的
      // 字段（版本号 / 版本名 / 屏幕 / 密度 / ABI / 语言 / 权限）都应是
      // `[unsupported]`，而不是留白。
      final info = ApkInfo()..manifestSource = FieldSource.unknown;

      await pumpAndroidPage(tester, info);
      final text = visibleText(tester);

      for (final label in [
        t.apk_info.version_code,
        t.apk_info.version_name,
        t.apk_info.screen_size,
        t.apk_info.screen_density,
        t.apk_info.abi,
        t.apk_info.languages,
      ]) {
        expect(text, contains(label), reason: '$label 的卡片必须显示出来');
      }
      expect(
        '[unsupported]'.allMatches(text).length,
        greaterThanOrEqualTo(7),
        reason: '每个「没读到」的字段都要带状态，不能只显示标题',
      );
    });

    testWidgets('文件里确实没有的字段不显示卡片', (tester) async {
      // 内置解析器**会报** maxSdkVersion，没值就是真的没声明 → absent。
      final info = ApkInfo()
        ..packageName = 'com.example'
        ..label = '示例'
        ..sdkVersion = 21
        ..manifestSource = FieldSource.builtinParser;

      await pumpAndroidPage(tester, info);
      final text = visibleText(tester);

      // absent 时整张卡片不渲染。
      expect(
        text,
        isNot(contains(t.apk_info.max_sdk)),
        reason: '文件里确实没有的字段不必占一张卡片',
      );
    });

    test('约定守卫：详情页不再用空串兜底字段值', () {
      // B4 的验收条件就是这条 grep。它值得钉成测试而不是写在文档里 ——
      // `?? ""` 正是「把『没读到』渲染成『没有』」的写法，加回来会让上面
      // 那几条行为测试悄悄失效（空串也是「有内容」，`contains` 照样过）。
      final source = File('lib/pages/info_page.dart').readAsStringSync();
      expect(
        source.contains(r'?? ""'),
        isFalse,
        reason: '字段值不要用空串兜底：走 FieldValue，或在确实拿不到时用 "-"',
      );
    });
  });
}
