// 安全检测引擎数据模型测试（V1.1 规格第六章）。
//
// 重点不是「字段能赋值」，而是三条直接影响结论正确性的性质：
// 1. 等级可比较，且 UNKNOWN 不与 P3 混淆；
// 2. 「没有风险发现」不等于「安全」—— highestRiskFinding 为 null 时
//    调用方只能得到「未发现」的审慎结论；
// 3. 覆盖不足（limitations / UNKNOWN）必须能被检出，否则界面会把
//    「没查」显示成绿色。

import 'package:analysis_model/analysis_model.dart';
import 'package:flutter_test/flutter_test.dart';

SecurityFinding _finding(
  SecuritySeverity severity, {
  SecurityConfidence confidence = SecurityConfidence.confirmed,
}) {
  return SecurityFinding(
    ruleId: 'TEST-RULE',
    platform: SecurityPlatform.android,
    category: SecurityCategory.photoAccess,
    severity: severity,
    confidence: confidence,
    finding: 'test finding',
    evidence: const [
      SecurityEvidence(
        source: SecurityEvidenceSource.manifest,
        location: 'test',
        detail: 'test evidence',
      ),
    ],
    recommendation: 'test recommendation',
  );
}

void main() {
  group('SecuritySeverity 排序', () {
    test('rank 越小越严重，P0 最严重', () {
      expect(SecuritySeverity.p0.rank, lessThan(SecuritySeverity.p1.rank));
      expect(SecuritySeverity.p1.rank, lessThan(SecuritySeverity.p2.rank));
      expect(SecuritySeverity.p2.rank, lessThan(SecuritySeverity.p3.rank));
      expect(SecuritySeverity.p3.rank, lessThan(SecuritySeverity.info.rank));
      expect(
          SecuritySeverity.info.rank, lessThan(SecuritySeverity.unknown.rank));
    });

    test('isRisk 只覆盖 P0–P3', () {
      expect(SecuritySeverity.p0.isRisk, isTrue);
      expect(SecuritySeverity.p3.isRisk, isTrue);
      expect(SecuritySeverity.info.isRisk, isFalse);
      expect(SecuritySeverity.unknown.isRisk, isFalse);
    });

    test('UNKNOWN 是「无法确认」，不是「没风险」', () {
      expect(SecuritySeverity.unknown.isInconclusive, isTrue);
      expect(SecuritySeverity.p3.isInconclusive, isFalse);
      expect(SecuritySeverity.p3.isRisk, isTrue);
    });
  });

  group('SecurityConfidence 四态', () {
    test('四种状态各自独立，标签可读', () {
      expect(SecurityConfidence.values, hasLength(4));
      for (final c in SecurityConfidence.values) {
        expect(c.label, isNotEmpty);
      }
      // 「疑似」与「仅发现能力」必须能分辨：规格 7.3 要求分别渲染。
      expect(SecurityConfidence.suspected.label,
          isNot(SecurityConfidence.independentCapability.label));
    });
  });

  group('SecurityAnalysisResult 结论推导', () {
    test('没有风险发现时 highestRiskFinding 为 null', () {
      const result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [],
      );
      expect(result.hasRiskFindings, isFalse);
      expect(result.hasCoverageGaps, isFalse);
    });

    test('取最严重的风险发现（不是第一条）', () {
      final result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [
          _finding(SecuritySeverity.p3),
          _finding(SecuritySeverity.p1),
          _finding(SecuritySeverity.info),
        ],
      );
      expect(result.highestRiskFinding!.severity, SecuritySeverity.p1);
      expect(result.hasRiskFindings, isTrue);
    });

    test('UNKNOWN 发现算覆盖不足，即使它是唯一条目', () {
      final result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [_finding(SecuritySeverity.unknown)],
      );
      expect(result.hasRiskFindings, isFalse);
      // 关键：没有风险档位，但覆盖不足必须为真 —— 否则界面会渲染成绿色。
      expect(result.hasCoverageGaps, isTrue);
    });

    test('limitations 非空也算覆盖不足', () {
      const result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        limitations: ['DEX 未读取'],
      );
      expect(result.hasCoverageGaps, isTrue);
    });

    test('按等级计数', () {
      final result = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [
          _finding(SecuritySeverity.p2),
          _finding(SecuritySeverity.p2),
          _finding(SecuritySeverity.info),
        ],
      );
      final counts = result.countBySeverity();
      expect(counts[SecuritySeverity.p2], 2);
      expect(counts[SecuritySeverity.info], 1);
    });

    test('includesRuntimeEvidence 默认为 false（本版本无动态分析）', () {
      const result =
          SecurityAnalysisResult(engineVersion: 'e', rulesVersion: 'r');
      expect(result.includesRuntimeEvidence, isFalse);
    });
  });

  group('SecurityFinding.withDedupedEvidence（缺陷 D9）', () {
    SecurityFinding findingWith(List<SecurityEvidence> evidence) =>
        SecurityFinding(
          ruleId: 'TEST-RULE',
          platform: SecurityPlatform.android,
          category: SecurityCategory.photoAccess,
          severity: SecuritySeverity.p2,
          confidence: SecurityConfidence.suspected,
          finding: '测试',
          evidence: evidence,
          recommendation: '复核',
        );

    test('去掉完全相同的证据条目', () {
      const dup = SecurityEvidence(
        source: SecurityEvidenceSource.manifest,
        location: 'AndroidManifest.xml:12',
        detail: 'READ_MEDIA_IMAGES',
      );
      final f = findingWith(const [dup, dup]);

      final deduped = f.withDedupedEvidence();
      expect(deduped.evidence, hasLength(1));
      // 原对象不受影响。
      expect(f.evidence, hasLength(2));
    });

    test('去重后必须保留迁移用的 code（否则本地化会悄悄退回原文）', () {
      // 回归：`withDedupedEvidence` 是手工重建对象的，加字段时最容易漏。
      // Android 侧对**每条**发现都调它，漏了就等于整批迁移白做。
      const dup = SecurityEvidence(
        source: SecurityEvidenceSource.manifest,
        location: 'AndroidManifest.xml:12',
        detail: 'READ_MEDIA_IMAGES',
      );
      const f = SecurityFinding(
        ruleId: 'TEST-RULE',
        platform: SecurityPlatform.android,
        category: SecurityCategory.photoAccess,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.suspected,
        finding: 'fallback finding',
        evidence: [dup, dup],
        relationship: 'fallback relationship',
        limitation: 'fallback limitation',
        recommendation: 'fallback recommendation',
        messageCode: 'test.finding',
        messageArgs: <String, Object>{'n': 1},
        recommendationCode: 'test.recommendation',
        recommendationArgs: <String, Object>{'m': 2},
        relationshipCode: 'test.relationship',
        limitationCode: 'test.limitation',
      );

      final deduped = f.withDedupedEvidence();
      expect(deduped.evidence, hasLength(1), reason: '去重本身要生效');
      expect(deduped.messageCode, 'test.finding');
      expect(deduped.messageArgs, <String, Object>{'n': 1});
      expect(deduped.recommendationCode, 'test.recommendation');
      expect(deduped.recommendationArgs, <String, Object>{'m': 2});
      expect(deduped.relationshipCode, 'test.relationship');
      expect(deduped.limitationCode, 'test.limitation');
    });

    test('三元组任一项不同就不算重复', () {
      final f = findingWith(const [
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'A:1',
          detail: 'X',
        ),
        // 位置不同
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'A:2',
          detail: 'X',
        ),
        // 来源不同
        SecurityEvidence(
          source: SecurityEvidenceSource.dexString,
          location: 'A:1',
          detail: 'X',
        ),
        // 摘要不同
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'A:1',
          detail: 'Y',
        ),
      ]);

      expect(f.withDedupedEvidence().evidence, hasLength(4));
    });

    test('没有重复时返回同一个对象（避免无谓重建）', () {
      final f = findingWith(const [
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'A:1',
          detail: 'X',
        ),
      ]);
      expect(identical(f.withDedupedEvidence(), f), isTrue);
    });
  });
}
