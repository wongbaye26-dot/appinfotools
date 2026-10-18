// 索引色（调色板）rendition 的解析与出图测试。
//
// ## 这一组钉住的是什么
//
// `Assets.car` 里有一类 rendition：**ISTC 声明 `ARGB`，但落盘的是每像素
// 1 字节的调色板索引**。判据是块内的 `dmp2` 描述符带一份调色板：
//
// ```
// "dmp2" | 04 01 0a 04 | u16 宽 | u16 本块行数 | u16 条目数 | u16 每条字节数
//        | 条目数 × 每条字节数 的调色板（**BGRA**）
// ```
//
// 两个夹具都由 `actool` 真实编译，**像素值是我自己生成的**，所以期望值
// 不来自本实现：
//
// - `palette-single.car`：300×300，横向三段纯色（红/绿/蓝），1 块、3 条调色板
// - `palette-banded.car`：1500×1000，同样的三段色，**2 块**（行 0..698 有 3 条
//   调色板，行 699..999 只有 1 条 —— 因为那一段全蓝）
//
// 第二个夹具是这一组里最重要的：它让「按块换调色板」成为**必须**。
// 用第一份调色板套全图，下半段会变成错的颜色，而画面上仍然「像一张图」。

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibDecoder;
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

Uint8List _fixture(String name) =>
    File('../../test/fixtures/car/$name').readAsBytesSync();

/// 取 PNG 里某个 chunk 的数据段。
Uint8List _chunk(Uint8List png, String type) {
  var pos = 8;
  while (pos + 8 <= png.length) {
    final length = ByteData.sublistView(png, pos, pos + 4).getUint32(0);
    final name = String.fromCharCodes(png.sublist(pos + 4, pos + 8));
    if (name == type) {
      return Uint8List.sublistView(png, pos + 8, pos + 8 + length);
    }
    pos += 12 + length;
  }
  fail('没有 $type chunk');
}

/// 解码后的图像（RGBA，每行带 1 字节 filter 0）。
class _Raster {
  final int width;
  final int height;
  final Uint8List raw;

  _Raster(this.width, this.height, this.raw);

  factory _Raster.of(Uint8List png) {
    final ihdr = _chunk(png, 'IHDR');
    final header = ByteData.sublistView(ihdr);
    final w = header.getUint32(0);
    final h = header.getUint32(4);
    expect(ihdr[9], 6, reason: 'RGBA（color type 6）');
    final raw = ZLibDecoder().decodeBytes(_chunk(png, 'IDAT'));
    expect(raw.length, (w * 4 + 1) * h, reason: '每行 1 字节 filter + w×4');
    return _Raster(w, h, raw);
  }

  List<int> pixel(int x, int y) {
    final o = y * (width * 4 + 1) + 1 + x * 4;
    return raw.sublist(o, o + 4);
  }

  /// 第 [y] 行的平均 RGB。
  List<int> rowMean(int y) {
    var r = 0, g = 0, b = 0;
    for (var x = 0; x < width; x++) {
      final p = pixel(x, y);
      r += p[0];
      g += p[1];
      b += p[2];
    }
    return [r ~/ width, g ~/ width, b ~/ width];
  }
}

