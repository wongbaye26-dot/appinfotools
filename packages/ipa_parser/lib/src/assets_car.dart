// `Assets.car` 的**索引**解析：包里有哪些图，每张图属于哪个资产。
//
// ## 两层，各自独立可验证
//
// 1. `ISTC` 块 —— 每张 rendition 自己的元数据：宽高、像素格式、压缩方式、
//    块字节数。这一层能用 `assetutil --info` 的 `RenditionName` /
//    `PixelWidth` / `Encoding` / `SizeOnDisk` 逐条核对。
// 2. `RENDITIONS` 键索引 —— 把 rendition 归到**资产名**（`AppIcon`、
//    `BrandMark`）下。这一层没有任何文档，布局全是实测反解的，见下。
//
// 像素不在这里取：见 `assets_car_extract.dart`（LZFSE 解码 + PNG 编码）。
//
// ## 键索引（无文档，三条结构都靠自洽性反解）
//
// ```
// KEYFORMAT 块（魔数 "tmfk"，其余字段**小端**）
//   0x00 "tmfk"
//   0x04 u32 0
//   0x08 u32 属性个数 N
//   0x0C N × u32 属性编号（有序）
//
// 键签名 = 2 × N 字节：N 个 u16 **小端**字段，顺序与 KEYFORMAT 一致。
//   每个 ISTC 块在**块表里**的前一块就是它自己的键，长度恰为 2N。
//   字段 17（`kCRThemeIdentifierName`）= 资产名哈希。
//
// 名字表：一块字符串 + 紧随其后的「稀疏键」块
//   稀疏键 = u32 0 + u16 个数 M + M × (u16 属性编号, u16 值)，
//   总长恰为 6 + 4M，属性编号严格递增且都出现在 KEYFORMAT 里。
//   它也带 17 号字段时，那一对就是「资产名 → 哈希」。
// ```
//
// 反解过程留三句话：
//
// - 稀疏键的 `03 00` 按大端读成 768（不可能），按**小端**读成 3（= 字段数）。
// - `2N` 不是猜的：83 个容器里**每一个** ISTC 的前一块长度都恰好是 `2N`。
// - 「前一块就是它的键」是块表顺序，不是文件偏移顺序。
//
// ## 验证到什么程度
//
// 属性编号 17 = `kCRThemeIdentifierName`：`assetutil --info` 的 `Key Format`
// 名字数组与本实现解析出的编号数组**逐位对应**（8/11/12… 项全等），且每张
// rendition 的 `NameIdentifier` 与键里 17 号字段**逐条相等**。
//
// 83 个真实容器（80 个 macOS 系统目录 + 3 个 iOS 应用目录，共 25,986 个
// ISTC）：除 `PackedImage`（图集成员，本来就没有资产名）外**零差异**。
// 7,500 个名字，16 位哈希**零碰撞** —— 但仍按「可能碰撞」处理（见
// [AssetsCarCatalog.ambiguousNameCount]）。
//
// 夹具由 `actool` 真实编译：`test/fixtures/car/appicon-ios.car`。
//
// ## 容器格式（实测确认，见 `docs/notes/assets-car.md`）
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

import 'dart:convert';
import 'dart:typed_data';

/// `kCRThemeIdentifierName` 在 `KEYFORMAT` 里的属性编号。
///
/// 由 `assetutil --info` 的 `Key Format` 数组与本实现解析出的编号数组
/// **逐位对应**确认（见文件头）。它不是一个凭空的魔数：编号数组随容器变化
/// （8 / 11 / 12 / 14 / 17 项都见过），17 始终落在
/// `kCRThemeIdentifierName` 那一格。
const int kAssetIdentifierAttribute = 17;

/// `KEYFORMAT` 块的魔数。
const String _keyFormatMagic = 'tmfk';

/// 键属性个数的上限。
const int maxKeyAttributes = 64;

