import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';

/// 从已解析的结果推断「架构位数」标签：`64-bit` / `32-bit` / `64/32-bit`。
///
/// **取不到时返回 `null`，绝不猜。** 没解析出结果、或结果里没有可用的位数
/// 线索时，界面上就不显示这一项 —— 「不知道」与「32 位」是两件事，把前者
/// 渲染成后者会让用户按错的架构去分发。
///
/// 两侧的依据不同，但都来自**文件里的真实结构**：
/// - **iOS**：主可执行文件 Mach-O 各镜像的 `is64Bit`（`LC_SEGMENT` 的
///   段位数，不是文件名里的字样）；
/// - **Android**：容器里 `lib/<abi>/` 的 ABI 名字（`structure.abis`），
///   ABI 名里带 `64` 的就是 64 位。
///
/// 三种结果都要能出来：只含 64 位、只含 32 位、以及**两者都有**（fat
/// Mach-O 或同时带 `arm64-v8a` 与 `armeabi-v7a` 的 APK）。第三种最容易被
/// 简化掉 —— 而它恰恰是「这个包能不能装在老设备上」的答案。
///
/// 这份实现原先内联在概览页的 Hero 里；详情页的应用信息也要显示同一项，
/// 两处各写一遍迟早会分叉（本项目已经因为「同一个判定两处实现」踩过坑）。
String? architectureLabelOf(PackageAnalysisResult? analysis) {
  if (analysis == null) return null;

  final bool has64;
  final bool has32;
  final ios = analysis.ios;
  if (ios != null) {
    final images = ios.executable?.images;
    if (images == null || images.isEmpty) return null;
    has64 = images.any((img) => img.is64Bit);
    has32 = images.any((img) => !img.is64Bit);
  } else {
    final abis = analysis.android?.structure?.abis;
    if (abis == null || abis.isEmpty) return null;
    has64 = abis.any((abi) => abi.contains('64'));
    has32 = abis.any((abi) => !abi.contains('64'));
  }

  if (has64 && has32) return '64/32-bit';
  if (has64) return '64-bit';
  return '32-bit';
}
