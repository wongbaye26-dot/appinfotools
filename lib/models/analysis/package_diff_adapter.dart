import 'package:analysis_model/analysis_model.dart';

import 'package_analysis_result.dart';

/// 把一份 [PackageAnalysisResult] 适配成平台中立的 [DiffSubject]。
///
/// **适配层为什么在应用层**：差异模型（`analysis_model` 的 `package_diff.dart`）
/// 刻意不认识 `PackageAnalysisResult` —— 那会让零依赖的模型包反过来依赖应用层。
/// 于是由这里负责「把两份解析结果摊平成差异模型认识的形状」。
///
/// **字段清单与顺序即报告的输出顺序**，因此这份清单是**契约**：
/// 加字段要同步 `test/package_diff_adapter_test.dart` 里的断言，
/// 否则新增的字段会静默地不进差异。
///
/// 只比**同一平台**的两份包才有意义 —— 跨平台（APK vs IPA）时各自的
/// 平台专属字段会全部落进 `added` / `removed`，那是噪音而不是差异。
/// 调用方负责拦住这种情况（见 [samePlatform]）。
DiffSubject diffSubjectOf(PackageAnalysisResult result) {
  final android = result.android;
  final ios = result.ios;
  // 网络端点挂在安全分析结果上（它是那一步的产物）。
  final network = result.security?.network;

  return DiffSubject(
    fields: [
      // --- 文件身份 ---
      (id: 'file.fileName', value: result.fileName),
      (id: 'file.fileSize', value: result.fileSize),
      (id: 'file.sha256', value: result.sha256),
      // --- 应用身份（两平台通用字段）---
      (id: 'app.name', value: result.appName),
      (id: 'app.id', value: result.packageId),
      (id: 'app.version', value: result.version),
      (id: 'app.buildNumber', value: result.buildNumber),
      // --- Android 专属 ---
      if (android != null) ...[
        (id: 'android.minSdkVersion', value: android.minSdkVersion),
        (id: 'android.targetSdkVersion', value: android.targetSdkVersion),
        (id: 'android.maxSdkVersion', value: android.maxSdkVersion),
        (id: 'android.debuggable', value: android.debuggable),
        (id: 'android.archiveType', value: android.archiveType),
      ],
      // --- iOS 专属 ---
      if (ios != null) ...[
        (id: 'ios.bundleIdentifier', value: ios.bundleIdentifier),
        (id: 'ios.displayName', value: ios.displayName),
        (id: 'ios.shortVersion', value: ios.shortVersion),
        (id: 'ios.buildNumber', value: ios.buildNumber),
        (id: 'ios.minimumOSVersion', value: ios.minimumOSVersion),
        (id: 'ios.executableName', value: ios.executableName),
      ],
    ],
    sets: {
      // --- Android 集合 ---
      if (android != null) ...{
        'android.permissions': android.permissions,
        'android.nativeCodes': android.nativeCodes,
        'android.locales': android.locales,
        'android.densities': android.densities,
      },
      // --- iOS 集合 ---
      if (ios != null) ...{
        'ios.urlSchemes': ios.urlSchemes,
        'ios.queriesSchemes': ios.queriesSchemes,
        'ios.backgroundModes': ios.backgroundModes,
        'ios.requiredDeviceCapabilities': ios.requiredDeviceCapabilities,
      },
      // --- 网络端点：平台中立，单列成一级字段，因此这里也单列 ---
      // `NetworkFacts` 是复合结构而不是 `FieldValue`，这里按「读到了就是
      // extracted、空就是 absent」还原状态 —— 它是**静态提取**的结果，
      // 不存在「来源不报」这一态（提取器总会跑）。
      // 没做安全分析时**不产出**这两个维度 —— 那与「做了、没提取到」
      // 结论相反，不能压成同一个空列表。
      if (network != null) ...{
        'network.domains': _asFieldValue(network.domains),
        'network.ips': _asFieldValue(network.ips),
      },
    },
  );
}

/// 两份包是不是同一个平台。
///
/// 跨平台比较没有意义：Android 与 iOS 的专属字段会全部落进 `added` /
/// `removed`，把噪音当差异。调用方在发起比较前应该先问这一句。
bool samePlatform(PackageAnalysisResult a, PackageAnalysisResult b) =>
    a.platform == b.platform && a.platform != PackagePlatform.unknown;

/// 把一串**静态提取**得到的成员包成 [FieldValue]。
///
/// 空列表记 `absent`（「提取器跑了，包里没有」），不记 `unsupported` ——
/// 提取器不存在「这个来源不报」的情形。
FieldValue<List<String>> _asFieldValue(List<String> members) => members.isEmpty
    ? const FieldValue<List<String>>.absent(source: FieldSource.builtinParser)
    : FieldValue<List<String>>.extracted(
        members,
        source: FieldSource.builtinParser,
      );
