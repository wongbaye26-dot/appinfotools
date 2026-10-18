import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';

import 'assets_car.dart';
import 'cgbi_png.dart';
import 'ipa_info_plist.dart';

/// 图片格式，由**魔数**判定。
///
/// 不信扩展名：容器里的文件可以叫 `AppIcon60x60@2x.png` 而内容完全是别的东西。
/// 规范 5.3 要求「支持识别常见 PNG 图标」，识别的是内容，不是名字。
enum IosImageFormat {
  png,
  jpeg,
  gif,
  webp,
  heic,
  unknown;

  String get displayName => switch (this) {
        IosImageFormat.png => 'PNG',
        IosImageFormat.jpeg => 'JPEG',
        IosImageFormat.gif => 'GIF',
        IosImageFormat.webp => 'WebP',
        IosImageFormat.heic => 'HEIC',
        IosImageFormat.unknown => 'unknown',
      };
}

/// 图标候选的来源。
enum IosIconSource {
  /// `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles`。
  primaryIconFiles,

  /// `CFBundleIcons.CFBundleAlternateIcons.<name>`。
  alternateIconFiles,

  /// `CFBundleIcons~ipad.CFBundlePrimaryIcon.CFBundleIconFiles`。
  primaryIconFilesIpad,

  /// 旧式顶层 `CFBundleIconFiles`。
  legacyIconFiles,

  /// 更旧的顶层 `CFBundleIconFile`。
  legacyIconFile,

  /// `CFBundleIconName`（iOS 11+，指向 `Assets.car` 内的资源）。
  assetCatalogName,
}

/// 一个可直接使用的图标候选。
class IosIconCandidate {
  final IosIconSource source;

  /// 相对 bundle 根目录的路径。
  final String relativePath;

  /// 归档内的完整条目名。
  final String archivePath;

  /// 声明的解压后字节数。
  final int size;

  /// 由魔数判定的格式。
  final IosImageFormat format;

  /// 像素宽度。仅 PNG（从 IHDR 读）与部分格式可确定，否则为 `null`。
  final int? pixelWidth;

  final int? pixelHeight;

  /// 图片字节。超过大小上限时为 `null`（此时会有一条诊断说明）。
  final Uint8List? bytes;

  const IosIconCandidate({
    required this.source,
    required this.relativePath,
    required this.archivePath,
    required this.size,
    required this.format,
    this.pixelWidth,
    this.pixelHeight,
    this.bytes,
  });

  /// 像素面积，用于排序；未知尺寸时为 -1。
  int get pixelArea => (pixelWidth == null || pixelHeight == null)
      ? -1
      : pixelWidth! * pixelHeight!;

  /// 是否是「常见 PNG 图标」。
  bool get isPng => format == IosImageFormat.png;

  @override
  String toString() => 'IosIconCandidate($archivePath, ${format.displayName}, '
      '${pixelWidth ?? '?'}x${pixelHeight ?? '?'}, $size B)';
}

/// 配置里声明了、但当前**无法直接取出**的图标资源。
///
/// 规范 5.3 要求「对无法直接预览的资源给出明确提示」—— 这就是那个提示的载体。
/// 关键是不能因为取不到就去别处随便找一张图代替。
class IosUnresolvedIcon {
  final IosIconSource source;

  /// 配置里声明的内容。
  final String declared;

  /// 为什么取不到（面向人的说明）。
  final String reason;

  /// 相关条目名（若存在）。
  final String? archivePath;

  const IosUnresolvedIcon({
    required this.source,
    required this.declared,
    required this.reason,
    this.archivePath,
  });

  @override
  String toString() => 'IosUnresolvedIcon(${source.name}, $declared): $reason';
}

/// 图标解析结果。
class IosIconResolution {
  /// 可预览的候选，按像素面积**从大到小**排序（[best] 即最高分辨率的一个）。
  final List<IosIconCandidate> candidates;

  /// 声明了但取不到的图标资源。
  final List<IosUnresolvedIcon> unresolved;

  final List<AnalysisDiagnostic> diagnostics;

