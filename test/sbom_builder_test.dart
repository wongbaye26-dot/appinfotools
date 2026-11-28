import 'dart:convert';

import 'package:apk_info_tool/utils/sbom_builder.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

LibCheckerRule _rule(int id, String name, String label) => LibCheckerRule(
      id: id,
      name: name,
      label: label,
      type: LibCheckerRuleType.native,
      iconId: null,
      simpleColorIcon: false,
      isRegex: false,
      detailIndex: -1,
      priority: id,
    );

LibraryGroup _group(LibCheckerRule rule, {int hits = 1}) {
  final group = LibraryGroup(
    label: rule.label,
    iconId: null,
    simpleColorIcon: false,
    rule: rule,
  );
  for (var i = 0; i < hits; i++) {
    group.hits.add(
      LibraryHit(
        kind: LibraryHitKind.nativeLibrary,
        name: 'lib$i.so',
        source: LibraryMatchSource.exact,
      ),
    );
  }
  return group;
}

void main() {
  test('CycloneDX：应用组件 + 库组件 + 稳定序列号', () {
    final report = LibraryReport(
      dataVersion: 50,
      nativeGroups: [_group(_rule(1, 'libflutter.so', 'Flutter'), hits: 2)],
      componentGroups: const [],
      dexGroups: const [],
      unmatchedNative: const [],
      dexPackages: const [],
      dexClasses: 0,
      dexTruncated: false,
      kotlin: false,
      compose: false,
    );

    final components = SbomBuilder.fromLibraryReport(report);
    expect(components, hasLength(1));
    expect(components.single.name, 'Flutter');
    expect(components.single.properties['appinfotool:ruleId'], '1');
    expect(components.single.properties['appinfotool:hitCount'], '2');

    final bom = SbomBuilder.buildCycloneDx(
      appName: 'Demo',
      appVersion: '1.2.3',
      packageName: 'com.example.demo',
      packageSha256: 'abc123',
      components: components,
      timestamp: DateTime.utc(2026, 11, 28),
    );
    expect(bom['bomFormat'], 'CycloneDX');
    expect(bom['specVersion'], '1.5');
    expect(bom['serialNumber'], startsWith('urn:uuid:'));
    final list = bom['components'] as List<dynamic>;
    expect(list, hasLength(1));
    final lib = list.single as Map<String, dynamic>;
    expect(lib['type'], 'library');
    expect(lib['name'], 'Flutter');
    expect(lib['purl'], 'pkg:generic/Flutter');
    expect(
      (lib['properties'] as List).length,
      3,
    );

    // 同样输入 → 同样序列号（便于跨次比对同一份清单）。
    final again = SbomBuilder.buildCycloneDx(
      appName: 'Demo',
      appVersion: '1.2.3',
      packageName: 'com.example.demo',
      packageSha256: 'abc123',
      components: components,
      timestamp: DateTime.utc(2027, 1, 1),
    );
    expect(again['serialNumber'], bom['serialNumber']);

    // 必须是合法 JSON。
    expect(() => jsonDecode(SbomBuilder.toJsonString(bom)), returnsNormally);
  });

  test('非 ASCII 名称按 RFC3986 编码进 purl', () {
    final bom = SbomBuilder.buildCycloneDx(
      appName: '示例',
      packageName: 'com.example.demo',
      components: const [
        SbomComponent(name: '信鸽推送', purl: null),
      ],
    );
    final lib = (bom['components'] as List).single as Map<String, dynamic>;
    expect(lib['purl'], 'pkg:generic/%E4%BF%A1%E9%B8%BD%E6%8E%A8%E9%80%81');
  });

  test('没有库识别时是空组件数组，而不是缺键', () {
    final bom =
        SbomBuilder.buildCycloneDx(appName: 'Demo', components: const []);
    expect(bom['components'], isEmpty);
  });
}
