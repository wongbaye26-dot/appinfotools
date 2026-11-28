import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v11 报告契约与常量版本一致', () {
    expect(AnalysisReport.reportSchemaVersion, 11);
    final schema = jsonDecode(
      File('docs/contracts/analysis-report-v11.schema.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final props = schema['properties'] as Map<String, dynamic>;
    expect(
      (props['reportSchemaVersion'] as Map<String, dynamic>)['const'],
      11,
    );
    expect(props.containsKey('analysisRun'), isTrue);
    expect(props.containsKey('findings'), isTrue);
    expect(props.containsKey('security'), isTrue);
    // v10 新增：权限分级与库识别（均可选，未采集时不出现）
    expect(props.containsKey('libraries'), isTrue);
    final application = props['application'] as Map<String, dynamic>;
    expect(
      (application['properties'] as Map<String, dynamic>)
          .containsKey('permissionDetails'),
      isTrue,
    );
    final defs = schema[r'$defs'] as Map<String, dynamic>;
    expect(defs.containsKey('evidenceId'), isTrue);
    expect(defs.containsKey('analysisRun'), isTrue);
    expect(defs.containsKey('evidence'), isTrue);
    expect(defs.containsKey('libraryGroup'), isTrue);
    // v11 新增：包内证书事实（可选键，null 不出现）
    expect(props.containsKey('signatureSummary'), isTrue);
    expect(defs.containsKey('certificate'), isTrue);
  });
}