  const IosIconResolution({
    this.candidates = const [],
    this.unresolved = const [],
    this.diagnostics = const [],
    this.assetCatalog,
  });

  bool get hasPreviewableIcon => candidates.isNotEmpty;

  IosIconCandidate? get best => candidates.isEmpty ? null : candidates.first;

  /// 是否完全没有图标信息（既没有候选，也没有未解析声明）。
  bool get isEmpty => candidates.isEmpty && unresolved.isEmpty;

  /// 是否只有 `Assets.car` 形式的图标（无法直接预览）。
  bool get assetCatalogOnly =>
      candidates.isEmpty &&
      unresolved.any((u) => u.source == IosIconSource.assetCatalogName);

  /// `Assets.car` 的**索引**（解析成功时非空）。
  ///
  /// 里面有每张 rendition 的名字、宽高、像素格式、压缩方式与字节数 —— 足以
  /// 回答「这个应用的图标是什么尺寸」，但**不含像素**：数据是 LZFSE 压缩的，
  /// 本实现不解码（见 `docs/notes/assets-car.md`）。
  ///
  /// 为 `null` 表示没有 `Assets.car`，或者它读不出来 / 解析失败。
  final AssetsCarCatalog? assetCatalog;
}

/// 按 `Info.plist` 的图标配置在 bundle 内定位图标资源。
///
/// **只查配置里点名的文件**，绝不做「在 bundle 里找最大的 PNG」这类扫描 ——
/// 规范 5.3 明确要求不得把启动画面、截图或其他图片当作应用图标。
class IpaIconResolver {
  IpaIconResolver._();

  /// 单个图标的字节上限（4 MiB）。
  ///
  /// 规范 5.3 要求「避免大图解码导致内存耗尽」，因此上限必须在**解码之前**
  /// 检查。超过上限的候选仍会被列出（让用户知道它存在），但不带字节。
  static const int maxIconBytes = 4 * 1024 * 1024;

  /// `CFBundleIconFiles` 里给的是**不含扩展名**的基础名，实际文件按平台的
  /// 命名约定加上倍率与设备修饰符。这里按该约定逐个尝试，不做目录扫描。
  ///
  /// 顺序有意义：不带修饰符的排在前面，设备专属的排在后面 —— 同名时优先
  /// 通用那张。
  ///
  /// `~ipad` / `~iphone` 这一档不能漏：实测真实样本的
  /// `CFBundleIcons~ipad` 声明的是 `AppIcon76x76`，而文件叫
  /// `AppIcon76x76@2x~ipad.png`，只试 `@2x.png` / `@3x.png` 会找不到。
  static const List<String> _suffixes = [
    '',
    '.png',
    '@2x.png',
    '@3x.png',
    '~ipad.png',
    '@2x~ipad.png',
    '@3x~ipad.png',
    '~iphone.png',
    '@2x~iphone.png',
    '@3x~iphone.png',
  ];

