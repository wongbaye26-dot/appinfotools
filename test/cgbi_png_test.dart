// CgBI（Apple 的 PNG 变体）支持。
//
// 两件事必须钉死：
// 1. **解出来的像素要和 Apple 自己的实现一致** —— 期望值来自
//    `pngcrush -revert-iphone-optimizations`（见 fixtures/cgbi/README.md）；
// 2. **不接受猜** —— 遇到不是「8 位 RGBA 非隔行」的形态要如实说明原因，
//    而不是解出一张颜色或透明度错误的「应用图标」。
//
// 这份能力不是可选的锦上添花：真实样本 `sun_signed.ipa` 里两个 `AppIcon*.png`
// 都是 CgBI，不支持就等于「IPA 拿不到图标」。

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show isCgbiPng, normalizeCgbiPng, readPngSize;

const String _fixtureDir = 'test/fixtures/cgbi';

Uint8List _fixture(String name) {
  final file = File('$_fixtureDir/$name');
  expect(file.existsSync(), isTrue, reason: '缺少夹具 $_fixtureDir/$name');
  return file.readAsBytesSync();
}

// ---------------------------------------------------------------------------
// 手工构造 CgBI（用于覆盖 pngcrush 夹具没覆盖到的路径）
// ---------------------------------------------------------------------------

Uint8List _u32(int v) => Uint8List.fromList([
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ]);

Uint8List _chunk(String type, Uint8List data) {
  final t = Uint8List.fromList(type.codeUnits);
  final crcInput = Uint8List(t.length + data.length)
    ..setRange(0, t.length, t)
    ..setRange(t.length, t.length + data.length, data);
  return (BytesBuilder(copy: false)
        ..add(_u32(data.length))
        ..add(t)
        ..add(data)
        ..add(_u32(getCrc32(crcInput)))
        ..add(Uint8List(0)))
      .takeBytes();
}

/// 把**直通 RGBA** 编成 CgBI 的磁盘形态：`B, G, R, A`，且 RGB 按 alpha 预乘。
///
/// `pngcrush -iphone` 做的就是这件事，测试里必须照做。
///
/// 预乘是**有损**的，因此这个辅助函数只在 `A == 255` 时能保证逐字节往返；
/// 半透明的情形由 `pngcrush` 夹具覆盖（期望值来自 Apple 的还原结果）。
Uint8List _toCgbiLayout(Uint8List rgba) {
  final out = Uint8List(rgba.length);
  for (var i = 0; i < rgba.length; i += 4) {
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    final a = rgba[i + 3];
    out[i] = (b * a + 127) ~/ 255;
    out[i + 1] = (g * a + 127) ~/ 255;
    out[i + 2] = (r * a + 127) ~/ 255;
    out[i + 3] = a;
  }
  return out;
}

/// 造一个 CgBI 文件：`IDAT` 是**裸 deflate**（`Deflate` 不写 zlib 头）。
///
/// [rgba] 是**期望的直通 RGBA**，函数负责编成 CgBI 的磁盘形态。
/// [filters] 逐行给出过滤器类型，用来确定性地覆盖全部五种。
Uint8List _buildCgbi({
  required int width,
  required int height,
  required Uint8List rgba,
  List<int>? filters,
  int colorType = 6,
  int bitDepth = 8,
  int interlace = 0,
  bool includeCgbiChunk = true,
}) {
  final bpp = colorType == 6 ? 4 : 3;
  final stride = width * bpp;
  // [rgba] 是期望的直通 RGBA；磁盘上必须写成 CgBI 的形态，否则造出来的
  // 文件根本不是 CgBI，测出来的东西也不成立。
  final stored = colorType == 6 ? _toCgbiLayout(rgba) : rgba;
  final body = Uint8List(height * (1 + stride));
  for (var y = 0; y < height; y++) {
    final filter = filters == null ? 0 : filters[y % filters.length];
    body[y * (1 + stride)] = filter;
    body.setRange(y * (1 + stride) + 1, y * (1 + stride) + 1 + stride, stored,
        y * stride);
  }
  // 过滤器作用在字节上，所以上面先按「未过滤」填好、再由下面手工施加过滤。
  final filtered = _applyFilters(body, width, height, bpp, filters);

  final builder = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  if (includeCgbiChunk) {
    builder.add(_chunk('CgBI', Uint8List.fromList([0x50, 0x00, 0x20, 0x06])));
  }
  builder
    ..add(_chunk(
      'IHDR',
      Uint8List.fromList([
        ..._u32(width),
        ..._u32(height),
        bitDepth,
        colorType,
        0,
        0,
        interlace,
      ]),
    ))
    ..add(_chunk('IDAT', Deflate(filtered).getBytes()))
    ..add(_chunk('IEND', Uint8List(0)));
  return builder.takeBytes();
}

