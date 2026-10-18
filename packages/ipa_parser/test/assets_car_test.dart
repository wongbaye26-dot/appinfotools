// `Assets.car` 索引解析 —— 期望值全部来自 `assetutil --info`。
//
// ## 为什么期望值只能来自外部工具
//
// `Assets.car` 是 Apple 私有格式，**没有公开文档**。所以任何「按我理解写成
// 的字段偏移」都必须拿一个独立实现去核对，否则就是自证。
//
// macOS 自带 `/usr/bin/assetutil --info <file>` 输出 JSON，里面有
// `PixelWidth` / `PixelHeight` / `Encoding` / `SizeOnDisk` / `RenditionName`
// —— 正好覆盖本实现给出的每一个字段。夹具的 README 里存了原始输出。
//
// ## 夹具来源
//
// `test/fixtures/car/installer-progress.car` 是 macOS 系统自带的真实资产目录
// （`/System/Library/CoreServices/Installer Progress.app`），18 KB、4 张图。
// 用真实产物而不是手拼：BOM 的块表、ISTC 的字段偏移都是**按偏移访问的二进制
// 结构**，拼错不会报错，只会读出一个看起来合理的错值。
//
// ## 三个实测踩过的坑（都写成了断言）
//
// 1. **端序混用**：BOM 头与块表是大端，`RATC` 与 `ISTC` 头是小端。
//    按大端读 `RATC` 的版本字段会得到 285212672 / 4077060096 这种数。
// 2. **块表条目数不是 `indexOffset` 处的那个 u32**：它读出 256，而真实块数是
//    头里的 `blockCount`（本夹具 23）。
// 3. **4CC 是反序存的**：文件里的 `BGRA` 表示 `ARGB`（与 assetutil 的
//    `Encoding: "ARGB"` 一致），`GA8 ` 读出来是 ` 8AG`。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

/// 夹具在仓库里的相对路径（`dart test` 的 cwd 是包目录）。
const _fixture = '../../test/fixtures/car/installer-progress.car';

Uint8List _bytes() => File(_fixture).readAsBytesSync();

AssetsCarCatalog _parse() => parseAssetsCar(_bytes());

/// 按 rendition 名取图；找不到直接失败（避免「断言跳过了一个不存在的条目」）。
AssetsCarImage _byName(AssetsCarCatalog catalog, String name) {
  for (final image in catalog.images) {
    if (image.renditionName == name) return image;
  }
  fail('没有 rendition 名叫 $name；实际有 '
      '${catalog.images.map((i) => i.renditionName).toList()}');
}

