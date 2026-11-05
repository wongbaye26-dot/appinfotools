import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('LoadGraph', () {
    const node = LoadNode(
      id: 'artifact:classes.dex',
      kind: LoadNodeKind.dex,
      resolvedPath: 'classes.dex',
      presentInPackage: true,
    );
    const missing = LoadNode(
      id: 'runtime:payload.dex',
      kind: LoadNodeKind.missing,
      presentInPackage: false,
    );
    const edge = LoadEdge(
      fromId: 'artifact:classes.dex',
      toId: 'runtime:payload.dex',
      kind: LoadEdgeKind.dexClassLoader,
      source: SecurityEvidenceSource.loadGraph,
      location: 'Lcom/a/Loader;.run()V @0x12',
    );

    test('danglingEdgeIds 表达目标不在包内', () {
      const graph = LoadGraph(
        nodes: [node, missing],
        edges: [edge],
        danglingEdgeIds: ['artifact:classes.dex->runtime:payload.dex'],
        complete: false,
      );
      expect(graph.hasDanglingEdges, isTrue);
      expect(graph.complete, isFalse);
      expect(graph.edges.single.source, SecurityEvidenceSource.loadGraph);
    });

    test('node/edgesFrom 按 id 查找', () {
      const graph = LoadGraph(nodes: [node, missing], edges: [edge]);
      expect(graph.node('artifact:classes.dex')?.presentInPackage, isTrue);
      expect(graph.node('nope'), isNull);
      expect(graph.edgesFrom('artifact:classes.dex').single, edge);
      expect(graph.edgesFrom('runtime:payload.dex'), isEmpty);
    });

    test('空图不等于 complete=false（空是事实，complete 是覆盖状态）', () {
      const graph = LoadGraph();
      expect(graph.isEmpty, isTrue);
      expect(graph.complete, isTrue);
      expect(graph.hasDanglingEdges, isFalse);
    });

    test('LoadEdge.id 稳定拼接', () {
      expect(edge.id, 'artifact:classes.dex->runtime:payload.dex');
    });
  });

  group('SecurityFinding.blindSpots', () {
    SecurityFinding make({List<String> blindSpots = const []}) =>
        SecurityFinding(
          ruleId: 'TEST-RULE',
          platform: SecurityPlatform.android,
          category: SecurityCategory.cryptoAsset,
          severity: SecuritySeverity.p2,
          confidence: SecurityConfidence.suspected,
          finding: 'test',
          evidence: const [
            SecurityEvidence(
              source: SecurityEvidenceSource.dexString,
              location: 'classes.dex',
              detail: 'x',
            ),
            SecurityEvidence(
              source: SecurityEvidenceSource.dexString,
              location: 'classes.dex',
              detail: 'x',
            ),
          ],
          recommendation: 'review',
          blindSpots: blindSpots,
        );

    test('默认空列表；去重后仍然保留', () {
      expect(make().blindSpots, isEmpty);
      final deduped = make(blindSpots: ['dexPartial', 'nativePacked'])
          .withDedupedEvidence();
      expect(deduped.evidence, hasLength(1));
      expect(deduped.blindSpots, ['dexPartial', 'nativePacked']);
    });

    test('去重不丢 isMeta', () {
      final finding = SecurityFinding(
        ruleId: 'TEST-META',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: 'meta',
        evidence: const [
          SecurityEvidence(
            source: SecurityEvidenceSource.infoPlist,
            location: 'Info.plist',
            detail: 'x',
          ),
          SecurityEvidence(
            source: SecurityEvidenceSource.infoPlist,
            location: 'Info.plist',
            detail: 'x',
          ),
        ],
        recommendation: 'none',
        isMeta: true,
      );
      expect(finding.withDedupedEvidence().isMeta, isTrue);
    });
  });
}
