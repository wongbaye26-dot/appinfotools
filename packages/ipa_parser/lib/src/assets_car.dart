// `Assets.car` 的**索引**解析（不解码图像）。
//
// ## 边界：这份实现只回答「包里有哪些图」
//
// Apple 的 `Assets.car` 把图像存成 `ISTC` 块，像素数据是 **BGRA 等原始格式
// 再经 LZFSE 压缩**的。实测 Chess.app 1024×1024 的图标：未压缩 4,194,304
// 字节，`SizeOnDisk` 只有 311,137（13.5:1），块内魔数是 `bvx2`。
//
// Dart 侧没有 LZFSE 实现，**所以这里不提取像素**，只给出元数据：
// 名字、宽高、像素格式、压缩方式、块字节数。要真正取出图还需要一个
// LZFSE 解码器（约 500–700 行）与 PNG 编码器 —— 那是独立的一件事。
//
// ## 为什么不用 RENDITIONS 块
//
// 直觉上应该读 `RENDITIONS`（资产名 → rendition 的映射）。但它是一个
// **CPI key 数组**，`csi_key` 的字段布局随 `StorageVersion` 变化，而且没有
// 任何公开文档 —— 靠猜字段偏移做出来的是「看起来对」的东西。
//
// `ISTC` 块**自己就带全部需要的元数据**（宽高、像素格式、rendition 名），
// 且每一项都能用 `assetutil --info` 的外部输出逐条核对。所以走这条路。
//
// 代价：**拿不到「资产名」**（`AppIcon` / `AppIcon_Assets/...`）。但
// iOS 的 rendition 名本身就是 `AppIcon60x60@2x.png` 这种形态，对「找图标」
// 这个用途够用。
//
// ## 格式（实测确认，见 `docs/notes/assets-car.md`）
//
// ```
// BOMStore 头（大端）
//   0x00 magic[8] "BOMStore"
//   0x08 u32 version = 1
//   0x0C u32 blockCount
//   0x10 u32 indexOffset
//   0x14 u32 indexLength
//   0x18 u32 varsOffset
//   0x1C u32 varsLength
//
// 块表（**大端**）：indexOffset + 4 起，每 8 字节 { u32 address, u32 length }
//   注意：indexOffset + 0 处那个 u32（实测 256）**不是**条目数 ——
//   条目数用头里的 blockCount。按 `count + count×8` 读会走进死路。
//
// ISTC 块（**小端**）
//   0x00 magic[4] "ISTC"
//   0x04 u32 version
//   0x08 u32 flags
//   0x0C u32 width
//   0x10 u32 height
//   0x14 u32 ——
//   0x18 u32 pixelFormat（4CC 按小端存，**读出来是反序的**：
//        `BGRA` 实际是 "ARGB"，与 assetutil 的 Encoding 一致）
//   0x1C u32 ——
//   0x20 u32 ——
//   0x28 rendition 名（NUL 结尾；长度字段的位置随 flags 变，不可靠）
// ```
//
// 端序混用是实测结果，不是笔误：BOM 头与块表是大端，ISTC 头是小端。

import 'dart:typed_data';

/// 图像数据的压缩方式。
///
/// 依据 `ISTC` 块内的 LZFSE 块魔数：
/// `bvx2` = v2、`bvxn` = v1、`bvx-` = 未压缩、`bvx1` = v1。
enum CarCompression {
  /// 块内没有找到 LZFSE 魔数 —— 像素可能是原样存储的。
  none('none', 'not compressed'),

  /// `bvx2`：LZFSE v2，现代工具链默认。
  lzfseV2('lzfse-v2', 'LZFSE (v2)'),

  /// `bvxn`：LZFSE v1。
  lzfseV1('lzfse-v1', 'LZFSE (v1)'),

  /// `bvx1`：LZFSE v1 的另一种标记。
  lzfseV1Alt('lzfse-v1-alt', 'LZFSE (v1, alt magic)'),

  /// `bvx-`：LZFSE 的「未压缩块」封装。
  lzfseUncompressed('lzfse-raw', 'LZFSE container, block uncompressed'),

  /// 找到了 `bvx` 开头但后缀不认识的块。
  unknown('unknown', 'unknown compression');

  const CarCompression(this.id, this.label);

  final String id;
  final String label;

  bool get isCompressed =>
      this != CarCompression.none && this != CarCompression.lzfseUncompressed;
}

/// `Assets.car` 里的一张图（**元数据，不含像素**）。
class AssetsCarImage {
  /// rendition 名，例如 `AppIcon60x60@2x.png`、`image.svg`。
  final String renditionName;