/// 资产名的字节上限。
///
/// 实测最长的是 `AppIcon_Assets/chs0000_comp_v028_Knight_2kSq-P3.1001`
/// （52 字节）。给到 512 是为了拦住伪造长度，不是预期值。
const int maxAssetNameBytes = 512;

/// 资产名索引的状态。
///
/// 三种状态必须分开，否则读者分不清「这个容器本来就没有资产名」与
/// 「我们没读出来」—— 这正是 V2.4.14 反复修的那类问题。
enum AssetNameIndex {
  /// 容器里没有 `KEYFORMAT`（旧版存储格式）—— 本来就没有资产名可读。
  absent('absent', 'no key format in this container'),

  /// 解出来了。
  parsed('parsed', 'asset names resolved'),

  /// 有 `KEYFORMAT`，但键块与 `ISTC` 对不上 —— 结构不是我们理解的那样，
  /// 不猜（宁可不给名字，也不给错名字）。
  inconsistent('inconsistent', 'key blocks do not line up with the images');

  const AssetNameIndex(this.id, this.label);

  final String id;
  final String label;
}

/// 一个「索引色分块」：一段行范围的调色板。
///
/// ## 为什么要按块存调色板
///
/// 大字图会被 `actool` 切成若干条带（实测 1125×2436 的启动图切成
/// 932 + 932 + 572 行），**每条带带一份自己的调色板**（252 / 240 / 244 条，
/// 互不相同）。索引数据是拼接的（`w × h` 字节），但调色板不能共用 ——
/// 套错一块，那 932 行的颜色就全错，而画面看起来仍然「像一张图」。
///
/// ## 布局（实测，`actool` 产出的两种模式之一）
///
/// ```
/// "dmp2" | 04 01 0a 04 | u16 宽 | u16 本块行数 | u16 调色板条目数 | u16 每条的字节数
///        | 条目数 × 每条的字节数 的调色板（**BGRA**）
///        | u32 紧随其后的流字节数
/// ```
///
/// 模式字节是 `04`（`02` 是另一种多层格式，本实现不解）。
class CarPaletteChunk {
  /// 本块覆盖的**首行**（在整图中的行号）。
  final int firstRow;

  /// 本块覆盖的行数。
  final int rowCount;

  /// 调色板条目数。
  final int entryCount;

  /// 调色板原始字节（`entryCount × stride`，**BGRA** 顺序）。
  final Uint8List palette;

  /// 每条调色板记录的字节数（实测 4）。
  final int stride;

  const CarPaletteChunk({
    required this.firstRow,
    required this.rowCount,
    required this.entryCount,
    required this.palette,
    required this.stride,
  });

  /// 取第 [index] 个条目的 RGBA（已按 [AssetsCarImage] 的字节序规则反转）。
  ///
  /// 调色板条目是 `B,G,R,A`（与 `ARGB` 像素的内存布局相同 ——
  /// 实测三色图的索引 0 落在图像右侧的蓝色区，而调色板[0] 是
  /// `ff 00 00 ff`，只有按 BGRA 读才是蓝）。
  List<int> rgbaAt(int index) {
    final base = index * stride;
    if (stride < 4) {
      final v = palette[base];
      return [v, v, v, stride == 2 ? palette[base + 1] : 255];
    }
    return [
      palette[base + 2],
      palette[base + 1],
      palette[base],
      palette[base + 3]
    ];
  }

