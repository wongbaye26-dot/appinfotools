import 'package:apk_info_tool/models/analysis/diagnostic.dart';
import 'package:apk_info_tool/models/analysis/field_value.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, HardeningObservation, HardeningSignal;
import 'package:path/path.dart' as path;

/// 把各来源的解析结果合并成统一的 [PackageAnalysisResult]。
///
/// 这是规范 4.2 第 4 步「对每个字段分别合并可靠结果，保留字段来源和错误原因」
/// 的落点：**逐字段**决定取哪个来源，而不是整包二选一。
///
/// 刻意接收扁平字段而不是 `ApkMeta`：这样合并器不依赖解析器包的模型，
/// 也才能让 XAPK 分支（字段来自 aapt2）和内置分支（字段来自 AXML/ARSC）
/// 各自如实标注来源。
class AnalysisBuilder {
  AnalysisBuilder._();

  /// 构建 Android 分析结果。
  ///
  /// [manifestSource] 必须由调用方如实给出 —— 它是「这个值是谁给的」的唯一
  /// 依据，猜错会让后续排查找错方向。
  static PackageAnalysisResult buildAndroid({
    required String filePath,
    required int fileSize,
    required FieldSource manifestSource,
    FileHashes? hashes,
    String? appName,
    String? packageId,
    String? version,
    String? buildNumber,
    int? minSdkVersion,
    int? targetSdkVersion,
    int? maxSdkVersion,
    bool? debuggable,
    List<String> permissions = const [],
    List<AndroidComponent> components = const [],
    List<HardeningObservation> hardeningObservations = const [],
    SignatureAnalysis? signature,
    List<AnalysisDiagnostic> diagnostics = const [],
  }) {
    final hardeningHints = <HardeningHint>[
      for (final observation in hardeningObservations)
        HardeningHint(
          signal: observation.signal,
          evidence: observation.evidence,
          confidence: confidenceOf(observation.signal),
        ),
    ];

    final android = AndroidPackageInfo(
      minSdkVersion: _manifest(minSdkVersion, manifestSource),
      targetSdkVersion: _manifest(targetSdkVersion, manifestSource),
      maxSdkVersion: _manifest(maxSdkVersion, manifestSource),
      debuggable: _manifest(debuggable, manifestSource),
      permissions: permissions,
      components: components,
      signature: signature,
      hardeningHints: hardeningHints,
    );

    return PackageAnalysisResult(
      platform: PackagePlatform.android,
      fileName: FieldValue<String>.extracted(
        path.basename(filePath),
        source: FieldSource.fileSystem,
      ),
      fileSize: FieldValue<int>.extracted(
        fileSize,
        source: FieldSource.fileSystem,
      ),
      sha256: hashes == null
          ? const FieldValue<String>.notRequested(
              diagnostic: 'hashing is disabled in settings',
              source: FieldSource.fileSystem,
            )
          : FieldValue<String>.extracted(
              hashes.sha256,
              source: FieldSource.fileSystem,
            ),
      appName: _manifest(appName, manifestSource),
      packageId: _manifest(packageId, manifestSource),
      version: _manifest(version, manifestSource),
      buildNumber: _manifest(buildNumber, manifestSource),
      signatureVerdict: PackageAnalysisResult.verdictFrom(signature),
      diagnostics: diagnostics,
      android: android,
    );
  }

  /// 加固线索的置信度。
  ///
  /// 分级依据是「这条特征本身是否正常」：
  /// - **strong**：正常构建流程不会产出这些特征，单条即可说明异常。
  /// - **weak**：本身常见或属于推断，单独出现不足以支撑任何结论。
  ///
  /// `multipleDexFiles` 与 `unusualNativeLibraryName` 都归 weak —— 未加固的
  /// 现代应用因 64K 方法数上限也会分片 DEX，原生库命名不合约定也可能只是
  /// 构建脚本的怪癖。规范 4.2 要求不得据单一特征下判断，置信度就是那个约束
  /// 在数据上的体现。
  static HintConfidence confidenceOf(HardeningSignal signal) =>
      switch (signal) {
        HardeningSignal.missingPrimaryDex ||
        HardeningSignal.dexHeaderNotStandard ||
        HardeningSignal.executableInAssets =>
          HintConfidence.strong,
        HardeningSignal.multipleDexFiles ||
        HardeningSignal.unusualNativeLibraryName ||
        HardeningSignal.resourceTableAnomaly =>
          HintConfidence.weak,
      };

  /// 构造一个来自 manifest 的字段值。
  ///
  /// `null` 一律记为 [FieldStatus.absent]：解析器**成功读到了** manifest 时，
  /// 取不到值就意味着 manifest 里确实没有声明该属性。这与「读不到」不同 ——
  /// 读不到由 [FieldValue.failed] / [FieldValue.hardenedUnknown] 表达。
  static FieldValue<T> _manifest<T>(T? value, FieldSource source) {
    if (value == null) return FieldValue<T>.absent(source: source);
    return FieldValue<T>.extracted(value, source: source);
  }
}
