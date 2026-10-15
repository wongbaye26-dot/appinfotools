// analysis_model 的包级测试。
//
// 这个包是 Android 与 iOS 两侧共用的「值 + 状态 + 来源 + 诊断」模型，
// 也是安全检测引擎的平台中立发现项模型。它是**零依赖**包 —— 因此这里的
// 测试只用 `package:test`，顺带证明「它确实不依赖任何东西」。
//
// 断言的落点：
// - 六种字段状态**语义不重叠**（`absent` 与 `failed` 结论相反）；
// - `UNKNOWN` 与低风险（P3）严格分开；
// - 覆盖率四态里 `notApplicable` 不是缺口；
// - 取不到的值不编造（`ratioText` 不返回 0）。
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

SecurityFinding finding({
  required SecuritySeverity severity,
  SecurityConfidence confidence = SecurityConfidence.suspected,
  List<SecurityEvidence> evidence = const [],
}) =>
    SecurityFinding(
      ruleId: 'TEST-RULE',
      platform: SecurityPlatform.android,
      category: SecurityCategory.dataExfiltration,
      severity: severity,
      confidence: confidence,
      finding: '测试用发现',
      evidence: evidence,
      recommendation: '人工核查',
    );

const _evidence = SecurityEvidence(
  source: SecurityEvidenceSource.dexString,
  location: 'classes.dex',
  detail: 'okhttp',
);

