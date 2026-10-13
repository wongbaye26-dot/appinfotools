// 统一分析数据模型的语义测试。
//
// 重点不在「能不能存值」，而在几处**容易搞错就会误导用户**的区分：
// 「没读到」不等于「不存在」，「工具不可用」不等于「签名无效」，
// 「空候选值」不该抹掉已有的好结果。

import 'package:apk_info_tool/models/analysis/diagnostic.dart';
import 'package:apk_info_tool/models/analysis/field_value.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FieldValue 的状态语义', () {
    test('只有 extracted 才有值，display 不伪造占位', () {
      const extracted = FieldValue<String>.extracted('com.example',
          source: FieldSource.builtinParser);
      expect(extracted.hasValue, isTrue);
      expect(extracted.display, 'com.example');

      const absent =
          FieldValue<String>.absent(source: FieldSource.builtinParser);
      expect(absent.hasValue, isFalse);
      expect(absent.display, '');
    });

    test('isInconclusive 覆盖「读不到」的三种情况，但不含 absent', () {
      // absent 是**明确的结论**：文件里确实没有。它不该被当成「读不到」。
      expect(const FieldValue<String>.absent().status.isInconclusive, isFalse);
      expect(
          const FieldValue<String>.unsupported().status.isInconclusive, isTrue);
      expect(
        const FieldValue<String>.failed(diagnostic: 'boom')
            .status
            .isInconclusive,
        isTrue,
      );
      expect(
        const FieldValue<String>.hardenedUnknown().status.isInconclusive,
        isTrue,
      );
    });

    test('failed 必须带诊断说明，否则用户无从判断', () {
      const failed = FieldValue<String>.failed(diagnostic: 'arsc parse failed');
      expect(failed.diagnostic, isNotNull);
      expect(failed.hasValue, isFalse);
    });
  });

  group('FieldValue.overriddenBy 的合并规则', () {
    test('候选有值时覆盖', () {
      const builtin = FieldValue<String>.extracted('from-builtin',
          source: FieldSource.builtinParser);
      const fromAapt2 =
          FieldValue<String>.extracted('from-aapt2', source: FieldSource.aapt2);

      final merged = builtin.overriddenBy(fromAapt2);

      expect(merged.value, 'from-aapt2');
      expect(merged.source, FieldSource.aapt2);
    });

    test('候选无值时保留原值 —— 空结果不能抹掉好结果', () {
      const builtin = FieldValue<String>.extracted('from-builtin',
          source: FieldSource.builtinParser);
      const emptyCandidate = FieldValue<String>.absent();

      final merged = builtin.overriddenBy(emptyCandidate);

      expect(merged.value, 'from-builtin');
      expect(merged.source, FieldSource.builtinParser);
    });

    test('原值缺失时，候选有值也能补上', () {
      const absent = FieldValue<String>.absent();
      const fromZip = FieldValue<String>.extracted('inferred',
          source: FieldSource.zipDirectory);

      expect(absent.overriddenBy(fromZip).value, 'inferred');
    });
  });

  group('SignatureVerdict 的折算', () {
    test('analysis 为 null -> notChecked（未启用检查，不是无法确认）', () {
      expect(
          PackageAnalysisResult.verdictFrom(null), SignatureVerdict.notChecked);
    });

    test('toolUnavailable -> inconclusive，绝不折算成 rejected', () {
      final verdict = PackageAnalysisResult.verdictFrom(
        SignatureAnalysis.toolUnavailable('apksigner not found'),
      );

      expect(verdict, SignatureVerdict.inconclusive);
      expect(verdict, isNot(SignatureVerdict.rejected));
      expect(verdict.isConclusive, isFalse);
    });

    test('verified / verificationFailed 是有结论的', () {
      expect(
        PackageAnalysisResult.verdictFrom(
            SignatureAnalyzer.parseResult(exitCode: 0, stdout: 'Verifies')),
        SignatureVerdict.verified,
      );
      expect(
        PackageAnalysisResult.verdictFrom(SignatureAnalyzer.parseResult(
            exitCode: 1, stdout: 'DOES NOT VERIFY')),
        SignatureVerdict.rejected,
      );
    });

    test('非预期退出码 -> inconclusive', () {
      expect(
        PackageAnalysisResult.verdictFrom(
            SignatureAnalyzer.parseResult(exitCode: 2, stdout: 'usage')),
        SignatureVerdict.inconclusive,
      );
    });
  });

  group('PackageAnalysisResult 默认值', () {
    test('默认构造不假装任何字段有值', () {
      const result = PackageAnalysisResult();

      expect(result.platform, PackagePlatform.unknown);
      expect(result.fileName.hasValue, isFalse);
      expect(result.sha256.hasValue, isFalse);
      expect(result.signatureVerdict, SignatureVerdict.notChecked);
      expect(result.android, isNull);
      expect(result.ios, isNull);
      expect(result.diagnostics, isEmpty);
    });

    test('hasDiagnosticAtLeast 按严重度比较', () {
      const result = PackageAnalysisResult(diagnostics: [
        AnalysisDiagnostic.info('a', 'just info'),
        AnalysisDiagnostic.warning('b', 'careful'),
      ]);

      expect(result.hasDiagnosticAtLeast(DiagnosticSeverity.info), isTrue);
      expect(result.hasDiagnosticAtLeast(DiagnosticSeverity.warning), isTrue);
      expect(result.hasDiagnosticAtLeast(DiagnosticSeverity.error), isFalse);
    });
  });

  group('平台专属信息', () {
    test('AndroidPackageInfo 的 debuggable 未声明时是 absent，不是 false', () {
      const info = AndroidPackageInfo();

      expect(info.debuggable.status, FieldStatus.absent);
      expect(info.debuggable.hasValue, isFalse);
    });

    test('mayBeHardened / hasStrongHardeningSignal 区分线索强弱', () {
      const weakOnly = AndroidPackageInfo(hardeningHints: [
        HardeningHint(
          signal: HardeningSignal.multipleDexFiles,
          evidence: '2 DEX entries',
          confidence: HintConfidence.weak,
        ),
      ]);
      expect(weakOnly.mayBeHardened, isTrue);
      expect(weakOnly.hasStrongHardeningSignal, isFalse);

      const withStrong = AndroidPackageInfo(hardeningHints: [
        HardeningHint(
          signal: HardeningSignal.dexHeaderNotStandard,
          evidence: 'classes.dex: header is 0x9d',
          confidence: HintConfidence.strong,
        ),
      ]);
      expect(withStrong.hasStrongHardeningSignal, isTrue);
    });

    test('iOS 类型明确说明能力不可用，而不是留一个无法解释的空壳', () {
      const ios = IosPackageInfo();
      expect(ios.unavailableReason, isNotEmpty);
    });
  });
}
