// `Assets.car` 的**资产名**索引（`RENDITIONS` 的键）测试。
//
// 这一层的字段布局没有任何文档，全部靠实测反解 + `assetutil --info` 核对。
// 所以用例分两类：
//   1. **对齐外部实现**：真实夹具上，资产名与 `NameIdentifier` 必须与
//      `assetutil` 逐条相等。这是唯一能证明「不是自证」的办法。
//   2. **不猜**：图集成员（标识符 0）、名字对不上、空壳，各自的处理都钉住。

import 'dart:io';
import 'dart:typed_data';

import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

Uint8List _fixture(String name) {
  final file = File('../../test/fixtures/car/$name');
  if (!file.existsSync()) {
    fail('缺少夹具 test/fixtures/car/$name —— 见同目录 README');
  }
  return file.readAsBytesSync();
}

void main() {
  group('资产名索引 — 与 assetutil 对齐', () {
    test('iOS 目录：3 个资产名，AppIcon 的 4 条 rendition 全部归到它名下', () {
      final catalog = parseAssetsCar(_fixture('appicon-ios.car'));

      expect(catalog.parsed, isTrue, reason: catalog.failure);
      expect(catalog.nameIndex, AssetNameIndex.parsed);
      expect(catalog.assetNames, ['AppIcon', 'BrandMark', 'ToolbarGlyph']);
      expect(catalog.ambiguousNameCount, 0);

      final appIcon = catalog.imagesNamed('AppIcon');
      expect(appIcon, hasLength(4),
          reason: '两张真图（1024 / 60）+ 两张 MultiSized 空壳');
      expect(appIcon.map((i) => i.assetIdentifier).toSet(), {6849},
          reason: 'assetutil --info 的 NameIdentifier 是 6849');
      expect(catalog.imagesNamed('BrandMark'), hasLength(2));
      expect(catalog.imagesNamed('ToolbarGlyph'), hasLength(1));
    });

    test('macOS 目录：Key Format 只有 8 项，编号仍能对上', () {
      final catalog = parseAssetsCar(_fixture('installer-progress.car'));

      expect(catalog.nameIndex, AssetNameIndex.parsed);
      expect(catalog.assetNames, ['LowBatteryEmpty', 'LowBatteryFlashing']);
      // 两个名字各 2 条 rendition，标识符分别是 33588 / 48467。
      expect(
        catalog.imagesNamed('LowBatteryEmpty').map((i) => i.assetIdentifier),
        [33588, 33588],
      );
      expect(
        catalog.imagesNamed('LowBatteryFlashing').map((i) => i.assetIdentifier),
        [48467, 48467],
      );
    });

    test('资产名精确匹配，不做前缀/包含匹配', () {
      final catalog = parseAssetsCar(_fixture('appicon-ios.car'));

      expect(catalog.imagesNamed('App').isEmpty, isTrue);
      expect(catalog.imagesNamed('appicon').isEmpty, isTrue,
          reason: '资产名大小写敏感 —— 它是键，不是展示文案');
      expect(catalog.imagesNamed('AppIcon_Assets/Color-1').isEmpty, isTrue,
          reason: '这一份目录里没有那个资产');
    });

    test('`looksLikeAppIcon` 优先用资产名，不再只看 rendition 名', () {
      final catalog = parseAssetsCar(_fixture('appicon-ios.car'));
      final appIcon =
          catalog.imagesNamed('AppIcon').firstWhere((i) => i.width == 1024);

      expect(appIcon.renditionName, isNot(contains('AppIcon')),
          reason: 'rendition 名是 icon1024.png —— 光看它判断不出是图标');
      expect(appIcon.looksLikeAppIcon, isTrue, reason: '资产名是 AppIcon，这才是判据');
    });
  });

  group('资产名索引 — 不猜的情形', () {
    test('图集成员（标识符 0）没有资产名，并被单独计数', () {
      final catalog = parseAssetsCar(_fixture('appicon-ios.car'));

      expect(catalog.atlasMemberCount, 1);
      final atlas = catalog.images.firstWhere((i) => i.isAtlasMember);
      expect(atlas.assetName, isNull);
      expect(atlas.assetIdentifier, 0);
      expect(atlas.renditionName, 'ZZZZPackedAsset-1.1.0-gamut0',
          reason: 'assetutil 对这个条目也只给合成名，不给 NameIdentifier');
      // 图集成员的 rendition 名不带 appicon，所以不该被当图标候选。
      expect(atlas.looksLikeAppIcon, isFalse);
    });

    test('空壳 rendition 也有资产名（它的键是完整的）', () {
      final catalog = parseAssetsCar(_fixture('appicon-ios.car'));
      final shells =
          catalog.imagesNamed('AppIcon').where((i) => !i.embedsPixels).toList();

      expect(shells, hasLength(2));
      for (final shell in shells) {
        expect(shell.width, isNull, reason: 'MultiSized 条目没有像素尺寸');
        expect(shell.isRasterImage, isFalse);
      }
    });

    test('不是 BOMStore 时不崩，并说清原因', () {
      final catalog = parseAssetsCar(Uint8List(64));

      expect(catalog.parsed, isFalse);
      expect(catalog.failure, contains('BOMStore'));
      expect(catalog.nameIndex, AssetNameIndex.absent);
      expect(catalog.assetNames, isEmpty);
    });
  });

  group('可解码候选', () {
    test('按面积从大到小，且排除空壳与 deepmap2', () {
      final catalog = parseAssetsCar(_fixture('appicon-ios.car'));
      final images = decodableImagesForAsset(catalog, 'AppIcon');

      expect(images, hasLength(2), reason: '1024 与 60 两条；两张 MultiSized 空壳被排除');
      expect(images.first.width, 1024);
      expect(images.last.width, 60);

      // BrandMark 的 1x 只有 330 字节（无自己的像素），只剩 80×80 那条。
      final brand = decodableImagesForAsset(catalog, 'BrandMark');
      expect(brand, hasLength(1));
      expect(brand.single.width, 80);
    });

    test('没有这个资产时返回空列表，而不是退化成「随便挑一张」', () {
      final catalog = parseAssetsCar(_fixture('appicon-ios.car'));

      expect(decodableImagesForAsset(catalog, 'NotThere'), isEmpty);
      expect(
          decodableImagesForAsset(catalog, 'AppIcon_Assets/Color-1'), isEmpty);
    });
  });
}
