import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/report_extras.dart';
import 'package:flutter_test/flutter_test.dart';

SecretMatch _match() => SecretMatch(
      id: 'v1:0123456789abcdef0123456789abcdef',
      ruleId: 'aws-access-key',
      kind: SecretKind.awsAccessKey,
      redactedValue: 'AKIA…MPLE',
      valueSha256: 'a1b2c3d4e5f60718',
      location: 'assets/config.json',
      contextRedacted: 'aws: "AKIA…MPLE"',
      confidence: SecretConfidence.high,
      extractorId: SecretScanner.extractorId,
    );

void main() {
  final t = AppLocale.en.buildSync();

  PackageAnalysisResult result() => PackageAnalysisResult(
        fileName: const FieldValue<String>.extracted(
          'demo.apk',
          source: FieldSource.fileSystem,
        ),
        fileSize: const FieldValue<int>.extracted(
          1024,
          source: FieldSource.fileSystem,
        ),
        platform: PackagePlatform.android,
        android: null,
        ios: null,
        diagnostics: const [],
      );

  test('schema v12：JSON 写入 secrets，且只有脱敏值', () {
    final json = AnalysisReport.renderJson(
      result(),
      t: t,
      generatedAt: DateTime.utc(2026, 11, 28),
      extras: ReportExtras(secrets: [_match()]),
    );
    final map = jsonDecode(json) as Map<String, dynamic>;
    expect(map['reportSchemaVersion'], 12);
    final secrets = map['secrets'] as List<dynamic>;
    expect(secrets, hasLength(1));
    final entry = secrets.single as Map<String, dynamic>;
    expect(entry['redactedValue'], 'AKIA…MPLE');
    expect(entry['fingerprint'], startsWith('v1:'));
    expect(entry['valueSha256'], 'a1b2c3d4e5f60718');
    // 明文绝不出现（报告会被导出、归档、发给别人）。
    expect(json, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
  });

  test('没有 secrets 时整个键不出现（而不是空数组）', () {
    final json = AnalysisReport.renderJson(
      result(),
      t: t,
      generatedAt: DateTime.utc(2026, 11, 28),
    );
    expect(json, isNot(contains('"secrets"')));
  });

  test('Markdown 小节包含脱敏表与启发式声明', () {
    final markdown = AnalysisReport.render(
      result(),
      t,
      generatedAt: DateTime.utc(2026, 11, 28),
      extras: ReportExtras(secrets: [_match()]),
    );
    expect(markdown, contains('## ${t.secrets.title}'));
    expect(markdown, contains('AKIA…MPLE'));
    expect(markdown, contains(t.secrets.heuristic_note));
    expect(markdown, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
  });
}
