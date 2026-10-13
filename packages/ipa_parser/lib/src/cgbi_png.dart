/// CgBI —— Apple 对 PNG 的私有变体（俗称 "PNG crush"）支持。
///
/// Xcode 打包 iOS 应用时会把 bundle 里的彩色 PNG 换成这种形式：
/// 签名之后紧跟一个 `CgBI` 块，`IDAT` 是**裸 deflate**（没有 zlib 头，
/// 也没有 adler32 尾），像素是 **BGRA 且 RGB 已按 alpha 预乘**。
///
/// Flutter 的解码器读不了它。表现是「图标文件明明找到了，却显示不出来」——
/// 实测真实样本 `sun_signed.ipa` 里的两个 `AppIcon*.png` 都是这种形式。
///
/// 本模块把 CgBI 规范化成标准 PNG（重打包 IDAT、通道换回 RGBA、反预乘），
/// 之后交给平台解码器。**它只做格式转换，不挑选替代图**：规范 5.3 禁止拿
/// 启动画面、截图或随便一张图冒充应用图标。
///
/// ## 变换规则是怎么确定的
///
/// 不是照抄博客，而是拿 Apple 自己的实现当基准逐像素比对：
///
/// 1. 用 `pngcrush -iphone` 把已知像素值的 PNG 转成 CgBI；
/// 2. 用 `pngcrush -revert-iphone-optimizations` 与 `sips` 转回标准 PNG 作基准；
/// 3. 比对得到：`ch0=B, ch1=G, ch2=R, ch3=A`，且 RGB 已预乘
///    （半透明像素满足 `通道 ≤ alpha`），反预乘用**整数截断**
///    （16 个含半透明像素的样本 16/16 一致，四舍五入只有 12/16）。
///
/// 另外实测 `pngcrush -iphone` 对灰度（色彩类型 0）与灰度+alpha（4）**不做**
/// 这个变换，仍输出标准 PNG；对 RGB（2）会先转成 RGBA。因此 CgBI 实际上只以
/// **8 位 RGBA、非隔行**出现 —— [normalizeCgbiPng] 也只接受这一种，其余
/// 一律如实说明原因，而不是猜着解。
///
/// 详细的样本来历与复现命令见 `test/fixtures/cgbi/README.md`。
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// PNG 文件签名。
const List<int> _pngSignature = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A
];

/// 一次 CgBI 规范化的结果。
///
/// 与项目里其它「值 + 状态」的地方一样：失败必须带原因，调用方据此告诉用户
/// 「为什么这张图显示不出来」，而不是留一个空白框。
class CgbiNormalizeResult {
  /// 规范化后的标准 PNG；失败时为 `null`。
  final Uint8List? png;

  /// 失败原因（英文，进日志与诊断）。
  final String? failure;

  const CgbiNormalizeResult._(this.png, this.failure);

  const CgbiNormalizeResult.success(Uint8List png) : this._(png, null);

  const CgbiNormalizeResult.failure(String reason) : this._(null, reason);

  bool get ok => png != null;
}

/// 解析出来的 IHDR。
class _Ihdr {
  final int width;
  final int height;
  final int bitDepth;
  final int colorType;
  final int interlace;

  const _Ihdr(
      this.width, this.height, this.bitDepth, this.colorType, this.interlace);
}

class _Chunk {
  /// 块类型（4 个 ASCII 字符）。
  final String type;

  /// 数据段在文件中的起止（不含长度与 CRC）。
  final int start;
  final int end;

  const _Chunk(this.type, this.start, this.end);
}

/// 是否是 CgBI 变体。
///
/// 判据是**签名之后的第一个块是 `CgBI`** —— 只看这个块，不看扩展名，
/// 也不看有没有别的块（实测还可能出现 `iDOT`，它是 Apple 的并行解码优化，
/// 对解码没有影响）。
bool isCgbiPng(List<int> bytes) {
  final chunks = _readChunks(_asBytes(bytes));
  return chunks != null && chunks.first.type == 'CgBI';
}

/// 走块链读出 PNG 的像素尺寸。
///
/// **不能写死 `IHDR` 在偏移 12**：标准 PNG 确实如此，但 CgBI 的 `IHDR` 前面
/// 还有一个 `CgBI` 块。此前就是写死的，于是真实样本的图标尺寸读成 `null`，
/// 连带「按面积排序」和「解码前的像素预算检查」一起失效。
///
/// 读不出时返回 `null`（畸形文件不猜尺寸）。
(int, int)? readPngSize(List<int> bytes) {
  final data = _asBytes(bytes);
  final chunks = _readChunks(data);
  if (chunks == null) return null;
  for (final chunk in chunks) {
    if (chunk.type != 'IHDR') continue;
    final hdr = _parseIhdr(data, chunk);
    if (hdr == null) return null;
    return (hdr.width, hdr.height);
  }
  return null;
}

