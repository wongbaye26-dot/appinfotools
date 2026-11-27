// 结构化证据卡片：制品清单 / 加载链。
//
// 数据模型本身有测试；这里钉住的是「真的渲染出来、并明确标出截断/不完整」。
// 这两项以前只参与内部链判定，报告里恒为 null，用户无法核对结论背后的范围。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/security_evidence_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUp(() => LocaleSettings.setLocaleRaw('en'));

  testWidgets('渲染制品清单与加载链，并标出截断/不完整', (tester) async {
    await tester.pumpWidget(_wrap(const SecurityEvidenceCard(
      artifacts: ArtifactInventory(
        entries: [
          ArtifactEntry(
            path: 'classes.dex',
            kind: ArtifactKind.dex,
            sizeBytes: 1024,
          ),
        ],
        totalEntries: 9,
        inventoriedEntries: 1,
        entriesComplete: false,
        skippedCodes: ['inventory.entries_truncated'],
      ),
      loadGraph: LoadGraph(
        nodes: [
          LoadNode(
            id: 'classes.dex',
            kind: LoadNodeKind.dex,
            presentInPackage: true,
          ),
        ],
        danglingEdgeIds: ['classes.dex->libmissing.so'],
        complete: false,
      ),
    )));

    expect(find.text(t.security.evidence_title), findsOneWidget);
    expect(find.textContaining('1 security-relevant artifact'), findsOneWidget);
    expect(find.text(t.security.evidence_artifacts_truncated), findsOneWidget);
    expect(find.textContaining('1 node(s), 0 edge(s)'), findsOneWidget);
    expect(
        find.text(t.security.evidence_load_graph_incomplete), findsOneWidget);
    expect(find.textContaining('1 edge(s) point outside'), findsOneWidget);
  });

  testWidgets('两项都为空时不渲染空卡，避免暗示「查过了」', (tester) async {
    await tester.pumpWidget(_wrap(const SecurityEvidenceCard()));
    expect(find.byType(Card), findsNothing);
  });
}
