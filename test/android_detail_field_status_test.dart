// Android 详情页的字段状态渲染（缺陷 D5 的回归测试）。
//
// 背景：Android 详情页此前直读 `ApkInfo` 的裸字段并 `?? ""` 兜底 ——
// 「文件里没有」与「我们没读到」渲染成一模一样的空串，而这两件事的结论
// 完全相反（后者意味着结论不可靠）。修复后走统一模型
// （`PackageAnalysisResult.android` 的 `FieldValue`），两者分开显示。

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
  });
}
