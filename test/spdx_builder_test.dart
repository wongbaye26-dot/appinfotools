import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/utils/spdx_builder.dart';
import 'package:flutter_test/flutter_test.dart';

Component _component({String? version}) => Component.create(
      name: 'Flutter',
      version: version,
      ecosystem: ComponentEcosystem.generic,
      platform: ComponentPlatform.android,
      identification: ComponentIdentificationMethod.ruleMatch,
      confidence: ComponentConfidence.low,
    );

void main() {
  test('SPDX 2.3：文档头、应用包与组件包、CONTAINS 关系', () {
    final doc = SpdxBuilder.build(
      appName: 'Demo',
      appVersion: '1.2.3',
      packageName: 'com.example.demo',
      packageSha256: 'abc123',
      components: [_component()],
      timestamp: DateTime.utc(2026, 11, 28),
    );

    expect(doc['spdxVersion'], 'SPDX-2.3');
    expect(doc['dataLicense'], 'CC0-1.0');
    expect(doc['SPDXID'], 'SPDXRef-DOCUMENT');
    final creation = doc['creationInfo'] as Map<String, dynamic>;
    expect(creation['created'], '2026-11-28T00:00:00.000Z');
    expect(creation['creators'], ['Tool: AppInfoTool']);

    final packages = doc['packages'] as List<dynamic>;
    expect(packages, hasLength(2));
    final app = packages.first as Map<String, dynamic>;
    expect(app['SPDXID'], 'SPDXRef-Application');
    expect(app['filesAnalyzed'], isFalse);
    expect(app['licenseConcluded'], 'NOASSERTION');
    expect(app['checksums'], [
      {'algorithm': 'SHA256', 'checksumValue': 'abc123'},
    ]);

    final lib = packages.last as Map<String, dynamic>;
    expect(lib['name'], 'Flutter');
    expect(lib['SPDXID'], startsWith('SPDXRef-cmp-'));
    // 没有版本就不写 versionInfo（不编 unknown）。
    expect(lib.containsKey('versionInfo'), isFalse);
    expect(
      (lib['externalRefs'] as List).single['referenceLocator'],
      'pkg:generic/Flutter?platform=android',
    );

    final relationships = doc['relationships'] as List<dynamic>;
    expect(relationships, hasLength(2));
    expect(relationships.first['relationshipType'], 'DESCRIBES');
    expect(relationships.last['relationshipType'], 'CONTAINS');

    expect(() => jsonDecode(SpdxBuilder.toJsonString(doc)), returnsNormally);
  });

  test('SPDXID 唯一：同名不同版本的组件不会撞 id', () {
    final doc = SpdxBuilder.build(
      appName: 'Demo',
      components: [_component(version: '1.0'), _component(version: '2.0')],
    );
    final ids = (doc['packages'] as List)
        .map((p) => (p as Map<String, dynamic>)['SPDXID'])
        .toList();
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('documentNamespace 对同一输入稳定', () {
    final a = SpdxBuilder.build(appName: 'Demo', components: const []);
    final b = SpdxBuilder.build(appName: 'Demo', components: const []);
    expect(a['documentNamespace'], b['documentNamespace']);
    expect(
        a['documentNamespace'], startsWith('https://appinfotool.local/spdx/'));
  });
}
