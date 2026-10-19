/// 只读字节头就能回答的两件事：**这是什么格式**、**它有多大**。
///
/// 刻意不解码：解码发生在 Explorer / Finder 进程里（Windows 用 WIC，
/// macOS 用 ImageIO），代价由系统承担、且系统本来就有对应解码器。
/// 这里只读几十字节的头。
///
/// 尺寸解析的意义在于**像素上限**：一个 20000×20000 的图标即使只有 300 KB，
/// 系统解码时也会要求 1.6 GB 内存。在 helper 里用 24 字节拦掉它，
/// 比让 Explorer 去承担要好。
library;

import 'dart:typed_data';

import 'app_icon_result.dart';

/// PNG 签名：`89 50 4E 47 0D 0A 1A 0A`。
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

/// 是否为 PNG。
bool isPng(List<int> bytes) {
  if (bytes.length < _pngSignature.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return false;
  }
  return true;
}

/// 是否为 Android 二进制 XML（`<adaptive-icon>` / `<vector>` 这类）。
///
/// 判据是 AXML 的文件头：`RES_XML_TYPE = 0x0003` + 头部大小 8。
/// 这不是「猜」—— 二进制 XML 的 chunk 头就是这样定义的（与
/// `binary_xml.dart` 同一套事实）。
bool isAndroidBinaryXml(List<int> bytes) {
  if (bytes.length < 8) return false;
  return bytes[0] == 0x03 &&
      bytes[1] == 0x00 &&
      bytes[2] == 0x08 &&
      bytes[3] == 0x00;
}

/// 是否为 WebP（`RIFF....WEBP`）。
///
/// Android Studio 的默认模板从 AGP 3.0 起把 launcher 图标生成为 `.webp`，
/// 真实样本里占相当比例（本机 32 个样本里有 4 个）。
bool isWebp(List<int> bytes) {
  if (bytes.length < 12) return false;
  const riff = [0x52, 0x49, 0x46, 0x46]; // "RIFF"
  const webp = [0x57, 0x45, 0x42, 0x50]; // "WEBP"
  for (var i = 0; i < 4; i++) {
    if (bytes[i] != riff[i] || bytes[8 + i] != webp[i]) return false;
  }
  return true;
}

/// 是否为 JPEG（`FF D8 FF`）。
bool isJpeg(List<int> bytes) =>
    bytes.length >= 3 &&
    bytes[0] == 0xFF &&
    bytes[1] == 0xD8 &&
    bytes[2] == 0xFF;

