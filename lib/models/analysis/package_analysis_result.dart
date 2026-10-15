import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ContainerStructure;
import 'package:ipa_parser/ipa_parser.dart'
    show
        IosAuthorizationComparison,
        IosBundle,
        IosIconConfiguration,
        IosIconResolution,
        IosSignatureMaterials,
        IpaContainer,
        MachOFile;
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
/// **刻意保留为独立类型**而不是把字段塞进 [PackageAnalysisResult] 的通用部分：
/// Android 权限与 iOS Entitlements 语义不同（前者是「申请什么」，
/// 后者是「被授权什么」），合并成一个列表会让两边都失真。
///
/// 字段分两类：
/// - 来自 `Info.plist` 的**声明**（bundle id、版本、最低系统版本…），
///   每个都是 [FieldValue]，因此「文件里没有」与「读不出来」始终分开；
/// - 来自容器与二进制的**观察**（bundle 清单、Mach-O、签名材料），
///   它们是复合结构，内部不存在「值 + 状态」的多种组合。
class IosPackageInfo {
  // --- Info.plist 声明 ---

  final FieldValue<String> bundleIdentifier;
  final FieldValue<String> displayName;
  final FieldValue<String> bundleName;
  final FieldValue<String> shortVersion;
  final FieldValue<String> buildNumber;
  final FieldValue<String> minimumOSVersion;
  final FieldValue<List<int>> deviceFamily;
  final FieldValue<List<String>> queriesSchemes;
  final FieldValue<List<String>> requiredDeviceCapabilities;

  /// `CFBundleURLTypes` 里注册的 URL scheme —— **外部可以唤起本应用**的入口。
  ///
  /// 与 [queriesSchemes] 方向相反：那个是本应用能唤起别人（白名单），
  /// 这个是别人能唤起本应用（攻击面）。
  final FieldValue<List<String>> urlSchemes;

  /// `UIBackgroundModes`：声明申请的后台执行模式。
  final FieldValue<List<String>> backgroundModes;
  final FieldValue<IosIconConfiguration> icons;

  /// `CFBundleExecutable` —— 主可执行文件名。
  final FieldValue<String> executableName;

  // --- 容器与二进制观察 ---

  /// 容器结构（全部 bundle、体积、条目数）。
  final IpaContainer container;

  /// 主可执行文件的 Mach-O 解析结果；取不到时为 `null`。
  final MachOFile? executable;

  /// 主可执行文件在归档中的条目名。
  final String? executablePath;

  /// 嵌套 bundle 的二进制清单（扩展 / Watch / 框架）。
  final List<IosNestedBinary> nestedBinaries;

  /// 图标定位结果。
  final IosIconResolution? icon;

  // --- 签名与授权 ---

  /// 签名材料的**静态**内容（`_CodeSignature/` 条目、描述文件字段）。
  ///
  /// 注意这与 [codeSign] 的区别：这里只是「材料长什么样」。
  final IosSignatureMaterials? signatureMaterials;

  /// 应用声明与描述文件授权的比对；无法比较时为 `null`。
  final IosAuthorizationComparison? authorization;

  /// macOS `codesign` 的验证结果。
  ///
  /// 为 `null` 表示**没有做**这项检查（非 macOS、用户关闭了该功能、
  /// 或解包失败）—— 与 `toolUnavailable` 的含义不同，前者是「我们没查」，
  /// 后者是「查不了」。UI 必须把这两件事分开显示。
  final IosCodeSignResult? codeSign;

  final List<AnalysisDiagnostic> diagnostics;

  /// 说明该平台分析为何不可用；可用时为 `null`。
  ///
  /// 非空时其余字段都是空状态 —— UI 据此显示「为什么这里是空的」，
  /// 而不是把空字段渲染成「没有这些信息」。
  final String? unavailableReason;

  const IosPackageInfo({
    required this.container,
    this.bundleIdentifier = const FieldValue.absent(),
    this.displayName = const FieldValue.absent(),
    this.bundleName = const FieldValue.absent(),
    this.shortVersion = const FieldValue.absent(),
    this.buildNumber = const FieldValue.absent(),
    this.minimumOSVersion = const FieldValue.absent(),
    this.deviceFamily = const FieldValue<List<int>>.absent(),
    this.queriesSchemes = const FieldValue<List<String>>.absent(),
    this.requiredDeviceCapabilities = const FieldValue<List<String>>.absent(),
    this.urlSchemes = const FieldValue<List<String>>.absent(),
    this.backgroundModes = const FieldValue<List<String>>.absent(),
    this.icons = const FieldValue<IosIconConfiguration>.absent(),
    this.executableName = const FieldValue.absent(),
    this.executable,
    this.executablePath,
    this.nestedBinaries = const [],
    this.icon,
    this.signatureMaterials,
    this.authorization,
    this.codeSign,
    this.diagnostics = const [],
    this.unavailableReason,
  });

  /// 名称：优先显示名，退回 `CFBundleName`（与 `IpaInfoPlist.preferredName`
  /// 同一条规则，这里再走一遍是因为两个模型之间刻意不共享 getter）。
  FieldValue<String> get preferredName {
    if (displayName.hasValue) return displayName;
    if (bundleName.hasValue) return bundleName;
    if (displayName.status != FieldStatus.absent) return displayName;
    return bundleName;
  }

  /// 主应用的 bundle。
  IosBundle? get mainApp => container.mainApp;

  /// 主可执行文件的全部架构名。
  List<String> get architectures =>
      executable?.architectureNames ?? const <String>[];

  /// 是否观察到多个 `Payload/*.app`。
  bool get hasMultipleMainApps => container.hasMultipleMainApps;

  /// 签名材料是否存在（**不代表签名有效**）。
  bool get hasSignatureMaterials => signatureMaterials?.hasAnyMaterial ?? false;

  /// 是否拿到了明确的签名结论。
  bool get hasConclusiveSignature =>
      codeSign?.status.hasConclusiveResult ?? false;
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

  /// 分包一致性核对结果。
  ///
  /// `null` 表示**没查**（单 APK 没有分包，或本次未做这项检查）——
  /// 与「查了没问题」（非 null 且 `issues` 为空）必须分开。
  final SplitConsistency? splitConsistency;

  /// 安全检测分析结果。
  ///
  /// `null` 表示未启用安全检测，或该解析路径尚未接入安全分析
  ///（例如 aapt2 路径信息不完整）。
  final SecurityAnalysisResult? security;

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
    this.security,
    this.splitConsistency,
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

  /// 把 iOS 的签名状态折算成平台中立结论。
  ///
  /// 与 Android 侧的关键差别：iOS 上**有签名材料**不代表验证过。因此：
  /// - 跑过 `codesign` → 用它的结论；
  /// - 没跑（非 macOS / 用户关闭 / 解包失败）→ 一律 [SignatureVerdict.inconclusive]，
  ///   即便材料看起来齐全。这正是规范 5.5 禁止的「把材料存在当作验证通过」。
  static SignatureVerdict verdictFromIos(IosCodeSignResult? codeSign) {
    if (codeSign == null) return SignatureVerdict.inconclusive;
    return switch (codeSign.status) {
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
