// 安全检测引擎（V1.1）应用层集成测试。
//
// 覆盖：
// - AnalysisBuilder 把 security 挂到 PackageAnalysisResult 上；
// - FileState.analysis 从 apkInfo / FileState 读取 securityResult；
// - AnalysisReport 渲染安全章节与 JSON；
// - 设置开关关闭时 securityResult 被清空。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

final _at = DateTime.utc(2026, 10, 14, 12, 0, 0);

void main() {
  group('SecurityIntegration — PackageAnalysisResult 挂载 security', () {
    test('AnalysisBuilder.buildAndroid 把 security 传入结果', () {
      const security = SecurityAnalysisResult(
        engineVersion: 'android-security-1.1.0',
        rulesVersion: 'android-rules-2026.10.1',
        findings: [
          SecurityFinding(
            ruleId: 'ANDROID-RULE-A',
            platform: SecurityPlatform.android,
            category: SecurityCategory.photoAccess,
            severity: SecuritySeverity.p2,
            confidence: SecurityConfidence.suspected,
            finding: 'found broad storage access',
            evidence: [
              SecurityEvidence(
                source: SecurityEvidenceSource.manifest,
                location: 'AndroidManifest.xml',
                detail: 'READ_EXTERNAL_STORAGE',
              ),
            ],
            recommendation: 'manual review recommended',
          ),
        ],
        limitations: ['DEX budget: skipped 1 file'],
      );

      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/test.apk',
        fileSize: 1024,
        manifestSource: FieldSource.builtinParser,
        security: security,
      );

      expect(result.security, same(security));
      expect(result.security!.findings, hasLength(1));
      expect(result.security!.findings.first.ruleId, 'ANDROID-RULE-A');
    });

    test('AnalysisBuilder.buildIos 把 security 传入结果', () {
      const security = SecurityAnalysisResult(
        engineVersion: 'ios-security-1.1.0',
        rulesVersion: 'ios-privacy-2026.10.1',
        findings: [],
        limitations: [],
      );

      final result = AnalysisBuilder.buildIos(
        filePath: '/tmp/test.ipa',
        fileSize: 1024,
        security: security,
      );

      expect(result.security, same(security));
    });

    test('默认构造的 PackageAnalysisResult security 为 null', () {
      const result = PackageAnalysisResult();
      expect(result.security, isNull);
    });
  });

  group('SecurityIntegration — AnalysisReport 安全章节', () {
    test('security 为 null 时报告不出现安全章节', () {
      final report = AnalysisReport.render(
        const PackageAnalysisResult(),
        t,
        generatedAt: _at,
      );

      expect(report, isNot(contains('## ${t.security.title}')));
    });

    test('有发现项时报告列出规则、等级与证据', () {
      const result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: FieldValue<String>.extracted('test.apk',
            source: FieldSource.fileSystem),
        security: SecurityAnalysisResult(
          engineVersion: 'test',
          rulesVersion: 'test',
          findings: [
            SecurityFinding(
              ruleId: 'ANDROID-RULE-B',
              platform: SecurityPlatform.android,
              category: SecurityCategory.ocrImage,
              severity: SecuritySeverity.p2,
              confidence: SecurityConfidence.suspected,
              finding: 'photo + OCR detected',
              evidence: [
                SecurityEvidence(
                  source: SecurityEvidenceSource.dexString,
                  location: 'classes.dex',
                  detail: 'Tesseract',
                ),
              ],
              recommendation: 'review photo usage',
            ),
          ],
          limitations: [],
        ),
      );

      final report = AnalysisReport.render(result, t, generatedAt: _at);

      expect(report, contains('## ${t.security.title}'));
      expect(report, contains('ANDROID-RULE-B'));
      expect(report, contains('p2'));
      expect(report, contains('photo + OCR detected'));
      expect(report, contains('Tesseract'));
      expect(report, contains('review photo usage'));
    });

    test('发现项标签是本地化的「发现项」，不是翻译对象本身', () {
      // 回归：B11 第一批把新映射命名成 `finding_texts` 时，报告里的标签
      // 曾误写成 `t.security.finding_texts` —— 那是个翻译**对象**，
      // 插值进 Markdown 会渲染成 `Instance of '...'`。
      const result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: FieldValue<String>.extracted('test.apk',
            source: FieldSource.fileSystem),
        security: SecurityAnalysisResult(
          engineVersion: 'test',
          rulesVersion: 'test',
          findings: [
            SecurityFinding(
              ruleId: 'ANDROID-RULE-A',
              platform: SecurityPlatform.android,
              category: SecurityCategory.other,
              severity: SecuritySeverity.info,
              confidence: SecurityConfidence.confirmed,
              finding: 'placeholder',
              evidence: [],
              recommendation: 'review',
            ),
          ],
          limitations: [],
        ),
      );

      final report = AnalysisReport.render(result, t, generatedAt: _at);

      expect(report, contains('- **${t.security.findings}:** placeholder'));
      expect(report, isNot(contains('Instance of')));
    });

    test('无发现项时报告明确说明', () {
      const result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: FieldValue<String>.extracted('test.apk',
            source: FieldSource.fileSystem),
        security: SecurityAnalysisResult(
          engineVersion: 'test',
          rulesVersion: 'test',
          findings: [],
          limitations: [],
        ),
      );

      final report = AnalysisReport.render(result, t, generatedAt: _at);

      expect(report, contains('## ${t.security.title}'));
      expect(report, contains(t.security.no_findings));
    });

    test('覆盖不足时单独列出局限', () {
      const result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: FieldValue<String>.extracted('test.apk',
            source: FieldSource.fileSystem),
        security: SecurityAnalysisResult(
          engineVersion: 'test',
          rulesVersion: 'test',
          findings: [],
          limitations: ['DEX budget exceeded'],
        ),
      );

      final report = AnalysisReport.render(result, t, generatedAt: _at);

      expect(report, contains('### ${t.security.limitations}'));
      expect(report, contains('DEX budget exceeded'));
    });

    test('security 为 null 时局限章节列出「未执行」', () {
      const result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: FieldValue<String>.extracted('test.apk',
            source: FieldSource.fileSystem),
        sha256:
            FieldValue<String>.extracted('abc', source: FieldSource.fileSystem),
        android: AndroidPackageInfo(
          signature: SignatureAnalysis(
            status: SignatureStatus.verified,
            toolExecuted: true,
            exitCode: 0,
          ),
        ),
      );

      final report = AnalysisReport.render(result, t, generatedAt: _at);

      expect(report, contains(t.report.limitations));
      expect(report, contains('Security audit was not performed'));
    });
  });

  group('SecurityIntegration — JSON 报告', () {
    test('renderJson 输出结构化数据', () {
      const result = PackageAnalysisResult(
        platform: PackagePlatform.ios,
        fileName: FieldValue<String>.extracted('test.ipa',
            source: FieldSource.fileSystem),
        packageId: FieldValue<String>.extracted('com.test',
            source: FieldSource.infoPlist),
        version:
            FieldValue<String>.extracted('1.0', source: FieldSource.infoPlist),
        security: SecurityAnalysisResult(
          engineVersion: 'ios-security-1.1.0',
          rulesVersion: 'ios-privacy-2026.10.1',
          findings: [
            SecurityFinding(
              ruleId: 'IOS-RULE-A',
              platform: SecurityPlatform.ios,
              category: SecurityCategory.photoAccess,
              severity: SecuritySeverity.p2,
              confidence: SecurityConfidence.suspected,
              finding: 'PhotoKit without usage description',
              evidence: [
                SecurityEvidence(
                  source: SecurityEvidenceSource.machoSymbol,
                  location: 'Payload/Test.app/Test',
                  detail: 'PHPhotoLibrary',
                ),
              ],
              recommendation: 'add NSPhotoLibraryUsageDescription',
            ),
          ],
          limitations: [],
        ),
      );

      final json = AnalysisReport.renderJson(result, generatedAt: _at, t: t);

      // 报告 schema 化（缺陷 D3）：结构版本、报告 ID、输入文件身份、
      // 引擎与规则版本都要在 —— 否则脚本无法判断能不能解析这份报告、
      // 也无法追溯它是用哪套规则跑出来的。
      expect(json, contains('"reportSchemaVersion": 3'));
      expect(json, contains('"reportId"'));
      expect(json, contains('"generatedAt": "2026-10-14T12:00:00.000Z"'));
      expect(json, contains('"inputArtifact"'));
      expect(json, contains('"fileName": "test.ipa"'));
      expect(json, contains('"application"'));
      expect(json, contains('"platform": "ios"'));
      expect(json, contains('"signatureSummary"'));
      expect(json, contains('"securitySummary"'));
      expect(json, contains('"engineVersions"'));
      expect(json, contains('"rulesVersions"'));
      expect(json, contains('"coverage"'));
      expect(json, contains('"ruleId": "IOS-RULE-A"'));
      expect(json, contains('"severity": "p2"'));
      expect(json, contains('"detail": "PHPhotoLibrary"'));
      expect(json, contains('"hasCoverageGaps": false'));
    });

    test('renderJson security 为 null 时输出 null', () {
      const result = PackageAnalysisResult(
        fileName: FieldValue<String>.extracted('test.apk',
            source: FieldSource.fileSystem),
      );

      final json = AnalysisReport.renderJson(result, generatedAt: _at, t: t);

      expect(json, contains('"securitySummary": null'));
      expect(json, contains('"findings": []'));
      // 没跑安全审计时 coverage 必须是「有缺口」，不能默认成没问题。
      expect(json, contains('"hasGaps": true'));
    });

    test('securityOnly 范围只输出安全相关内容', () {
      const result = PackageAnalysisResult(
        fileName: FieldValue<String>.extracted('test.apk',
            source: FieldSource.fileSystem),
        platform: PackagePlatform.android,
      );

      final full = AnalysisReport.renderJson(result, generatedAt: _at, t: t);
      final only = AnalysisReport.renderJson(
        result,
        generatedAt: _at,
        t: t,
        securityOnly: true,
      );

      // 完整报告有 application / signatureSummary，仅安全版没有。
      expect(full, contains('"application"'));
      expect(full, contains('"signatureSummary"'));
      expect(only, isNot(contains('"application"')));
      expect(only, isNot(contains('"signatureSummary"')));

      // 但两者都必须保留文件身份 —— 否则这份安全报告对不上是哪份文件。
      expect(only, contains('"inputArtifact"'));
      expect(only, contains('"reportSchemaVersion"'));
    });
  });
}
