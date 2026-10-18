// IPA 图标解析测试（规范 5.3）。
//
// 三条硬约束各有对应用例：
//   1. 只按 Info.plist 点名的文件定位 —— 有「不扫描目录」的用例钉住。
//   2. 无法直接预览的资源要明确说明 —— 有 Assets.car 的用例。
//   3. 解码前挡住大图 —— 有超限候选不带字节的用例。
//
// PNG 样本用的是项目里真实存在的 assets/image/icon.png（256x256）。需要不同
// 尺寸时用只含签名 + IHDR 的最小头部构造 —— 被测逻辑只读头部、不校验 CRC，
// 真实完整 PNG 的用例由前者覆盖。

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

/// 项目内真实的 PNG（256x256）。
///
/// 直接读仓库文件而不是内嵌 12 KB base64：这份资产本来就在版本控制里，
/// 用它当样本比把同样的字节再抄一遍更不容易失真。
Uint8List _realPng() {
  final file = File('assets/image/icon.png');
  expect(file.existsSync(), isTrue,
      reason: '测试依赖仓库内的 assets/image/icon.png 作为真实 PNG 样本');
  return file.readAsBytesSync();
}

List<int> _be32(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF
    ];

/// 只含 PNG 签名与 IHDR 的最小头部，用于构造指定尺寸的候选。
///
/// 不是完整可解码的 PNG。块必须**四个部分齐全**（长度 + 类型 + 数据 + CRC）——
/// 尺寸读取走的是块链，缺 CRC 就是被截断的块，会被当成畸形文件拒掉；CRC 的
/// 值本身不校验（填 0）。
Uint8List _pngHeader(int width, int height) => Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 签名
      0, 0, 0, 13, // IHDR 块长度
      0x49, 0x48, 0x44, 0x52, // "IHDR"
      ..._be32(width), ..._be32(height),
      8, 6, 0, 0, 0, // 位深 / 颜色类型 / 压缩 / 过滤 / 隔行
      0, 0, 0, 0, // CRC 占位
    ]);

ArchiveFile _file(String name, List<int> bytes, {int? declaredSize}) =>
    ArchiveFile(name, declaredSize ?? bytes.length, bytes);

/// 用给定的图标配置构造一个 IPA 归档。
Archive _ipa({
  required String iconConfig,
  Map<String, List<int>> extraEntries = const {},
}) {
  final archive = Archive()
    ..addFile(_file('Payload/MyApp.app/MyApp', List.filled(16, 0)));
  archive.addFile(_file(
    'Payload/MyApp.app/Info.plist',
    Uint8List.fromList(
      ('<?xml version="1.0"?><plist version="1.0"><dict>'
              '<key>CFBundleIdentifier</key><string>com.example.app</string>'
              '$iconConfig'
              '</dict></plist>')
          .codeUnits,
    ),
  ));
  extraEntries.forEach((name, bytes) {
    archive.addFile(_file('Payload/MyApp.app/$name', bytes));
  });
  return archive;
}

IosIconResolution _resolve(Archive archive) {
  final container = IpaContainerReader.read(archive);
  final info = IpaInfoPlistReader.read(archive, container.mainApp!);
  return IpaIconResolver.resolve(archive, info);
}

String _iconFiles(List<String> names) =>
    '<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict>'
    '<key>CFBundleIconFiles</key><array>'
    '${names.map((n) => '<string>$n</string>').join()}'
    '</array></dict></dict>';

