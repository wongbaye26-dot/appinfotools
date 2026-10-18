// 从 `Assets.car` 里**取出**一张图（LZFSE 解码 + 转 PNG）。
//
// ## 通道顺序是实测定的，不是猜的
//
// `ISTC` 头里的 4CC 是**反序存**的：文件里写 `BGRA`，读出来（反转后）是
// `ARGB`（与 `assetutil --info` 的 `Encoding` 一致）。但 4CC 只说明**逻辑**
// 通道顺序，不说明字节布局 —— `kCGBitmapByteOrder32Little` 会把
// `ARGB` 变成内存里的 `B,G,R,A`。
//
// 这一点**不能靠推理定**，所以用真实图标做了目视验证：解出 Chess.app 的
// 1024×1024 图标，按 `B,G,R,A` 与 `A,R,G,B` 两种顺序各出一张 PNG，看图。
// 结论写在 [_channelPlan] 的注释里。
//
// ## 只做能验证的格式
//
// | `pixelFormat` | 处理 |
// |---|---|
// | `ARGB` / `BGRA` | 4 通道 → PNG RGBA |
// | `GA8 ` | 灰度 + alpha → PNG 灰度+alpha |
// | 其它（`RGBW` / `ATAD` / `GVS ` …） | 明确报「不支持」，不猜 |
//
// `ATAD` 是解压后的数据区（不是像素），`GVS `/`PDF ` 是矢量 —— 它们本来
// 就没有像素可取。

import 'dart:typed_data';

import 'assets_car.dart';
import 'lzfse.dart';
import 'png_encoder.dart';

/// 一次提取的结果。
class CarImageExtraction {
  /// 编码好的 PNG；失败时为 `null`。
  final Uint8List? png;

  /// 失败原因；成功时为 `null`。
  final String? failure;

  /// 失败原因的稳定标识。
  final String? failureCode;

  const CarImageExtraction({this.png, this.failure, this.failureCode});

  const CarImageExtraction.failed(String code, String reason)
      : png = null,
        failure = reason,
        failureCode = code;

  bool get ok => png != null;
}

/// 一张图的通道布局。
class _ChannelPlan {
  /// 输出用的 PNG 颜色类型。
  final PngColorType colorType;

  /// 每像素字节数（源）。
  final int bytesPerPixel;

  /// 源字节索引 → 输出通道的映射（顺序即 R,G,B,A 或 Gray,Alpha）。
  final List<int> pick;

  const _ChannelPlan(this.colorType, this.bytesPerPixel, this.pick);
}

/// 已知的像素格式 → 通道布局。
///
/// **`ARGB` / `BGRA` 都映射到 `B,G,R,A` 的字节布局再取 `R,G,B,A`**：
/// 实测（Chess.app 的图标目视核对）印证了这一点 —— 若按 `A,R,G,B` 读，
/// 图标会呈现明显的蓝/橙互换。`CGImage` 的
/// `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`
/// 正是这个组合。
const Map<String, _ChannelPlan> _channelPlan = {
  'ARGB': _ChannelPlan(PngColorType.rgba, 4, [2, 1, 0, 3]),
  'BGRA': _ChannelPlan(PngColorType.rgba, 4, [2, 1, 0, 3]),
  'GA8 ': _ChannelPlan(PngColorType.grayAlpha, 2, [0, 1]),
  'GA16': _ChannelPlan(PngColorType.grayAlpha, 2, [0, 1]),
};

/// 从 `Assets.car` 的字节里提取 [image] 的像素并编码成 PNG。
///
/// [carBytes] 必须是完整的 `Assets.car` 内容（`image.payloadOffset` 是它的
/// 绝对偏移）。
CarImageExtraction extractCarImagePng(
  Uint8List carBytes,
  AssetsCarImage image,
) {
  if (!image.isRasterImage) {
    return CarImageExtraction.failed('not_raster',
        'this rendition is not a raster image (${image.pixelFormat ?? 'no pixel format'})');
  }
  final offset = image.payloadOffset;
  if (offset == null) {
    return const CarImageExtraction.failed(
        'no_payload',
        'the rendition has no compressed payload — a placeholder entry with '
            'dimensions but no pixel data');
  }
  if (!image.compression.isCompressed &&
      image.compression != CarCompression.lzfseUncompressed) {
    return const CarImageExtraction.failed(
        'not_compressed', 'the payload is not a recognised LZFSE stream');
  }
  final format = image.pixelFormat;
  final plan = format == null ? null : _channelPlan[format];
  if (plan == null) {
    return CarImageExtraction.failed(
        'unsupported_format',
        'pixel format "${format ?? 'none'}" is not handled (only ARGB / BGRA / '
            'GA8 are)');
  }

  final width = image.width!;
  final height = image.height!;
  final blockEnd = image.blockOffset + image.sizeOnDisk;
  if (offset < 0 || offset >= blockEnd || blockEnd > carBytes.length) {
    return CarImageExtraction.failed(
        'bad_payload_bounds',
        'the payload offset $offset / block end $blockEnd does not fit the '
            'file (${carBytes.length} bytes)');
  }

  final Uint8List pixels;
  try {
    pixels = lzfseDecode(Uint8List.sublistView(carBytes, offset, blockEnd));
  } on LzfseException catch (e) {
    return CarImageExtraction.failed('lzfse_${e.code}', e.message);
  }

  final expected = width * height * plan.bytesPerPixel;
  if (pixels.length != expected) {
    return CarImageExtraction.failed(
        'pixel_size_mismatch',
        'decoded ${pixels.length} bytes but ${width}x$height x '
            '${plan.bytesPerPixel} channels needs $expected');
  }

  // 通道重排（例如 B,G,R,A → R,G,B,A）。
  final channels = plan.colorType.channels;
  final reordered = Uint8List(width * height * channels);
  for (var i = 0; i < width * height; i++) {
    for (var c = 0; c < channels; c++) {
      reordered[i * channels + c] =
          pixels[i * plan.bytesPerPixel + plan.pick[c]];
    }
  }

  final png = encodePng(
    width: width,
    height: height,
    colorType: plan.colorType,
    pixels: reordered,
  );
  if (png == null) {
    return const CarImageExtraction.failed(
        'encode_failed', 'the PNG encoder rejected the pixel data');
  }
  return CarImageExtraction(png: png);
}

/// 在 `Assets.car` 的图片里挑一张「最像应用图标」的。
///
/// 判据只有两条，都是**可观察的事实**，不做猜测：
/// 1. 真有像素（`embedsPixels`）；
/// 2. 像素面积最大。
///
/// 名字里带 `AppIcon` 的优先 —— 那是 iOS 的惯例命名，但**不是必需**：
/// macOS 应用的图标叫 `image.png` / `AppIcon256x256_...` 都出现过。
AssetsCarImage? pickLargestImage(AssetsCarCatalog catalog) {
  final images = catalog.rasterImages;
  if (images.isEmpty) return null;
  final sorted = [...images]..sort((a, b) {
      final areaA = (a.width ?? 0) * (a.height ?? 0);
      final areaB = (b.width ?? 0) * (b.height ?? 0);
      return areaB.compareTo(areaA);
    });
  return sorted.first;
}