  /// 像素宽高；非图像块（Color / Data）为 `null`。
  final int? width;
  final int? height;

  /// 像素格式，**已转成可读的 4CC**（`ARGB` / `BGRA` / `GVS ` / `GA8 ` …）。
  final String? pixelFormat;

  final CarCompression compression;

  /// 块在文件里的字节数（= 压缩后大小，与 `assetutil` 的 `SizeOnDisk` 相同）。
  final int sizeOnDisk;

  /// 块在文件中的偏移（排查用）。
  final int blockOffset;

  const AssetsCarImage({
    required this.renditionName,
    this.width,
    this.height,
    this.pixelFormat,
    this.compression = CarCompression.none,
    required this.sizeOnDisk,
    required this.blockOffset,
  });

  /// 是不是一张真的**像素**图。
  ///
  /// 光有宽高不够：`GVS `（SVG）、`PDF `、`SVG ` 这些矢量 rendition 也带
  /// 宽高（实测 Music.app 的 `concert.tickets.fill.svg` 是 27×23）。
  /// 把它们算进「位图」会让调用方以为能拿到像素。
  bool get isRasterImage => (width ?? 0) > 0 && (height ?? 0) > 0 && !isVector;

  /// 是不是矢量 rendition（SVG / PDF）—— 有尺寸但没有像素。
  ///
  /// `GVS `（SVG）、`PDF `、`SVG ` 这些也带宽高（实测 Music.app 的
  /// `concert.tickets.fill.svg` 是 27×23）。把它们算进位图会让调用方以为
  /// 能拿到像素。
  bool get isVector {
    final format = pixelFormat;
    if (format == null) return false;
    return format.startsWith('GVS') ||
        format.startsWith('SVG') ||
        format.startsWith('PDF');
  }

  /// 这个块里**是否真的内嵌了像素数据**。
  ///
  /// 实测有一类「空壳」rendition：宽高齐全、`compression == none`，但块只有
  /// 334 字节且内容全是 0（`SizeOnDisk: 334` 在 `assetutil --info` 里出现过
  /// 成千上万次）。它们是引用/占位，**没有像素**。
  ///
  /// 判据：压缩过 → 有；未压缩 → 块至少要装得下 1 字节/像素。
  bool get embedsPixels {
    if (!isRasterImage) return false;
    if (compression.isCompressed) return true;
    if (compression == CarCompression.lzfseUncompressed) return true;
    final w = width ?? 0;
    final h = height ?? 0;
    return sizeOnDisk >= w * h;
  }

  /// 名字看起来像应用图标。
  ///
  /// 只做**字符串判断**，不推断「这就是 AppIcon」—— 真正的资产名在
  /// `RENDITIONS` 里，本实现没有解析它。
  bool get looksLikeAppIcon {
    final lower = renditionName.toLowerCase();
    if (!lower.contains('appicon')) return false;
    // `AppIcon` / `AppIcon60x60@2x` / `AppIcon76x76~ipad` 都算；
    // 但 `AppIcon_Assets/Color-1` 这种是**图标内部图层**，不是图标本身。
    return !lower.contains('/');
  }

  @override
  String toString() => 'AssetsCarImage($renditionName, '
      '${width}x$height, $pixelFormat, ${compression.id}, $sizeOnDisk bytes)';
}

/// 解析结果。
class AssetsCarCatalog {
  /// `CARHEADER` 里的 `StorageVersion`（实测 17）；读不到为 `null`。
  final int? storageVersion;

  /// `CARHEADER` 里的 `CoreUIVersion`（实测 1011）。
  final int? coreUiVersion;

  /// 块总数。
  final int blockCount;

  /// 解析出来的图（含非图像块之外的 ISTC 块）。
  final List<AssetsCarImage> images;

  /// 读不出原因；`null` 表示读成功。
  final String? failure;

  const AssetsCarCatalog({
    this.storageVersion,
    this.coreUiVersion,
    this.blockCount = 0,
    this.images = const [],
    this.failure,
  });

  const AssetsCarCatalog.unreadable(String reason)
      : storageVersion = null,
        coreUiVersion = null,
        blockCount = 0,
        images = const [],
        failure = reason;

  bool get parsed => failure == null;

  /// 有像素的**位图**。
  ///
  /// 排除三类：Color / Data（无宽高）、矢量（`GVS `/`PDF `）、空壳
  /// （`compression == none` 且块装不下像素）。
  List<AssetsCarImage> get rasterImages => [
        for (final image in images)
          if (image.embedsPixels) image
      ];

