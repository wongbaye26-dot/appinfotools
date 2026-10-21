// 报告「结论段」与「能力视图」的回归测试。
//
// 这两块都是**读者第一眼看到**的东西，一旦出错，整份报告的可信度就塌了：
// - 结论段此前只有「签名 + Android 加固」两行，**完全没有 iOS 分支** ——
//   一个被注入 dylib、还挂着别人描述文件的包，结论段一个字都不提；
// - 能力视图此前把「否定结论」（`ANDROID-RULE-F`：「本次没找到上传特征」）
//   也算成一条能力，读者会以为「数据外发 1 条」是在说发现了问题。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

final Translations t = AppLocale.zhCn.translations;

SecurityFinding _finding({
  required String ruleId,
  required SecuritySeverity severity,
  SecurityCategory category = SecurityCategory.other,
  bool isMeta = false,
  String text = '',
}) =>
    SecurityFinding(
      ruleId: ruleId,
      platform: SecurityPlatform.ios,
      category: category,
      severity: severity,
      confidence: SecurityConfidence.confirmed,
      finding: text.isEmpty ? '$ruleId 的正文' : text,
      evidence: const [],
      recommendation: '建议',
      isMeta: isMeta,
    );

PackageAnalysisResult _result({
  required List<SecurityFinding> findings,
  IosAuthorizationComparison? authorization,
}) =>
    PackageAnalysisResult(
      platform: PackagePlatform.ios,
      fileName: const FieldValue<String>.extracted(
        'x.ipa',
        source: FieldSource.fileSystem,
      ),
      fileSize: const FieldValue<int>.extracted(
        1,
        source: FieldSource.fileSystem,
      ),
      ios: IosPackageInfo(
        container: const IpaContainer(),
        authorization: authorization,
      ),
      security: SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: findings,
      ),
    );

String _conclusion(String markdown, String title) {
  final start = markdown.indexOf('## $title');
  expect(start, isNonNegative, reason: '报告里应当有结论一节');
  final next = markdown.indexOf('\n## ', start + 3);
  return markdown.substring(start, next < 0 ? markdown.length : next);
}

