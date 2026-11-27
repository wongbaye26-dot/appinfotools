import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v9 报告契约与常量版本一致', () {
    expect(AnalysisReport.reportSchemaVersion, 9);
    final schema = jsonDecode(
      File('docs/contracts/analysis-report-v9.schema.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final props = schema['properties'] as Map<String, dynamic>;
    expect(
      (props['reportSchemaVersion'] as Map<String, dynamic>)['const'],
      9,
    );
    expect(props.containsKey('analysisRun'), isTrue);
    expect(props.containsKey('findings'), isTrue);
    expect(props.containsKey('security'), isTrue);
    final defs = schema[r'$defs'] as Map<String, dynamic>;
    expect(defs.containsKey('evidenceId'), isTrue);
    expect(defs.containsKey('analysisRun'), isTrue);
    expect(defs.containsKey('evidence'), isTrue);
  });
}
