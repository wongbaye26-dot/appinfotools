import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ContainerStructure;
import 'hardening.dart';

/// 应用包所属平台。
enum PackagePlatform { android, ios, unknown }

/// 签名结论 —— 平台中立。
///
/// Android 走 apksigner、iOS 走 codesign 或静态材料分析，机制完全不同；
/// 但对用户而言结论只有三种：通过 / 不通过 / 无法确认。
///
/// 这里**只放结论**：平台特有的细节（验证了哪些方案、证书指纹、退出码）
/// 留在各自的平台信息对象里。把 Android 的签名方案和 iOS 的
/// `embedded.mobileprovision` 塞进同一个字段，会让两边都失真。
enum SignatureVerdict {
  /// 验证通过。
  verified,

  /// 明确验证不通过。
  rejected,

  /// 无法得出结论（工具不可用、结果未知、或该平台尚未实现）。
  ///
  /// 这是**必须**与 [rejected] 分开的一态：把「没装 Android SDK」显示成
  /// 「签名无效」，会把正常开发机误报成恶意应用。
  inconclusive,

  /// 未做签名检查（用户关闭了该功能）。
  notChecked;

  /// 是否给出了明确结论。
  bool get isConclusive =>
      this == SignatureVerdict.verified || this == SignatureVerdict.rejected;
}

/// Android 专属信息。
///
/// 与 [PackageAnalysisResult] 的通用字段分开：SDK 版本、组件、权限这些概念
/// 在 iOS 上没有对应物，混进通用字段只会让通用字段变成「有时有意义的杂项」。
class AndroidPackageInfo {
  final FieldValue<int> minSdkVersion;
  final FieldValue<int> targetSdkVersion;
  final FieldValue<int> maxSdkVersion;

  /// `<application android:debuggable>`。未声明时为 `absent`，不是 `false`。
  final FieldValue<bool> debuggable;

  final List<String> permissions;

  /// 组件列表。
  ///
  /// 是 [FieldValue] 而不是裸 List：`aapt2 dump badging` 只输出
  /// `launchable-activity`，不输出 service / receiver / provider，也没有
  /// `exported`。用一个空列表表示「没有组件」会让用户以为应用真的没有这些
  /// 组件 —— 实际是那个来源根本不报。状态字段把这两件事分开。
  final FieldValue<List<AndroidComponent>> components;

  /// 签名分析详情（含证书、方案、工具原始输出）。
  ///
  /// 为 `null` 表示未启用签名检查；`SignatureStatus.toolUnavailable` 表示
  /// 工具不可用 —— 两者含义不同，不能合并。
  final SignatureAnalysis? signature;

  /// 可能经过加固的线索。
  ///
  /// 规范 4.2 要求区分「可能经过加固，无法确认原始内容」，本列表就是那类
  /// 结论的载体。
  final List<HardeningHint> hardeningHints;

  /// 容器结构概览（DEX 数量、原生库、ABI、顶层目录、解压后总字节数）。
  ///
  /// 这里刻意**不**用 `FieldValue` 包一层：它是复合结构而不是单一字段，
  /// 内部的计数要么观测到、要么没有，不存在「值 + 状态 + 来源」的多种组合，
  /// 来源恒为 `FieldSource.zipDirectory`。
  final ContainerStructure? structure;

  const AndroidPackageInfo({
    this.minSdkVersion = const FieldValue.absent(),
    this.targetSdkVersion = const FieldValue.absent(),
    this.maxSdkVersion = const FieldValue.absent(),
    this.debuggable = const FieldValue.absent(),
    this.permissions = const [],
    this.components = const FieldValue<List<AndroidComponent>>.absent(),
    this.signature,
    this.hardeningHints = const [],
    this.structure,
  });

  /// 是否观察到了任何加固线索。
  bool get mayBeHardened => hardeningHints.isNotEmpty;

  /// 是否存在**强**线索（单独一条即可说明异常）。
  bool get hasStrongHardeningSignal =>
      hardeningHints.any((h) => h.confidence == HintConfidence.strong);
}

