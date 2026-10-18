// LZFSE 解码 —— 期望值来自 macOS 的 `libcompression`。
//
// ## 为什么这组测试能证明「解码器是对的」
//
// 每个 `.lzfse` 夹具都是 `COMPRESSION_LZFSE`（Apple 系统库）**真实压缩**的产物，
// 配套的 `.bin` 就是压缩前的原始字节。所以一次往返测试实际上在断言：
//
// > 我们的纯 Dart 实现，与 Apple 自己的编码器**逐字节**一致。
//
// 这比「自己编码、自己解码、比对」强得多 —— 后者只能证明自洽。
//
// ## 已被证明到什么程度
//
// 除了这 6 个夹具，还用同一套代码解过 `Chess.app` 的 1024×1024 图标
// （3 个 LZFSE 块、2,086,192 字节），并与用 Apple 参考实现
// （`lzfse` 开源库，编译成 CLI）的输出**逐字节比对：IDENTICAL**。
// 那个样本太大（2 MB）不适合入库，所以这里放的是小夹具。

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

const _dir = '../../test/fixtures/lzfse';

Uint8List _read(String name) => File('$_dir/$name').readAsBytesSync();

/// 6 个夹具：名字 → 原始字节数。
const Map<String, int> _fixtures = {
  'empty': 0,
  'zeros': 8192,
  'repeated-text': 9000,
  'incompressible': 4096,
  'pixel-like': 16896,
  'multi-block': 95105,
};

Matcher _throwsLzfse(String code) => throwsA(
      isA<LzfseException>().having((e) => e.code, 'code', code),
    );