  /// [ledger] 见 `IpaInfoPlistReader.read`：真实解析路径传同一个账本。
  static IosIconResolution resolve(
    Archive archive,
    IpaInfoPlist info, {
    BoundedReadLedger? ledger,
  }) {
    final budget = ledger ?? BoundedReadLedger.session();
    final diagnostics = <AnalysisDiagnostic>[];
    final candidates = <IosIconCandidate>[];
    final unresolved = <IosUnresolvedIcon>[];
    final seenPaths = <String>{};
    AssetsCarCatalog? assetCatalog;

    final icons = info.icons.value;
    if (icons == null) {
      diagnostics.add(const AnalysisDiagnostic.info(
        'ios.icons.not_configured',
        'Info.plist declares no icon configuration',
        source: FieldSource.infoPlist,
      ));
      return IosIconResolution(diagnostics: diagnostics);
    }

    void collect(IosIconSource source, List<String> names) {
      for (final name in names) {
        final matched = _resolveName(archive, info.bundle.path, name);
        if (matched.isEmpty) {
          unresolved.add(IosUnresolvedIcon(
            source: source,
            declared: name,
            reason: 'no entry matches "$name" under ${info.bundle.path}',
          ));
          continue;
        }
        for (final path in matched) {
          if (!seenPaths.add(path)) continue;
          final candidate = _buildCandidate(
              archive, source, info.bundle.path, path, diagnostics, budget);
          if (candidate != null) candidates.add(candidate);
        }
      }
    }

    final primary = icons.primary;
    if (primary != null) {
      collect(IosIconSource.primaryIconFiles, primary.iconFiles);
      if (primary.iconName != null) {
        assetCatalog ??= _noteAssetCatalog(
            info,
            primary.iconName!,
            IosIconSource.assetCatalogName,
            archive,
            budget,
            unresolved,
            diagnostics);
      }
    }

    for (final entry in icons.alternate.entries) {
      collect(IosIconSource.alternateIconFiles, entry.value.iconFiles);
    }

    final ipad = icons.primaryIpad;
    if (ipad != null) {
      collect(IosIconSource.primaryIconFilesIpad, ipad.iconFiles);
      if (ipad.iconName != null) {
        assetCatalog ??= _noteAssetCatalog(
            info,
            ipad.iconName!,
            IosIconSource.assetCatalogName,
            archive,
            budget,
            unresolved,
            diagnostics);
      }
    }

    collect(IosIconSource.legacyIconFiles, icons.legacyIconFiles);
    if (icons.legacyIconFile != null) {
      collect(IosIconSource.legacyIconFile, [icons.legacyIconFile!]);
    }

    // 最高分辨率排在最前 —— 展示时优先用它。
    candidates.sort((a, b) => b.pixelArea.compareTo(a.pixelArea));

    // 同一份声明会被多个入口各报一次：实测 `CFBundleIconName=AppIcon` 同时
    // 出现在 `CFBundleIcons` 与 `CFBundleIcons~ipad` 里，于是「取不到」清单
    // 里出现了两条一模一样的记录。用户要看到的是「有几条取不到」，
    // 不是「我们报了几次」。
    final uniqueUnresolved = <IosUnresolvedIcon>[];
    final seenUnresolved = <(IosIconSource, String)>{};
    for (final item in unresolved) {
      if (seenUnresolved.add((item.source, item.declared))) {
        uniqueUnresolved.add(item);
      }
    }

    diagnostics.add(AnalysisDiagnostic.info(
      'ios.icons.resolved',
      '${candidates.length} previewable icon(s), '
          '${uniqueUnresolved.length} unresolved',
      source: FieldSource.infoPlist,
    ));

    return IosIconResolution(
      candidates: candidates,
      unresolved: uniqueUnresolved,
      diagnostics: diagnostics,
      assetCatalog: assetCatalog,
    );
  }

  /// 按平台命名约定找出候选条目名。
  static List<String> _resolveName(
      Archive archive, String bundleRoot, String name) {
    // 已经带扩展名时先按原样试，避免拼出 `Icon.png.png`。
    final hasExtension =
        name.contains('.') && !name.endsWith('@2x') && !name.endsWith('@3x');

    final matched = <String>[];
    for (final suffix in _suffixes) {
      if (hasExtension && suffix != '') continue;
      final path = '$bundleRoot/$name$suffix';
      if (archive.findFile(path) != null) matched.add(path);
    }
    return matched;
  }