  @override
  String toString() => 'CarPaletteChunk(rows $firstRow..'
      '${firstRow + rowCount - 1}, $entryCount entries)';
}

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

  /// `dmp2`：Apple 的 deepmap2。**有像素，但本实现不解这个码**。
  ///
  /// 单独列出来是为了不再把「我们解不了」说成「没有像素」——
  /// 实测 `actool` 产出的 40×40 图标就是纯 `deepmap2`（330 字节），
  /// `assetutil` 明确说它有 `Encoding: ARGB`。此前它被归到 [none]，
  /// 于是 `embedsPixels` 判成「空壳」。
  ///
  /// 注意 `dmp2` 这个标记在**多数**块里与 `bvx` 同时出现（实测 2,595 个
  /// 光栅块两者都有，只有 284 个是纯 `dmp2`）—— 那时像素仍是 LZFSE，
  /// 所以判定的第一优先永远是 `bvx`。
  deepmap2('deepmap2', 'deepmap2 (not decoded)'),

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

  /// 压缩流在文件里的**绝对偏移**；没有压缩流时为 `null`。
  ///
  /// 就是块内 `bvx2` / `bvx-` 魔数的位置 —— LZFSE 的流以这个魔数开头，
  /// 所以直接从这儿读到最后即可。
  final int? payloadOffset;

  /// **资产名**（`AppIcon` / `AppIcon_Assets/Color-1` / `BrandMark`）。
  ///
  /// 来自 `RENDITIONS` 键索引，不是从 rendition 名里猜的 —— 两者不是一回事：
  /// rendition 名是 `icon1024.png` 这种文件名，资产名才是 `Info.plist` 的
  /// `CFBundleIconName` 会指向的东西。
  ///
  /// `null` 的三种情形要分开看：容器没有键索引（[AssetsCarCatalog.nameIndex]
  /// 为 `absent`）、这个键对不上任何名字、或者这个 rendition 是图集成员
  /// （[isAtlasMember]）。
  final String? assetName;

  /// 键里的 `kCRThemeIdentifierName` 值；没有键块时为 `null`。
  final int? assetIdentifier;

  /// 索引色的分块调色板；非索引色图为空。
  ///
  /// 非空表示这个 rendition 的像素数据是**每像素 1 字节的调色板索引**，
  /// 不是 ISTC 声明的 ARGB。实测这类块解出的字节数恰好是 `宽 × 高`，
  /// 而 ISTC 的 `pixelFormat` 仍然写着 `ARGB` —— 那个字段描述的是
  /// **解码后的目标格式**，不是落盘的形态。
  final List<CarPaletteChunk> paletteChunks;

  const AssetsCarImage({
    required this.renditionName,
    this.width,
    this.height,
    this.pixelFormat,
    this.compression = CarCompression.none,
    required this.sizeOnDisk,
    required this.blockOffset,
    this.payloadOffset,
    this.assetName,
    this.assetIdentifier,
    this.paletteChunks = const [],
  });

  /// 这张图的像素是调色板索引（每像素 1 字节）。
  bool get isIndexedColor => paletteChunks.isNotEmpty;

  /// 这个 rendition 属于一个**图集**（`ZZZZPackedAsset-*`）。
  ///
  /// 判据是键里标识符为 0：图集成员没有自己的资产名，`assetutil` 给它的是
  /// 合成名。实测 FindMy 有 19 个、Music 有 645 个。
  bool get isAtlasMember => assetIdentifier == 0 && assetName == null;

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
  /// 判据按「能证明的强度」分两档：
  ///
  /// - **压缩过 → 有。** `bvx*` / `dmp2` 都是像素数据的编码方式，块里有它们
  ///   就说明像素在（未必是我们能解的码）。实测 `installer-progress.car` 里
  ///   739 字节的 `LowBatteryFlashing.png` 就是 deepmap2 —— 它一度被本文档
  ///   判成「空壳」，其实块里有 `dmp2 04 01 0a 04 1e 00 48 00` 这样的
  ///   描述符（30×72 与 `ISTC` 声明一致）。
  /// - **没有任何编码标记 → 只有块装得下 1 字节/像素才算。**
  ///   这类里确实存在真空壳：`SizeOnDisk: 334` 在 `assetutil --info` 里
  ///   出现过成千上万次（Music.app 有 5,694 个），宽高齐全但块体没有内容。
  ///
  /// 这一档是**启发式**，不是判据 —— 所以 `AssetsCarImage` 上没有任何字段
  /// 声称「这里有像素」，只有 `embedsPixels` 这个「能不能试一下」。
  bool get embedsPixels {
    if (!isRasterImage) return false;
    if (compression != CarCompression.none) return true;
    final w = width ?? 0;
    final h = height ?? 0;
    return sizeOnDisk >= w * h;
  }

  /// 名字看起来像应用图标。
  ///
  /// **优先用资产名**：`assetName == 'AppIcon'` 是事实，
  /// `renditionName == 'icon1024.png'` 只能算线索。两者都没有时才退回
  /// rendition 名的字符串判断。
  bool get looksLikeAppIcon {
    final asset = assetName;
    return _iconLike(asset ?? renditionName);
  }

  static bool _iconLike(String value) {
    final lower = value.toLowerCase();
    if (!lower.contains('appicon')) return false;
    // `AppIcon` / `AppIcon60x60@2x` / `AppIcon76x76~ipad` 都算；
    // 但 `AppIcon_Assets/Color-1` 这种是**图标内部图层**，不是图标本身。
    return !lower.contains('/');
  }

  @override
  String toString() => 'AssetsCarImage(${assetName ?? renditionName}, '
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

  /// 资产名索引的状态。
  final AssetNameIndex nameIndex;

  /// 读不出原因；`null` 表示读成功。
  final String? failure;

  /// 同一个标识符对应多个名字的次数（16 位哈希碰撞）。
  ///
  /// 实测 83 个容器、7,500 个名字**一次都没出现**，所以这个值正常为 0。
  /// 留着是因为哈希空间只有 16 位 —— 真撞上时必须报「不确定」，
  /// 不能随手挑一个名字。
  final int ambiguousNameCount;

  /// 图集成员的个数（标识符为 0，本来就没有资产名）。
  final int atlasMemberCount;

  const AssetsCarCatalog({
    this.storageVersion,
    this.coreUiVersion,
    this.blockCount = 0,
    this.images = const [],
    this.failure,
    this.nameIndex = AssetNameIndex.absent,
    this.ambiguousNameCount = 0,
    this.atlasMemberCount = 0,
  });

  const AssetsCarCatalog.unreadable(String reason)
      : storageVersion = null,
        coreUiVersion = null,
        blockCount = 0,
        images = const [],
        failure = reason,
        nameIndex = AssetNameIndex.absent,
        ambiguousNameCount = 0,
        atlasMemberCount = 0;

  bool get parsed => failure == null;

  /// 解出资产名的 rendition（按名字分组去重后）。
  List<String> get assetNames {
    final names = <String>{
      for (final image in images)
        if (image.assetName != null) image.assetName!
    };
    final sorted = names.toList()..sort();
    return sorted;
  }

  /// 有资产名的 rendition 数。
  int get namedRenditionCount =>
      images.where((image) => image.assetName != null).length;

  /// 某个资产名下的全部 rendition（含空壳）；没有时为空。
  ///
  /// 精确匹配：调用方给的通常是 `CFBundleIconName`，**不能**做模糊匹配 ——
  /// `AppIcon` 与 `AppIcon_Assets/Color-1` 是两个不同的资产。
  List<AssetsCarImage> imagesNamed(String name) => [
        for (final image in images)
          if (image.assetName == name) image
      ];

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

  /// 名字像应用图标的那些（优先用资产名，见 [AssetsCarImage.looksLikeAppIcon]）。
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
      'raster: ${rasterImages.length}, names: ${nameIndex.id}, '
      'failure: $failure)';
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
/// [bytes] 是该文件的完整字节。读不出来时返回 `failure` 非空的结果；
/// 容器读出来了但**资产名**读不出时，[AssetsCarCatalog.failure] 仍为 `null`，
/// 由 [AssetsCarCatalog.nameIndex] 说明是哪一种情形。
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

  // 先把块表摊平：键索引要看「前一块 / 后一块」，逐次读块表会让代码难懂，
  // 而且同一条目会被读三遍。
  final addresses = Uint32List(blockCount);
  final lengths = Uint32List(blockCount);
  for (var i = 0; i < blockCount; i++) {
    final entryBase = tableStart + i * 8;
    addresses[i] = header.getUint32(entryBase, Endian.big);
    lengths[i] = header.getUint32(entryBase + 4, Endian.big);
  }

  /// 这一条能否安全地当块用。
  bool usable(int i) {
    final length = lengths[i];
    if (length == 0 || length > maxBlockBytes) return false;
    final address = addresses[i];
    return address >= 0x20 && address + length <= bytes.length;
  }

  // 第一遍：CARHEADER 的版本信息 + `KEYFORMAT`。
  //
  // 不依赖块索引号，直接按 magic 找 —— 实测 `RATC` 在索引 1，
  // 但那是「通常」而不是约定。
  int? storageVersion;
  int? coreUiVersion;
  _KeyFormat? keyFormat;
  for (var i = 0; i < blockCount; i++) {
    if (!usable(i)) continue;
    final address = addresses[i];
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
    if (keyFormat == null && _startsWith(bytes, address, _keyFormatMagic)) {
      keyFormat = _parseKeyFormat(bytes, header, address, lengths[i]);
    }
  }

  // 第二遍前的准备：名字表。
  final nameById = <int, Set<String>>{};
  if (keyFormat != null) {
    _scanNameTable(bytes, addresses, lengths, blockCount, keyFormat, nameById);
  }

  // 第二遍：每个 `ISTC` 连同它自己的键。
  final images = <AssetsCarImage>[];
  var unkeyed = 0;
  var ambiguous = 0;
  var atlasMembers = 0;
  for (var i = 0; i < blockCount; i++) {
    if (!usable(i)) continue;
    final address = addresses[i];
    if (!_startsWith(bytes, address, 'ISTC')) continue;

    int? identifier;
    if (keyFormat == null) {
      unkeyed++;
    } else {
      identifier = _readKeyIdentifier(
          bytes, header, addresses, lengths, i, keyFormat, usable);
      if (identifier == null) unkeyed++;
    }

    String? assetName;
    if (identifier != null && identifier != 0) {
      final names = nameById[identifier];
      if (names != null && names.isNotEmpty) {
        if (names.length == 1) {
          assetName = names.first;
        } else {
          // 16 位哈希撞了。给哪一个都是编 —— 记成「不确定」。
          ambiguous++;
        }
      }
    } else if (identifier == 0) {
      atlasMembers++;
    }

    final image = _parseIstc(bytes, header, address, lengths[i],
        assetName: assetName, assetIdentifier: identifier);
    if (image != null) images.add(image);
  }

  // 状态判定：`KEYFORMAT` 在，但一个键都没对上 → 结构不是我们理解的那样。
  var nameIndex = AssetNameIndex.absent;
  if (keyFormat != null) {
    nameIndex = unkeyed > 0 &&
            images.isNotEmpty &&
            images.every((image) => image.assetIdentifier == null)
        ? AssetNameIndex.inconsistent
        : AssetNameIndex.parsed;
  }

  return AssetsCarCatalog(
    storageVersion: storageVersion,
    coreUiVersion: coreUiVersion,
    blockCount: blockCount,
    images: images,
    nameIndex: nameIndex,
    ambiguousNameCount: ambiguous,
    atlasMemberCount: atlasMembers,
  );
}

