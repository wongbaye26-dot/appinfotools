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

    test('报告里的局限也走本地化，不直接打印原文', () {
      // 回归：`limitation` 曾经是直接插值 `finding.limitation`，
      // 于是英文界面下的报告里会出现中文。
      const result = PackageAnalysisResult(
        platform: PackagePlatform.ios,
        fileName: FieldValue<String>.extracted('test.ipa',
            source: FieldSource.fileSystem),
        security: SecurityAnalysisResult(
          engineVersion: 'test',
          rulesVersion: 'test',
          findings: [
            SecurityFinding(
              ruleId: 'IOS-RULE-F',
              platform: SecurityPlatform.ios,
              category: SecurityCategory.dataExfiltration,
              severity: SecuritySeverity.info,
              confidence: SecurityConfidence.confirmed,
              finding: 'placeholder',
              evidence: [],
              limitation: '只扫描主可执行文件的 ASCII 字符串（旧的中文原文）',
              limitationCode: 'ios.rule_f.limitation',
              recommendation: 'review',
            ),
          ],
          limitations: [],
        ),
      );

      final report = AnalysisReport.render(result, t, generatedAt: _at);

      expect(report, contains('Only ASCII strings from the main executable'));
      expect(report, isNot(contains('旧的中文原文')));
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

  // B11 第六批：原生符号说明 + 证据详情标签。
  //
  // 两件事一起做，因为它们同源：符号的说明既出现在发现项正文里，
  // 也出现在证据详情里 —— 只做一边会得到「正文英文、证据中文」的半成品。
  group('B11 第六批：原生符号说明与证据详情本地化', () {
    const cjk = r'[\u4e00-\u9fff]';

    test('每个原生符号标记都有本地化说明（descriptionCode 不许拼错）', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await LocaleSettings.setLocaleRaw(locale);
        for (final marker in nativeSymbolMarkers) {
          final text = AnalysisReport.nativeSymbolText(marker.symbol, t);
          // 命中查表时返回的是「标签（符号）」，与英文回退**不同** ——
          // 相等就说明 descriptionCode 拼错了，悄悄退回了回退文案。
          expect(text, isNot(marker.description),
              reason: '$locale 下 ${marker.symbol} 的 descriptionCode '
                  '（${marker.descriptionCode}）没有对应文案');
          expect(text, contains(marker.symbol), reason: '符号名要拼进去');
          expect(text, isNot(contains('{')));
        }
      }
    });

    test('未知符号名原样返回，不显示空白', () {
      expect(
        AnalysisReport.nativeSymbolText('not_a_symbol', t),
        'not_a_symbol',
      );
    });

    test('证据详情认得 code 时给出本地化标签', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      const reference = SecurityEvidence(
        source: SecurityEvidenceSource.dexMethodReference,
        location: 'classes.dex',
        detail: 'ocr-mlkit (reference): Lfoo;.bar()',
        detailCode: 'code.reference',
        detailArgs: {'marker': 'ocr-mlkit', 'samples': 'Lfoo;.bar()'},
      );

      await LocaleSettings.setLocaleRaw('en');
      expect(
        AnalysisReport.detailText(reference, t),
        'ocr-mlkit (reference): Lfoo;.bar()',
      );

      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.detailText(reference, t);
      expect(zh, 'ocr-mlkit（引用）: Lfoo;.bar()');
      expect(RegExp(cjk).hasMatch(zh), isTrue);
    });

    test('符号证据的「导入」标签按语言拼，说明也查表', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      const symbol = SecurityEvidence(
        source: SecurityEvidenceSource.nativeSymbol,
        location: 'libfoo.so',
        detail: 'system (imported): run a shell command (system)',
        detailCode: 'native_symbol.imported',
        detailArgs: {'symbol': 'system'},
      );

      await LocaleSettings.setLocaleRaw('zh-CN');
      expect(
        AnalysisReport.detailText(symbol, t),
        'system（导入）: 执行 shell 命令（system）',
      );

      await LocaleSettings.setLocaleRaw('en');
      expect(
        AnalysisReport.detailText(symbol, t),
        'system (imported): run a shell command (system)',
      );
    });

    test('没填 code 的证据详情原样返回（迁移是增量的）', () {
      const plain = SecurityEvidence(
        source: SecurityEvidenceSource.dexString,
        location: 'classes.dex',
        detail: '原始详情',
      );
      expect(AnalysisReport.detailText(plain, t), '原始详情');
    });
  });
}