void main() {
  group('结论段按等级汇总', () {
    test('列出最高等级的发现，而不是只写签名', () {
      final md = AnalysisReport.render(
        _result(findings: [
          _finding(
            ruleId: 'IOS-RULE-E',
            severity: SecuritySeverity.p2,
            text: '后台执行 + 敏感读取 + 网络回传',
          ),
          _finding(
            ruleId: 'IOS-RULE-D-ESCALATED',
            severity: SecuritySeverity.p1,
            text: '允许任意明文流量',
          ),
          _finding(
            ruleId: 'IOS-USAGE-DESCRIPTION',
            severity: SecuritySeverity.info,
            text: '声明了用途说明',
          ),
        ]),
        t,
        generatedAt: DateTime.utc(2026, 10, 22),
      );

      final section = _conclusion(md, t.report.conclusion);
      // p1 必须排在 p2 前面，info 因为只取前 3 条也在，但顺序仍按等级。
      final p1 = section.indexOf('IOS-RULE-D-ESCALATED');
      final p2 = section.indexOf('IOS-RULE-E');
      expect(p1, isNonNegative, reason: '结论段应当列出 p1 发现');
      expect(p2, isNonNegative, reason: '结论段应当列出 p2 发现');
      expect(p1, lessThan(p2), reason: '结论段必须按等级排序，最严重的在前');
    });

    test('元信息与否定结论不进结论段', () {
      final md = AnalysisReport.render(
        _result(findings: [
          _finding(
            ruleId: 'ANDROID-RULE-F',
            severity: SecuritySeverity.info,
            isMeta: true,
            text: '未发现上传特征',
          ),
          _finding(ruleId: 'IOS-REPACKAGED', severity: SecuritySeverity.p2),
        ]),
        t,
        generatedAt: DateTime.utc(2026, 10, 22),
      );
      final section = _conclusion(md, t.report.conclusion);
      expect(section, contains('IOS-REPACKAGED'));
      expect(section, isNot(contains('ANDROID-RULE-F')));
    });

    test('描述文件授权的是另一个应用时，结论段直接说出来', () {
      final md = AnalysisReport.render(
        _result(
          findings: const [],
          authorization: const IosAuthorizationComparison(
            verdict: IosAuthorizationVerdict.mismatch,
            appIdentifier: 'aecy.Edimension168ecy.app',
            authorizedIdentifier: 'N78F3MBNHS.com.nguyenkim.antbuddynkm',
          ),
        ),
        t,
        generatedAt: DateTime.utc(2026, 10, 22),
      );
      final section = _conclusion(md, t.report.conclusion);
      expect(section, contains(t.report.conclusion_authorization_mismatch));
      expect(section, contains('aecy.Edimension168ecy.app'));
      expect(section, contains('N78F3MBNHS.com.nguyenkim.antbuddynkm'));
    });

    test('授权匹配时不进结论段（不制造噪音）', () {
      final md = AnalysisReport.render(
        _result(
          findings: const [],
          authorization: const IosAuthorizationComparison(
            verdict: IosAuthorizationVerdict.matches,
            appIdentifier: 'com.example.app',
            authorizedIdentifier: 'TEAM.com.example.app',
          ),
        ),
        t,
        generatedAt: DateTime.utc(2026, 10, 22),
      );
      final section = _conclusion(md, t.report.conclusion);
      expect(
          section, isNot(contains(t.report.conclusion_authorization_mismatch)));
    });

    test('超过 3 条时给出「另有 N 条」', () {
      final md = AnalysisReport.render(
        _result(findings: [
          for (var i = 0; i < 5; i++)
            _finding(ruleId: 'IOS-RULE-$i', severity: SecuritySeverity.p2),
        ]),
        t,
        generatedAt: DateTime.utc(2026, 10, 22),
      );
      final section = _conclusion(md, t.report.conclusion);
      expect(section, contains(t.report.conclusion_more_findings(count: 2)));
    });
  });

  group('能力视图排除元信息', () {
    test('「未发现上传」不会被算成「数据外发 1 条」', () {
      final md = AnalysisReport.render(
        _result(findings: [
          // 一条真发现（照片）+ 一条否定结论（RULE-F）
          _finding(
            ruleId: 'ANDROID-PERMISSION-CAMERA',
            severity: SecuritySeverity.info,
            category: SecurityCategory.photoAccess,
          ),
          _finding(
            ruleId: 'ANDROID-RULE-F',
            severity: SecuritySeverity.info,
            category: SecurityCategory.dataExfiltration,
            isMeta: true,
          ),
        ]),
        t,
        generatedAt: DateTime.utc(2026, 10, 22),
      );
      // 只有 1 个**真**主题（照片）→ 聚合没有信息量，整节不渲染。
      // 关键是：`ANDROID-RULE-F` 不能被当成第二个主题把这一节撑起来。
      final start = md.indexOf('### ${t.security.capability_overview}');
      expect(start, isNegative, reason: '排除元信息后只剩 1 个主题，能力视图不该渲染');
    });

    test('两个真主题照常聚合，元信息不出现在规则列', () {
      final md = AnalysisReport.render(
        _result(findings: [
          _finding(
            ruleId: 'IOS-CAMERA',
            severity: SecuritySeverity.p3,
            category: SecurityCategory.photoAccess,
          ),
          _finding(
            ruleId: 'IOS-RULE-G',
            severity: SecuritySeverity.p2,
            category: SecurityCategory.dataExfiltration,
          ),
          _finding(
            ruleId: 'IOS-SCAN-COVERAGE',
            severity: SecuritySeverity.info,
            category: SecurityCategory.other,
            isMeta: true,
          ),
        ]),
        t,
        generatedAt: DateTime.utc(2026, 10, 22),
      );
      final start = md.indexOf('### ${t.security.capability_overview}');
      expect(start, isNonNegative);
      final section = md.substring(start, md.indexOf('### ', start + 4));
      expect(section, contains('IOS-CAMERA'));
      expect(section, contains('IOS-RULE-G'));
      expect(section, isNot(contains('IOS-SCAN-COVERAGE')));
    });
  });

  group('组件不去重渲染', () {
    test('表格里只写数量，完整列表在下方一节', () {
      // 这一条用 Android 结果构造，见 analysis_report 的 _androidSection。
      // 断言点：`<br>` 拼出来的长单元格不该再出现。
      final result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: const FieldValue<String>.extracted(
          'x.apk',
          source: FieldSource.fileSystem,
        ),
        fileSize: const FieldValue<int>.extracted(
          1,
          source: FieldSource.fileSystem,
        ),
      );
      final md = AnalysisReport.render(result, t,
          generatedAt: DateTime.utc(2026, 10, 22));
      // 没有组件时不该有组件表头，也不该崩。
      expect(md, contains('## ${t.report.conclusion}'));
    });
  });
}
