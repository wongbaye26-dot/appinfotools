import 'package:apk_info_tool/utils/component_catalog.dart';
import 'package:analysis_model/analysis_model.dart';
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

LibraryReport _report() => LibraryReport(
      dataVersion: 50,
      nativeGroups: [_group(_rule(1, 'libflutter.so', 'Flutter'), hits: 2)],
      componentGroups: [_group(_rule(2, 'com.example.X', 'Example SDK'))],
      dexGroups: const [],
      unmatchedNative: const [],
      dexPackages: const [],
      dexClasses: 0,
      dexTruncated: false,
      kotlin: false,
      compose: false,
    );

void main() {
  test('库识别 → Component：身份稳定、置信度为 low、带规则证据', () {
    final components = ComponentCatalog.fromLibraryReport(
      _report(),
      artifactPath: 'demo.apk',
    );
    expect(components, hasLength(2));

    final flutter = components.first;
    expect(flutter.name, 'Flutter');
    expect(flutter.id, startsWith('cmp_'));
    expect(flutter.purl, 'pkg:generic/Flutter?platform=android');
    expect(flutter.platform, ComponentPlatform.android);
    expect(flutter.identification, ComponentIdentificationMethod.ruleMatch);
    expect(flutter.confidence, ComponentConfidence.low);
    expect(flutter.sourceArtifacts, ['demo.apk']);
    expect(flutter.sourceDatabaseVersion, 'libchecker-v50');
    expect(
      flutter.relations[ComponentRelationType.evidencedBy],
      ['libchecker:rule:1'],
    );

    // 同一输入必须得到同一身份：后续 F06 靠它把结论挂到组件上。
    final again = ComponentCatalog.fromLibraryReport(
      _report(),
      artifactPath: 'demo.apk',
    );
    expect(
        again.map((c) => c.id).toList(), components.map((c) => c.id).toList());
  });

  test('没有库识别结果时是空列表，不编造组件', () {
    expect(ComponentCatalog.fromLibraryReport(null), isEmpty);
  });
}
