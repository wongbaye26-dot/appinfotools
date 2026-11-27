// 证据中心：稳定 ID、去重后的证据列表与“查看全部”弹层。
import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/security_evidence_center.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) =>
    TranslationProvider(child: MaterialApp(home: Scaffold(body: child)));

const _a = SecurityEvidence(
  source: SecurityEvidenceSource.dexString,
  location: 'classes.dex / Lfoo/Bar;',
  detail: 'https://example.test/collect',
);
const _b = SecurityEvidence(
  source: SecurityEvidenceSource.manifest,
  location: 'AndroidManifest.xml / uses-permission',
  detail: 'android.permission.READ_SMS',
);

void main() {
  setUp(() => LocaleSettings.setLocaleRaw('en'));

  testWidgets('渲染证据数量、稳定 ID 与来源', (tester) async {
    await tester.pumpWidget(
        _wrap(const SecurityEvidenceCenterCard(evidence: [_a, _b])));
    expect(find.text(t.security.evidence_center_title), findsOneWidget);
    expect(
        find.text(t.security.evidence_center_count(count: 2)), findsOneWidget);
    expect(find.text(_a.evidenceId), findsOneWidget);
    expect(find.text(_b.evidenceId), findsOneWidget);
  });

  testWidgets('超过 4 条时打开全部证据弹层', (tester) async {
    final evidence = List.generate(
      6,
      (i) => SecurityEvidence(
        source: SecurityEvidenceSource.dexString,
        location: 'classes$i.dex',
        detail: 'evidence-$i',
      ),
    );
    await tester
        .pumpWidget(_wrap(SecurityEvidenceCenterCard(evidence: evidence)));
    expect(find.text(t.security.evidence_center_view_all), findsOneWidget);
    await tester.tap(find.text(t.security.evidence_center_view_all));
    await tester.pumpAndSettle();
    expect(find.text(t.security.evidence_center_close), findsOneWidget);
    expect(find.text('evidence-5'), findsOneWidget);
  });
}
