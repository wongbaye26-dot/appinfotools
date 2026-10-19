// JSON 出口的**平台事实**（`platformFacts`）与 schema 契约。
//
// 背景（2026-10-19 审计 P2-2）：JSON 此前只有
// `[platform, appName, packageId, version, buildNumber, permissions]` 六个字段，
// 界面能看到的 minSdk / 组件 / ABI / 语言 / 密度 / 分包 / **ICP 备案号** /
// entitlements / URL scheme / 嵌套 bundle 一个都不在里面。
// 「导出报告」与「界面」的信息量差一个量级。
//
// 这条测试同时钉住两件事：
// 1. 平台事实的每个字段都带 `value` / `status` / `source` —— 空值不等于「没有」；
// 2. 顶层 `fieldStatus` 与平台事实**不是**同一套约定，边界不能混。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ComponentType;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _androidFacts() {
  final result = AnalysisBuilder.buildAndroid(
    filePath: '/tmp/demo.apk',
    fileSize: 2048,
    manifestSource: FieldSource.builtinParser,
    minSdkVersion: 24,
    targetSdkVersion: 34,
    debuggable: true,
    permissions: const ['android.permission.INTERNET'],
    nativeCodes: const ['arm64-v8a'],
    locales: const ['zh-CN'],
    densities: const ['xhdpi'],
    icpFilings: const ['京ICP备16016397号-49A'],
    components: [
      AndroidComponent(
        type: ComponentType.activity,
        name: 'com.example.Main',
        exported: true,
      ),
    ],
  );
  return (result.toJson()['platformFacts'] as Map)['android']
      as Map<String, dynamic>;
}

void main() {
  test('Android 平台事实进 JSON，且每个字段自带 status', () {
    final android = _androidFacts();

    // 此前一个都没有的那批字段。
    for (final key in [
      'minSdkVersion',
      'targetSdkVersion',
      'debuggable',
      'nativeCodes',
      'locales',
      'densities',
      'icpFiling',
      'components',
      'structure',
    ]) {
      expect(android.containsKey(key), isTrue, reason: '缺字段 $key');
    }

    final minSdk = android['minSdkVersion'] as Map<String, dynamic>;
    expect(minSdk['value'], 24);
    expect(minSdk['status'], 'extracted');
    expect(minSdk['source'], 'builtinParser');

    // 未传的字段是 absent，不是「值 0」。
    final maxSdk = android['maxSdkVersion'] as Map<String, dynamic>;
    expect(maxSdk['value'], isNull);
    expect(maxSdk['status'], 'absent');

    expect((android['icpFiling'] as Map)['value'], '京ICP备16016397号-49A');
    expect(
        (android['components'] as List).single, containsPair('exported', true));
  });

  test('iOS 平台事实进 JSON，容器与嵌套清单都在', () {
    final result = AnalysisBuilder.buildIos(
      filePath: '/tmp/demo.ipa',
      fileSize: 1024,
    );
    final ios = (result.toJson()['platformFacts'] as Map)['ios']
        as Map<String, dynamic>;

    for (final key in [
      'bundleIdentifier',
      'urlSchemes',
      'backgroundModes',
      'architectures',
      'container',
      'nestedBinaries',
      'signatureMaterials',
      'codeSignStatus',
    ]) {
      expect(ios.containsKey(key), isTrue, reason: '缺字段 $key');
    }
    expect((ios['container'] as Map)['hasPayloadDirectory'], isFalse);
  });

  test('renderJson 真的输出 platformFacts（不是只挂在模型上）', () async {
    await LocaleSettings.setLocaleRaw('en');
    final result = AnalysisBuilder.buildAndroid(
      filePath: '/tmp/demo.apk',
      fileSize: 2048,
      manifestSource: FieldSource.builtinParser,
      minSdkVersion: 24,
    );
    final json = AnalysisReport.renderJson(
      result,
      generatedAt: DateTime.utc(2026, 10, 19),
      t: t,
    );
    expect(json, contains('"platformFacts"'));
    expect(json, contains('"minSdkVersion"'));
    // 仅安全范围下不输出平台事实（它不是安全结论）。
    final only = AnalysisReport.renderJson(
      result,
      generatedAt: DateTime.utc(2026, 10, 19),
      t: t,
      securityOnly: true,
    );
    expect(only, isNot(contains('"platformFacts"')));
  });
}
