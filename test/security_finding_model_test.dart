// B-4：安全发现模型的「能力评估」—— source / transform / sink / confidence
// 这四个维度，模型到底支持到什么程度。
//
// ## 为什么用测试来表达「评估结论」
//
// 「模型支持 source / sink / confidence」这种判断，如果只写在文档里，下一次
// 有人改 `withDedupedEvidence()` 就会静默退化 —— 而这个方法**每一条发现都会
// 过**（历史踩过：它曾漏带四个 code 字段，编译通过、测试不报、功能静默退化）。
//
// 所以把评估结论落成断言：
//
// | 维度 | 现状 | 断言 |
// |---|---|---|
// | `confidence` | ✅ 一等字段（枚举） | 去重后不变；JSON 里有 |
// | `dataSource` | ✅ 一等字段（字符串） | 去重后不变；JSON 里有 |
// | `dataSink` | ✅ 一等字段（字符串） | 去重后不变；JSON 里有 |
// | `transform` | ✅ 一等字段（B-5 补上，消费者是 `ANDROID-RULE-C`） | 去重后不变；JSON 里有；Markdown 里显示 |
//
// 「transform」这一项在 B-4 评估时**还没有**（中间跳只能塞进 `relationship`
// 自由文本）。当时刻意没加 —— 没有消费者就先加字段，只会得到一个没人读的字段。
// B-5 把它补上了，消费者是 `ANDROID-RULE-C` 的「同一方法体」分支：
// 识别与上传的调用指令都落在哪个方法里，那个方法就是中间跳。
//
// 所以下面这条用例从「断言没有这个字段」改成了「断言有这个字段且带得动」——
// 这正是当初那条 `throwsNoSuchMethodError` 想提醒的事：加字段时要回来改它。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime _at = DateTime.utc(2026, 10, 18, 12, 0, 0);

