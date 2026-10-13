import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';

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
  int get pixelArea =>
      (pixelWidth == null || pixelHeight == null)
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
  });

  bool get hasPreviewableIcon => candidates.isNotEmpty;

  IosIconCandidate? get best => candidates.isEmpty ? null : candidates.first;

  /// 是否完全没有图标信息（既没有候选，也没有未解析声明）。
  bool get isEmpty => candidates.isEmpty && unresolved.isEmpty;

  /// 是否只有 `Assets.car` 形式的图标（无法直接预览）。
  bool get assetCatalogOnly =>
      candidates.isEmpty &&
      unresolved.any((u) => u.source == IosIconSource.assetCatalogName);
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
  /// `@2x` / `@3x` 约定命名。这里按该约定逐个尝试，不做目录扫描。
  static const List<String> _suffixes = ['', '.png', '@2x.png', '@3x.png'];

  static IosIconResolution resolve(Archive archive, IpaInfoPlist info) {
    final diagnostics = <AnalysisDiagnostic>[];
    final candidates = <IosIconCandidate>[];
    final unresolved = <IosUnresolvedIcon>[];
    final seenPaths = <String>{};

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
          final candidate = _buildCandidate(archive, source, path, diagnostics);
          if (candidate != null) candidates.add(candidate);
        }
      }
    }

    final primary = icons.primary;
    if (primary != null) {
      collect(IosIconSource.primaryIconFiles, primary.iconFiles);
      if (primary.iconName != null) {
        _noteAssetCatalog(
            info, primary.iconName!, IosIconSource.assetCatalogName, archive,
            unresolved, diagnostics);
      }
    }

    for (final entry in icons.alternate.entries) {
      collect(IosIconSource.alternateIconFiles, entry.value.iconFiles);
    }

    final ipad = icons.primaryIpad;
    if (ipad != null) {
      collect(IosIconSource.primaryIconFilesIpad, ipad.iconFiles);
      if (ipad.iconName != null) {
        _noteAssetCatalog(info, ipad.iconName!,
            IosIconSource.assetCatalogName, archive, unresolved, diagnostics);
      }
    }

    collect(IosIconSource.legacyIconFiles, icons.legacyIconFiles);
    if (icons.legacyIconFile != null) {
      collect(IosIconSource.legacyIconFile, [icons.legacyIconFile!]);
    }

    // 最高分辨率排在最前 —— 展示时优先用它。
    candidates.sort((a, b) => b.pixelArea.compareTo(a.pixelArea));

    diagnostics.add(AnalysisDiagnostic.info(
      'ios.icons.resolved',
      '${candidates.length} previewable icon(s), '
          '${unresolved.length} unresolved',
      source: FieldSource.infoPlist,
    ));

    return IosIconResolution(
      candidates: candidates,
      unresolved: unresolved,
      diagnostics: diagnostics,
    );
  }

  /// 按平台命名约定找出候选条目名。
  static List<String> _resolveName(
      Archive archive, String bundleRoot, String name) {
    // 已经带扩展名时先按原样试，避免拼出 `Icon.png.png`。
    final hasExtension = name.contains('.') &&
        !name.endsWith('@2x') &&
        !name.endsWith('@3x');

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
    String archivePath,
    List<AnalysisDiagnostic> diagnostics,
  ) {
    final entry = archive.findFile(archivePath);
    if (entry == null) return null;

    final content = entry.content;
    final format = detectImageFormat(content);

    int? width;
    int? height;
    if (format == IosImageFormat.png) {
      final dimensions = readPngDimensions(content);
      width = dimensions?.$1;
      height = dimensions?.$2;
    }

    Uint8List? bytes;
    if (entry.size <= maxIconBytes && content.length <= maxIconBytes) {
      bytes = content;
    } else {
      diagnostics.add(AnalysisDiagnostic.warning(
        'ios.icons.too_large',
        '$archivePath is ${content.length} bytes, above the $maxIconBytes byte '
        'limit; not carrying its bytes so it is never decoded',
        source: FieldSource.infoPlist,
      ));
    }

    return IosIconCandidate(
      source: source,
      relativePath: archivePath,
      archivePath: archivePath,
      size: entry.size,
      format: format,
      pixelWidth: width,
      pixelHeight: height,
      bytes: bytes,
    );
  }

  /// 记录一个「图标在 Assets.car 里」的声明。
  ///
  /// 不去 `Assets.car` 里找替代品：那个容器是编译过的资源目录，需要专门的
  /// 解析器；随便挑一张别的图代替正是规范禁止的行为。
  static void _noteAssetCatalog(
    IpaInfoPlist info,
    String iconName,
    IosIconSource source,
    Archive archive,
    List<IosUnresolvedIcon> unresolved,
    List<AnalysisDiagnostic> diagnostics,
  ) {
    final carPath = '${info.bundle.path}/Assets.car';
    final carPresent = archive.findFile(carPath) != null;

    unresolved.add(IosUnresolvedIcon(
      source: source,
      declared: 'CFBundleIconName=$iconName',
      reason: carPresent
          ? 'the icon lives inside Assets.car, which needs an asset-catalog '
              'parser; it cannot be previewed directly'
          : 'CFBundleIconName is set but no Assets.car entry was found',
      archivePath: carPresent ? carPath : null,
    ));

    diagnostics.add(AnalysisDiagnostic.info(
      'ios.icons.asset_catalog',
      carPresent
          ? 'CFBundleIconName=$iconName resolves into Assets.car '
              '(not directly previewable)'
          : 'CFBundleIconName=$iconName is set but $carPath is missing',
      source: FieldSource.infoPlist,
    ));
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
  /// 布局：8 字节签名 + 4 字节块长度 + `IHDR` + 宽(4) + 高(4)。
  /// **只读头部，不解码像素** —— 这正是规范 5.3 想要的：知道图有多大，
  /// 而不必先把整张图解出来。
  static (int, int)? readPngDimensions(List<int> bytes) {
    if (bytes.length < 24) return null;
    if (bytes[12] != 0x49 || // I
        bytes[13] != 0x48 || // H
        bytes[14] != 0x44 || // D
        bytes[15] != 0x52) {
      return null;
    }
    final width = _readUint32(bytes, 16);
    final height = _readUint32(bytes, 20);
    if (width <= 0 || height <= 0) return null;
    return (width, height);
  }

  static int _readUint32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}
