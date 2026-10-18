// LZFSE 解码的**根级冒烟测试**。
//
// 详细用例在 `packages/ipa_parser/test/lzfse_test.dart`（24 条）。这里只做两件事：
//
// 1. 从**应用侧**确认 `package:ipa_parser` 导出的 `lzfseDecode` 可用；
// 2. 让 `test/fixtures/lzfse/` 下的夹具在根 `test/` 里被引用 ——
//    `acceptance_test.dart` 的「没有死夹具」守卫只扫根 `test/`，
//    否则这些夹具会被判成没人用。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const _dir = 'test/fixtures/lzfse';

/// 夹具清单。
///
/// **必须逐个列出文件名**：`acceptance_test.dart` 的「没有死夹具」守卫是按
/// 文件名匹配源码文本的，路径拼接不会命中。顺带这个清单本身就是一条断言：
/// 夹具缺了会红。
const List<String> _fixtureFiles = [
  'empty.bin',
  'empty.lzfse',
  'incompressible.bin',
  'incompressible.lzfse',
  'repeated-text.bin',
  'repeated-text.lzfse',
  'zeros.bin',
  'zeros.lzfse',
  'pixel-like.bin',
  'pixel-like.lzfse',
  'multi-block.bin',
  'multi-block.lzfse',
  'make_fixtures.c',
];

void main() {
  test('夹具齐全（含生成器源码）', () {
    for (final name in _fixtureFiles) {
      expect(File('$_dir/$name').existsSync(), isTrue, reason: '缺夹具 $name');
    }
    // 每个压缩夹具都必须有配套的原始数据 —— 没有它就无法验证解码结果。
    for (final name in _fixtureFiles.where((n) => n.endsWith('.lzfse'))) {
      final base = name.substring(0, name.length - '.lzfse'.length);
      expect(File('$_dir/$base.bin').existsSync(), isTrue,
          reason: '$name 没有配套的 $base.bin');
    }
  });

  test('往返：与 libcompression 的输出逐字节一致', () {
    for (final name in ['zeros', 'repeated-text', 'multi-block']) {
      final packed = File('$_dir/$name.lzfse').readAsBytesSync();
      final expected = File('$_dir/$name.bin').readAsBytesSync();
      expect(lzfseDecode(packed), orderedEquals(expected),
          reason: '$name 的解码结果与原始字节不一致');
    }
  });

  test('`Assets.car` 的图能真的取出来（LZFSE + PNG 一条链）', () {
    final car =
        File('test/fixtures/car/installer-progress.car').readAsBytesSync();
    final catalog = parseAssetsCar(car);
    final image = catalog.images
        .firstWhere((i) => i.renditionName == 'LowBatteryEmpty@2x.png');

    final result = extractCarImagePng(car, image);
    expect(result.ok, isTrue, reason: result.failure);
    // PNG 头里的宽高必须与 rendition 声明的一致。
    expect(String.fromCharCodes(result.png!.sublist(1, 4)), 'PNG');
    expect(result.png!.length, greaterThan(100));
  });

  test('不支持的块类型报错带稳定 code，便于上层分类', () {
    // `bvxn` = LZVN。它从不作为光栅图的**首个**流出现，但在多流 payload 的
    // 后续 chunk 里会碰到（实测 3,244 张里 109 张），所以必须报而不是猜。
    final src = File('$_dir/empty.lzfse').readAsBytesSync();
    final patched = [...src];
    if (patched.length >= 4) {
      patched[0] = 0x62;
      patched[1] = 0x76;
      patched[2] = 0x78;
      patched[3] = 0x6E;
    }
    expect(
      () => lzfseDecode(Uint8List.fromList(patched)),
      throwsA(isA<LzfseException>()
          .having((e) => e.code, 'code', 'block.unsupported_lzvn')),
    );
  });

  test('索引色：调色板 + 逐块换板，跨块边界颜色不跳', () {
    // 详细用例在 `packages/ipa_parser/test/assets_car_palette_test.dart`。
    // 这里做端到端确认：夹具是 `actool` 编的三段纯色图，第二份切成了两块
    // （行 0..698 有 3 条调色板，699 之后只有 1 条）。
    //
    // 两个夹具都从根 `test/` 引用一次 —— `acceptance_test.dart` 的
    // 「没有死夹具」守卫只扫根 `test/`。
    for (final name in ['palette-single.car', 'palette-banded.car']) {
      final car = File('test/fixtures/car/$name').readAsBytesSync();
      final catalog = parseAssetsCar(car);
      expect(catalog.parsed, isTrue, reason: '$name: ${catalog.failure}');

      final indexed =
          catalog.rasterImages.where((i) => i.isIndexedColor).toList();
      expect(indexed, hasLength(1), reason: '$name 应当有一个索引色 rendition');

      final result = extractCarImagePng(car, indexed.single);
      expect(result.ok, isTrue, reason: '$name: ${result.failure}');
      expect(String.fromCharCodes(result.png!.sublist(1, 4)), 'PNG');
    }
  });
}
