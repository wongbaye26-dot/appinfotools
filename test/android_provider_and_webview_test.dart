// ContentProvider 专项 + WebView 配置组合（2026-10-19 审计 §13）。
//
// ## 为什么 provider 要单独一条
//
// 此前 provider 混在「导出组件」的汇总里：抖音有 159 个导出组件，provider
// 排在第一但淹没在长列表里，而且读者看不到**暴露的是哪个 authority**、
// 有没有 `grantUriPermissions`、`readPermission` / `writePermission` 是不是
// 只护住了一个方向。这三件事恰恰决定了数据能不能被拿走。
//
// ## 为什么 WebView 要分两档
//
// 单有 JS 桥是 P3（验证码 / 统计 / 分享 SDK 普遍这么干，见 `_buildWebViewBridge`
// 的样本表）。但桥 + `file://` 跨域访问同开时，加载进来的任何页面都能读本地
// 文件并调用被注入的对象 —— 那是完整的外传通路，P3 明显偏低。
//
// 顺带钉住一个本地化 bug：开关列表原来是以英文句子直接拼进 `finding` 的，
// 中文界面上会出现「Also observed: JavaScript enabled」。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _blob(List<String> strings) {
  final parts = <int>[];
  for (final s in strings) {
    parts.addAll(s.codeUnits);
    parts.add(0);
  }
  return Uint8List.fromList(parts);
}

ApkMeta _meta({
  List<AndroidComponent> components = const [],
  List<AndroidDeclaredPermission> declared = const [],
}) =>
    ApkMeta()
      ..targetSdkVersion = 34
      ..components = List.of(components)
      ..declaredPermissions = List.of(declared);

SecurityAnalysisResult _audit(
  ApkMeta meta, {
  List<String> dexStrings = const [],
}) =>
    AndroidSecurityAudit.audit(
      meta: meta,
      dexEntries: [
        if (dexStrings.isNotEmpty) DexBytes('classes.dex', _blob(dexStrings)),
      ],
    );

AndroidComponent _provider({
  required String authorities,
  bool? exported = true,
  String? permission,
  String? readPermission,
  String? writePermission,
  bool? grantUri,
}) =>
    AndroidComponent(
      type: ComponentType.provider,
      name: 'com.example.$authorities',
      exported: exported,
      permission: permission,
      readPermission: readPermission,
      writePermission: writePermission,
      grantUriPermissions: grantUri,
      authorities: authorities,
    );

SecurityFinding? _byId(SecurityAnalysisResult r, String ruleId) {
  for (final f in r.findings) {
    if (f.ruleId == ruleId) return f;
  }
  return null;
}

void main() {
  group('ContentProvider 暴露面', () {
    test('导出且无权限 → P2，正文点名 authority，并从「导出组件」汇总里移除', () {
      final result = _audit(_meta(components: [
        _provider(authorities: 'com.example.files'),
      ]));

      final finding = _byId(result, 'ANDROID-PROVIDER-EXPOSED');
      expect(finding, isNotNull);
      expect(finding!.severity, SecuritySeverity.p2);
      expect(finding.messageArgs['count'], 1);
      expect(finding.messageArgs['names'], ['com.example.files']);
      expect(finding.evidence.single.detail, contains('com.example.files'));

      // 同一条 provider 不能又在「导出组件」里出现一次。
      final generic = _byId(result, 'ANDROID-EXPORTED-COMPONENT');
      expect(generic, isNull, reason: 'provider 已由专项规则负责');
    });

    test('read + write 权限都声明 → 不算暴露', () {
      final result = _audit(_meta(components: [
        _provider(
          authorities: 'com.example.safe',
          readPermission: 'com.example.permission.READ',
          writePermission: 'com.example.permission.WRITE',
        ),
      ]));
      expect(_byId(result, 'ANDROID-PROVIDER-EXPOSED'), isNull);
    });

    test('只声明 readPermission → 半开，带 partial 标记', () {
      final result = _audit(_meta(components: [
        _provider(
          authorities: 'com.example.half',
          readPermission: 'com.example.permission.READ',
        ),
      ]));
      final finding = _byId(result, 'ANDROID-PROVIDER-EXPOSED')!;
      expect(finding.messageArgs['partial'], isTrue);
      expect(
        AnalysisReport.findingText(finding, t),
        isNotEmpty,
      );
    });

    test('grantUriPermissions → 正文说明「能把单个 URI 授出去」', () {
      final result = _audit(_meta(components: [
        _provider(authorities: 'com.example.grant', grantUri: true),
      ]));
      final finding = _byId(result, 'ANDROID-PROVIDER-EXPOSED')!;
      expect(finding.messageArgs['grantUri'], isTrue);
      expect(
          finding.evidence.single.detail, contains('grantUriPermissions=true'));
    });

    test('exported=false 的 provider 不报', () {
      final result = _audit(_meta(components: [
        _provider(authorities: 'com.example.internal', exported: false),
      ]));
      expect(_byId(result, 'ANDROID-PROVIDER-EXPOSED'), isNull);
    });
  });

  group('WebView 配置组合', () {
    test('只有 JS 桥 → P3（第三方 SDK 普遍如此）', () {
      final result = _audit(_meta(), dexStrings: ['addJavascriptInterface']);
      final finding = _byId(result, 'ANDROID-WEBVIEW-BRIDGE')!;
      expect(finding.severity, SecuritySeverity.p3);
      expect(finding.messageCode, 'android.webview_bridge');
    });

    test('桥 + universal access → 升 P2，用「外传通路」措辞', () {
      final result = _audit(_meta(), dexStrings: [
        'addJavascriptInterface',
        'setAllowUniversalAccessFromFileURLs'
      ]);
      final finding = _byId(result, 'ANDROID-WEBVIEW-BRIDGE')!;
      expect(finding.severity, SecuritySeverity.p2);
      expect(finding.messageCode, 'android.webview_bridge_unsafe');
      expect(finding.confidence, SecurityConfidence.suspected);
    });

    test('桥 + setAllowFileAccessFromFileURLs 也算组合（另一个开关）', () {
      final result = _audit(_meta(), dexStrings: [
        'addJavascriptInterface',
        'setAllowFileAccessFromFileURLs'
      ]);
      final finding = _byId(result, 'ANDROID-WEBVIEW-BRIDGE')!;
      expect(finding.severity, SecuritySeverity.p2);
      expect(finding.messageCode, 'android.webview_bridge_unsafe');
    });

    test('中文界面下开关列表是中文，不夹 "Also observed"', () async {
      await LocaleSettings.setLocaleRaw('zh-CN');
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      final result = _audit(_meta(), dexStrings: [
        'addJavascriptInterface',
        'setJavaScriptEnabled',
        'setAllowUniversalAccessFromFileURLs',
      ]);
      final finding = _byId(result, 'ANDROID-WEBVIEW-BRIDGE')!;
      final text = AnalysisReport.findingText(finding, t);

      expect(text, contains('同时观察到'));
      expect(text, contains('JavaScript 已启用'));
      expect(text, isNot(contains('Also observed')));
      expect(text, isNot(contains('{')), reason: '不能留占位符');
    });
  });
}