/// iOS 专属信息。
///
/// 目前是空壳 —— IPA 解析引擎尚未实现（规范第五步）。
///
/// **刻意保留为独立类型**而不是把字段塞进 [PackageAnalysisResult] 的通用部分：
/// Android 权限与 iOS Entitlements 语义不同（前者是「申请什么」，
/// 后者是「被授权什么」），合并成一个列表会让两边都失真。
class IosPackageInfo {
  /// 说明该平台分析能力的可用状态，供 UI 明确告知用户「为什么这里是空的」。
  final String unavailableReason;

  const IosPackageInfo({
    this.unavailableReason = 'iOS (IPA) analysis is not implemented yet',
  });
}

/// 跨平台的应用包分析结果。
///
/// 顶层字段按规范第六步要求固定；平台专属信息用 [android] / [ios] 分离承载。
///
/// 每个字段都是 [FieldValue]，因此「值 + 状态 + 来源 + 诊断」四件事始终在
/// 一起 —— 不会出现「有值但不知道哪来的」或「空着但不知道是没读还是没读到」。
class PackageAnalysisResult {
  final PackagePlatform platform;

  final FieldValue<String> fileName;
  final FieldValue<int> fileSize;

  /// 文件 SHA-256（十六进制小写）。
  ///
  /// 规范 4.1 要求提供 SHA-256；此前项目只有 MD5 / SHA-1。
  final FieldValue<String> sha256;

  final FieldValue<String> appName;

  /// 包标识：Android 是包名，iOS 是 `CFBundleIdentifier`。
  final FieldValue<String> packageId;

  /// 面向用户的版本：Android 是 `versionName`，iOS 是
  /// `CFBundleShortVersionString`。
  final FieldValue<String> version;

  /// 构建号：Android 是 `versionCode`，iOS 是 `CFBundleVersion`。
  final FieldValue<String> buildNumber;

  /// 签名结论（平台中立的三态 + 未检查）。
  final SignatureVerdict signatureVerdict;

  /// 解析过程中的诊断记录。
  final List<AnalysisDiagnostic> diagnostics;

  final AndroidPackageInfo? android;
  final IosPackageInfo? ios;

  const PackageAnalysisResult({
    this.platform = PackagePlatform.unknown,
    this.fileName = const FieldValue.absent(),
    this.fileSize = const FieldValue.absent(),
    this.sha256 = const FieldValue.absent(),
    this.appName = const FieldValue.absent(),
    this.packageId = const FieldValue.absent(),
    this.version = const FieldValue.absent(),
    this.buildNumber = const FieldValue.absent(),
    this.signatureVerdict = SignatureVerdict.notChecked,
    this.diagnostics = const [],
    this.android,
    this.ios,
  });

  /// 把 Android 的签名状态折算成平台中立结论。
  ///
  /// `toolUnavailable` 与 `unknown` 都归入 [SignatureVerdict.inconclusive] ——
  /// 它们对用户的含义是一样的：我们没法给结论。但**详情仍然保留**在
  /// [AndroidPackageInfo.signature] 里，用户能看到究竟为什么没结论。
  static SignatureVerdict verdictFrom(SignatureAnalysis? analysis) {
    if (analysis == null) return SignatureVerdict.notChecked;
    return switch (analysis.status) {
      SignatureStatus.verified => SignatureVerdict.verified,
      SignatureStatus.verificationFailed => SignatureVerdict.rejected,
      SignatureStatus.toolUnavailable ||
      SignatureStatus.unknown =>
        SignatureVerdict.inconclusive,
    };
  }

  /// 是否有任何诊断达到指定严重度。
  bool hasDiagnosticAtLeast(DiagnosticSeverity severity) {
    final rank = {
      DiagnosticSeverity.info: 0,
      DiagnosticSeverity.warning: 1,
      DiagnosticSeverity.error: 2
    };
    return diagnostics.any((d) => rank[d.severity]! >= rank[severity]!);
  }
}