/// 把 CgBI 规范化成标准 PNG。
///
/// 失败时返回带原因的结果，**绝不**返回一张「看起来差不多」的图。
CgbiNormalizeResult normalizeCgbiPng(List<int> bytes) {
  final data = _asBytes(bytes);
  final chunks = _readChunks(data);
  if (chunks == null) {
    return const CgbiNormalizeResult.failure(
      'the PNG signature or chunk layout is invalid',
    );
  }
  if (chunks.first.type != 'CgBI') {
    return const CgbiNormalizeResult.failure(
      'this is not a CgBI image; no conversion was applied',
    );
  }

  _Chunk? ihdrChunk;
  for (final chunk in chunks) {
    if (chunk.type == 'IHDR') {
      ihdrChunk = chunk;
      break;
    }
  }
  if (ihdrChunk == null) {
    return const CgbiNormalizeResult.failure('IHDR is missing');
  }
  final hdr = _parseIhdr(data, ihdrChunk);
  if (hdr == null) {
    return const CgbiNormalizeResult.failure('IHDR is malformed');
  }

  // 只接受实测会出现的那一种形态。其余情况如实说明，而不是猜着解 ——
  // 猜错的后果是给用户看一张颜色或透明度错误的「应用图标」。
  if (hdr.bitDepth != 8 || hdr.colorType != 6) {
    return CgbiNormalizeResult.failure(
      'only 8-bit RGBA CgBI images are supported (this one is '
      '${hdr.bitDepth}-bit colour type ${hdr.colorType})',
    );
  }
  if (hdr.interlace != 0) {
    return const CgbiNormalizeResult.failure(
      'interlaced CgBI images are not supported',
    );
  }
  if (hdr.width <= 0 || hdr.height <= 0) {
    return const CgbiNormalizeResult.failure(
      'IHDR declares a zero or negative size',
    );
  }

  final idat = _collectIdat(data, chunks);
  if (idat == null) {
    return const CgbiNormalizeResult.failure('no IDAT data was found');
  }

  const bpp = 4;
  final stride = hdr.width * bpp;
  final expected = hdr.height * (1 + stride);

  Uint8List inflated;
  try {
    // `Inflate` 直接进 `_parseBlock()`，不读 zlib 头、不校验 adler32 ——
    // 正好就是 CgBI 需要的裸 deflate。
    inflated = Inflate(idat, uncompressedSize: expected).getBytes();
  } catch (e) {
    return CgbiNormalizeResult.failure(
      'the deflate stream could not be inflated: $e',
    );
  }
  if (inflated.length < expected) {
    return CgbiNormalizeResult.failure(
      'the inflated data is short: ${inflated.length} < $expected bytes',
    );
  }

  final pixels = _unfilter(inflated, hdr.width, hdr.height, bpp);
  if (pixels == null) {
    return const CgbiNormalizeResult.failure(
      'a scanline uses an unknown filter type',
    );
  }

  // BGRA（预乘）→ RGBA（直通）。
  final rgba = _bgraPremultipliedToRgba(pixels);

  final body = Uint8List(hdr.height * (1 + stride));
  for (var y = 0; y < hdr.height; y++) {
    // 过滤器一律用 0（None）：这里的目标是**正确**，不是压得最小。
    body[y * (1 + stride)] = 0;
    body.setRange(
      y * (1 + stride) + 1,
      y * (1 + stride) + 1 + stride,
      rgba,
      y * stride,
    );
  }

  Uint8List compressed;
  try {
    compressed = const ZLibEncoder().encodeBytes(body);
  } catch (e) {
    return CgbiNormalizeResult.failure('re-compression failed: $e');
  }

  return CgbiNormalizeResult.success(
    _assemblePng(hdr.width, hdr.height, compressed),
  );
}

/// 按块链读取块表。
///
/// 任何越界、长度不自洽都返回 `null` —— 这是不可信输入，先验边界再使用。
List<_Chunk>? _readChunks(Uint8List bytes) {
  if (bytes.length < 8) return null;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _pngSignature[i]) return null;
  }

  final chunks = <_Chunk>[];
  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final length = _readUint32(bytes, offset);
    // 长度是 32 位无符号数；长度 + 数据 + CRC 必须仍在文件内。
    if (offset + 12 + length > bytes.length) return null;
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    chunks.add(_Chunk(type, offset + 8, offset + 8 + length));
    offset += 12 + length;
    if (type == 'IEND') break;
    // 防御：正常 PNG 不会有这么多块，避免畸形文件把内存吃光。
    if (chunks.length > 4096) return null;
  }
  return chunks.isEmpty ? null : chunks;
}

_Ihdr? _parseIhdr(Uint8List bytes, _Chunk chunk) {
  if (chunk.end - chunk.start < 13) return null;
  final width = _readUint32(bytes, chunk.start);
  final height = _readUint32(bytes, chunk.start + 4);
  return _Ihdr(
    width,
    height,
    bytes[chunk.start + 8],
    bytes[chunk.start + 9],
    bytes[chunk.start + 12],
  );
}

