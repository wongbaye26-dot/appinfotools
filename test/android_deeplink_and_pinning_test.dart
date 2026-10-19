// 链接入口（deeplink）+ 证书固定（pin-set）。
//
// ## 为什么是这两件
//
// 它们都是「数据已经解析出来了，但报告里看不到」的那一类：
//
// | 数据 | 此前状态 |
// |---|---|
// | `IntentFilterInfo.schemes` | 解析了，只用于判断「是否导出」，从没列出过 scheme |
// | `<pin-set>` | `network_security_config.dart` 整段跳过，`pin` 完全不可见 |
//
// 两者的共同点是**只做事实记录、不做判定**：一个 scheme、一组 pin 本身都不是
// 风险，但缺了它们，读者没法回答「这个应用能被哪些链接唤起」「它有没有做证书固定」。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ApkMeta _meta({List<AndroidComponent> components = const []}) => ApkMeta()
  ..targetSdkVersion = 34
  ..components = List.of(components);

AndroidComponent _component({
  required String name,
  ComponentType type = ComponentType.activity,
  bool? exported = true,
  List<IntentFilterInfo> filters = const [],
}) =>
    AndroidComponent(
      type: type,
      name: name,
      exported: exported,
      hasIntentFilter: filters.isNotEmpty,
      intentFilters: filters,
    );

SecurityFinding? _byId(SecurityAnalysisResult r, String ruleId) {
  for (final f in r.findings) {
    if (f.ruleId == ruleId) return f;
  }
  return null;
}

/// 构造一份带 `<pin-set>` 的网络安全配置文档。
///
/// 用包内的 XML 模型直接构造：`parseNetworkSecurityConfigDocument` 的输入
/// 就是它。二进制 AXML → 文档 那一层由真实夹具
/// （`network_security_config_test.dart`）覆盖，这里只测「文档 → 事实」。
XmlDocument _pinnedDoc() {
  final pinSet = XmlElement()
    ..name = 'pin-set'
    ..attributes = {'expiration': '2027-01-01'}
    ..children = [
      XmlElement()
        ..name = 'pin'
        ..attributes = {'digest': 'SHA-256'}
        ..text = 'AAAA',
      XmlElement()
        ..name = 'pin'
        ..attributes = {'digest': 'SHA-256'}
        ..text = 'BBBB',
    ];
  final domain = XmlElement()
    ..name = 'domain'
    ..attributes = {'includeSubdomains': 'true'}
    ..text = 'api.example.com';
  final domainConfig = XmlElement()
    ..name = 'domain-config'
    ..attributes = {'cleartextTrafficPermitted': 'false'}
    ..children = [domain, pinSet];
  final baseConfig = XmlElement()
    ..name = 'base-config'
    ..attributes = {'cleartextTrafficPermitted': 'false'};
  final root = XmlElement()
    ..name = 'network-security-config'
    ..children = [baseConfig, domainConfig];
  return XmlDocument()..children = [root];
}

XmlDocument _plainDoc() {
  final root = XmlElement()
    ..name = 'network-security-config'
    ..children = [
      XmlElement()
        ..name = 'base-config'
        ..attributes = {'cleartextTrafficPermitted': 'false'},
    ];
  return XmlDocument()..children = [root];
}

void main() {
  group('链接入口（deeplink）', () {
    test('导出组件上的 scheme 被列出，等级是 info（事实而非风险）', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(components: [
          _component(name: 'com.example.Login', filters: const [
            IntentFilterInfo(
              actions: ['android.intent.action.VIEW'],
              categories: ['android.intent.category.BROWSABLE'],
              schemes: ['myapp', 'https'],
            ),
          ]),
        ]),
        dexEntries: const [],
      );

      final finding = _byId(result, 'ANDROID-DEEPLINK')!;
      expect(finding.severity, SecuritySeverity.info);
      expect(finding.messageArgs['count'], 2);
      expect(finding.messageArgs['schemes'], ['https', 'myapp']);
      expect(finding.messageArgs['components'], 1);
      expect(finding.evidence.single.detail, contains('schemes=https, myapp'));
    });

    test('启动页的 MAIN/LAUNCHER 不算链接入口', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(components: [
          _component(name: 'com.example.Main', filters: const [
            IntentFilterInfo(
              actions: ['android.intent.action.MAIN'],
              categories: ['android.intent.category.LAUNCHER'],
              schemes: ['launcher-only'],
            ),
          ]),
        ]),
        dexEntries: const [],
      );
      expect(_byId(result, 'ANDROID-DEEPLINK'), isNull);
    });

    test('未导出的组件上的 scheme 不算（外部唤不起）', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(components: [
          _component(
            name: 'com.example.Internal',
            exported: false,
            filters: const [
              IntentFilterInfo(
                actions: ['android.intent.action.VIEW'],
                schemes: ['internal'],
              ),
            ],
          ),
        ]),
        dexEntries: const [],
      );
      expect(_byId(result, 'ANDROID-DEEPLINK'), isNull);
    });
  });

  group('证书固定（pin-set）', () {
    test('pin-set 被解析出来：域名、条数、算法、过期时间', () {
      final parsed = parseNetworkSecurityConfigDocument(
        _pinnedDoc(),
        path: 'res/xml/nsc.xml',
      );
      expect(parsed.pinSets, hasLength(1));
      final set = parsed.pinSets.single;
      expect(set.domain, 'api.example.com');
      expect(set.pinCount, 2);
      expect(set.digests, ['SHA-256']);
      expect(set.expiration, '2027-01-01');
      // 明文判定不受影响。
      expect(parsed.allowsCleartext, isFalse);
    });

    test('有 pin-set 时报一条 info，证据里带条数与过期时间', () {
      final meta = _meta()
        ..networkSecurityConfigInfo = parseNetworkSecurityConfigDocument(
          _pinnedDoc(),
          path: 'res/xml/nsc.xml',
        );
      final result =
          AndroidSecurityAudit.audit(meta: meta, dexEntries: const []);

      final finding = _byId(result, 'ANDROID-CERT-PINNING')!;
      expect(finding.severity, SecuritySeverity.info);
      expect(finding.messageArgs['count'], 1);
      expect(finding.messageArgs['domains'], ['api.example.com']);
      expect(finding.evidence.single.detail, contains('2 pin(s)'));
      expect(finding.evidence.single.detail, contains('2027-01-01'));
    });

    test('没有 pin-set 时不报（不做「未配置」的告警）', () {
      final meta = _meta()
        ..networkSecurityConfigInfo = parseNetworkSecurityConfigDocument(
          _plainDoc(),
          path: 'res/xml/nsc.xml',
        );
      final result =
          AndroidSecurityAudit.audit(meta: meta, dexEntries: const []);
      expect(_byId(result, 'ANDROID-CERT-PINNING'), isNull);
    });
  });
}
