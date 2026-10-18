// APK Signing Block：只读「用了哪几套签名方案」，不做任何密码学验证。
//
// ## 为什么值得单独解析
//
// 现在签名结论完全交给 `apksigner`。这有两个后果：
//
// 1. **没装工具就一律「未验证」** —— 而「有没有签名」与「签名是否有效」
//    是两件事，前者纯结构、可以自己回答；
// 2. 看不出「这个包**只有 v1 签名**」。v1（JAR 签名）只保护 ZIP 条目的
//    摘要，**不保护 ZIP 结构本身**，因此可以往里面塞额外的条目而不破坏签名 ——
//    这正是重打包最常见的形态。v2+ 把整份归档的摘要放进签名块，塞条目就会失效。
//
// 所以要回答的是：**v2 / v3 签名块在不在**。答案只有三种：在、不在、读不出。
// 「读不出」必须是独立状态，不能折成「不在」。
//
// ## 边界（必须如实写在 limitation 里）
//
// - 只解析块**结构**与其中的 pair id，**不验证**任何签名、不比对证书；
// - 有 v2 块不等于签名有效 —— 那仍然要 `apksigner` 说了算；
// - v4 是独立文件（`.idsig`），不在归档里，不判。
//
// 结构（AOSP `ApkSigningBlockUtils`）：
//
// ```
// [size:uint64][pairs...][size:uint64][magic:16 = "APK Sig Block 42"]
//   每个 pair: [len:uint64][id:uint32][value: len-4 字节]
//   size = len(pairs) + 8 + 16，因此整块长度 = size + 8
// ```
//
// 块紧贴在中央目录之前，所以定位方式是：EOCD → 中央目录偏移 → 往前 24 字节。

import 'dart:typed_data';

/// 一次**有界**读取：从 [offset] 起读 [length] 字节。
///
/// 用回调而不是传 `Uint8List`：APK 有几百 MB，而签名块与 EOCD 都在文件尾部，
/// 只需要两次几十 KB 级的读取。传整份字节会把峰值内存翻倍。
typedef ApkRangeReader = Uint8List Function(int offset, int length);

/// 已知的 APK Signing Block pair id。
class ApkSignatureBlockId {
  ApkSignatureBlockId._();

  /// APK Signature Scheme v2。
  static const int v2 = 0x7109871a;

  /// APK Signature Scheme v3（密钥轮换）。
  static const int v3 = 0xf05368c0;

  /// APK Signature Scheme v3.1（SDK 版本定向轮换）。
  static const int v31 = 0x1b93ad61;

  /// 源戳（Play 的 source stamp），不是签名方案，但同在块里。
  static const int sourceStamp = 0x6dff800d;

  /// verity 填充（用于给未来的签名预留空间）。
  static const int verityPadding = 0x42726577;

  /// id → 简短名字；未收录的返回 `0x...` 十六进制。
  static String describe(int id) => switch (id) {
        v2 => 'v2',
        v3 => 'v3',
        v31 => 'v3.1',
        sourceStamp => 'source-stamp',
        verityPadding => 'verity-padding',
        _ => '0x${id.toRadixString(16)}',
      };
}

/// 一次解析的结果。
class ApkSigningSchemes {
  /// 块里出现的 pair id（按出现顺序，已去重）。
  final List<int> pairIds;

  /// 解析失败的原因；`null` 表示成功读到了结构（**不代表签名有效**）。
  final String? failure;

  const ApkSigningSchemes({this.pairIds = const [], this.failure});

  const ApkSigningSchemes.unreadable(String reason)
      : pairIds = const [],
        failure = reason;

  bool get parsed => failure == null;

  bool get hasV2 => pairIds.contains(ApkSignatureBlockId.v2);
  bool get hasV3 => pairIds.contains(ApkSignatureBlockId.v3);
  bool get hasV31 => pairIds.contains(ApkSignatureBlockId.v31);

  /// 签名方案的可读列表，例如 `['v2', 'v3']`。
  ///
  /// 只列签名方案，不含 source-stamp / verity-padding —— 那两个不是方案。
  List<String> get schemeNames => [
        if (hasV2) 'v2',
        if (hasV3) 'v3',
        if (hasV31) 'v3.1',
      ];

  /// 只有 v1（JAR）签名 —— 结构上没有任何 v2+ 签名块。
  ///
  /// **这一条是「重打包友好」的结构信号**，不是「已被篡改」的结论：
  /// v1 只保护条目内容，不保护 ZIP 结构，塞入额外条目不会让 v1 失效。
  bool get v1Only => parsed && schemeNames.isEmpty;

  /// 整个 block 都不存在（连 magic 都没有）。与 [v1Only] 同义，
  /// 保留两个名字是因为调用方的措辞不同：一个说「没有 v2+ 方案」，
  /// 一个说「没有签名块」。
  bool get missingBlock => v1Only;

  @override
  String toString() => 'ApkSigningSchemes(pairs: '
      '${pairIds.map(ApkSignatureBlockId.describe).toList()}, '
      'failure: $failure)';
}

/// 块体允许的最大字节数。
///
/// v2/v3 签名通常是几 KB；带大量证书链或 verity 填充的包会到几十 KB。
/// 16 MiB 已经远超任何真实签名块 —— 超过这个值说明声明长度被伪造过，
/// 继续读等于让一个不可信的长度决定我们的内存分配。
const int _kMaxBlockBytes = 16 << 20;