/// `KEYFORMAT` 块解出来的键布局。
class _KeyFormat {
  /// 属性编号，有序。
  final List<int> attributes;

  /// 键签名字节数（= 2 × [attributes] 的长度）。
  final int signatureBytes;

  /// 属性编号 → 字段下标。
  final Map<int, int> positionOf;

  const _KeyFormat(this.attributes, this.signatureBytes, this.positionOf);
}

/// 解析 `KEYFORMAT` 块。字段不合理时返回 `null`。
///
/// ```
/// 0x00 "tmfk"
/// 0x04 u32 0
/// 0x08 u32 属性个数 N          ← 小端
/// 0x0C N × u32 属性编号        ← 小端
/// ```
_KeyFormat? _parseKeyFormat(
    Uint8List bytes, ByteData header, int address, int length) {
  const headerBytes = 12;
  if (length < headerBytes || address + headerBytes > bytes.length) return null;

  final count = header.getUint32(address + 8, Endian.little);
  if (count == 0 || count > maxKeyAttributes) return null;
  if (length < headerBytes + count * 4) return null;
  if (address + headerBytes + count * 4 > bytes.length) return null;

  final attributes = <int>[];
  final positionOf = <int, int>{};
  for (var i = 0; i < count; i++) {
    final id = header.getUint32(address + headerBytes + i * 4, Endian.little);
    attributes.add(id);
    positionOf.putIfAbsent(id, () => i);
  }
  return _KeyFormat(attributes, count * 2, positionOf);
}