/// 一条「来源 → 处理 → 去向」三段都写全的发现项。
SecurityFinding _flowFinding() => const SecurityFinding(
      ruleId: 'TEST-FLOW-1',
      platform: SecurityPlatform.android,
      category: SecurityCategory.dataExfiltration,
      severity: SecuritySeverity.p2,
      confidence: SecurityConfidence.suspected,
      finding: '读取设备标识后可能上传到第三方域名',
      evidence: [
        SecurityEvidence(
          source: SecurityEvidenceSource.dexMethodReference,
          location: 'com.example.Tracker.getDeviceId',
          detail: 'TelephonyManager.getDeviceId 的调用点',
        ),
        SecurityEvidence(
          source: SecurityEvidenceSource.dexMethodReference,
          location: 'com.example.Net.upload',
          detail: 'HttpURLConnection 的写入点',
        ),
      ],
      dataSource: '设备标识（IMEI）',
      dataTransform: 'Lcom/example/Pipeline;.run()V',
      dataSink: 'https://tracker.example.com/collect',
      relationship: '识别与上传的调用点出现在同一方法体内'
          '（Lcom/example/Pipeline;.run()V），但**未证实**两者之间存在数据传递'
          '（未做反汇编）',
      limitation: '未反汇编，关联来自调用点同现',
      recommendation: '人工核查该方法的参数传递',
    );

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('四个维度的现状', () {
    test('confidence / dataSource / dataSink 是一等字段，可以直接读', () {
      final f = _flowFinding();
      expect(f.confidence, SecurityConfidence.suspected);
      expect(f.dataSource, contains('IMEI'));
      expect(f.dataSink, contains('tracker.example.com'));
    });

    test('transform 是结构化字段（B-5 补上），与 relationship 分工明确', () {
      final f = _flowFinding();
      // 中间跳：机器可读的定位。
      expect(f.dataTransform, contains('Pipeline'));
      expect(f.dataTransform, contains('('), reason: '要能定位到方法原型');
      // relationship：给人读的说明，含「哪一段没证实」。
      expect(f.relationship, contains('同一方法体'));
      // 两者说的是同一个方法，但不是同一句话 —— 一个能拿去搜代码，一个能读懂。
      expect(f.relationship, contains('Pipeline'));
      expect(f.relationship, isNot(f.dataTransform));
    });
  });

  group('withDedupedEvidence 必须保住这些字段', () {
    test('去重之后 confidence / dataSource / dataSink / relationship 都还在', () {
      // 构造一条**有重复证据**的发现项，强制走重建分支。
      const duplicated = SecurityFinding(
        ruleId: 'TEST-FLOW-2',
        platform: SecurityPlatform.android,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.independentCapability,
        finding: '疑似采集并上传',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.dexMethodReference,
            location: 'A',
            detail: 'x',
          ),
          SecurityEvidence(
            source: SecurityEvidenceSource.dexMethodReference,
            location: 'A',
            detail: 'x',
          ),
        ],
        dataSource: '相册',
        dataTransform: 'Lcom/example/Sender;.send()V',
        dataSink: 'https://up.example.com',
        relationship: '同一方法体内出现',
        limitation: '未反汇编',
        recommendation: '人工核查',
      );

      final deduped = duplicated.withDedupedEvidence();

      expect(deduped.evidence, hasLength(1), reason: '重复证据应被去掉');
      // 这四项是最容易被漏带的（历史上 `withDedupedEvidence` 漏过字段）。
      expect(deduped.confidence, SecurityConfidence.independentCapability);
      expect(deduped.dataSource, '相册');
      expect(deduped.dataTransform, 'Lcom/example/Sender;.send()V');
      expect(deduped.dataSink, 'https://up.example.com');
      expect(deduped.relationship, '同一方法体内出现');
      expect(deduped.limitation, '未反汇编');
    });

    test('没有重复时原样返回同一个实例（不必无谓重建）', () {
      final f = _flowFinding();
      expect(identical(f.withDedupedEvidence(), f), isTrue);
    });
  });

  group('JSON 是 B-5 的消费者契约', () {
    test('dataSource / dataSink / confidence / relationship 都在 JSON 里', () {
      final result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: const FieldValue<String>.extracted(
          'a.apk',
          source: FieldSource.fileSystem,
        ),
        fileSize: const FieldValue<int>.extracted(
          1,
          source: FieldSource.fileSystem,
        ),
        sha256: const FieldValue<String>.absent(source: FieldSource.fileSystem),
        appName:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        packageId:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        version:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        buildNumber:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        signatureVerdict: PackageAnalysisResult.verdictFrom(null),
        diagnostics: const [],
        security: SecurityAnalysisResult(
          engineVersion: 'test',
          rulesVersion: 'test',
          findings: [_flowFinding()],
        ),
      );

      final json = AnalysisReport.renderJson(result, generatedAt: _at, t: t);

      expect(json, contains('"confidence": "suspected"'));
      expect(json, contains('"dataSource"'));
      expect(json, contains('IMEI'));
      expect(json, contains('"dataTransform"'));
      expect(json, contains('Pipeline'));
      expect(json, contains('"dataSink"'));
      expect(json, contains('tracker.example.com'));
      expect(json, contains('"relationship"'));
    });
  });

  group('Markdown 报告里也要显示数据流三段', () {
    test('来源 / 中间处理 / 去向按顺序出现在同一条「数据流」里', () {
      final result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: const FieldValue<String>.extracted(
          'a.apk',
          source: FieldSource.fileSystem,
        ),
        fileSize: const FieldValue<int>.extracted(
          1,
          source: FieldSource.fileSystem,
        ),
        sha256: const FieldValue<String>.absent(source: FieldSource.fileSystem),
        appName:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        packageId:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        version:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        buildNumber:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        signatureVerdict: PackageAnalysisResult.verdictFrom(null),
        diagnostics: const [],
        security: SecurityAnalysisResult(
          engineVersion: 'test',
          rulesVersion: 'test',
          findings: [_flowFinding()],
        ),
      );

      final markdown = AnalysisReport.render(result, t, generatedAt: _at);
      final flowLine = markdown.split('\n').firstWhere(
          (l) => l.contains(t.security.data_flow),
          orElse: () => '');

      expect(flowLine, isNotEmpty, reason: '报告里应有「数据流」一行');
      expect(flowLine, contains(t.security.data_flow_source));
      expect(flowLine, contains(t.security.data_flow_transform));
      expect(flowLine, contains(t.security.data_flow_sink));
      // 顺序必须是 来源 → 处理 → 去向，不能反过来。
      expect(
        flowLine.indexOf(t.security.data_flow_source),
        lessThan(flowLine.indexOf(t.security.data_flow_transform)),
      );
      expect(
        flowLine.indexOf(t.security.data_flow_transform),
        lessThan(flowLine.indexOf(t.security.data_flow_sink)),
      );
    });

    test('三段都没有时不留一行空的「数据流」', () {
      const bare = SecurityFinding(
        ruleId: 'TEST-BARE',
        platform: SecurityPlatform.android,
        category: SecurityCategory.configuration,
        severity: SecuritySeverity.p3,
        confidence: SecurityConfidence.independentCapability,
        finding: 'f',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.manifest,
            location: 'l',
            detail: 'd',
          ),
        ],
        recommendation: 'r',
      );
      final result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: const FieldValue<String>.extracted(
          'a.apk',
          source: FieldSource.fileSystem,
        ),
        fileSize: const FieldValue<int>.extracted(
          1,
          source: FieldSource.fileSystem,
        ),
        sha256: const FieldValue<String>.absent(source: FieldSource.fileSystem),
        appName:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        packageId:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        version:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        buildNumber:
            const FieldValue<String>.absent(source: FieldSource.builtinParser),
        signatureVerdict: PackageAnalysisResult.verdictFrom(null),
        diagnostics: const [],
        security: const SecurityAnalysisResult(
          engineVersion: 'test',
          rulesVersion: 'test',
          findings: [bare],
        ),
      );

      final markdown = AnalysisReport.render(result, t, generatedAt: _at);
      expect(markdown, isNot(contains(t.security.data_flow)),
          reason: '没有来源/处理/去向就不该出现「数据流」这个标题');
    });
  });

  group('Markdown 里 relationship 有就写、没有就不编', () {
    test('有 relationship 时出现在报告里', () {
      final text = AnalysisReport.relationshipText(_flowFinding(), t);
      expect(text, isNotNull);
      expect(text, contains('同一方法体'));
    });

    test('没有 relationship 时返回 null（而不是「未知」占位）', () {
      const noRelationship = SecurityFinding(
        ruleId: 'TEST-NO-REL',
        platform: SecurityPlatform.android,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p3,
        confidence: SecurityConfidence.independentCapability,
        finding: 'f',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.manifest,
            location: 'p',
            detail: 'd',
          ),
        ],
        recommendation: 'r',
      );
      expect(AnalysisReport.relationshipText(noRelationship, t), isNull);
    });
  });
}