void main() {
  group('IpaIconResolver — 基本定位', () {
    test('按 CFBundleIconFiles 找到 PNG，并读出真实尺寸', () {
      final archive = _ipa(
        iconConfig: _iconFiles(['AppIcon60x60']),
        extraEntries: {'AppIcon60x60.png': _realPng()},
      );

      final resolution = _resolve(archive);

      expect(resolution.hasPreviewableIcon, isTrue);
      final icon = resolution.best!;
      expect(icon.archivePath, 'Payload/MyApp.app/AppIcon60x60.png');
      expect(icon.format, IosImageFormat.png);
      expect(icon.isPng, isTrue);
      expect(icon.pixelWidth, 256);
      expect(icon.pixelHeight, 256);
      expect(icon.bytes, isNotNull);
      expect(resolution.unresolved, isEmpty);
    });

    test('@2x / @3x 变体都被收集，最高分辨率排在最前', () {
      final archive = _ipa(
        iconConfig: _iconFiles(['AppIcon60x60']),
        extraEntries: {
          'AppIcon60x60@2x.png': _pngHeader(120, 120),
          'AppIcon60x60@3x.png': _pngHeader(180, 180),
        },
      );

      final resolution = _resolve(archive);

      expect(resolution.candidates, hasLength(2));
      expect(resolution.best!.pixelWidth, 180, reason: '展示时优先用最高分辨率的那个');
      expect(
          resolution.candidates.map((c) => c.pixelWidth).toList(), [180, 120]);
    });

    test('声明里已带扩展名时按原样匹配，不会拼成 .png.png', () {
      final archive = _ipa(
        iconConfig: _iconFiles(['Icon.png']),
        extraEntries: {'Icon.png': _realPng()},
      );

      final resolution = _resolve(archive);

      expect(resolution.candidates, hasLength(1));
      expect(resolution.best!.archivePath, 'Payload/MyApp.app/Icon.png');
    });

    test('备用图标与 iPad 图标都被收集，且来源标注正确', () {
      final archive = _ipa(
        iconConfig: '<key>CFBundleIcons</key><dict>'
            '<key>CFBundlePrimaryIcon</key><dict>'
            '<key>CFBundleIconFiles</key><array><string>Main</string></array>'
            '</dict>'
            '<key>CFBundleAlternateIcons</key><dict>'
            '<key>Dark</key><dict><key>CFBundleIconFiles</key>'
            '<array><string>DarkIcon</string></array></dict>'
            '</dict></dict>'
            '<key>CFBundleIcons~ipad</key><dict>'
            '<key>CFBundlePrimaryIcon</key><dict>'
            '<key>CFBundleIconFiles</key><array><string>Pad</string></array>'
            '</dict></dict>',
        extraEntries: {
          'Main.png': _pngHeader(60, 60),
          'DarkIcon.png': _pngHeader(60, 60),
          'Pad.png': _pngHeader(76, 76),
        },
      );

      final resolution = _resolve(archive);
      final bySource = {
        for (final c in resolution.candidates) c.source: c.archivePath,
      };

      expect(bySource[IosIconSource.primaryIconFiles],
          'Payload/MyApp.app/Main.png');
      expect(bySource[IosIconSource.alternateIconFiles],
          'Payload/MyApp.app/DarkIcon.png');
      expect(bySource[IosIconSource.primaryIconFilesIpad],
          'Payload/MyApp.app/Pad.png');
    });

    test('旧式顶层 CFBundleIconFiles / CFBundleIconFile 也能定位', () {
      final archive = _ipa(
        iconConfig: '<key>CFBundleIconFiles</key>'
            '<array><string>Old</string></array>'
            '<key>CFBundleIconFile</key><string>Older</string>',
        extraEntries: {
          'Old.png': _pngHeader(57, 57),
          'Older.png': _pngHeader(29, 29),
        },
      );

      final resolution = _resolve(archive);
      final sources = resolution.candidates.map((c) => c.source).toSet();

      expect(sources, contains(IosIconSource.legacyIconFiles));
      expect(sources, contains(IosIconSource.legacyIconFile));
    });
  });

  group('IpaIconResolver — 不扫描目录（规范 5.3 硬约束）', () {
    test('未在配置里声明的图片绝不会成为候选', () {
      final archive = _ipa(
        iconConfig: _iconFiles(['AppIcon60x60']),
        extraEntries: {
          // 这些都在 bundle 里，但配置没点名
          'Splash.png': _realPng(),
          'LaunchImage.png': _realPng(),
          'Screenshot.png': _realPng(),
        },
      );

      final resolution = _resolve(archive);

      expect(resolution.candidates, isEmpty,
          reason: '配置点名的 AppIcon60x60 不存在，就不能拿别的图顶上');
      expect(resolution.unresolved, hasLength(1));
      expect(resolution.unresolved.single.declared, 'AppIcon60x60');
    });

    test('声明的文件不存在时给出「找不到」而不是去找替代品', () {
      final archive = _ipa(iconConfig: _iconFiles(['Missing']));

      final resolution = _resolve(archive);

      expect(resolution.candidates, isEmpty);
      expect(resolution.unresolved.single.reason, contains('Missing'));
    });
  });

  group('IpaIconResolver — Assets.car（无法直接预览）', () {
    test('只有 CFBundleIconName 且有 Assets.car → 明确说明无法直接预览', () {
      final archive = _ipa(
        iconConfig: '<key>CFBundleIcons</key><dict>'
            '<key>CFBundlePrimaryIcon</key><dict>'
            '<key>CFBundleIconName</key><string>AppIcon</string>'
            '</dict></dict>',
        extraEntries: {'Assets.car': List.filled(128, 0)},
      );

      final resolution = _resolve(archive);

      expect(resolution.candidates, isEmpty);
      expect(resolution.assetCatalogOnly, isTrue);
      expect(
          resolution.unresolved.single.source, IosIconSource.assetCatalogName);
      expect(resolution.unresolved.single.reason, contains('Assets.car'));
      // 措辞升级了：以前说「需要一个解析器」，现在真的解析一遍并说清
      // 「索引读不出来」—— `List.filled(128, 0)` 不是 BOMStore。
      expect(
          resolution.unresolved.single.reason, contains('could not be parsed'),
          reason: '读不出索引时要说清是解析失败，不能说「无法预览」了事');
      expect(resolution.assetCatalog, isNotNull);
      expect(resolution.assetCatalog!.parsed, isFalse);
      expect(resolution.unresolved.single.archivePath,
          'Payload/MyApp.app/Assets.car');
    });

    test('真实的 Assets.car 会被真的解析一遍（不再是「需要一个解析器」）', () {
      // 用 macOS 自带的真实资产目录做夹具：18 KB、4 张图。
      // 期望值来自 `assetutil --info`，详见 test/fixtures/car/README.md。
      final car =
          File('test/fixtures/car/installer-progress.car').readAsBytesSync();
      final archive = _ipa(
        iconConfig: '<key>CFBundleIcons</key><dict>'
            '<key>CFBundlePrimaryIcon</key><dict>'
            '<key>CFBundleIconName</key><string>AppIcon</string>'
            '</dict></dict>',
        extraEntries: {'Assets.car': car},
      );

      final resolution = _resolve(archive);

      // 仍然没有可预览的候选 —— 像素是 LZFSE 压缩的。
      expect(resolution.candidates, isEmpty);
      expect(resolution.assetCatalogOnly, isTrue);
      // 但容器里有什么，现在说得出来了。
      final catalog = resolution.assetCatalog;
      expect(catalog, isNotNull);
      expect(catalog!.parsed, isTrue, reason: catalog.failure);
      expect(catalog.storageVersion, 17);
      expect(catalog.images, hasLength(4));
      expect(catalog.rasterImages, hasLength(3),
          reason: 'LowBatteryFlashing.png 是空壳（739 字节装不下 30×72 像素）');
      expect(
        catalog.rasterImages
            .where((i) => i.compression == CarCompression.lzfseV2),
        hasLength(3),
      );
    });

    test('CFBundleIconName 声明了但 Assets.car 不存在 → 提示缺文件', () {
      final archive = _ipa(
        iconConfig: '<key>CFBundleIcons</key><dict>'
            '<key>CFBundlePrimaryIcon</key><dict>'
            '<key>CFBundleIconName</key><string>AppIcon</string>'
            '</dict></dict>',
      );

      final resolution = _resolve(archive);

      expect(
          resolution.unresolved.single.reason, contains('no Assets.car entry'));
      expect(resolution.unresolved.single.archivePath, isNull);
    });
  });

  group('IpaIconResolver — 大图防护（规范 5.3 硬约束）', () {
    test('超过上限的候选仍被列出，但不带字节，并给出诊断', () {
      final archive = _ipa(
        iconConfig: _iconFiles(['Huge']),
        extraEntries: {
          // 声明尺寸超过上限（内容本身很小，避免测试真的分配 5 MiB）
          'Huge.png': _pngHeader(6000, 6000),
        },
      );
      // 手动把声明尺寸抬高
      archive.findFile('Payload/MyApp.app/Huge.png')!.size =
          IpaIconResolver.maxIconBytes + 1;

      final resolution = _resolve(archive);

      expect(resolution.candidates, hasLength(1));
      expect(resolution.best!.bytes, isNull, reason: '超过上限就不带字节，避免后续解码耗尽内存');
      expect(resolution.best!.pixelWidth, 6000,
          reason: '尺寸仍从头部读出 —— 这正是「解码前就知道有多大」的意义');
      expect(
        resolution.diagnostics.any((d) => d.code == 'ios.icons.too_large'),
        isTrue,
      );
    });
  });

  group('IpaIconResolver — 没有图标配置', () {
    test('Info.plist 未声明图标时返回空结果并说明', () {
      final archive = _ipa(iconConfig: '');

      final resolution = _resolve(archive);

      expect(resolution.isEmpty, isTrue);
      expect(resolution.hasPreviewableIcon, isFalse);
      expect(resolution.assetCatalogOnly, isFalse);
      expect(resolution.diagnostics.single.code, 'ios.icons.not_configured');
    });

    test('图标配置存在但一个都没定位到时，诊断里给出计数', () {
      final archive = _ipa(iconConfig: _iconFiles(['Missing']));

      final resolution = _resolve(archive);

      expect(
        resolution.diagnostics.any((d) => d.code == 'ios.icons.resolved'),
        isTrue,
      );
      final summary = resolution.diagnostics
          .firstWhere((d) => d.code == 'ios.icons.resolved');
      expect(summary.message, contains('1 unresolved'));
    });
  });

  group('图片格式识别（按魔数，不信扩展名）', () {
    test('PNG', () {
      expect(IpaIconResolver.detectImageFormat(_realPng()), IosImageFormat.png);
    });

    test('JPEG / GIF / WebP / HEIC', () {
      expect(
        IpaIconResolver.detectImageFormat([0xFF, 0xD8, 0xFF, 0xE0]),
        IosImageFormat.jpeg,
      );
      expect(
        IpaIconResolver.detectImageFormat('GIF89a'.codeUnits),
        IosImageFormat.gif,
      );
      expect(
        IpaIconResolver.detectImageFormat([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, //
          0x57, 0x45, 0x42, 0x50,
        ]),
        IosImageFormat.webp,
      );
      expect(
        IpaIconResolver.detectImageFormat([
          0, 0, 0, 0x20, //
          ...'ftyp'.codeUnits,
          ...'heic'.codeUnits,
        ]),
        IosImageFormat.heic,
      );
    });

    test('认不出时返回 unknown，而不是猜一个', () {
      expect(IpaIconResolver.detectImageFormat([]), IosImageFormat.unknown);
      expect(IpaIconResolver.detectImageFormat([1, 2, 3, 4, 5, 6, 7, 8]),
          IosImageFormat.unknown);
    });

    test('扩展名是 .png 但内容是 JPEG 时按 JPEG 记录', () {
      final archive = _ipa(
        iconConfig: _iconFiles(['Fake']),
        extraEntries: {
          'Fake.png': [0xFF, 0xD8, 0xFF, 0xE0, 0, 0],
        },
      );

      final resolution = _resolve(archive);

      expect(resolution.best!.format, IosImageFormat.jpeg);
      expect(resolution.best!.isPng, isFalse);
      expect(resolution.best!.pixelWidth, isNull, reason: '非 PNG 不读尺寸，而不是瞎猜');
    });
  });

  group('PNG 尺寸读取', () {
    test('从 IHDR 读出宽高', () {
      expect(IpaIconResolver.readPngDimensions(_realPng()), (256, 256));
      expect(
          IpaIconResolver.readPngDimensions(_pngHeader(180, 120)), (180, 120));
    });

    test('头部不足或不是 IHDR 时返回 null', () {
      expect(IpaIconResolver.readPngDimensions([]), isNull);
      expect(IpaIconResolver.readPngDimensions(List.filled(10, 0)), isNull);
      // 签名对但第 13 个字节起不是 IHDR
      final bad = Uint8List.fromList(_realPng())..[13] = 0x58;
      expect(IpaIconResolver.readPngDimensions(bad), isNull);
    });

    test('宽或高为 0 时返回 null（畸形头部）', () {
      expect(IpaIconResolver.readPngDimensions(_pngHeader(0, 100)), isNull);
      expect(IpaIconResolver.readPngDimensions(_pngHeader(100, 0)), isNull);
    });
  });
}