/// 扫一遍块表，填「资产名哈希 → 名字」。
///
/// 布局：一块字符串，紧跟一块稀疏键。两者缺一不可 —— 只有字符串没有键
/// 就不知道它是哪个资产的，只有键没有字符串就不知道它叫什么。
void _scanNameTable(
  Uint8List bytes,
  Uint32List addresses,
  Uint32List lengths,
  int blockCount,
  _KeyFormat keyFormat,
  Map<int, Set<String>> out,
) {
  for (var i = 0; i + 1 < blockCount; i++) {
    final length = lengths[i];
    if (length < 1 || length > maxAssetNameBytes) continue;
    final address = addresses[i];
    if (address < 0x20 || address + length > bytes.length) continue;

    final name = _readNameString(bytes, address, length);
    if (name == null) continue;

    final next = i + 1;
    final nextLength = lengths[next];
    final nextAddress = addresses[next];
    if (nextAddress < 0x20 || nextLength > maxBlockBytes) continue;
    if (nextAddress + nextLength > bytes.length) continue;

    final fields = _parseSparseKey(bytes, nextAddress, nextLength, keyFormat);
    if (fields == null) continue;

    final id = fields[kAssetIdentifierAttribute];
    if (id == null || id == 0) continue;
    out.putIfAbsent(id, () => <String>{}).add(name);
  }
}