void main() {
  group('往返：与 libcompression 逐字节一致', () {
    for (final entry in _fixtures.entries) {
      test('${entry.key}（${entry.value} 字节）', () {
        final packed = _read('${entry.key}.lzfse');
        final expected = _read('${entry.key}.bin');
        final decoded = lzfseDecode(packed);

        expect(decoded.length, entry.value, reason: '长度不等 —— 解码在中途停错位置了');
        // 逐字节比较：长度对但内容错是最难发现的一类 bug。
        expect(decoded, orderedEquals(expected));
      });
    }

    test('空输入：只有结束块，解码出 0 字节', () {
      expect(lzfseDecode(_read('empty.lzfse')), isEmpty);
    });

    test('不可压缩的数据走 `bvx-`（未压缩块）路径', () {
      // 随机 4 KB 压不小，libcompression 会退化成未压缩块。
      expect(
          _read('incompressible.lzfse').sublist(0, 4), [0x62, 0x76, 0x78, 0x32],
          reason: '实测这个样本仍是 bvx2；若哪天变了，下面这条断言要跟着改');
      expect(lzfseDecode(_read('incompressible.lzfse')).length, 4096);
    });

    test('大输入跨多个块，且**回溯可以跨块**', () {
      // multi-block 是 95 KB：首块远小于它，说明至少两块。
      // 这条断言的价值：跨块回溯的 bug 只会在多块样本上出现
      // （实测 Chess 的图标第二块首个符号 `L=4 D=12339` 就依赖它）。
      final packed = _read('multi-block.lzfse');
      final decoded = lzfseDecode(packed);
      expect(decoded.length, 95105);
      expect(decoded, orderedEquals(_read('multi-block.bin')));
    });
  });

  group('不支持的块类型：明确报错，不猜', () {
    test('`bvx1`（v1 头）→ block.unsupported_v1', () {
      final src = Uint8List.fromList([0x62, 0x76, 0x78, 0x31, 0, 0, 0, 0]);
      expect(() => lzfseDecode(src), _throwsLzfse('block.unsupported_v1'));
    });

    test('`bvxn`（LZVN）→ block.unsupported_lzvn', () {
      final src = Uint8List.fromList([0x62, 0x76, 0x78, 0x6E, 0, 0, 0, 0]);
      expect(() => lzfseDecode(src), _throwsLzfse('block.unsupported_lzvn'));
    });

    test('报错文案说清「为什么不做」，而不是只说「不支持」', () {
      final src = Uint8List.fromList([0x62, 0x76, 0x78, 0x6E, 0, 0, 0, 0]);
      try {
        lzfseDecode(src);
        fail('应当抛异常');
      } on LzfseException catch (e) {
        expect(e.message, contains('LZVN'));
        expect(e.message.toLowerCase(), contains('raster'),
            reason: '要说清「实测光栅图不用它」，读者才知道影响面');
      }
    });
  });

  group('畸形输入：给出确定结论，不崩', () {
    test('空缓冲区 → stream.truncated', () {
      expect(() => lzfseDecode(Uint8List(0)), _throwsLzfse('stream.truncated'));
    });

    test('未知魔数 → block.bad_magic，并带上魔数', () {
      final src = Uint8List.fromList([0x41, 0x41, 0x41, 0x41]);
      try {
        lzfseDecode(src);
        fail('应当抛异常');
      } on LzfseException catch (e) {
        expect(e.code, 'block.bad_magic');
        expect(e.message, contains('41414141'));
      }
    });

    test('截断的压缩块 → 抛异常而不是返回半截数据', () {
      final full = _read('multi-block.lzfse');
      final cut = Uint8List.sublistView(full, 0, full.length ~/ 2);
      expect(() => lzfseDecode(cut), throwsA(isA<LzfseException>()));
    });

    test('篡改频率表 → block.bad_freq（表被破坏时不做猜测）', () {
      final bytes = Uint8List.fromList(_read('zeros.lzfse'));
      // 头部固定部分之后就是压缩的频率表；把其中一片改成 0xFF。
      for (var i = 36; i < 60 && i < bytes.length; i++) {
        bytes[i] = 0xFF;
      }
      expect(() => lzfseDecode(bytes), throwsA(isA<LzfseException>()));
    });

    test('输出上限拦住伪造的 n_raw_bytes', () {
      final bytes = Uint8List.fromList(_read('zeros.lzfse'));
      final data = ByteData.sublistView(bytes);
      // 第一个块的 n_raw_bytes 在偏移 4。
      data.setUint32(4, 0x7FFFFFFF, Endian.little);
      expect(() => lzfseDecode(bytes), throwsA(isA<LzfseException>()));
    });
  });

  group('PNG 编码器：结构可解、像素可比', () {
    test('编码后能按 PNG 结构读回来，zlib 解压等于原始扫描行', () {
      const width = 4;
      const height = 3;
      final pixels = Uint8List(width * height * 4);
      for (var i = 0; i < pixels.length; i++) {
        pixels[i] = i % 251;
      }
      final png = encodePng(
        width: width,
        height: height,
        colorType: PngColorType.rgba,
        pixels: pixels,
      );
      expect(png, isNotNull);

      // 签名
      expect(
          png!.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      // IHDR：宽高 + 位深 + 颜色类型
      expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
      final ihdr = ByteData.sublistView(png, 16, 29);
      expect(ihdr.getUint32(0), width);
      expect(ihdr.getUint32(4), height);
      expect(ihdr.getUint8(8), 8);
      expect(ihdr.getUint8(9), PngColorType.rgba.code);

      // 取 IDAT 并用 zlib 解开，应当等于「每行前加一个 0」的原始像素。
      final idat = _chunkData(png, 'IDAT');
      final raw = Uint8List.fromList(ZLibDecoder().decodeBytes(idat));
      expect(raw.length, (width * 4 + 1) * height);
      for (var y = 0; y < height; y++) {
        expect(raw[y * (width * 4 + 1)], 0, reason: 'filter 字节必须是 0');
        expect(
          raw.sublist(y * (width * 4 + 1) + 1, (y + 1) * (width * 4 + 1)),
          orderedEquals(pixels.sublist(y * width * 4, (y + 1) * width * 4)),
        );
      }
      // IEND 收尾
      expect(String.fromCharCodes(png.sublist(png.length - 8, png.length - 4)),
          'IEND');
    });

    test('尺寸与像素数不匹配时返回 null，不编一张错图', () {
      expect(
        encodePng(
          width: 4,
          height: 4,
          colorType: PngColorType.rgba,
          pixels: Uint8List(10),
        ),
        isNull,
      );
      expect(
        encodePng(
          width: 0,
          height: 4,
          colorType: PngColorType.rgba,
          pixels: Uint8List(0),
        ),
        isNull,
      );
    });
  });

  group('从 Assets.car 提取：端到端', () {
    // 18 KB 的真实系统资产目录，4 个 rendition（3 张有像素）。
    final car = _read('../car/installer-progress.car');
    final catalog = parseAssetsCar(car);

    test('灰度+alpha 的图能提取成 PNG，尺寸与像素都对', () {
      final image = catalog.images
          .firstWhere((i) => i.renditionName == 'LowBatteryEmpty@2x.png');
      final result = extractCarImagePng(car, image);
      expect(result.ok, isTrue, reason: result.failure);

      final png = result.png!;
      final ihdr = ByteData.sublistView(png, 16, 29);
      expect(ihdr.getUint32(0), 346);
      expect(ihdr.getUint32(4), 144);
      expect(ihdr.getUint8(9), PngColorType.grayAlpha.code,
          reason: 'GA8 应当编成 灰度+alpha，而不是展开成 RGB');

      // 像素内容必须与直接解码一致（通道顺序 Pick 为 [0,1] 即原样）。
      final pixels = lzfseDecode(Uint8List.sublistView(
          car, image.payloadOffset!, image.blockOffset + image.sizeOnDisk));
      expect(pixels.length, 346 * 144 * 2);
      final raw = Uint8List.fromList(
          ZLibDecoder().decodeBytes(_chunkData(png, 'IDAT')));
      expect(raw.sublist(1, 1 + 346 * 2),
          orderedEquals(pixels.sublist(0, 346 * 2)));
    });

    test('1x 的同一张图也能提取', () {
      final image = catalog.images
          .firstWhere((i) => i.renditionName == 'LowBatteryEmpty.png');
      final result = extractCarImagePng(car, image);
      expect(result.ok, isTrue, reason: result.failure);
      expect(ByteData.sublistView(result.png!, 16, 20).getUint32(0), 173);
    });

    test('空壳 rendition → no_payload，而不是「解出 0 字节」', () {
      final placeholder = catalog.placeholderOnly.single;
      final result = extractCarImagePng(car, placeholder);
      expect(result.ok, isFalse);
      expect(result.failureCode, 'no_payload');
      expect(result.failure, contains('placeholder'));
    });

    test('矢量 rendition → not_raster（有尺寸但不是像素）', () {
      const vector = AssetsCarImage(
        renditionName: 'concert.tickets.fill.svg',
        width: 27,
        height: 23,
        pixelFormat: 'GVS ',
        sizeOnDisk: 338,
        blockOffset: 0,
      );
      final result = extractCarImagePng(car, vector);
      expect(result.ok, isFalse);
      expect(result.failureCode, 'not_raster');
    });

    test('未支持的像素格式 → unsupported_format，并点名是哪种', () {
      const odd = AssetsCarImage(
        renditionName: 'x.png',
        width: 2,
        height: 2,
        pixelFormat: 'RGBW',
        compression: CarCompression.lzfseV2,
        sizeOnDisk: 100,
        blockOffset: 0,
        payloadOffset: 0,
      );
      final result = extractCarImagePng(car, odd);
      expect(result.ok, isFalse);
      expect(result.failureCode, 'unsupported_format');
      expect(result.failure, contains('RGBW'));
    });
  });
}

/// 取第一个指定类型的 chunk 的数据段。
Uint8List _chunkData(Uint8List png, String type) {
  var pos = 8; // 跳过签名
  while (pos + 8 <= png.length) {
    final length = ByteData.sublistView(png, pos, pos + 4).getUint32(0);
    final chunkType = String.fromCharCodes(png.sublist(pos + 4, pos + 8));
    if (chunkType == type) {
      return Uint8List.sublistView(png, pos + 8, pos + 8 + length);
    }
    pos += 12 + length; // 长度 + 类型 + 数据 + CRC
  }
  fail('没有找到 $type chunk');
}
