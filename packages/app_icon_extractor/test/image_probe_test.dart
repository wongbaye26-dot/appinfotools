// 图片头解析：**只读字节头**，不解码。
//
// 这一组测试的价值在于：真实样本里既有 PNG 也有 WebP，而 WebP 有三种子格式
// （VP8X / VP8L / VP8），它们的尺寸字段位置各不相同。写错任何一个，
// 像素上限检查就会失效 —— 那是本包唯一的「防解码爆内存」闸门。

import 'dart:typed_data';

import 'package:app_icon_extractor/app_icon_extractor.dart';
import 'package:test/test.dart';

/// 造一个 PNG 头（签名 + IHDR 长度 + "IHDR" + 宽高）。
Uint8List pngHeader(int width, int height) {
  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b.add([0, 0, 0, 13]); // IHDR 长度
  b.add('IHDR'.codeUnits);
  b.add([
    (width >> 24) & 0xFF,
    (width >> 16) & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF
  ]);
  b.add([
    (height >> 24) & 0xFF,
    (height >> 16) & 0xFF,
    (height >> 8) & 0xFF,
    height & 0xFF
  ]);
  b.add([
    8,
    6,
    0,
    0,
    0
  ]); // bitDepth / colorType / compression / filter / interlace
  return b.toBytes();
}

/// 造一个 VP8X（扩展）WebP 头。
Uint8List webpVp8x(int width, int height) {
  final b = BytesBuilder();
  b.add('RIFF'.codeUnits);
  b.add([0, 0, 0, 0]); // RIFF size（本测试不校验）
  b.add('WEBP'.codeUnits);
  b.add('VP8X'.codeUnits);
  b.add([10, 0, 0, 0]); // chunk size
  b.add([0, 0, 0, 0]); // flags + reserved
  final w = width - 1;
  final h = height - 1;
  b.add([w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF]);
  b.add([h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF]);
  b.add(List.filled(16, 0)); // 补齐，让长度足够
  return b.toBytes();
}

/// 造一个 VP8L（无损）WebP 头。
Uint8List webpVp8l(int width, int height) {
  final b = BytesBuilder();
  b.add('RIFF'.codeUnits);
  b.add([0, 0, 0, 0]);
  b.add('WEBP'.codeUnits);
  b.add('VP8L'.codeUnits);
  b.add([10, 0, 0, 0]);
  b.add([0x2F]); // 必要的签名
  final w = width - 1;
  final h = height - 1;
  // 14 位宽 + 14 位高，小端打包进 4 字节。
  final packed = (w & 0x3FFF) | ((h & 0x3FFF) << 14);
  b.add([
    packed & 0xFF,
    (packed >> 8) & 0xFF,
    (packed >> 16) & 0xFF,
    (packed >> 24) & 0xFF,
  ]);
  b.add(List.filled(16, 0));
  return b.toBytes();
}

/// 造一个 VP8（有损）WebP 头。
Uint8List webpVp8(int width, int height) {
  final b = BytesBuilder();
  b.add('RIFF'.codeUnits);
  b.add([0, 0, 0, 0]);
  b.add('WEBP'.codeUnits);
  b.add('VP8 '.codeUnits);
  b.add([10, 0, 0, 0]);
  b.add([0, 0, 0]); // 帧标记 3 字节
  b.add([0x9D, 0x01, 0x2A]); // 起始码
  b.add([width & 0xFF, (width >> 8) & 0x3F]);
  b.add([height & 0xFF, (height >> 8) & 0x3F]);
  b.add(List.filled(8, 0));
  return b.toBytes();
}

/// 造一个最小 JPEG 头（SOI + SOF0）。
Uint8List jpegHeader(int width, int height) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8]);
  b.add([0xFF, 0xC0, 0x00, 0x11, 0x08]);
  b.add([(height >> 8) & 0xFF, height & 0xFF]);
  b.add([(width >> 8) & 0xFF, width & 0xFF]);
  b.add([0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
  return b.toBytes();
}

/// 造一个最小 GIF 头。
Uint8List gifHeader(int width, int height) {
  final b = BytesBuilder();
  b.add('GIF89a'.codeUnits);
  b.add([width & 0xFF, (width >> 8) & 0xFF]);
  b.add([height & 0xFF, (height >> 8) & 0xFF]);
  b.add([0, 0, 0, 0, 0, 0]);
  return b.toBytes();
}

void main() {
  group('格式识别', () {
    test('PNG / WebP / JPEG / GIF 各认得出', () {
      expect(detectFormat(pngHeader(16, 16)), AppIconFormat.png);
      expect(detectFormat(webpVp8x(16, 16)), AppIconFormat.webp);
      expect(detectFormat(jpegHeader(16, 16)), AppIconFormat.jpeg);
      expect(detectFormat(gifHeader(16, 16)), AppIconFormat.gif);
    });

    test('认不出来的字节返回 unknown，而不是猜一个格式', () {
      expect(detectFormat(Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7])),
          AppIconFormat.unknown);
      expect(detectFormat(Uint8List(0)), AppIconFormat.unknown);
    });

    test('Android 二进制 XML 单独识别 —— 它不是图片', () {
      final axml = Uint8List.fromList([0x03, 0x00, 0x08, 0x00, 0, 0, 0, 0]);
      expect(isAndroidBinaryXml(axml), isTrue);
      expect(detectFormat(axml), AppIconFormat.unknown);
    });
  });

  group('像素尺寸', () {
    test('PNG 读 IHDR', () {
      expect(pngPixelSize(pngHeader(1024, 512)), (1024, 512));
    });

    test('WebP 三种子格式的尺寸字段位置都不同，逐一验证', () {
      expect(webpPixelSize(webpVp8x(300, 200)), (300, 200));
      expect(webpPixelSize(webpVp8l(301, 201)), (301, 201));
      expect(webpPixelSize(webpVp8(302, 202)), (302, 202));
    });

    test('VP8L 缺少 0x2F 签名时拒绝，而不是读出乱码尺寸', () {
      final bytes = webpVp8l(100, 100);
      bytes[20] = 0x00; // 破坏签名
      expect(webpPixelSize(bytes), isNull);
    });

    test('VP8 起始码不对时拒绝', () {
      final bytes = webpVp8(100, 100);
      bytes[23] = 0x00;
      expect(webpPixelSize(bytes), isNull);
    });

    test('JPEG 扫到 SOF0 才给尺寸', () {
      expect(jpegPixelSize(jpegHeader(640, 480)), (640, 480));
    });

    test('GIF 读逻辑屏幕描述符', () {
      expect(gifPixelSize(gifHeader(64, 32)), (64, 32));
    });

    test('统一的 imagePixelSize 分派到各格式', () {
      expect(imagePixelSize(pngHeader(10, 20)), (10, 20));
      expect(imagePixelSize(webpVp8x(10, 20)), (10, 20));
      expect(imagePixelSize(jpegHeader(10, 20)), (10, 20));
      expect(imagePixelSize(gifHeader(10, 20)), (10, 20));
    });

    test('尺寸为 0 的 PNG 头不可信 → null（不返回 0×0）', () {
      expect(pngPixelSize(pngHeader(0, 0)), isNull);
    });
  });
}