/// 解析「稀疏键」：只列出**非默认**字段的键。
///
/// ```
/// 0x00 u32 0
/// 0x04 u16 字段个数 M           ← 小端
/// 0x06 M × (u16 属性编号, u16 值) ← 小端，编号严格递增
/// ```
///
/// 总长必须**恰好**是 `6 + 4M`：这一条同时是防误判的闸门 —— 随便一段
/// 二进制很少能正好满足「长度自洽 + 编号递增 + 编号都在 KEYFORMAT 里」。
Map<int, int>? _parseSparseKey(
  Uint8List bytes,
  int address,
  int length,
  _KeyFormat keyFormat,
) {
  if (length < 6) return null;
  // 前 4 字节必须是 0。
  for (var i = 0; i < 4; i++) {
    if (bytes[address + i] != 0) return null;
  }
  final count = bytes[address + 4] | (bytes[address + 5] << 8);
  if (count < 1 || count > keyFormat.attributes.length) return null;
  if (length != 6 + count * 4) return null;

  final fields = <int, int>{};
  var previous = -1;
  for (var i = 0; i < count; i++) {
    final base = address + 6 + i * 4;
    final id = bytes[base] | (bytes[base + 1] << 8);
    final value = bytes[base + 2] | (bytes[base + 3] << 8);
    if (id <= previous) return null; // 必须严格递增
    if (!keyFormat.positionOf.containsKey(id)) return null;
    previous = id;
    fields[id] = value;
  }
  return fields;
}

/// 读一块资产名。
///
/// 名字块**不带长度前缀、也不带 NUL**（长度就是块长度），所以这里要求
/// 整块都是合法文本：能按 UTF-8 解、且没有控制字符。实测 83 个容器里
/// 没有一个非 ASCII 名字，但按 UTF-8 处理不需要额外代价，也不会把
/// 未来可能出现的本地化名字漏掉。
String? _readNameString(Uint8List bytes, int address, int length) {
  for (var i = 0; i < length; i++) {
    final b = bytes[address + i];
    if (b < 0x20 || b == 0x7F) return null; // 控制字符 → 不是名字块
  }
  try {
    final text = const Utf8Decoder(allowMalformed: false)
        .convert(Uint8List.sublistView(bytes, address, address + length));
    return text.isEmpty ? null : text;
  } on FormatException {
    return null;
  }
}