/// 是否为 GIF（`GIF8`）。
bool isGif(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x47 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x38;

/// 由魔数判定格式；认不出来时返回 [AppIconFormat.unknown]。
AppIconFormat detectFormat(List<int> bytes) {
  if (isPng(bytes)) return AppIconFormat.png;
  if (isWebp(bytes)) return AppIconFormat.webp;
  if (isJpeg(bytes)) return AppIconFormat.jpeg;
  if (isGif(bytes)) return AppIconFormat.gif;
  return AppIconFormat.unknown;
}

/// 从图片头读像素尺寸；读不出时返回 `null`。
///
/// 支持 PNG（IHDR）、WebP（VP8 / VP8L / VP8X 三种子格式）、JPEG（SOF 段）、
/// GIF（逻辑屏幕描述符）。**不完整解码**，只扫必要的头。
(int width, int height)? imagePixelSize(List<int> bytes) {
  if (isPng(bytes)) return pngPixelSize(bytes);
  if (isWebp(bytes)) return webpPixelSize(bytes);
  if (isJpeg(bytes)) return jpegPixelSize(bytes);
  if (isGif(bytes)) return gifPixelSize(bytes);
  return null;
}

/// PNG 的像素尺寸。
///
/// IHDR 布局（大端）：
/// `[0..7] 签名 | [8..11] 长度 | [12..15] "IHDR" | [16..19] 宽 | [20..23] 高`
(int, int)? pngPixelSize(List<int> bytes) {
  if (!isPng(bytes) || bytes.length < 24) return null;
  final width = _u32be(bytes, 16);
  final height = _u32be(bytes, 20);
  // 0 或非正都说明 IHDR 不可信（PNG 规范要求 ≥1）。
  if (width <= 0 || height <= 0) return null;
  return (width, height);
}

/// WebP 的像素尺寸。
///
/// 三种子格式的布局不同（这是 WebP 容器规范，不是推测）：
/// - **VP8X**（扩展）：`[12..15]"VP8X"`，`[24..26]` 画布宽-1（24 位小端），
///   `[27..29]` 高-1；
/// - **VP8L**（无损）：`[12..15]"VP8L"`，`[21]` 必须是 `0x2F` 签名，
///   `[21..24]` 起 14 位宽-1、14 位高-1；
/// - **VP8 **（有损）：`[12..15]"VP8 "`，帧头 3 字节后是起始码
///   `9D 01 2A`，随后 2 字节宽（14 位）、2 字节高（14 位）。
(int, int)? webpPixelSize(List<int> bytes) {
  if (!isWebp(bytes) || bytes.length < 30) return null;
  final tag = String.fromCharCodes(bytes.sublist(12, 16));

  if (tag == 'VP8X') {
    final w = _u24le(bytes, 24) + 1;
    final h = _u24le(bytes, 27) + 1;
    return (w > 0 && h > 0) ? (w, h) : null;
  }
  if (tag == 'VP8L') {
    if (bytes[20] != 0x2F) return null;
    final b = _u32le(bytes, 21);
    final w = (b & 0x3FFF) + 1;
    final h = ((b >> 14) & 0x3FFF) + 1;
    return (w > 0 && h > 0) ? (w, h) : null;
  }
  if (tag == 'VP8 ') {
    // 帧头：3 字节帧标记，然后是起始码 9D 01 2A。
    final startCode = 23;
    if (bytes.length < startCode + 7) return null;
    if (bytes[startCode] != 0x9D ||
        bytes[startCode + 1] != 0x01 ||
        bytes[startCode + 2] != 0x2A) {
      return null;
    }
    final w = _u16le(bytes, startCode + 3) & 0x3FFF;
    final h = _u16le(bytes, startCode + 5) & 0x3FFF;
    return (w > 0 && h > 0) ? (w, h) : null;
  }
  return null;
}

/// JPEG 的像素尺寸：扫描 SOFn 段（C0–CF，排除 C4/C8/CC）。
///
/// 不做熵解码，只在段头之间跳。
(int, int)? jpegPixelSize(List<int> bytes) {
  if (!isJpeg(bytes)) return null;
  var i = 2;
  while (i + 9 < bytes.length) {
    if (bytes[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = bytes[i + 1];
    // 填充字节与无长度段。
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0xD8 || marker == 0xD9) {
      i += 2;
      continue;
    }
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2) return null;
    final isSof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (i + 9 >= bytes.length) return null;
      final h = (bytes[i + 5] << 8) | bytes[i + 6];
      final w = (bytes[i + 7] << 8) | bytes[i + 8];
      return (w > 0 && h > 0) ? (w, h) : null;
    }
    i += 2 + length;
  }
  return null;
}

/// GIF 的像素尺寸：逻辑屏幕描述符在固定偏移 6。
(int, int)? gifPixelSize(List<int> bytes) {
  if (!isGif(bytes) || bytes.length < 10) return null;
  final w = _u16le(bytes, 6);
  final h = _u16le(bytes, 8);
  return (w > 0 && h > 0) ? (w, h) : null;
}

int _u32be(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _u32le(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _u24le(List<int> b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);

int _u16le(List<int> b, int o) => b[o] | (b[o + 1] << 8);

/// 便于测试与日志的十六进制前缀。
String hexPrefix(Uint8List bytes, [int count = 8]) {
  final end = bytes.length < count ? bytes.length : count;
  return [
    for (var i = 0; i < end; i++) bytes[i].toRadixString(16).padLeft(2, '0')
  ].join(' ');
}