void main() {
  group('容器与版本', () {
    test('解析成功，块数与版本与 assetutil 一致', () {
      final catalog = _parse();
      expect(catalog.parsed, isTrue, reason: catalog.failure);
      // assetutil --info 的第一条：StorageVersion 17、CoreUIVersion 1011
      expect(catalog.storageVersion, 17);
      expect(catalog.coreUiVersion, 1011);
      expect(catalog.blockCount, 23);
    });

    test('4 张图全部读出来（assetutil 里 AssetType=Image 的正好 4 条）', () {
      final catalog = _parse();
      expect(catalog.images, hasLength(4));
      expect(
        catalog.images.map((i) => i.renditionName).toSet(),
        {
          'LowBatteryEmpty.png',
          'LowBatteryEmpty@2x.png',
          'LowBatteryFlashing.png',
          'LowBatteryFlashing@2x.png',
        },
      );
    });
  });

  group('逐条对照 assetutil', () {
    // 期望值逐字抄自 `assetutil --info`（原始输出见夹具 README）。
    test('LowBatteryEmpty.png：173×72、Gray、857 字节', () {
      final image = _byName(_parse(), 'LowBatteryEmpty.png');
      expect(image.width, 173);
      expect(image.height, 72);
      expect(image.sizeOnDisk, 857);
      // assetutil 说 Encoding = "Gray"；本实现给的是 4CC `GA8 `（Gray 8-bit）。
      expect(image.pixelFormat, 'GA8 ');
    });

    test('LowBatteryEmpty@2x.png：346×144、Gray、1332 字节', () {
      final image = _byName(_parse(), 'LowBatteryEmpty@2x.png');
      expect(image.width, 346);
      expect(image.height, 144);
      expect(image.sizeOnDisk, 1332);
      expect(image.pixelFormat, 'GA8 ');
    });

    test('LowBatteryFlashing.png：30×72、ARGB、739 字节', () {
      final image = _byName(_parse(), 'LowBatteryFlashing.png');
      expect(image.width, 30);
      expect(image.height, 72);
      expect(image.sizeOnDisk, 739);
      // 文件里写的是 `BGRA`，反序后才是 assetutil 的 "ARGB"。
      expect(image.pixelFormat, 'ARGB');
    });

    test('LowBatteryFlashing@2x.png：60×144、ARGB、1155 字节', () {
      final image = _byName(_parse(), 'LowBatteryFlashing@2x.png');
      expect(image.width, 60);
      expect(image.height, 144);
      expect(image.sizeOnDisk, 1155);
      expect(image.pixelFormat, 'ARGB');
    });
  });

  group('压缩：图像数据是 LZFSE，不是可直接取用的像素', () {
    test('三张 2x/1x 的图都被识别为 lzfse-v2（块内有 bvx2）', () {
      final catalog = _parse();
      final compressed = catalog.rasterImages
          .where((i) => i.compression == CarCompression.lzfseV2);
      expect(compressed, hasLength(3), reason: '实测这三张图块内都有 bvx2 魔数');
    });

    test('LZFSE 算「已压缩」，也就是「有像素但要解码」', () {
      final image = _byName(_parse(), 'LowBatteryEmpty.png');
      expect(image.compression.isCompressed, isTrue);
      expect(image.embedsPixels, isTrue);
      // 这就是本实现**不**提供像素的原因：要取图必须先解 LZFSE。
      expect(image.compression.label, contains('LZFSE'));
    });
  });

  group('空壳：有宽高但没有像素', () {
    test('LowBatteryFlashing.png 是空壳（739 字节装不下 30×72 的像素）', () {
      // assetutil 也说它 SizeOnDisk = 739，与 30×72×1 = 2160 差得远。
      // 实测这类条目在系统样本里成千上万（Music.app 有 5694 个）。
      final image = _byName(_parse(), 'LowBatteryFlashing.png');
      expect(image.compression, CarCompression.none, reason: '块内没有 bvx 魔数');
      expect(image.embedsPixels, isFalse);
      expect(image.isRasterImage, isTrue, reason: '它有宽高，只是没像素');
    });

    test('空壳不进 rasterImages，但在 placeholderOnly 里', () {
      final catalog = _parse();
      expect(catalog.rasterImages, hasLength(3));
      expect(catalog.placeholderOnly.map((i) => i.renditionName),
          ['LowBatteryFlashing.png']);
      expect(catalog.sizedImages, hasLength(4));
    });
  });

  group('读不出 ≠ 没有', () {
    test('不是 BOMStore → failure，不是「0 张图」', () {
      final catalog = parseAssetsCar(
        Uint8List.fromList(List.filled(64, 0x41)),
      );
      expect(catalog.parsed, isFalse);
      expect(catalog.failure, contains('BOMStore'));
      expect(catalog.images, isEmpty);
    });

    test('文件太短 → failure', () {
      final catalog = parseAssetsCar(Uint8List.fromList([0x42, 0x4F, 0x4D]));
      expect(catalog.parsed, isFalse);
      expect(catalog.failure, contains('too small'));
    });

    test('块表越界 → failure（不可信长度不能决定读多少）', () {
      final bytes = Uint8List.fromList(_bytes());
      final data = ByteData.sublistView(bytes);
      // indexOffset 在 0x10（大端）
      data.setUint32(0x10, 0xFFFFFF, Endian.big);
      final catalog = parseAssetsCar(bytes);
      expect(catalog.parsed, isFalse);
      expect(catalog.failure, contains('out of range'));
    });

    test('块数被夸张 → 在上限处拒绝', () {
      final bytes = Uint8List.fromList(_bytes());
      final data = ByteData.sublistView(bytes);
      data.setUint32(0x0C, 0x7FFFFFFF, Endian.big); // blockCount
      final catalog = parseAssetsCar(bytes);
      expect(catalog.parsed, isFalse);
      expect(catalog.failure, contains('cap'));
    });

    test('块地址越界的条目被跳过，不影响其它块', () {
      final bytes = Uint8List.fromList(_bytes());
      final data = ByteData.sublistView(bytes);
      final blockCount = data.getUint32(0x0C, Endian.big);
      final indexOffset = data.getUint32(0x10, Endian.big);
      // 把第一条块表条目的地址改到文件之外。
      data.setUint32(indexOffset + 4, 0xFFFFFF, Endian.big);
      final catalog = parseAssetsCar(bytes);
      expect(catalog.parsed, isTrue, reason: '单条坏条目不该让整个文件失败');
      expect(catalog.blockCount, blockCount);
    });
  });

  group('appIcon 候选的判据', () {
    test('本夹具没有 AppIcon，候选为空', () {
      expect(_parse().appIconCandidates, isEmpty);
    });

    test('名字含 appicon 且不带路径才算候选', () {
      const icon = AssetsCarImage(
        renditionName: 'AppIcon60x60@2x.png',
        width: 120,
        height: 120,
        pixelFormat: 'ARGB',
        sizeOnDisk: 5000,
        blockOffset: 0,
      );
      // `AppIcon_Assets/Color-1` 这种是图标内部图层，不是图标本身。
      const layer = AssetsCarImage(
        renditionName: 'AppIcon_Assets/Color-1',
        width: 1,
        height: 1,
        pixelFormat: 'ARGB',
        sizeOnDisk: 200,
        blockOffset: 0,
      );
      expect(icon.looksLikeAppIcon, isTrue);
      expect(layer.looksLikeAppIcon, isFalse, reason: '带 `/` 的是资产内部图层');
    });
  });
  _endToEndTests();
}