/// 把所有 `IDAT` 的数据段首尾相接。
///
/// CgBI 允许把一条 deflate 流拆成多个 `IDAT`（实测就是两个），因此必须拼起来
/// 再解，不能只看第一个。
Uint8List? _collectIdat(Uint8List bytes, List<_Chunk> chunks) {
  final builder = BytesBuilder(copy: false);
  var found = false;
  for (final chunk in chunks) {
    if (chunk.type != 'IDAT') continue;
    builder.add(Uint8List.sublistView(bytes, chunk.start, chunk.end));
    found = true;
  }
  return found ? builder.takeBytes() : null;
}

/// 还原 PNG 的行过滤器。
///
/// 五种过滤器（None / Sub / Up / Average / Paeth）在 PNG 规范里是逐字节运算，
/// **与通道顺序无关** —— 所以先还原、后换通道，两步互不影响。
Uint8List? _unfilter(Uint8List raw, int width, int height, int bpp) {
  final stride = width * bpp;
  final out = Uint8List(height * stride);
  final prev = Uint8List(stride);
  var pos = 0;
  for (var y = 0; y < height; y++) {
    if (pos >= raw.length) return null;
    final filter = raw[pos];
    pos += 1;
    if (filter > 4) return null;
    if (pos + stride > raw.length) return null;

    final lineStart = y * stride;
    for (var i = 0; i < stride; i++) {
      final value = raw[pos + i];
      final a = i >= bpp ? out[lineStart + i - bpp] : 0;
      final b = prev[i];
      final c = i >= bpp ? prev[i - bpp] : 0;
      out[lineStart + i] = switch (filter) {
        0 => value,
        1 => (value + a) & 0xFF,
        2 => (value + b) & 0xFF,
        3 => (value + ((a + b) >> 1)) & 0xFF,
        _ => (value + _paeth(a, b, c)) & 0xFF,
      };
    }
    prev.setRange(0, stride, out, lineStart);
    pos += stride;
  }
  return out;
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// CgBI 的像素布局 → 直通 RGBA。
///
/// 输入是 `B, G, R, A`，且 `B/G/R` 已按 `A` 预乘；输出是 `R, G, B, A` 直通。
/// `A == 255`（应用图标基本都是不透明）时反预乘是恒等变换，结果**逐字节精确**；
/// 半透明像素会有预乘本身的量化误差，这是格式带来的，不是这里的近似。
Uint8List _bgraPremultipliedToRgba(Uint8List pixels) {
  final out = Uint8List(pixels.length);
  for (var i = 0; i < pixels.length; i += 4) {
    final b = pixels[i];
    final g = pixels[i + 1];
    final r = pixels[i + 2];
    final a = pixels[i + 3];
    if (a == 255 || a == 0) {
      out[i] = a == 0 ? 0 : r;
      out[i + 1] = a == 0 ? 0 : g;
      out[i + 2] = a == 0 ? 0 : b;
    } else {
      out[i] = _unpremultiply(r, a);
      out[i + 1] = _unpremultiply(g, a);
      out[i + 2] = _unpremultiply(b, a);
    }
    out[i + 3] = a;
  }
  return out;
}

/// `v / a * 255`，整数**截断**并夹到 255。
///
/// 用截断而不是四舍五入：这是 Apple 自己实现（`pngcrush
/// -revert-iphone-optimizations`）的行为 —— 在 16 个含半透明像素的样本上
/// 逐字节一致，四舍五入会在 `.5` 上差 1（实测 12/16 对 16/16）。
///
/// `A == 255` 时两种写法都是恒等变换，而应用图标基本不透明，因此这一处差异
/// 在真实样本上看不出来 —— 但没必要和基准实现不一致。
int _unpremultiply(int v, int a) {
  final scaled = (v * 255) ~/ a;
  return scaled > 255 ? 255 : scaled;
}

/// 组装一张最小的标准 PNG。
Uint8List _assemblePng(int width, int height, Uint8List idat) {
  final builder = BytesBuilder(copy: false)
    ..add(_pngSignature)
    ..add(_chunk(
      'IHDR',
      Uint8List.fromList([
        (width >> 24) & 0xFF,
        (width >> 16) & 0xFF,
        (width >> 8) & 0xFF,
        width & 0xFF,
        (height >> 24) & 0xFF,
        (height >> 16) & 0xFF,
        (height >> 8) & 0xFF,
        height & 0xFF,
        8, // 位深
        6, // 色彩类型：RGBA
        0, // 压缩方法
        0, // 过滤方法
        0, // 非隔行
      ]),
    ))
    ..add(_chunk('IDAT', idat))
    ..add(_chunk('IEND', Uint8List(0)));
  return builder.takeBytes();
}

Uint8List _chunk(String type, Uint8List data) {
  final typeBytes = Uint8List.fromList(type.codeUnits);
  final out = BytesBuilder(copy: false)
    ..add(_uint32(data.length))
    ..add(typeBytes)
    ..add(data);
  // CRC 覆盖类型与数据，不含长度。
  final crcInput = Uint8List(typeBytes.length + data.length)
    ..setRange(0, typeBytes.length, typeBytes)
    ..setRange(typeBytes.length, typeBytes.length + data.length, data);
  out.add(_uint32(getCrc32(crcInput)));
  return out.takeBytes();
}

Uint8List _uint32(int value) => Uint8List.fromList([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);

Uint8List _asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

int _readUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
