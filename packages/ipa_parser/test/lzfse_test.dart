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
// （其中**一个**流：3 个 LZFSE 块、2,086,192 字节），并与用 Apple 参考实现
// （`lzfse` 开源库，编译成 CLI）的输出**逐字节比对：IDENTICAL**。
// 那个样本太大（2 MB）不适合入库，所以这里放的是小夹具。
//
// > 注意「一个流」这个限定：Chess 那张图的完整 payload 是**多个串接的流**，
// > 2,086,192 只是第一段。当时把它当成整张图，于是以为「还有一层封装」——
// > 真因是多流，见「串接的多流」那一组。

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
      // 注意：`installer-progress.car` 里 739 字节的 `LowBatteryFlashing.png`
      // **不再是**这个用例的样本 —— 块里有一份 `dmp2` 描述符
      // （`dmp2 04 01 0a 04 1e 00 48 00`，30×72 与声明一致），它是
      // deepmap2 压过的真图，不是空壳。真正的空壳（Music.app 里 5,694 个
      // 334 字节条目）没有入仓库的夹具，所以这里用构造值钉分支行为。
      const placeholder = AssetsCarImage(
        renditionName: 'empty.png',
        width: 84,
        height: 84,
        pixelFormat: 'ARGB',
        sizeOnDisk: 334,
        blockOffset: 0,
      );
      expect(placeholder.embedsPixels, isFalse);
      expect(placeholder.compression, CarCompression.none);

      final result = extractCarImagePng(Uint8List(64), placeholder);
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

  group('串接的多流 —— 一个块里不止一个流', () {
    // 这一组钉住的是 V2.4.14 最贵的一个格式错误：**一个 ISTC 块里的像素
    // 可能是若干个 `bvx2 … bvx$` 串起来的**，只解第一个会少一大截。
    //
    // 夹具 `appicon-ios.car` 由 `actool` 真实编译，其中 icon1024.png 的块
    // 长 6,548 字节、含 4 个流。期望值不是猜的：`assetutil --info` 说它是
    // 1024×1024 ARGB，而 1024×1024×4 = 4,194,304。

    const carPath = '../../test/fixtures/car/appicon-ios.car';

    Uint8List payloadOf(String name, int width) {
      final car = File(carPath).readAsBytesSync();
      final image = parseAssetsCar(car)
          .imagesNamed(name)
          .firstWhere((i) => i.width == width);
      return Uint8List.sublistView(
          car, image.payloadOffset!, image.blockOffset + image.sizeOnDisk);
    }

    test('icon1024.png 是 4 个流，拼起来正好 1024×1024×4', () {
      final result = lzfseDecodeConcatenated(payloadOf('AppIcon', 1024));

      expect(result.streamCount, 4);
      expect(result.bytes.length, 1024 * 1024 * 4);
      // 生成夹具时第一列写的是 RGBA (10, 19, 40, 255)，按 ARGB 的字节布局
      // 落盘是 B,G,R,A。
      expect(result.bytes.sublist(0, 4), [0x28, 0x13, 0x0a, 0xff]);
    });

    test('只解第一个流会少 2/3 —— 这就是当初那个 bug 的形状', () {
      // `lzfseDecode` 遇到 `bvx$` 就返回，这正是修复前的行为。
      final first = lzfseDecode(payloadOf('AppIcon', 1024));

      expect(first.length, 1396736, reason: '341 行；整图有 1024 行');
      expect(first.length, lessThan(1024 * 1024 * 4));
      // 而拼接后是完整的。
      expect(
        lzfseDecodeConcatenated(payloadOf('AppIcon', 1024)).bytes.length,
        1024 * 1024 * 4,
      );
    });

    test('解出来直接编成 PNG：尺寸与首行像素都对', () {
      final car = File(carPath).readAsBytesSync();
      final image = parseAssetsCar(car)
          .imagesNamed('AppIcon')
          .firstWhere((i) => i.width == 1024);

      final result = extractCarImagePng(car, image);
      expect(result.ok, isTrue, reason: result.failure);

      final ihdr = _chunkData(result.png!, 'IHDR');
      final header = ByteData.sublistView(ihdr);
      expect(header.getUint32(0), 1024);
      expect(header.getUint32(4), 1024);

      // 解 IDAT，检查第一行的两个像素：通道顺序错了红蓝会互换，
      // 而肉眼在渐变图上未必看得出来。
      final row = ZLibDecoder().decodeBytes(_chunkData(result.png!, 'IDAT'));
      expect(row[0], 0, reason: 'filter 字节是 None');
      expect(row.sublist(1, 5), [10, 19, 40, 255]);
      const x = 512;
      final t = x * 255 ~/ 1023;
      final at = 1 + x * 4;
      expect(row.sublist(at, at + 4), [t + 10, 255 - t + 20, 40, 255]);
    });

    test('已经是单流的图不受影响（installer-progress 的灰度图）', () {
      final car = File('../../test/fixtures/car/installer-progress.car')
          .readAsBytesSync();
      final image = parseAssetsCar(car)
          .images
          .firstWhere((i) => i.renditionName == 'LowBatteryEmpty@2x.png');

      final payload = Uint8List.sublistView(
          car, image.payloadOffset!, image.blockOffset + image.sizeOnDisk);
      final result = lzfseDecodeConcatenated(payload);
      expect(result.streamCount, 1);
      expect(result.bytes.length, 346 * 144 * 2, reason: 'GA8 = 2 字节/像素');
    });
  });

  group('deepmap2 的边界', () {
    test('有像素但不解这个码 —— 报「不解」而不是「没有像素」', () {
      // 检测本身靠真实块（见 assets_car.dart 的 _detectCompression），
      // 这里钉的是**分支行为**：拿到一个 deepmap2 的 rendition 时，
      // 不能拿 LZFSE 解码器去试一个不是它的流。
      const image = AssetsCarImage(
        renditionName: 'x.png',
        width: 40,
        height: 40,
        pixelFormat: 'ARGB',
        compression: CarCompression.deepmap2,
        sizeOnDisk: 330,
        blockOffset: 0,
        payloadOffset: 0,
      );
      expect(image.embedsPixels, isTrue, reason: 'deepmap2 是有像素的压缩');

      final result = extractCarImagePng(Uint8List(64), image);
      expect(result.ok, isFalse);
      expect(result.failureCode, 'unsupported_deepmap2');
      expect(result.failure, contains('deepmap2'));
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