  static IosIconCandidate? _buildCandidate(
    Archive archive,
    IosIconSource source,
    String bundleRoot,
    String archivePath,
    List<AnalysisDiagnostic> diagnostics,
    BoundedReadLedger ledger,
  ) {
    final entry = archive.findFile(archivePath);
    if (entry == null) return null;

    // **有界读取**（V2.4.12）：图标是「一定要看，但不必整条带走」的典型 ——
    // 格式与像素尺寸都在头几十字节里。所以先按上限整读，超限就退回只读前缀，
    // 绝不为了识别格式而把一条几百 MB 的条目解压进内存。
    final read = readEntryBounded(
      entry,
      maxEntryBytes: maxIconBytes,
      ledger: ledger,
    );

    Uint8List content;
    Uint8List? bytes;
    if (read.isOk) {
      content = read.bytes!;
      bytes = content;
    } else {
      final prefix = readEntryPrefix(entry, maxBytes: 64, ledger: ledger);
      content = prefix.bytes ?? Uint8List(0);
      final failure = read.failure!;
      diagnostics.add(AnalysisDiagnostic.warning(
        failure.stage == BoundedReadStage.corrupt
            ? 'ios.icons.unreadable'
            : 'ios.icons.too_large',
        '$archivePath could not be read within the $maxIconBytes byte limit '
        '(${failure.describe()}); not carrying its bytes so it is never '
        'decoded',
        source: FieldSource.infoPlist,
      ));
    }

    final format = detectImageFormat(content);

    int? width;
    int? height;
    if (format == IosImageFormat.png) {
      final dimensions = readPngDimensions(content);
      width = dimensions?.$1;
      height = dimensions?.$2;
    }

    return IosIconCandidate(
      source: source,
      relativePath: _relativeTo(bundleRoot, archivePath),
      archivePath: archivePath,
      size: entry.size,
      format: format,
      pixelWidth: width,
      pixelHeight: height,
      bytes: bytes,
    );
  }

  /// 去掉 bundle 根前缀，得到相对路径。
  ///
  /// 保留这个区分是有用的：用户看到的「图标文件名」应当是
  /// `Icon@2x.png`，而排查时要用的归档条目名是
  /// `Payload/Example.app/Icon@2x.png`。两者曾经被填成同一个值，
  /// 于是字段名与内容对不上。
  static String _relativeTo(String bundleRoot, String archivePath) {
    final prefix = '$bundleRoot/';
    if (archivePath.startsWith(prefix)) {
      return archivePath.substring(prefix.length);
    }
    return archivePath;
  }

  /// 记录一个「图标在 Assets.car 里」的声明，并**真的读一遍那个容器**。
  ///
  /// 仍然不挑替代品：`Assets.car` 里的像素是 LZFSE 压缩的，取不出来就是
  /// 取不出来。但「容器里到底有什么」是可以回答的 —— 图数、尺寸、像素格式、
  /// 压缩方式。这比「需要一个解析器」有用得多。
  ///
  /// 返回解析出的索引（读不出 / 解析失败时为 `null`）。
  static AssetsCarCatalog? _noteAssetCatalog(
    IpaInfoPlist info,
    String iconName,
    IosIconSource source,
    Archive archive,
    BoundedReadLedger budget,
    List<IosUnresolvedIcon> unresolved,
    List<AnalysisDiagnostic> diagnostics,
  ) {
    final carPath = '${info.bundle.path}/Assets.car';
    final carFile = archive.findFile(carPath);
    if (carFile == null) {
      unresolved.add(IosUnresolvedIcon(
        source: source,
        declared: 'CFBundleIconName=$iconName',
        reason: 'CFBundleIconName is set but no Assets.car entry was found',
      ));
      diagnostics.add(AnalysisDiagnostic.info(
        'ios.icons.asset_catalog',
        'CFBundleIconName=$iconName is set but $carPath is missing',
        source: FieldSource.infoPlist,
      ));
      return null;
    }

    final read = ZipBudget.readEntry(carFile, ledger: budget);
    final catalog = read.isOk ? parseAssetsCar(read.bytes!) : null;

    unresolved.add(IosUnresolvedIcon(
      source: source,
      declared: 'CFBundleIconName=$iconName',
      reason: _describeAssetCatalog(
          catalog,
          iconName,
          read.isOk
              ? null
              : 'the entry could not be read: ${read.failure?.describe()}'),
      archivePath: carPath,
    ));

    diagnostics.add(AnalysisDiagnostic.info(
      'ios.icons.asset_catalog',
      catalog?.parsed == true
          ? 'CFBundleIconName=$iconName resolves into Assets.car '
              '(${catalog!.images.length} rendition(s), '
              '${catalog.rasterImages.length} with pixels; the pixel data is '
              'LZFSE-compressed and is not decoded)'
          : 'CFBundleIconName=$iconName resolves into Assets.car but its '
              'index could not be read (${catalog?.failure ?? 'read failed'})',
      source: FieldSource.infoPlist,
    ));
    return catalog;
  }

