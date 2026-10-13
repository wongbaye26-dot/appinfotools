import 'dart:ui' as ui;

import 'package:apk_info_tool/utils/logger.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show IosIconCandidate, IosImageFormat, isCgbiPng, normalizeCgbiPng;

/// 一次图标解码的结果。
///
/// 「没有图」与「图很大所以没解码」是两件事，因此 [failure] 必须带上原因 ——
/// 否则 UI 只能显示一个空白框，用户不知道是包有问题还是我们没做。
class IosIconDecodeResult {
  /// 解码出的图片；失败时为 `null`。
  final ui.Image? image;

  /// 没有图的原因（英文，进日志与诊断）。
  final String? failure;

  const IosIconDecodeResult._(this.image, this.failure);

  const IosIconDecodeResult.success(ui.Image image) : this._(image, null);

  const IosIconDecodeResult.failure(String reason) : this._(null, reason);

  bool get hasImage => image != null;
}

/// 把 iOS 图标字节解码成可显示的图片。
///
/// 规范 5.3 要求「避免大图解码导致内存耗尽」。这里有三道约束：
///
/// 1. **先看头部尺寸再决定是否解码**。PNG 的 IHDR 给出宽高，解码前就能算出
///    解码后的位图大小；超限直接不解 —— 解完再检查已经晚了，内存已经分配了。
/// 2. **只解码按魔数认定的 PNG / JPEG**。扩展名不算数。
/// 3. **字节缺失就不解码**（解析器对超过 4 MiB 的候选不携带字节）。
///
/// 解码必须在主 isolate 上进行：`dart:ui` 的 `Image` 不能跨 isolate 传递。
class IosIconDecoder {
  IosIconDecoder._();

  /// 允许解码的最大像素数（4096×4096）。
  ///
  /// 按 RGBA 算约 64 MiB —— 对一个图标预览来说已经是上限了。真实的 iOS 图标
  /// 最大也就 1024×1024。
  static const int maxPixels = 4096 * 4096;

  /// 可解码的格式。
  ///
  /// 就是 Flutter 的 `instantiateImageCodec` 支持的那几种位图。
  /// `HEIC` 不在其中（系统能解，Flutter 不能），`Assets.car` 里的图标根本不是
  /// 独立文件 —— 它们都会走 [IosIconDecodeResult.failure]，而不是被随便找一张
  /// 别的图代替（规范 5.3 明确禁止）。
  static const Set<IosImageFormat> _decodable = {
    IosImageFormat.png,
    IosImageFormat.jpeg,
    IosImageFormat.gif,
    IosImageFormat.webp,
  };

  static Future<IosIconDecodeResult> decode(IosIconCandidate candidate) async {
    final raw = candidate.bytes;
    if (raw == null || raw.isEmpty) {
      return const IosIconDecodeResult.failure(
        'the resolver did not carry this candidate\'s bytes '
        '(it exceeds the size limit)',
      );
    }

    if (!_decodable.contains(candidate.format)) {
      return IosIconDecodeResult.failure(
        '${candidate.format.displayName} is not a bitmap format Flutter can '
        'decode; no substitute image was used',
      );
    }

    // 尺寸已知时先做预算检查 —— 这是唯一能在**分配内存之前**拒绝的机会。
    final width = candidate.pixelWidth;
    final height = candidate.pixelHeight;
    if (width != null && height != null) {
      if (width <= 0 || height <= 0) {
        return const IosIconDecodeResult.failure(
          'the image header declares a zero or negative size',
        );
      }
      final pixels = width * height;
      if (pixels > maxPixels) {
        return IosIconDecodeResult.failure(
          '${width}x$height exceeds the $maxPixels pixel decode budget',
        );
      }
    }

    // Xcode 打包时会把 bundle 里的彩色 PNG 换成 Apple 的 CgBI 变体
    // （`CgBI` 块、裸 deflate、BGRA 预乘），Flutter 的解码器读不了它 ——
    // 表现就是「图标找到了却显示不出来」。这里先规范化成标准 PNG。
    //
    // 转换失败时**如实说明原因**，绝不退而求其次去找一张别的图：
    // 规范 5.3 禁止拿启动画面或截图冒充应用图标。
    var bytes = raw;
    if (isCgbiPng(raw)) {
      final normalized = normalizeCgbiPng(raw);
      if (!normalized.ok) {
        log.warning('IosIconDecoder: ${candidate.archivePath} 是 CgBI 但无法'
            '转换: ${normalized.failure}');
        return IosIconDecodeResult.failure(
          'this is an Apple CgBI ("PNG crush") image and it could not be '
          'converted to a standard PNG: ${normalized.failure}',
        );
      }
      log.info('IosIconDecoder: 已把 CgBI 图标 ${candidate.archivePath} '
          '转成标准 PNG (${raw.length} -> ${normalized.png!.length} bytes)');
      bytes = normalized.png!;
    }

    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return IosIconDecodeResult.success(frame.image);
    } catch (e) {
      log.warning('IosIconDecoder: 解码 ${candidate.archivePath} 失败: $e');
      return IosIconDecodeResult.failure('the image could not be decoded: $e');
    } finally {
      // 已经拿到 frame，codec 不再需要。不释放会一直占着底层解码器。
      codec?.dispose();
    }
  }
}
