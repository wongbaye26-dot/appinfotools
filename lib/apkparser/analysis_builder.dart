import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show
        AndroidComponent,
        ContainerStructure,
        HardeningObservation,
        HardeningSignal;
import 'package:ipa_parser/ipa_parser.dart' show IpaContainer;
import 'package:path/path.dart' as path;

/// 可被多个来源提供的 Android 字段。
///
/// 存在的意义是支撑 [AnalysisBuilder.capabilities]：**一个来源不报某字段**，
/// 与**文件里没有这个字段**，是两件必须分开的事。
enum AndroidField {
  appName,
  packageId,
  version,
  buildNumber,
  minSdkVersion,
  targetSdkVersion,
  maxSdkVersion,
  debuggable,
  components,
  permissions,
}

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

  /// 各来源**能够**提供的字段。
  ///
  /// 这是「分层、可回退」合并策略的前提。清单依据的是各工具的实际输出能力，
  /// 不是想当然：
  ///
  /// - 内置解析器直接读 AXML / ARSC，因此 manifest 里的东西它都能给，
  ///   包括全部五类组件与 `android:exported`。
  /// - `aapt2 dump badging` 的输出里**没有** `maxSdkVersion`，**没有**
  ///   `debuggable`，组件方面只给 `launchable-activity` —— 没有
  ///   service / receiver / provider，也没有 `exported`。
  ///   所以这三项不在 aapt2 的能力范围内。
  ///
  /// 缺了这份清单，aapt2 分支的空白就会被记成 `absent`（「文件里没有」），
  /// 而不是 `unsupported`（「这个来源不报」）—— 前者会误导用户，
  /// 也会让后续的字段级合并做出错误判断。
  static const Map<FieldSource, Set<AndroidField>> capabilities = {
    FieldSource.builtinParser: {
      AndroidField.appName,
      AndroidField.packageId,
      AndroidField.version,
      AndroidField.buildNumber,
      AndroidField.minSdkVersion,
      AndroidField.targetSdkVersion,
      AndroidField.maxSdkVersion,
      AndroidField.debuggable,
      AndroidField.components,
      AndroidField.permissions,
    },
    FieldSource.aapt2: {
      AndroidField.appName,
      AndroidField.packageId,
      AndroidField.version,
      AndroidField.buildNumber,
      AndroidField.minSdkVersion,
      AndroidField.targetSdkVersion,
      AndroidField.permissions,
    },
  };

  /// 某个来源是否提供某个字段。
  static bool sourceProvides(FieldSource source, AndroidField field) =>
      capabilities[source]?.contains(field) ?? false;

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
    ContainerStructure? structure,
    SignatureAnalysis? signature,
    SecurityAnalysisResult? security,
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
      minSdkVersion:
          _manifest(minSdkVersion, manifestSource, AndroidField.minSdkVersion),
      targetSdkVersion: _manifest(
          targetSdkVersion, manifestSource, AndroidField.targetSdkVersion),
      maxSdkVersion:
          _manifest(maxSdkVersion, manifestSource, AndroidField.maxSdkVersion),
      debuggable:
          _manifest(debuggable, manifestSource, AndroidField.debuggable),
      permissions: permissions,
      components: _manifest(
        components.isEmpty ? null : components,
        manifestSource,
        AndroidField.components,
      ),
      signature: signature,
      hardeningHints: hardeningHints,
      structure: structure,
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
      appName: _manifest(appName, manifestSource, AndroidField.appName),
      packageId: _manifest(packageId, manifestSource, AndroidField.packageId),
      version: _manifest(version, manifestSource, AndroidField.version),
      buildNumber:
          _manifest(buildNumber, manifestSource, AndroidField.buildNumber),
      signatureVerdict: PackageAnalysisResult.verdictFrom(signature),
      diagnostics: diagnostics,
      android: android,
      security: security,
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
        HardeningSignal.executableInAssets ||
        // 正常构建流程不会产出「文件同时被当目录前缀」的结构 ——
        // 与上面几条同属「单条即可说明异常」。
        HardeningSignal.decoyArchiveEntries ||
        // 同理：正常构建流程不会产出非标准 AXML 布局。
        HardeningSignal.manifestLayoutAnomaly =>
          HintConfidence.strong,
        HardeningSignal.multipleDexFiles ||
        HardeningSignal.unusualNativeLibraryName ||
        HardeningSignal.resourceTableAnomaly =>
          HintConfidence.weak,
      };

  /// 构造一个来自 manifest 的字段值。
  ///
  /// 三种结果的判定依据是**来源能力**，而不是「值是否为空」：
  /// - 有值 → [FieldStatus.extracted]
  /// - 该来源会报这个字段、但没有值 → [FieldStatus.absent]（文件里确实没声明）
  /// - 该来源**不报**这个字段 → [FieldStatus.unsupported]（我们没读到，不是没有）
  ///
  /// 第三点是这次对齐的核心：`aapt2 dump badging` 不输出 `maxSdkVersion`、
  /// `debuggable`，组件方面也只给 `launchable-activity`。若把这些空白一律记成
  /// `absent`，用户会以为文件里没有，而后续的字段级合并也会做出错误判断。
  static FieldValue<T> _manifest<T>(
    T? value,
    FieldSource source,
    AndroidField field,
  ) {
    if (value != null) return FieldValue<T>.extracted(value, source: source);
    if (sourceProvides(source, field)) {
      return FieldValue<T>.absent(source: source);
    }
    return FieldValue<T>.unsupported(
      diagnostic: '${source.name} does not report ${field.name}',
    );
  }

  /// 把 iOS 的解析结果组装成统一的 [PackageAnalysisResult]。
  ///
  /// 与 Android 侧不同的是这里**没有多来源合并**：`Info.plist` 是唯一来源，
  /// 不存在「分层、可回退」的问题。因此每个字段直接取
  /// [IpaInfoPlist] 里的 [FieldValue] —— 它已经带着「值 + 状态 + 来源 + 诊断」，
  /// 再包一层只会丢失信息。
  ///
  /// [analysis] 为 `null` 表示静态解析本身没做成（例如容器打开失败），
  /// 此时 [unavailableReason] 必须给出原因。
  static PackageAnalysisResult buildIos({
    required String filePath,
    required int fileSize,
    FileHashes? hashes,
    IpaAnalysis? analysis,
    IosCodeSignResult? codeSign,
    SecurityAnalysisResult? security,
    String? unavailableReason,
    List<AnalysisDiagnostic> diagnostics = const [],
  }) {
    final info = analysis?.infoPlist;

    final ios = IosPackageInfo(
      // 容器缺失时给一个空容器，而不是让 UI 面对 null 分支 ——
      // 「没有 bundle」本身就是容器层的合法结果。
      container: analysis?.container ?? const IpaContainer(),
      bundleIdentifier: _ios(info?.bundleIdentifier),
      displayName: _ios(info?.displayName),
      bundleName: _ios(info?.bundleName),
      shortVersion: _ios(info?.shortVersionString),
      buildNumber: _ios(info?.bundleVersion),
      minimumOSVersion: _ios(info?.minimumOSVersion),
      deviceFamily: _ios(info?.deviceFamily),
      queriesSchemes: _ios(info?.queriesSchemes),
      requiredDeviceCapabilities: _ios(info?.requiredDeviceCapabilities),
      urlSchemes: _ios(info?.urlSchemes),
      backgroundModes: _ios(info?.backgroundModes),
      icons: _ios(info?.icons),
      executableName: _ios(info?.executable),
      executable: analysis?.executable,
      executablePath: analysis?.executablePath,
      nestedBinaries: analysis?.nestedBinaries ?? const [],
      icon: analysis?.icon,
      signatureMaterials: analysis?.signature,
      authorization: analysis?.authorization,
      codeSign: codeSign,
      diagnostics: analysis?.allDiagnostics ?? const [],
      unavailableReason: unavailableReason,
    );

    return PackageAnalysisResult(
      platform: PackagePlatform.ios,
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
      appName: ios.preferredName,
      packageId: ios.bundleIdentifier,
      version: ios.shortVersion,
      buildNumber: ios.buildNumber,
      // **有材料不等于验证过**：结论只来自 codesign。没跑就是「无法确认」。
      signatureVerdict: PackageAnalysisResult.verdictFromIos(codeSign),
      diagnostics: diagnostics,
      ios: ios,
      security: security,
    );
  }

  /// 取 iOS 子解析器给出的字段；缺失时返回「不存在」而不是抛错。
  ///
  /// 这里保留 `source`：它来自 `infoPlist` / `machO` 等真实来源，
  /// 不该被这里改写成别的值。
  static FieldValue<T> _ios<T>(FieldValue<T>? value) =>
      value ?? FieldValue<T>.absent(source: FieldSource.infoPlist);
}