  /// 有宽高的图（含矢量与空壳）—— 排查用。
  List<AssetsCarImage> get sizedImages => [
        for (final image in images)
          if (image.isRasterImage) image
      ];

  /// 空壳：有宽高但没有像素数据。
  List<AssetsCarImage> get placeholderOnly => [
        for (final image in images)
          if (image.isRasterImage && !image.embedsPixels) image
      ];

  /// 名字像应用图标的那些。
  List<AssetsCarImage> get appIconCandidates => [
        for (final image in rasterImages)
          if (image.looksLikeAppIcon) image
      ];

  /// 图像数据的压缩方式分布。
  Map<CarCompression, int> get compressionHistogram {
    final result = <CarCompression, int>{};
    for (final image in rasterImages) {
      result[image.compression] = (result[image.compression] ?? 0) + 1;
    }
    return result;
  }

  @override
  String toString() => 'AssetsCarCatalog(storage: $storageVersion, '
      'blocks: $blockCount, images: ${images.length}, '
      'raster: ${rasterImages.length}, failure: $failure)';
}

/// 块表条目数上限。
///
/// 不可信的 `blockCount` 不能决定循环次数：19,393 个块是实测最大值
/// （Music.app），给到 100 万已经远超任何真实资产目录。
const int maxBlockCount = 1000000;

/// 单个块的长度上限（256 MiB）。
///
/// 最大实测块是 Music.app 里的几张 2x 图，几十 MB 量级。上限只用来拦住
/// 伪造的长度，不参与内存分配 —— 本实现只读块头几十字节。
const int maxBlockBytes = 256 * 1024 * 1024;

/// rendition 名的最大读取长度。
///
/// 长度字段不可靠（见文件头），所以读到 NUL 为止并设上限。
const int maxRenditionNameBytes = 256;

/// `ISTC` 头的固定长度：`0x28` 之前的字段 + 名字起点。
const int _istcNameOffset = 0x28;

/// 解析 `Assets.car` 的索引。
///
/// [bytes] 是该文件的完整字节。读不出来时返回 `failure` 非空的结果。
AssetsCarCatalog parseAssetsCar(Uint8List bytes) {
  if (bytes.length < 0x20) {
    return AssetsCarCatalog.unreadable(
        'file is only ${bytes.length} bytes, too small for a BOMStore header');
  }
  if (!_startsWith(bytes, 0, 'BOMStore')) {
    return const AssetsCarCatalog.unreadable(
        'not a BOMStore file (magic is not "BOMStore")');
  }
  final header = ByteData.sublistView(bytes);
  final blockCount = header.getUint32(0x0C, Endian.big);
  final indexOffset = header.getUint32(0x10, Endian.big);
  final indexLength = header.getUint32(0x14, Endian.big);

  if (blockCount > maxBlockCount) {
    return AssetsCarCatalog.unreadable(
        'block count $blockCount is beyond the $maxBlockCount cap');
  }
  // 块表 = indexOffset + 4 + blockCount × 8。
  final tableStart = indexOffset + 4;
  final tableEnd = tableStart + blockCount * 8;
  if (indexOffset < 0x20 ||
      indexLength == 0 ||
      tableEnd > bytes.length ||
      tableStart >= tableEnd) {
    return AssetsCarCatalog.unreadable(
        'block table is out of range (offset $indexOffset, '
        '$blockCount entries ending at $tableEnd, file ${bytes.length})');
  }

  // CARHEADER 的版本信息：块表里第二个块（实测索引 1）是 `RATC`。
  // 不依赖索引号，直接按 magic 找第一个 `RATC` 块更稳。
  int? storageVersion;
  int? coreUiVersion;

  final images = <AssetsCarImage>[];
  for (var i = 0; i < blockCount; i++) {
    final entryBase = tableStart + i * 8;
    final address = header.getUint32(entryBase, Endian.big);
    final length = header.getUint32(entryBase + 4, Endian.big);
    if (length == 0 || length > maxBlockBytes) continue;
    if (address < 0x20 || address + length > bytes.length) continue;

    if (_startsWith(bytes, address, 'RATC')) {
      // **RATC 头是小端**（与 BOM 头相反）：+4 = CoreUIVersion、
      // +8 = StorageVersion。按大端读会得到 4077060096 / 285212672 这种
      // 明显不可能的数 —— 实测踩过。
      if (address + 0x10 <= bytes.length) {
        coreUiVersion = header.getUint32(address + 4, Endian.little);
        storageVersion = header.getUint32(address + 8, Endian.little);
      }
      continue;
    }
    if (!_startsWith(bytes, address, 'ISTC')) continue;
    final image = _parseIstc(bytes, header, address, length);
    if (image != null) images.add(image);
  }

  return AssetsCarCatalog(
    storageVersion: storageVersion,
    coreUiVersion: coreUiVersion,
    blockCount: blockCount,
    images: images,
  );
}