/// 解析 APK Signing Block。
///
/// [fileLength] 是归档总长度；[read] 是按偏移读取的回调（必须有界）。
///
/// 读不到返回 `ApkSigningSchemes.unreadable(原因)` —— **不能返回「没有 v2」**，
/// 那会把「我们没读到」说成「这个包只有 v1 签名」。
ApkSigningSchemes parseApkSigningBlock({
  required int fileLength,
  required ApkRangeReader read,
}) {
  if (fileLength < 22) {
    return const ApkSigningSchemes.unreadable('file is too small to be a ZIP');
  }

  // ---- 1. 找 EOCD ----
  const maxTail = 22 + 65535;
  final tailStart = fileLength > maxTail ? fileLength - maxTail : 0;
  final tail = read(tailStart, fileLength - tailStart);
  final eocdOffset = _findEocd(tail);
  if (eocdOffset == null) {
    return const ApkSigningSchemes.unreadable('ZIP end-of-central-directory '
        'record not found');
  }
  // 16 = 中央目录偏移字段在 EOCD 内的位置。
  final cdOffset = _u32(tail, eocdOffset + 16);
  if (cdOffset == 0 || cdOffset > fileLength - 22 || cdOffset < 24) {
    return ApkSigningSchemes.unreadable(
        'central directory offset $cdOffset is out of range');
  }

  // ---- 2. 中央目录之前 24 字节：size(8) + magic(16) ----
  final footer = read(cdOffset - 24, 24);
  if (footer.length < 24) {
    return const ApkSigningSchemes.unreadable(
        'could not read the 24 bytes before the central directory');
  }
  if (!_hasMagic(footer)) {
    // 没有 magic = 没有签名块（绝大多数 v1-only 包就是这个形态）。
    return const ApkSigningSchemes();
  }

  // ---- 3. 按声明的块长度读整块 ----
  final declared = _u64(footer, 0);
  if (declared < 24) {
    return ApkSigningSchemes.unreadable(
        'signing block declares an impossible size ($declared)');
  }
  if (declared > _kMaxBlockBytes) {
    return ApkSigningSchemes.unreadable(
        'signing block declares $declared bytes, beyond the $_kMaxBlockBytes '
        'byte cap');
  }
  final blockStart = cdOffset - declared - 8;
  if (blockStart < 0) {
    return ApkSigningSchemes.unreadable(
        'signing block size $declared does not fit before the central '
        'directory');
  }
  final block = read(blockStart, declared + 8);
  if (block.length != declared + 8) {
    return const ApkSigningSchemes.unreadable(
        'could not read the whole signing block');
  }
  // 头部与尾部的 size 必须一致，否则长度是伪造的。
  if (_u64(block, 0) != declared ||
      _u64(block, block.length - 24) != declared) {
    return const ApkSigningSchemes.unreadable(
        'the two size fields of the signing block disagree');
  }

  // ---- 4. 逐个 pair ----
  final pairIds = <int>[];
  var cursor = 8;
  final pairsEnd = block.length - 24;
  while (cursor + 12 <= pairsEnd) {
    final length = _u64(block, cursor);
    if (length < 4 || cursor + 8 + length > pairsEnd) {
      return ApkSigningSchemes.unreadable(
          'signing block pair at $cursor declares $length bytes, which does '
          'not fit');
    }
    final id = _u32(block, cursor + 8);
    if (!pairIds.contains(id)) pairIds.add(id);
    cursor += 8 + length;
  }
  return ApkSigningSchemes(pairIds: pairIds);
}

const List<int> _kMagic = [
  0x41, 0x50, 0x4b, 0x20, 0x53, 0x69, 0x67, 0x20, // "APK Sig "
  0x42, 0x6c, 0x6f, 0x63, 0x6b, 0x20, 0x34, 0x32, // "Block 42"
];

bool _hasMagic(Uint8List bytes) {
  final start = bytes.length - 16;
  if (start < 0) return false;
  for (var i = 0; i < 16; i++) {
    if (bytes[start + i] != _kMagic[i]) return false;
  }
  return true;
}

/// 从尾部缓冲区里定位 EOCD，返回它在 [bytes] 内的偏移。
///
/// 与 `ZipStructure.declaredEntryCount` 同一套判据：签名之后还要校验
/// **注释长度恰好把记录顶到缓冲区末尾** —— 压缩数据里偶然出现
/// `PK\x05\x06` 的概率不低，不做这一步会读到假的中央目录偏移。
int? _findEocd(Uint8List bytes) {
  if (bytes.length < 22) return null;
  final earliest = bytes.length - 22 - 65535;
  final start = earliest < 0 ? 0 : earliest;
  for (var i = bytes.length - 22; i >= start; i--) {
    if (bytes[i] != 0x50 ||
        bytes[i + 1] != 0x4b ||
        bytes[i + 2] != 0x05 ||
        bytes[i + 3] != 0x06) {
      continue;
    }
    final commentLength = bytes[i + 20] | (bytes[i + 21] << 8);
    if (i + 22 + commentLength != bytes.length) continue;
    return i;
  }
  return null;
}

int _u32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

/// 读 64 位小端。**超过 2^53 时返回一个明显不可能的负数**：
/// 我们只用它比较大小，任何真实长度都远小于这个界，伪造的超大值会被
/// 后续的上限检查拦住。
int _u64(Uint8List bytes, int offset) {
  final low = _u32(bytes, offset);
  final high = _u32(bytes, offset + 4);
  if (high > 0x1fffff) return -1;
  return (high << 32) | (low & 0xffffffff);
}
