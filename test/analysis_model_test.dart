// 统一分析数据模型的语义测试。
//
// 重点不在「能不能存值」，而在几处**容易搞错就会误导用户**的区分：
// 「没读到」不等于「不存在」，「工具不可用」不等于「签名无效」，
// 「空候选值」不该抹掉已有的好结果。

import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/models/analysis/diagnostic.dart';
import 'package:apk_info_tool/models/analysis/field_value.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
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

  group('AnalysisBuilder.buildAndroid', () {
    test('文件名 / 大小 / 哈希来自文件系统，且如实标注来源', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/app.apk',
        fileSize: 12345,
        manifestSource: FieldSource.builtinParser,
        hashes: const FileHashes(md5: 'm', sha1: 's1', sha256: 's256'),
      );

      expect(result.platform, PackagePlatform.android);
      expect(result.fileName.value, 'app.apk');
      expect(result.fileName.source, FieldSource.fileSystem);
      expect(result.fileSize.value, 12345);
      expect(result.sha256.value, 's256');
      expect(result.sha256.source, FieldSource.fileSystem);
    });

    test('未计算哈希时记为 notRequested，而不是 absent', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/app.apk',
        fileSize: 1,
        manifestSource: FieldSource.builtinParser,
      );

      expect(result.sha256.status, FieldStatus.notRequested);
      expect(result.sha256.status, isNot(FieldStatus.absent));
      expect(result.sha256.status.isInconclusive, isTrue);
    });

    test('manifest 字段的来源跟随调用方给的 manifestSource', () {
      final builtin = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.builtinParser,
        packageId: 'com.example',
      );
      expect(builtin.packageId.source, FieldSource.builtinParser);

      final viaAapt2 = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.aapt2,
        packageId: 'com.example',
      );
      expect(viaAapt2.packageId.source, FieldSource.aapt2);
    });

    test('缺失的 manifest 字段记为 absent —— 这是明确结论，不是「读不到」', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.builtinParser,
      );

      expect(result.packageId.status, FieldStatus.absent);
      expect(result.packageId.status.isInconclusive, isFalse);
      expect(result.android!.maxSdkVersion.status, FieldStatus.absent);
      expect(result.android!.debuggable.status, FieldStatus.absent);
    });

    test('加固线索按强弱分级，证据原样保留', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.builtinParser,
        hardeningObservations: const [
          HardeningObservation(
              HardeningSignal.multipleDexFiles, '3 DEX entries'),
          HardeningObservation(
              HardeningSignal.dexHeaderNotStandard, 'classes.dex: header 0x9d'),
        ],
      );

      final hints = result.android!.hardeningHints;
      expect(hints, hasLength(2));
      expect(hints[0].confidence, HintConfidence.weak);
      expect(hints[1].confidence, HintConfidence.strong);
      expect(hints[1].evidence, contains('0x9d'));
      expect(result.android!.hasStrongHardeningSignal, isTrue);
      expect(result.android!.mayBeHardened, isTrue);
    });

    test('无线索时 mayBeHardened 为 false', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.builtinParser,
      );

      expect(result.android!.mayBeHardened, isFalse);
      expect(result.android!.hasStrongHardeningSignal, isFalse);
    });

    test('签名结论随分析结果折算，工具不可用不会变成 rejected', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.builtinParser,
        signature: SignatureAnalysis.toolUnavailable('apksigner not found'),
      );

      expect(result.signatureVerdict, SignatureVerdict.inconclusive);
      // 明细仍然保留，用户能看到为什么没结论
      expect(result.android!.signature!.error, isNotNull);
    });

    test('每个加固信号都有置信度分级', () {
      for (final signal in HardeningSignal.values) {
        expect(() => AnalysisBuilder.confidenceOf(signal), returnsNormally,
            reason: '${signal.name} 未分级');
      }
    });
  });

  group('来源能力对齐', () {
    test('内置解析器提供全部受管字段', () {
      for (final field in AndroidField.values) {
        expect(
          AnalysisBuilder.sourceProvides(FieldSource.builtinParser, field),
          isTrue,
          reason: '${field.name} 内置解析器应当能提供',
        );
      }
    });

    test('aapt2 不报的字段记为 unsupported，而不是 absent', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.aapt2,
      );

      // `aapt2 dump badging` 不输出 maxSdkVersion、不输出 debuggable，
      // 组件方面也只给 launchable-activity。
      for (final status in [
        result.android!.maxSdkVersion.status,
        result.android!.debuggable.status,
        result.android!.components.status,
      ]) {
        expect(status, FieldStatus.unsupported);
        expect(status, isNot(FieldStatus.absent),
            reason: '「这个来源不报」不能记成「文件里没有」');
        expect(status.isInconclusive, isTrue);
      }

      // 但它确实会报的字段，取不到就是真取不到
      expect(result.packageId.status, FieldStatus.absent);
      expect(result.android!.minSdkVersion.status, FieldStatus.absent);
    });

    test('unsupported 的诊断里说明是哪个来源不报哪个字段', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.aapt2,
      );

      final diagnostic = result.android!.maxSdkVersion.diagnostic!;
      expect(diagnostic, contains('aapt2'));
      expect(diagnostic, contains('maxSdkVersion'));
    });

    test('有值时来源能力不影响取值', () {
      final result = AnalysisBuilder.buildAndroid(
        filePath: '/tmp/a.apk',
        fileSize: 1,
        manifestSource: FieldSource.aapt2,
        packageId: 'com.example',
        minSdkVersion: 21,
      );

      expect(result.packageId.status, FieldStatus.extracted);
      expect(result.packageId.source, FieldSource.aapt2);
      expect(result.android!.minSdkVersion.value, 21);
    });

    test('能力表里没有的来源一律视为「不提供」', () {
      for (final source in [
        FieldSource.unknown,
        FieldSource.zipDirectory,
        FieldSource.apksigner,
        FieldSource.fileSystem,
        FieldSource.archiveManifest,
      ]) {
        expect(
          AnalysisBuilder.sourceProvides(source, AndroidField.packageId),
          isFalse,
          reason: '${source.name} 不在能力表里，不应被当作能提供 manifest 字段',
        );
      }
    });

    test('两个来源共同提供的字段就是可以安全合并的那些', () {
      const mergeable = {
        AndroidField.appName,
        AndroidField.packageId,
        AndroidField.version,
        AndroidField.buildNumber,
        AndroidField.minSdkVersion,
        AndroidField.targetSdkVersion,
        AndroidField.permissions,
      };

      for (final field in mergeable) {
        expect(
          AnalysisBuilder.sourceProvides(FieldSource.aapt2, field),
          isTrue,
          reason: '${field.name} 两个来源都能提供，可以合并',
        );
      }
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
