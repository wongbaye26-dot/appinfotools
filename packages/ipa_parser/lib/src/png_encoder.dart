// 最小 PNG 编码器 —— 只做「把原始像素变成 PNG」这一件事。
//
// ## 为什么自己写而不是找库
//
// 需求很窄：8 位 RGBA 或 8 位灰度+alpha，无隔行，单一 IDAT，filter 全 0。
// 引入一个完整的图片编码库只为这一点不划算，而且 PNG 的容器格式是**公开
// 且稳定**的（RFC 2083），不像 `Assets.car` 那样需要猜。
//
// ## 复用 `package:archive` 的 zlib
//
// IDAT 的内容就是 zlib 流（RFC 1950），`archive` 已有 `ZLibEncoder`。
// 自己写 deflate 只会多一份可能出错的东西。
//
// ## 不做什么
//
// - 不做隔行（Adam7）：图标不需要；
// - 不做调色板 / 16 位；
// - 不做 filter 优化（全用 0 = None）。文件会大一些，但解码结果完全相同。
//   对「看一眼图标」这个用途，体积不重要，**正确性才重要**。

import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoder;

/// PNG 颜色类型（只实现用到的两种）。
enum PngColorType {
  /// 1 通道灰度（8 位）。
  gray(0, 1),

  /// 灰度 + alpha（8 位）。
  grayAlpha(4, 2),

  /// RGB（8 位）。
  rgb(2, 3),

  /// RGBA（8 位）。
  rgba(6, 4);

  const PngColorType(this.code, this.channels);

  /// PNG IHDR 里的 color type 值。
  final int code;

  /// 每像素字节数。
  final int channels;
}

/// 把原始像素编码成 PNG。
///
/// [pixels] 必须是 `width * height * colorType.channels` 字节。
/// 尺寸或长度不匹配时返回 `null` —— 不编一张尺寸对不上的图出来。
Uint8List? encodePng({
  required int width,
  required int height,
  required PngColorType colorType,
  required Uint8List pixels,
}) {
  if (width <= 0 || height <= 0) return null;
  final expected = width * height * colorType.channels;
  if (pixels.length != expected) return null;

  final out = BytesBuilder(copy: true);
  // PNG 签名
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder(copy: true);
  _writeU32(ihdr, width);
  _writeU32(ihdr, height);
  ihdr.add([8]); // bit depth
  ihdr.add([colorType.code]);
  ihdr.add([0]); // compression = deflate
  ihdr.add([0]); // filter method = 0
  ihdr.add([0]); // interlace = none
  _writeChunk(out, 'IHDR', ihdr.takeBytes());

  // 每行前加一个 filter 字节 0（None）
  final stride = width * colorType.channels;
  final raw = Uint8List((stride + 1) * height);
  for (var y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    raw.setRange(
      y * (stride + 1) + 1,
      y * (stride + 1) + 1 + stride,
      pixels,
      y * stride,
    );
  }
  final compressed = ZLibEncoder().encode(raw);
  _writeChunk(out, 'IDAT', Uint8List.fromList(compressed));
  _writeChunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _writeChunk(BytesBuilder out, String type, Uint8List data) {
  _writeU32(out, data.length);
  final typeBytes = type.codeUnits;
  out.add(typeBytes);
  out.add(data);
  final crcInput = Uint8List(4 + data.length)
    ..setRange(0, 4, typeBytes)
    ..setRange(4, 4 + data.length, data);
  _writeU32(out, _crc32(crcInput));
}

void _writeU32(BytesBuilder out, int value) {
  out.add([
    (value >>> 24) & 0xFF,
    (value >>> 16) & 0xFF,
    (value >>> 8) & 0xFF,
    value & 0xFF,
  ]);
}

/// CRC-32（PNG 用的那个多项式，IEEE 802.3）。
///
/// 查表实现：PNG 的每个 chunk 都要算一次，逐位算在 1024×1024 的图上会明显变慢
/// （IDAT 有几 MB）。
final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c;
  }
  return table;
}

int _crc32(Uint8List data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