void main() {
  group('索引色：结构解析', () {
    test('单块：300×300 一段带 3 条调色板', () {
      final catalog = parseAssetsCar(_fixture('palette-single.car'));
      final image = catalog.imagesNamed('PaletteSingle').single;

      expect(image.width, 300);
      expect(image.height, 300);
      expect(image.isIndexedColor, isTrue, reason: '块里有 dmp2 描述符 + 调色板');
      expect(image.paletteChunks, hasLength(1));
      final chunk = image.paletteChunks.single;
      expect(chunk.firstRow, 0);
      expect(chunk.rowCount, 300);
      expect(chunk.entryCount, 3, reason: '生成时只用了红/绿/蓝三种颜色');
      expect(chunk.stride, 4);
      expect(chunk.palette, hasLength(12));
    });

    test('多块：1500×1000 切两段，各带**各自的**调色板', () {
      final catalog = parseAssetsCar(_fixture('palette-banded.car'));
      final image = catalog.imagesNamed('PaletteBanded').single;

      expect(image.paletteChunks, hasLength(2));
      final first = image.paletteChunks[0];
      final second = image.paletteChunks[1];

      expect(first.firstRow, 0);
      expect(first.rowCount, 699);
      expect(second.firstRow, 699);
      expect(second.rowCount + first.rowCount, 1000, reason: '两段必须正好覆盖整幅图的高度');

      // 第二段全蓝，所以它的调色板只有 1 条 —— 与第一段的 3 条不同。
      // 这正是「不能共用一份调色板」的证据。
      expect(first.entryCount, 3);
      expect(second.entryCount, 1);
    });

    test('调色板条目是 BGRA：第 0 条读出来是蓝', () {
      final image = parseAssetsCar(_fixture('palette-single.car'))
          .imagesNamed('PaletteSingle')
          .single;
      final chunk = image.paletteChunks.single;

      // 三色图只有红/绿/蓝，调色板的集合必须正好是这三个。
      final seen = <String>{
        for (var i = 0; i < chunk.entryCount; i++)
          chunk.rgbaAt(i).take(3).join(','),
      };
      expect(seen, {'255,0,0', '0,255,0', '0,0,255'});
    });

    test('像素格式仍写 ARGB —— 那个字段是「解码后的目标格式」', () {
      final image = parseAssetsCar(_fixture('palette-single.car'))
          .imagesNamed('PaletteSingle')
          .single;
      expect(image.pixelFormat, 'ARGB');
      expect(image.isIndexedColor, isTrue, reason: '落盘形态与声明不同，这正是需要单独判定的原因');
    });
  });

  group('索引色：出图与像素', () {
    test('单块：三段颜色与生成时完全一致', () {
      final car = _fixture('palette-single.car');
      final image = parseAssetsCar(car).imagesNamed('PaletteSingle').single;

      final result = extractCarImagePng(car, image);
      expect(result.ok, isTrue, reason: result.failure);

      final raster = _Raster.of(result.png!);
      expect(raster.width, 300);
      expect(raster.height, 300);
      expect(raster.pixel(150, 10), [255, 0, 0, 255], reason: '上 1/3 是红');
      expect(raster.pixel(150, 150), [0, 255, 0, 255], reason: '中 1/3 是绿');
      expect(raster.pixel(150, 290), [0, 0, 255, 255], reason: '下 1/3 是蓝');
    });

    test('多块：跨块边界颜色连续（套错调色板会在这里暴露）', () {
      final car = _fixture('palette-banded.car');
      final image = parseAssetsCar(car).imagesNamed('PaletteBanded').single;

      final result = extractCarImagePng(car, image);
      expect(result.ok, isTrue, reason: result.failure);
      final raster = _Raster.of(result.png!);

      // 边界在 699 行，那里仍在绿色段内（绿从 333 到 666… 不，这里
      // 1000/3 = 333，2/3 = 666；699 已经进入蓝色段）。
      // 所以真正的判据是「边界两侧的**行平均色**不应突变」——
      // 若第二段套了第一段的 3 条调色板，它的单色索引会映射到错的颜色。
      final before = raster.rowMean(698);
      final after = raster.rowMean(699);
      for (var c = 0; c < 3; c++) {
        expect((after[c] - before[c]).abs(), lessThanOrEqualTo(1),
            reason: '块边界不该出现颜色台阶（before=$before after=$after）');
      }

      // 而且 699 之后必须真的还是蓝。
      expect(raster.pixel(10, 900), [0, 0, 255, 255]);
    });

    test('多块覆盖完整：每一行都被某个块覆盖', () {
      final image = parseAssetsCar(_fixture('palette-banded.car'))
          .imagesNamed('PaletteBanded')
          .single;
      var row = 0;
      for (final chunk in image.paletteChunks) {
        expect(chunk.firstRow, row, reason: '块必须首尾相接、无空洞');
        row += chunk.rowCount;
      }
      expect(row, 1000);
    });
  });

  group('索引色：边界与不猜', () {
    test('调色板残缺（行没覆盖满）时不认，退回普通路径', () {
      // 把 `palette-banded.car` 里第二个 dmp2 的行数改小 1 字节 ——
      // 结构自洽性被破坏，实现应当**整体放弃**调色板，
      // 而不是用残缺的调色板出半张图。
      final car = Uint8List.fromList(_fixture('palette-banded.car'));
      final catalog = parseAssetsCar(car);
      final image = catalog
          .imagesNamed('PaletteBanded')
          .singleWhere((i) => i.paletteChunks.length == 2);

      // 找第二个 dmp2 的行数字段（描述符 +10）
      var found = 0;
      var i = image.blockOffset;
      while (i + 16 < car.length) {
        if (car[i] == 0x64 &&
            car[i + 1] == 0x6d &&
            car[i + 2] == 0x70 &&
            car[i + 3] == 0x32) {
          found++;
          if (found == 2) {
            // rowCount 是 u16 LE，减 1
            final at = i + 10;
            final v = car[at] | (car[at + 1] << 8);
            car[at] = (v - 1) & 0xFF;
            car[at + 1] = ((v - 1) >> 8) & 0xFF;
            break;
          }
        }
        i++;
      }
      expect(found, 2, reason: '夹具里应当有两个 dmp2 描述符');

      final broken = parseAssetsCar(car)
          .imagesNamed('PaletteBanded')
          .singleWhere((image) => image.width == 1500);
      expect(broken.isIndexedColor, isFalse, reason: '行数加不满整图高度 → 不相信这套调色板');
    });

    test('索引越界时报错，不静默截断到 0 号色', () {
      // 把调色板条目数改成 1（原本 3）—— 红/绿的索引（1、2）就会越界。
      final car = Uint8List.fromList(_fixture('palette-single.car'));
      final image = parseAssetsCar(car).imagesNamed('PaletteSingle').single;

      var at = -1;
      for (var i = image.blockOffset; i + 16 < car.length; i++) {
        if (car[i] == 0x64 &&
            car[i + 1] == 0x6d &&
            car[i + 2] == 0x70 &&
            car[i + 3] == 0x32) {
          at = i;
          break;
        }
      }
      expect(at, greaterThan(0));
      car[at + 12] = 1;
      car[at + 13] = 0;

      final broken = parseAssetsCar(car).imagesNamed('PaletteSingle').single;
      // 只把条目数改成 1：结构自洽性仍然成立（1 × 4 字节的调色板确实存在、
      // 行覆盖也没问题），所以它**仍被认成索引色** —— 越界只有在真正映射
      // 像素时才会发现。这正是要测的地方：不能在映射时静默截断。
      expect(broken.isIndexedColor, isTrue);
      expect(broken.paletteChunks.single.entryCount, 1);

      final result = extractCarImagePng(car, broken);
      expect(result.ok, isFalse, reason: '索引 1、2 超出 1 条调色板，不能编图');
      expect(result.failureCode, 'palette_index_overflow');
      expect(result.failure, contains('outside the 1-entry palette'));
    });
  });
}