  /// 把 `Assets.car` 的索引说成一句话。
  ///
  /// 三种情况必须分开说，否则读者分不清「没有图」与「我们没读到」：
  /// 解析成功、解析失败、容器读不出来。
  static String _describeAssetCatalog(
    AssetsCarCatalog? catalog,
    String iconName,
    String? readFailure,
  ) {
    if (readFailure != null) {
      return 'the icon lives inside Assets.car, which could not be read '
          '($readFailure)';
    }
    if (catalog == null || !catalog.parsed) {
      return 'the icon lives inside Assets.car, whose index could not be '
          'parsed (${catalog?.failure ?? 'unknown reason'})';
    }
    final icons = catalog.appIconCandidates;
    final withPixels = catalog.rasterImages;
    if (icons.isNotEmpty) {
      final largest = icons.first;
      return 'the icon lives inside Assets.car: ${icons.length} rendition(s) '
          'named like AppIcon, largest ${largest.width}x${largest.height} '
          '(${largest.pixelFormat ?? '?'}, ${largest.sizeOnDisk} bytes). The '
          'pixel data is LZFSE-compressed, so it cannot be previewed without '
          'a decoder';
    }
    // 无论能不能点出哪一张，像素都是 LZFSE 压缩的 —— 「为什么预览不了」的
    // 答案始终包含这一句，不能因为分支不同就说漏。
    if (withPixels.isNotEmpty) {
      return 'the icon lives inside Assets.car: ${withPixels.length} image(s) '
          'with pixel data, but none is named like AppIcon, so the asset for '
          'CFBundleIconName=$iconName cannot be identified without parsing '
          'the RENDITIONS index. The pixel data is LZFSE-compressed in any '
          'case, so it could not be previewed without a decoder either';
    }
    return 'the icon lives inside Assets.car: ${catalog.images.length} '
        'rendition(s) found but none carries pixel data '
        '(CFBundleIconName=$iconName)';
  }

  /// 由魔数判定图片格式。
  static IosImageFormat detectImageFormat(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return IosImageFormat.png;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return IosImageFormat.jpeg;
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return IosImageFormat.gif;
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && // R
        bytes[1] == 0x49 && // I
        bytes[2] == 0x46 && // F
        bytes[3] == 0x46 && // F
        bytes[8] == 0x57 && // W
        bytes[9] == 0x45 && // E
        bytes[10] == 0x42 && // B
        bytes[11] == 0x50) {
      return IosImageFormat.webp;
    }
    // ISO-BMFF：偏移 4 起是 `ftyp`，品牌里含 heic/heix/mif1。
    if (bytes.length >= 12 &&
        bytes[4] == 0x66 && // f
        bytes[5] == 0x74 && // t
        bytes[6] == 0x79 && // y
        bytes[7] == 0x70) {
      final brand = String.fromCharCodes(bytes.sublist(8, 12));
      if (brand.startsWith('hei') || brand == 'mif1' || brand == 'msf1') {
        return IosImageFormat.heic;
      }
    }
    return IosImageFormat.unknown;
  }

  /// 从 PNG 的 IHDR 读出像素尺寸。
  ///
  /// 走块链定位 `IHDR`，**不写死偏移 12**：CgBI（Apple 的 PNG 变体）在签名与
  /// `IHDR` 之间还有一个 `CgBI` 块，写死偏移会让尺寸读成 `null` —— 而尺寸是
  /// 「按面积排序」和「解码前的像素预算检查」的前提。
  ///
  /// **只读头部，不解码像素** —— 这正是规范 5.3 想要的：知道图有多大，
  /// 而不必先把整张图解出来。
  static (int, int)? readPngDimensions(List<int> bytes) {
    final size = readPngSize(bytes);
    if (size == null) return null;
    if (size.$1 <= 0 || size.$2 <= 0) return null;
    return size;
  }
}