/// 解析一个 `ISTC` 块。字段不足或明显不合理时返回 `null`。
AssetsCarImage? _parseIstc(
  Uint8List bytes,
  ByteData header,
  int address,
  int length,
) {
  if (address + _istcNameOffset > bytes.length) return null;
  // 小端：0x04 version、0x08 flags、0x0C width、0x10 height、0x18 pixelFormat。
  final width = header.getUint32(address + 0x0C, Endian.little);
  final height = header.getUint32(address + 0x10, Endian.little);
  // 宽高不合理时按「非图像块」处理（Color / Data 的 ISTC 块宽高是 0）。
  if (width > 65536 || height > 65536) return null;

  final formatBytes = bytes.sublist(address + 0x18, address + 0x18 + 4);
  final pixelFormat = _format4cc(formatBytes);

  final name = _readRenditionName(bytes, address + _istcNameOffset, length);
  if (name == null || name.isEmpty) return null;

  return AssetsCarImage(
    renditionName: name,
    width: width == 0 ? null : width,
    height: height == 0 ? null : height,
    pixelFormat: pixelFormat,
    compression: _detectCompression(bytes, address, length),
    sizeOnDisk: length,
    blockOffset: address,
  );
}

/// 4 字节 4CC → 可读字符串。
///
/// `ISTC` 里这个字段按**小端 u32** 存，所以按字节读出来是反序的：
/// 文件里的 `BGRA` 实际表示 `ARGB`（`assetutil --info` 的 `Encoding`
/// 正是 `ARGB`）。这里统一反转，让上层拿到的是人类约定的写法。
String? _format4cc(List<int> raw) {
  if (raw.length != 4) return null;
  final reversed = raw.reversed.toList();
  // 全是 0 或全是不可打印 → 不是有效的 4CC。
  if (reversed.every((b) => b == 0)) return null;
  if (reversed.any((b) => b < 0x20 || b > 0x7E)) return null;
  return String.fromCharCodes(reversed);
}

/// 在块内找 LZFSE 块魔数。
///
/// 只在前 4 KiB 内找：`bvx2` 紧跟在 ISTC 头的可选字段之后，实测偏移
/// 在 300–400 之间。搜整个块没意义（像素数据里偶然命中会误判）。
CarCompression _detectCompression(Uint8List bytes, int address, int length) {
  final scanEnd = address + (length < 4096 ? length : 4096);
  final limit = scanEnd > bytes.length ? bytes.length : scanEnd;
  for (var i = address; i + 4 <= limit; i++) {
    if (bytes[i] != 0x62 || bytes[i + 1] != 0x76 || bytes[i + 2] != 0x78) {
      continue; // 'bvx'
    }
    final kind = bytes[i + 3];
    return switch (kind) {
      0x32 => CarCompression.lzfseV2, // '2'
      0x6E => CarCompression.lzfseV1, // 'n'
      0x31 => CarCompression.lzfseV1Alt, // '1'
      0x2D => CarCompression.lzfseUncompressed, // '-'
      _ => CarCompression.unknown,
    };
  }
  return CarCompression.none;
}

/// 读 rendition 名（NUL 结尾，带上限）。
///
/// 长度字段的位置随 `flags` 变（实测 `flags=0` 的块读出来是 1021 这种
/// 明显错误的值），所以不依赖它：读到 NUL 或不可打印字符为止。
String? _readRenditionName(Uint8List bytes, int start, int blockLength) {
  final blockEnd = start + blockLength;
  final limit = blockEnd > bytes.length ? bytes.length : blockEnd;
  final buffer = <int>[];
  for (var i = start; i < limit && buffer.length < maxRenditionNameBytes; i++) {
    final b = bytes[i];
    if (b == 0) break;
    if (b < 0x20 || b > 0x7E) return null; // 名字必须是可打印 ASCII
    buffer.add(b);
  }
  if (buffer.isEmpty) return null;
  return String.fromCharCodes(buffer);
}

/// [bytes] 从 [offset] 起是否以 [prefix] 开头。
bool _startsWith(Uint8List bytes, int offset, String prefix) {
  if (offset < 0 || offset + prefix.length > bytes.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[offset + i] != prefix.codeUnitAt(i)) return false;
  }
  return true;
}
