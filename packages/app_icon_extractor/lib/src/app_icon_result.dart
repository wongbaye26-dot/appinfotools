/// 一次图标提取的结果。
///
/// 这个模型是**平台中立**的，也是「原生进程与主应用共用一套结论」的基础：
/// Windows 缩略图处理器只关心 `png` 有没有拿到，但设置页与诊断日志需要知道
/// **为什么没拿到** —— 两者读同一个对象。
library;

import 'dart:typed_data';

/// 提取结果的五态。
///
/// 与项目其它地方（`FieldStatus` / `CoverageStatus`）同一套思路：
/// **「没拿到」必须能区分原因**，因为补救方式完全不同 ——
/// `unsupported` 要补实现，`invalidInput` 要换文件，`resourceLimit` 要调预算。
enum AppIconStatus {
  /// 成功提取到图标。
  success,

  /// 拿到了图标，但用了退让方案（例如自适应图标只取到其中一层位图）。
  ///
  /// 首期不产出这一态：拿不到完整图标时宁可 `unsupported`，
  /// 也不要交一个「看起来像图标但缺了一层」的结果给文件管理器。
  fallback,

  /// 包本身没问题，但我们目前解不了这种图标形态。
  ///
  /// 典型：`<adaptive-icon>` 的矢量合成（需要光栅化，纯 Dart 侧还没有）、
  /// `Assets.car` 里 LZFSE 的未支持变体。
  unsupported,

  /// 输入不是有效安装包，或结构损坏。
  invalidInput,

  /// 触发了大小 / 条目数 / 像素预算。
  ///
  /// 与 [invalidInput] 分开：这类文件可能是**正常的大包**，
  /// 只是我们主动拒绝继续读。
  resourceLimit,
}

/// 图标的来源。
enum AppIconSource {
  /// Android：`resources.arsc` 里解析出的图标资源条目（PNG）。
  androidResourcePng,

  /// Android：`AndroidManifest.xml` 的 `android:icon` 直接写了一个归档路径。
  androidManifestPath,

  /// iOS：`Info.plist` 声明的 PNG（含 `CFBundleIcons` 各表示）。
  iosBundlePng,

  /// iOS：`Assets.car` 资产目录。
  iosAssetCatalog,

  /// 没有可用来源。
  none;

  /// 来源的稳定标识，用于日志与诊断。
  String get id => switch (this) {
        AppIconSource.androidResourcePng => 'android.resource_png',
        AppIconSource.androidManifestPath => 'android.manifest_path',
        AppIconSource.iosBundlePng => 'ios.bundle_png',
        AppIconSource.iosAssetCatalog => 'ios.asset_catalog',
        AppIconSource.none => 'none',
      };
}

/// 图标字节的图片格式。
///
/// ## 为什么不由本包统一转成 PNG
///
/// 最初的实现只发 PNG，结果在真实样本上掉了 4/32：那些包的 launcher 图标是
/// **WebP**（Android Studio 的默认模板从 AGP 3.0 起就这么生成）。
/// 纯 Dart 实现 VP8 解码是另一个工程，而调用方（Windows）本来就有系统级的
/// 图片解码器 —— **WIC** 支持 PNG / JPEG / GIF / BMP，装了 WebP 扩展后也支持
/// WebP。让系统去解，比在本包里重写一遍解码器正确得多。
///
/// 因此本包提供**原始字节 + 格式**，解码责任在调用方。像素尺寸仍在本包内
/// 解析（PNG 读 IHDR、WebP 读 VP8/VP8L/VP8X 头），这样像素上限检查与格式
/// 无关地成立。
enum AppIconFormat {
  png,
  webp,
  jpeg,
  gif,

  /// 认得出来的其它格式（首期不产出）。
  unknown;

  /// 稳定标识，用于日志与 JSON。
  String get id => name;
}

/// 提取结果。
///
/// 不提供 `isSuccess` 之外的任何「凑合」判断：调用方要么拿到 [png]，
/// 要么按 [status] 回退到系统文件图标。**绝不返回一个猜测的图标** ——
/// 文件管理器里「图标对了」和「图标是别人的」比「没有图标」更糟。
class AppIconResult {
  final AppIconStatus status;
  final AppIconSource source;

  /// 图标原始字节。仅 [AppIconStatus.success] / [AppIconStatus.fallback] 时非空。
  ///
  /// **不是**一定为 PNG —— 格式见 [format]，解码由调用方完成。
  final Uint8List? png;

  /// [png] 的图片格式。
  final AppIconFormat format;

  /// 像素宽度；格式头不足以判定时为 `null`。
  final int? pixelWidth;
  final int? pixelHeight;

  /// 稳定原因 code，例如 `android.adaptive_icon_unsupported`。
  ///
  /// 供日志与设置页的诊断区使用；**不要求向普通用户展示**。
  final String? reasonCode;

  /// 人类可读的补充说明（英文回退）。`reasonCode` 认不出来时至少还有它。
  final String? detail;

  const AppIconResult({
    required this.status,
    required this.source,
    this.png,
    this.format = AppIconFormat.unknown,
    this.pixelWidth,
    this.pixelHeight,
    this.reasonCode,
    this.detail,
  });

  /// 成功的构造器。
  factory AppIconResult.success({
    required Uint8List bytes,
    required AppIconFormat format,
    required AppIconSource source,
    int? pixelWidth,
    int? pixelHeight,
  }) =>
      AppIconResult(
        status: AppIconStatus.success,
        source: source,
        png: bytes,
        format: format,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      );

  /// 失败的构造器。
  const AppIconResult.failure(
    AppIconStatus status,
    String reasonCode, {
    String? detail,
    AppIconSource source = AppIconSource.none,
  }) : this(
          status: status,
          source: source,
          reasonCode: reasonCode,
          detail: detail,
        );

  /// 是否拿到了可用图标。
  bool get hasIcon => status == AppIconStatus.success && png != null;

  @override
  String toString() =>
      'AppIconResult(${status.name}, ${source.id}, ${format.id}, '
      '${png?.length ?? 0}B, ${pixelWidth ?? '?'}x${pixelHeight ?? '?'}, '
      'reason=${reasonCode ?? '-'})';
}