/// 读一个 `ISTC` 的键里的标识符。
///
/// 键就是块表里**前一块**，长度必须是 `2N`；对不上就返回 `null`（不猜）。
int? _readKeyIdentifier(
  Uint8List bytes,
  ByteData header,
  Uint32List addresses,
  Uint32List lengths,
  int index,
  _KeyFormat keyFormat,
  bool Function(int) usable,
) {
  if (index == 0) return null;
  final previous = index - 1;
  if (!usable(previous)) return null;
  if (lengths[previous] != keyFormat.signatureBytes) return null;

  final base = addresses[previous];
  // 长度恰好等于签名的块也可能是一段恰好这么长的其它块 —— 排除已知魔数。
  if (_startsWith(bytes, base, 'ISTC') ||
      _startsWith(bytes, base, 'tree') ||
      _startsWith(bytes, base, 'RATC') ||
      _startsWith(bytes, base, 'META') ||
      _startsWith(bytes, base, 'BOMS') ||
      _startsWith(bytes, base, _keyFormatMagic)) {
    return null;
  }

  final position = keyFormat.positionOf[kAssetIdentifierAttribute];
  if (position == null) return null;
  final offset = base + position * 2;
  if (offset + 2 > bytes.length) return null;
  return header.getUint16(offset, Endian.little);
}

/// 解析一个 `ISTC` 块。字段不足或明显不合理时返回 `null`。
AssetsCarImage? _parseIstc(
  Uint8List bytes,
  ByteData header,
  int address,
  int length, {
  String? assetName,
  int? assetIdentifier,
}) {
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
  final detected = _detectCompression(bytes, address, length);
  final paletteChunks = width == 0 || height == 0
      ? const <CarPaletteChunk>[]
      : _parsePaletteChunks(bytes, address, length, width, height);

  return AssetsCarImage(
    renditionName: name,
    width: width == 0 ? null : width,
    height: height == 0 ? null : height,
    pixelFormat: pixelFormat,
    compression: detected.compression,
    sizeOnDisk: length,
    blockOffset: address,
    payloadOffset: detected.offset,
    assetName: assetName,
    assetIdentifier: assetIdentifier,
    paletteChunks: paletteChunks,
  );
}

/// `dmp2` 描述符的魔数。
const String _deepMapMagic = 'dmp2';

/// 索引色模式的参数四字节（`dmp2` 之后）。
const List<int> _indexedColorParams = [0x04, 0x01, 0x0A, 0x04];