void main() {
  group('FieldValue — 六态语义不重叠', () {
    test('只有 extracted 算「有值」', () {
      const extracted = FieldValue<String>.extracted(
        'v',
        source: FieldSource.builtinParser,
      );
      expect(extracted.hasValue, isTrue);
      expect(extracted.value, 'v');
      expect(extracted.status.hasValue, isTrue);

      final others = <FieldValue<String>>[
        const FieldValue<String>.absent(),
        const FieldValue<String>.wrongType(diagnostic: '类型不符'),
        const FieldValue<String>.unsupported(),
        const FieldValue<String>.failed(diagnostic: '读不出来'),
        const FieldValue<String>.hardenedUnknown(),
        const FieldValue<String>.notRequested(),
      ];
      for (final field in others) {
        expect(field.hasValue, isFalse, reason: '${field.status} 不该算有值');
        expect(field.value, isNull);
      }
    });

    test('extracted 但值为 null 时不算有值（不把 null 当数据）', () {
      const field = FieldValue<String>.extracted(
        null,
        source: FieldSource.builtinParser,
      );
      expect(field.hasValue, isFalse);
    });

    test('absent 与 failed 是两个不同的结论', () {
      // 「文件里没有」与「我们没读到」不能合并 —— 后者意味着结论不可靠。
      expect(
        const FieldValue<String>.absent().status,
        isNot(const FieldValue<String>.failed(diagnostic: 'x').status),
      );
    });

    test('isInconclusive 覆盖「读不到」的几种，不覆盖 absent', () {
      expect(const FieldValue<String>.absent().status.isInconclusive, isFalse);
      for (final status in [
        FieldStatus.wrongType,
        FieldStatus.failed,
        FieldStatus.unsupported,
        FieldStatus.hardenedUnknown,
        FieldStatus.notRequested,
      ]) {
        expect(status.isInconclusive, isTrue, reason: '$status 应当算不确定');
      }
    });

    test('带诊断的状态把原因带出来', () {
      const field = FieldValue<String>.failed(diagnostic: '清单读不出来');
      expect(field.diagnostic, '清单读不出来');
      expect(field.hasValue, isFalse);
    });
  });

  group('AnalysisDiagnostic', () {
    test('三种严重度各有具名构造器', () {
      expect(const AnalysisDiagnostic.info('a', 'm').severity,
          DiagnosticSeverity.info);
      expect(const AnalysisDiagnostic.warning('b', 'm').severity,
          DiagnosticSeverity.warning);
      expect(const AnalysisDiagnostic.error('c', 'm').severity,
          DiagnosticSeverity.error);
    });

    test('source 可以为空（不是所有诊断都来自某个字段）', () {
      expect(const AnalysisDiagnostic.info('a', 'm').source, isNull);
      expect(
        const AnalysisDiagnostic.info('a', 'm',
                source: FieldSource.builtinParser)
            .source,
        FieldSource.builtinParser,
      );
    });
  });

  group('SecuritySeverity — UNKNOWN 与低风险分离', () {
    test('rank 越小越严重，unknown 排在最后', () {
      expect(SecuritySeverity.p0.rank, lessThan(SecuritySeverity.p1.rank));
      expect(SecuritySeverity.p3.rank, lessThan(SecuritySeverity.info.rank));
      expect(SecuritySeverity.unknown.rank,
          greaterThan(SecuritySeverity.info.rank));
    });

    test('isRisk 只覆盖 P0–P3', () {
      expect(SecuritySeverity.p0.isRisk, isTrue);
      expect(SecuritySeverity.p3.isRisk, isTrue);
      expect(SecuritySeverity.info.isRisk, isFalse);
      expect(SecuritySeverity.unknown.isRisk, isFalse, reason: '「无法确认」不是风险档位');
    });

    test('只有 unknown 算「无法得出结论」', () {
      for (final severity in SecuritySeverity.values) {
        expect(severity.isInconclusive, severity == SecuritySeverity.unknown);
      }
    });
  });

  group('SecurityConfidence — 四态独立', () {
    test('四态 label 互不相同', () {
      final labels = SecurityConfidence.values.map((c) => c.label).toSet();
      expect(labels, hasLength(SecurityConfidence.values.length));
    });

    test('independentCapability 不等于 suspected（不能混为一谈）', () {
      expect(SecurityConfidence.independentCapability,
          isNot(SecurityConfidence.suspected));
    });
  });

  group('SecurityFinding', () {
    test('证据可以逐条寻址（来源 / 位置 / 原文）', () {
      final f = finding(severity: SecuritySeverity.p2, evidence: [_evidence]);
      expect(f.evidence, hasLength(1));
      expect(f.evidence.first.source, SecurityEvidenceSource.dexString);
      expect(f.evidence.first.location, 'classes.dex');
      expect(f.evidence.first.detail, 'okhttp');
    });

    test('没有证据的来源写 null，而不是填「未知」占位', () {
      final f = finding(severity: SecuritySeverity.p3);
      expect(f.dataSource, isNull);
      expect(f.dataSink, isNull);
      expect(f.relationship, isNull);
    });
  });

  group('SecurityAnalysisResult', () {
    test('highestRiskFinding 取最严重的那条，而不是第一条', () {
      final result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [
          finding(severity: SecuritySeverity.info),
          finding(severity: SecuritySeverity.p0),
          finding(severity: SecuritySeverity.p2),
        ],
      );
      expect(result.highestRiskFinding?.severity, SecuritySeverity.p0);
    });

    test('只有 UNKNOWN 时没有「风险发现」', () {
      final result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [finding(severity: SecuritySeverity.unknown)],
      );
      expect(result.highestRiskFinding, isNull);
      expect(result.hasRiskFindings, isFalse);
    });

    test('无发现时 highestRiskFinding 为 null', () {
      const result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
      );
      expect(result.highestRiskFinding, isNull);
    });

    test('countBySeverity 按等级计数', () {
      final result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [
          finding(severity: SecuritySeverity.p1),
          finding(severity: SecuritySeverity.p1),
          finding(severity: SecuritySeverity.info),
        ],
      );
      expect(result.countBySeverity()[SecuritySeverity.p1], 2);
      expect(result.countBySeverity()[SecuritySeverity.info], 1);
    });

    test('UNKNOWN 发现或 limitations 非空都算覆盖不足', () {
      const noGap =
          SecurityAnalysisResult(engineVersion: 'e', rulesVersion: 'r');
      expect(noGap.hasCoverageGaps, isFalse);

      final withUnknown = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [finding(severity: SecuritySeverity.unknown)],
      );
      expect(withUnknown.hasCoverageGaps, isTrue);

      const withLimitation = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        limitations: ['只扫了主应用'],
      );
      expect(withLimitation.hasCoverageGaps, isTrue);
    });

    test('includesRuntimeEvidence 默认 false（本工具不做运行时分析）', () {
      const result =
          SecurityAnalysisResult(engineVersion: 'e', rulesVersion: 'r');
      expect(result.includesRuntimeEvidence, isFalse);
    });
  });

  group('AnalysisCoverage — 四态与合并', () {
    test('notApplicable 不是缺口，partial / notCovered 是', () {
      const coverage = AnalysisCoverage(entries: [
        CoverageEntry(id: 'a', status: CoverageStatus.covered),
        CoverageEntry(id: 'b', status: CoverageStatus.notApplicable),
        CoverageEntry(id: 'c', status: CoverageStatus.partial),
        CoverageEntry(id: 'd', status: CoverageStatus.notCovered),
      ]);
      expect(coverage.hasGaps, isTrue);
      expect(coverage.gaps.map((e) => e.id), ['c', 'd']);
      expect(coverage.applicable.map((e) => e.id), ['a', 'c', 'd'],
          reason: 'notApplicable 不计入「本次适用」');
    });

    test('ratioText 取不到时不编造 0', () {
      const noNumbers = CoverageEntry(id: 'a', status: CoverageStatus.covered);
      expect(noNumbers.ratioText, isNull);

      const zeroLimit = CoverageEntry(
        id: 'b',
        status: CoverageStatus.covered,
        covered: 3,
        limit: 0,
      );
      expect(zeroLimit.ratioText, isNull, reason: '除以 0 不能变成 0/0');

      const normal = CoverageEntry(
        id: 'c',
        status: CoverageStatus.partial,
        covered: 3,
        limit: 10,
      );
      expect(normal.ratioText, '3/10');
    });

    test('merge 同一 id 取更差的一条（覆盖是木桶）', () {
      const a = AnalysisCoverage(entries: [
        CoverageEntry(id: 'x', status: CoverageStatus.covered, covered: 10),
      ]);
      const b = AnalysisCoverage(entries: [
        CoverageEntry(id: 'x', status: CoverageStatus.partial, covered: 5),
      ]);
      final merged = a.merge(b);
      expect(merged.entries, hasLength(1));
      expect(merged.entry('x')!.status, CoverageStatus.partial);
    });

    test('merge 不同 id 都保留', () {
      const a = AnalysisCoverage(entries: [
        CoverageEntry(id: 'x', status: CoverageStatus.covered),
      ]);
      const b = AnalysisCoverage(entries: [
        CoverageEntry(id: 'y', status: CoverageStatus.covered),
      ]);
      expect(a.merge(b).entries, hasLength(2));
    });

    test('空 coverage 不算有缺口', () {
      expect(const AnalysisCoverage().hasGaps, isFalse);
      expect(const AnalysisCoverage().isEmpty, isTrue);
    });
  });

  group('NetworkFacts', () {
    test('空与非空可判定', () {
      expect(const NetworkFacts().isEmpty, isTrue);
      expect(const NetworkFacts(domains: ['a.example']).isNotEmpty, isTrue);
      expect(const NetworkFacts(ips: ['1.1.1.1']).isNotEmpty, isTrue);
    });
  });

  group('AsciiStrings.extract', () {
    test('只取可打印 ASCII，且丢掉过短的片段', () {
      final bytes = Uint8List.fromList([
        ...'okhttp3'.codeUnits,
        0x00,
        0x01,
        ...'ab'.codeUnits, // 太短
        0xff,
        ...'Retrofit'.codeUnits,
      ]);
      final strings = AsciiStrings.extract(bytes).toList();
      expect(strings, contains('okhttp3'));
      expect(strings, contains('Retrofit'));
      expect(strings, isNot(contains('ab')));
    });

    test('minLength 可调', () {
      final bytes = Uint8List.fromList('ab'.codeUnits);
      expect(AsciiStrings.extract(bytes).toList(), isEmpty);
      expect(AsciiStrings.extract(bytes, minLength: 2).toList(), ['ab']);
    });

    test('limit 只扫前 N 字节', () {
      final bytes = Uint8List.fromList([
        ...'header'.codeUnits,
        0x00,
        ...'trailer'.codeUnits,
      ]);
      // limit 恰好覆盖 'header' 与它的分隔符，因此看不到后面的 'trailer'。
      expect(AsciiStrings.extract(bytes, limit: 7).toList(), ['header']);
      expect(AsciiStrings.extract(bytes).toList(), ['header', 'trailer']);
    });

    test('空输入返回空，不抛异常', () {
      expect(AsciiStrings.extract(Uint8List(0)).toList(), isEmpty);
    });
  });

  group('nativeSymbolMarkers — 精确匹配表本身要干净', () {
    test('符号名不重复（重复会让同一个符号产出两条发现）', () {
      final names = nativeSymbolMarkers.map((m) => m.symbol).toList();
      expect(names.toSet(), hasLength(names.length));
    });

    test('不含「几乎每个库都会导入」的噪音符号', () {
      final names = nativeSymbolMarkers.map((m) => m.symbol).toSet();
      for (final noisy in ['memcpy', 'malloc', 'free', '__android_log_print']) {
        expect(names, isNot(contains(noisy)), reason: '$noisy 只会制造噪音');
      }
    });

    test('条目都带非空说明与类别', () {
      for (final marker in nativeSymbolMarkers) {
        expect(marker.symbol, isNotEmpty);
        expect(marker.description, isNotEmpty);
      }
    });
  });

  group('SplitConsistency — 「没查」与「查了没问题」分开', () {
    test('没查时整体为 null，而不是空报告', () {
      // 调用方用 null 表示「没查」；空报告会被读成「查了，没问题」。
      const SplitConsistency? notChecked = null;
      expect(notChecked, isNull);
    });

    test('查了没问题：issues 为空且全部比过', () {
      const split = SplitConsistency(checkedCount: 3, totalCount: 3);
      expect(split.hasIssues, isFalse);
      expect(split.isFullyChecked, isTrue);
      expect(split.uncheckedCount, 0);
    });

    test('抽检有上限时 isFullyChecked 为 false，且给出未比对数量', () {
      const split = SplitConsistency(checkedCount: 2, totalCount: 5);
      expect(split.isFullyChecked, isFalse, reason: '只比了 2 个不能说「全部分包都没问题」');
      expect(split.uncheckedCount, 3);
    });

    test('发现不一致时 hasIssues 为 true', () {
      const split = SplitConsistency(
        issues: ['split_config.arm64_v8a: versionCode 7 != base 6'],
        checkedCount: 1,
        totalCount: 1,
      );
      expect(split.hasIssues, isTrue);
      expect(split.isFullyChecked, isTrue);
    });

    test('totalCount 为 0 时不算「全部比过」（没有分包可比）', () {
      const split = SplitConsistency();
      expect(split.isFullyChecked, isFalse);
      expect(split.uncheckedCount, 0);
    });
  });
}