// ---------------------------------------------------------------------------
// 端到端：Info.plist 用 CFBundleIconName 指向 Assets.car
// ---------------------------------------------------------------------------
//
// 这一段把 `IpaIconResolver` 也串起来：真实的 `Assets.car` 放进一个临时
// Archive，`CFBundleIconName` 指过去，断言解析结果把「容器里有什么」说出来。
//
// Info.plist 是**手写的 XML** —— 这是允许的：plist 是公开文本格式，手写不会
// 引入「与解析器相同的错误假设」。而 `Assets.car` 用的是真实产物。

/// 造一个只有 Info.plist 与 Assets.car 的最小 bundle。
(IosBundle, Archive) _makeBundle({required bool withCar}) {
  const bundlePath = 'Payload/Example.app';
  const plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.carfixture</string>
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconName</key><string>AppIcon</string>
    </dict>
  </dict>
</dict></plist>
''';
  final archive = Archive();
  final plistBytes = const Utf8Encoder().convert(plist);
  archive.addFile(
      ArchiveFile('$bundlePath/Info.plist', plistBytes.length, plistBytes));
  if (withCar) {
    final car = File(_fixture).readAsBytesSync();
    archive.addFile(ArchiveFile('$bundlePath/Assets.car', car.length, car));
  }
  const bundle = IosBundle(
    kind: IosBundleKind.mainApp,
    path: bundlePath,
    name: 'Example.app',
    infoPlistPath: '$bundlePath/Info.plist',
    infoPlistSize: 512,
    fileCount: 2,
    uncompressedBytes: 4096,
  );
  return (bundle, archive);
}

void _endToEndTests() {
  group('端到端：CFBundleIconName → Assets.car', () {
    test('解析结果带上 Assets.car 索引，并说明「像素未解码」', () {
      final (bundle, archive) = _makeBundle(withCar: true);
      final info = IpaInfoPlistReader.read(archive, bundle);
      final resolution = IpaIconResolver.resolve(archive, info);

      expect(resolution.assetCatalog, isNotNull,
          reason: '声明了 CFBundleIconName 且容器在，就该把索引读出来');
      expect(resolution.assetCatalog!.parsed, isTrue);
      expect(resolution.assetCatalog!.images, hasLength(4));

      // 仍然没有可预览的候选 —— 像素是 LZFSE 压缩的，取不出来。
      expect(resolution.candidates, isEmpty);
      expect(resolution.assetCatalogOnly, isTrue);

      final unresolved = resolution.unresolved.single;
      expect(unresolved.source, IosIconSource.assetCatalogName);
      expect(unresolved.archivePath, 'Payload/Example.app/Assets.car');
      expect(unresolved.reason, contains('Assets.car'));
      // 夹具里的图名不含 AppIcon（它是菜单栏小图标），所以走「认不出是哪张」
      // 的分支 —— 但「为什么预览不了」的答案仍必须包含 LZFSE。
      expect(unresolved.reason, contains('RENDITIONS'),
          reason: '要说清「认不出是哪一张」的原因在 RENDITIONS 索引');
      expect(unresolved.reason, contains('LZFSE'),
          reason: '必须说清「为什么预览不了」是像素被压缩了，而不是「没实现」');
    });

    test('没有 Assets.car 时说「缺文件」，不说「解析失败」', () {
      final (bundle, archive) = _makeBundle(withCar: false);
      final info = IpaInfoPlistReader.read(archive, bundle);
      final resolution = IpaIconResolver.resolve(archive, info);

      expect(resolution.assetCatalog, isNull);
      expect(resolution.unresolved.single.reason,
          contains('no Assets.car entry was found'));
      expect(resolution.unresolved.single.archivePath, isNull);
    });

    test('容器坏了 → 说「读不出/解析不了」，不假装「没有图」', () {
      final (bundle, archive) = _makeBundle(withCar: false);
      // 放一个不是 BOMStore 的假 Assets.car
      final junk = Uint8List.fromList(List.filled(512, 0x41));
      archive.addFile(
          ArchiveFile('Payload/Example.app/Assets.car', junk.length, junk));
      final info = IpaInfoPlistReader.read(archive, bundle);
      final resolution = IpaIconResolver.resolve(archive, info);

      expect(resolution.assetCatalog, isNotNull);
      expect(resolution.assetCatalog!.parsed, isFalse);
      expect(resolution.unresolved.single.reason, contains('could not be'));
    });
  });
}