/// 解析块内所有「索引色分块」。
///
/// 逐条校验，任何一条不成立就**整体放弃**（返回空）—— 半套调色板比没有
/// 调色板糟得多：调用方会以为这是索引色，然后按错的颜色出图。
///
/// 校验项：
/// - 描述符参数是 `04 01 0a 04`（模式 04 = 索引色；`02` 是另一种格式，不认）；
/// - 描述符里的宽 == ISTC 声明的宽；
/// - 每条的字节数 ∈ {3, 4}，条目数 ∈ 1..256（索引是 8 位）；
/// - 调色板整体落在块内；
/// - **各块行数之和 == ISTC 声明的高**。
List<CarPaletteChunk> _parsePaletteChunks(
  Uint8List bytes,
  int address,
  int length,
  int width,
  int height,
) {
  final blockEnd = address + length;
  final limit = blockEnd > bytes.length ? bytes.length : blockEnd;
  final chunks = <CarPaletteChunk>[];
  var row = 0;
  var searchFrom = address;

  while (searchFrom + 16 <= limit) {
    final found = _findMagic(bytes, searchFrom, limit, _deepMapMagic);
    if (found < 0) break;
    searchFrom = found + 4;

    // 参数四字节。
    var paramsOk = found + 8 <= limit;
    if (paramsOk) {
      for (var i = 0; i < 4; i++) {
        if (bytes[found + 4 + i] != _indexedColorParams[i]) {
          paramsOk = false;
          break;
        }
      }
    }
    if (!paramsOk) continue;

    final header = ByteData.sublistView(bytes);
    final chunkWidth = header.getUint16(found + 8, Endian.little);
    final chunkRows = header.getUint16(found + 10, Endian.little);
    final entryCount = header.getUint16(found + 12, Endian.little);
    final stride = header.getUint16(found + 14, Endian.little);

    if (chunkWidth != width) continue;
    if (chunkRows <= 0 || row + chunkRows > height) continue;
    if (entryCount < 1 || entryCount > 256) continue;
    if (stride != 3 && stride != 4) continue;

    final paletteStart = found + 16;
    final paletteEnd = paletteStart + entryCount * stride;
    if (paletteEnd > limit) continue;

    chunks.add(CarPaletteChunk(
      firstRow: row,
      rowCount: chunkRows,
      entryCount: entryCount,
      palette: Uint8List.sublistView(bytes, paletteStart, paletteEnd),
      stride: stride,
    ));
    row += chunkRows;
    searchFrom = paletteEnd;
  }

  // 行数必须正好覆盖整张图，否则说明我们对结构的理解不成立。
  if (chunks.isEmpty || row != height) return const [];
  return chunks;
}

/// 在 [from, limit) 内找 [magic] 的首次出现；找不到返回 -1。
int _findMagic(Uint8List bytes, int from, int limit, String magic) {
  final last = limit - magic.length;
  for (var i = from; i <= last; i++) {
    var hit = true;
    for (var k = 0; k < magic.length; k++) {
      if (bytes[i + k] != magic.codeUnitAt(k)) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
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

/// 在块内找压缩魔数。
///
/// 只在前 4 KiB 内找：`bvx2` 紧跟在 ISTC 头的可选字段之后，实测偏移
/// 在 300–400 之间。搜整个块没意义（像素数据里偶然命中会误判）。
///
/// **`bvx` 优先于 `dmp2`**：实测 2,595 个光栅块同时含两个标记，那时像素
/// 仍是 LZFSE 流（`dmp2` 只是块里的附加元数据）。只有纯 `dmp2` 的块
/// （实测 284 个）才按 deepmap2 报。
({CarCompression compression, int? offset}) _detectCompression(
    Uint8List bytes, int address, int length) {
  final scanEnd = address + (length < 4096 ? length : 4096);
  final limit = scanEnd > bytes.length ? bytes.length : scanEnd;
  int? deepmapOffset;
  for (var i = address; i + 4 <= limit; i++) {
    if (bytes[i] != 0x62 || bytes[i + 1] != 0x76 || bytes[i + 2] != 0x78) {
      // 'dmp2'：deepmap2。
      if (deepmapOffset == null &&
          bytes[i] == 0x64 &&
          bytes[i + 1] == 0x6D &&
          bytes[i + 2] == 0x70 &&
          bytes[i + 3] == 0x32) {
        deepmapOffset = i;
      }
      continue; // 'bvx'
    }
    final kind = bytes[i + 3];
    // 魔数所在的 i 就是压缩流的起点 —— LZFSE 的流以它开头。
    final compression = switch (kind) {
      0x32 => CarCompression.lzfseV2, // '2'
      0x6E => CarCompression.lzfseV1, // 'n'
      0x31 => CarCompression.lzfseV1Alt, // '1'
      0x2D => CarCompression.lzfseUncompressed, // '-'
      _ => CarCompression.unknown,
    };
    return (compression: compression, offset: i);
  }
  if (deepmapOffset != null) {
    // 有 deepmap2 标记但没有 LZFSE 流：像素在，我们不解。
    return (compression: CarCompression.deepmap2, offset: deepmapOffset);
  }
  return (compression: CarCompression.none, offset: null);
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