/// 按 [filters] 把「未过滤」的扫描行编成 PNG 的过滤后字节。
Uint8List _applyFilters(
  Uint8List raw,
  int width,
  int height,
  int bpp,
  List<int>? filters,
) {
  final stride = width * bpp;
  final out = Uint8List(height * (1 + stride));
  final prev = Uint8List(stride);
  for (var y = 0; y < height; y++) {
    final filter = filters == null ? 0 : filters[y % filters.length];
    final srcStart = y * (1 + stride) + 1;
    final dstStart = y * (1 + stride) + 1;
    out[y * (1 + stride)] = filter;
    for (var i = 0; i < stride; i++) {
      final v = raw[srcStart + i];
      final a = i >= bpp ? raw[srcStart + i - bpp] : 0;
      final b = prev[i];
      final c = i >= bpp ? prev[i - bpp] : 0;
      out[dstStart + i] = switch (filter) {
        0 => v,
        1 => (v - a) & 0xFF,
        2 => (v - b) & 0xFF,
        3 => (v - ((a + b) >> 1)) & 0xFF,
        _ => (v - _paeth(a, b, c)) & 0xFF,
      };
    }
    prev.setRange(0, stride, raw, srcStart);
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

/// 把规范化后的 PNG 解回直通 RGBA，便于与期望值比对。
///
/// 这里**不复用被测实现**：自己再写一遍解压 + 还原过滤器，否则测试只是
/// 「实现与它自己一致」。
Uint8List _decodePngToRgba(Uint8List png) {
  final chunks = <String, List<int>>{};
  var off = 8;
  final idat = BytesBuilder();
  var width = 0;
  var height = 0;
  while (off + 12 <= png.length) {
    final len = (png[off] << 24) |
        (png[off + 1] << 16) |
        (png[off + 2] << 8) |
        png[off + 3];
    final type = String.fromCharCodes(png, off + 4, off + 8);
    final data = png.sublist(off + 8, off + 8 + len);
    if (type == 'IHDR') {
      width = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
      height = (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
      chunks['IHDR'] = data;
    } else if (type == 'IDAT') {
      idat.add(data);
    }
    off += 12 + len;
    if (type == 'IEND') break;
  }
  final raw = const ZLibDecoder().decodeBytes(idat.takeBytes());
  final stride = width * 4;
  final out = Uint8List(height * stride);
  final prev = Uint8List(stride);
  var pos = 0;
  for (var y = 0; y < height; y++) {
    final filter = raw[pos++];
    final lineStart = y * stride;
    for (var i = 0; i < stride; i++) {
      final a = i >= 4 ? out[lineStart + i - 4] : 0;
      final b = prev[i];
      final c = i >= 4 ? prev[i - 4] : 0;
      final v = raw[pos + i];
      out[lineStart + i] = switch (filter) {
        0 => v,
        1 => (v + a) & 0xFF,
        2 => (v + b) & 0xFF,
        3 => (v + ((a + b) >> 1)) & 0xFF,
        _ => (v + _paeth(a, b, c)) & 0xFF,
      };
    }
    prev.setRange(0, stride, out, lineStart);
    pos += stride;
  }
  return out;
}

void main() {
  group('isCgbiPng — 只看块链，不看扩展名', () {
    test('真实的 CgBI 夹具被认出', () {
      expect(isCgbiPng(_fixture('rgba-alpha-16x16.cgbi.png')), isTrue);
    });

    test('标准 PNG 不被误判', () {
      // 仓库里已有的普通 PNG。
      final plain = File('assets/image/icon.png').readAsBytesSync();
      expect(isCgbiPng(plain), isFalse);
    });

    test('不是 PNG 时不抛异常', () {
      expect(isCgbiPng(Uint8List(0)), isFalse);
      expect(isCgbiPng(Uint8List.fromList([1, 2, 3])), isFalse);
      expect(isCgbiPng('not a png at all'.codeUnits), isFalse);
    });

    test('签名对但块长度越界时不崩', () {
      final broken = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 签名
        0x7F, 0xFF, 0xFF, 0xFF, // 长度远超文件
        0x43, 0x67, 0x42, 0x49, // CgBI
      ]);
      expect(isCgbiPng(broken), isFalse);
      expect(normalizeCgbiPng(broken).ok, isFalse);
    });
  });

  group('readPngSize — 必须兼容 CgBI', () {
    test('CgBI 的 IHDR 前面还有 CgBI 块，尺寸仍要读出来', () {
      // 写死偏移 12 的实现在这里会返回 null —— 而尺寸是「按面积排序」与
      // 「解码前的像素预算检查」的前提。
      expect(readPngSize(_fixture('rgba-alpha-16x16.cgbi.png')), (16, 16));
    });

    test('标准 PNG 也能读', () {
      expect(readPngSize(File('assets/image/icon.png').readAsBytesSync()),
          isNotNull);
    });

    test('畸形输入返回 null 而不是抛异常', () {
      expect(readPngSize(Uint8List(0)), isNull);
      expect(readPngSize(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])), isNull);
    });
  });

  group('normalizeCgbiPng — 与 Apple 的实现逐字节一致', () {
    test('pngcrush 产出的夹具解出来与 revert 的结果完全相同', () {
      final result = normalizeCgbiPng(_fixture('rgba-alpha-16x16.cgbi.png'));
      expect(result.ok, isTrue, reason: result.failure);

      final actual = _decodePngToRgba(result.png!);
      final expected = _fixture('rgba-alpha-16x16.rgba');

      expect(actual.length, expected.length);
      // 逐字节比对，并报出第一处差异，否则失败信息只有一个「不相等」。
      var firstDiff = -1;
      for (var i = 0; i < expected.length; i++) {
        if (actual[i] != expected[i]) {
          firstDiff = i;
          break;
        }
      }
      expect(firstDiff, -1,
          reason: firstDiff == -1
              ? null
              : '第一处差异在字节 $firstDiff：期望 ${expected[firstDiff]}，'
                  '实际 ${actual[firstDiff]}');
    });

    test('输出是标准 PNG（不再含 CgBI 块，IDAT 带 zlib 头）', () {
      final result = normalizeCgbiPng(_fixture('rgba-alpha-16x16.cgbi.png'));
      final png = result.png!;

      expect(isCgbiPng(png), isFalse);
      // zlib 头的第一个字节是 0x78，CgBI 的裸 deflate 不会是它。
      final idatStart = _idatStart(png);
      expect(png[idatStart], 0x78, reason: 'IDAT 应当是 zlib 流（带 2 字节头）');
    });

    test('五种行过滤器都能还原', () {
      // pngcrush 的夹具只用了 Sub，覆盖不到其余四种 —— 这里自己造。
      const w = 6;
      const h = 5;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = (i * 7) & 0xFF;
        rgba[i * 4 + 1] = (i * 13) & 0xFF;
        rgba[i * 4 + 2] = (i * 29) & 0xFF;
        rgba[i * 4 + 3] = 255;
      }
      final cgbi = _buildCgbi(
        width: w,
        height: h,
        rgba: rgba,
        filters: const [0, 1, 2, 3, 4],
      );

      final result = normalizeCgbiPng(cgbi);
      expect(result.ok, isTrue, reason: result.failure);
      expect(_decodePngToRgba(result.png!), rgba,
          reason: '五种过滤器还原后应当逐字节回到原始像素');
    });

    test('全不透明像素是精确还原（真实图标的形态）', () {
      const w = 4;
      const h = 2;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 200 - i;
        rgba[i * 4 + 1] = 10 + i;
        rgba[i * 4 + 2] = 30 + i;
        rgba[i * 4 + 3] = 255;
      }
      final result =
          normalizeCgbiPng(_buildCgbi(width: w, height: h, rgba: rgba));
      expect(result.ok, isTrue, reason: result.failure);
      expect(_decodePngToRgba(result.png!), rgba);
    });
  });

  group('normalizeCgbiPng — 不接受猜', () {
    test('不是 CgBI 时明确拒绝，而不是照常转换', () {
      final plain = File('assets/image/icon.png').readAsBytesSync();
      final result = normalizeCgbiPng(plain);
      expect(result.ok, isFalse);
      expect(result.failure, contains('not a CgBI'));
    });

    test('非 8 位 RGBA 的形态如实说明，而不是解出颜色错误的图', () {
      // 灰度（色彩类型 0）不是 CgBI 会出现的形态；这里造一个假想的出来。
      final rgba = Uint8List(4 * 2 * 3);
      final cgbi = _buildCgbi(
        width: 4,
        height: 2,
        rgba: rgba,
        colorType: 2, // RGB
      );
      final result = normalizeCgbiPng(cgbi);
      expect(result.ok, isFalse);
      expect(result.failure, contains('only 8-bit RGBA'));
      expect(result.failure, contains('colour type 2'));
    });

    test('隔行的 CgBI 如实说明不支持', () {
      final rgba = Uint8List(4 * 2 * 4);
      final cgbi = _buildCgbi(
        width: 4,
        height: 2,
        rgba: rgba,
        interlace: 1,
      );
      final result = normalizeCgbiPng(cgbi);
      expect(result.ok, isFalse);
      expect(result.failure, contains('interlaced'));
    });

    test('缺少 IDAT 时说明原因', () {
      final builder = BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('CgBI', Uint8List.fromList([0x50, 0x00, 0x20, 0x06])))
        ..add(_chunk(
          'IHDR',
          Uint8List.fromList([..._u32(4), ..._u32(4), 8, 6, 0, 0, 0]),
        ))
        ..add(_chunk('IEND', Uint8List(0)));
      final result = normalizeCgbiPng(builder.takeBytes());
      expect(result.ok, isFalse);
      expect(result.failure, contains('no IDAT'));
    });

    test('deflate 流损坏时给出原因而不是抛异常', () {
      final rgba = Uint8List(4 * 2 * 4);
      final good = _buildCgbi(width: 4, height: 2, rgba: rgba);
      // 把 IDAT 的数据段改坏：保留结构，只破坏压缩流。
      final broken = Uint8List.fromList(good);
      final idat = _idatStart(broken);
      for (var i = idat + 4; i < idat + 12 && i < broken.length; i++) {
        broken[i] = 0xFF;
      }
      final result = normalizeCgbiPng(broken);
      expect(result.ok, isFalse);
      expect(result.failure, isNotNull);
    });
  });
}

/// 第一个 `IDAT` 数据段的起始偏移。
int _idatStart(Uint8List png) {
  var off = 8;
  while (off + 12 <= png.length) {
    final len = (png[off] << 24) |
        (png[off + 1] << 16) |
        (png[off + 2] << 8) |
        png[off + 3];
    final type = String.fromCharCodes(png, off + 4, off + 8);
    if (type == 'IDAT') return off + 8;
    off += 12 + len;
  }
  throw StateError('no IDAT found');
}
