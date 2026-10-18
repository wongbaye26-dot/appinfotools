/// 有界解压：**逐块**统计真实产出，超过预算立即中止。
///
/// ## 为什么不是「解压完再比长度」
///
/// 中央目录里的 `uncompressedSize` 来自不可信输入。实测（V2.4.10 审计 P1-1）：
/// 把 100 MiB 条目的声明值改成 1024，`ZipBudget.check` 会放行，而
/// `ZipFile.content` 仍会产出 104,857,600 字节 —— 先完整解压到内存再比长度，
/// 等于让攻击者决定分配多少。
///
/// ## 靠什么做到真正有界
///
/// `archive` 的 `ZipFile.decompress(OutputStream)` 是**流式**的：
/// 它把 zlib 的输出一块一块写进调用方给的 `OutputStream`。因此只要给一个
/// **带上限的 `OutputStream`**，超限时在 `writeBytes` 里抛异常，
/// zlib 就会在那一块停下来 —— 峰值内存是「预算 + 一块」，不是「整条条目」。
///
/// 实测（5 MiB 全零条目，上限 1 MiB）：在 `observed = 1,067,098` 处抛出，
/// 已产出 1,001,562 字节就中止，从未物化 5 MiB。
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 一次有界读取停在了哪一步。
enum BoundedReadStage {
  /// 声明值就超了 —— 根本没解压。
  declaredSize,

  /// 压缩后大小超了（连原始数据都不该读进来）。
  compressedSize,

  /// 解压过程中真实产出超了 —— **逐块中止**。
  inflate,

  /// 这个条目的形态不支持有界解压（加密等），拒绝而不是退回无界读取。
  unsupported,

  /// 解压本身失败（损坏 / 截断）。
  corrupt,
}

/// 一条「被拒绝」的结构化诊断。
///
/// 三项必填：**哪个条目**、**停在哪一步**、**实际观察到多少字节**。
/// 只写「超出解压上限」对排查毫无帮助。
class BoundedReadFailure {
  final String entry;
  final BoundedReadStage stage;

  /// 实际观察到的字节数（`declaredSize` 阶段是声明值，`inflate` 阶段是真实产出）。
  final int observedBytes;

  /// 本次生效的上限。
  final int limitBytes;

  const BoundedReadFailure({
    required this.entry,
    required this.stage,
    required this.observedBytes,
    required this.limitBytes,
  });

  /// 一行可贴进日志的说明（英文，面向排查）。
  String describe() => '$entry: stopped at ${stage.name} after $observedBytes '
      'bytes (limit $limitBytes)';

  @override
  String toString() => 'BoundedReadFailure(${describe()})';
}

/// 有界读取的结果。
class BoundedEntryRead {
  final Uint8List? bytes;
  final BoundedReadFailure? failure;

  const BoundedEntryRead._(this.bytes, this.failure);

  factory BoundedEntryRead.ok(Uint8List bytes) =>
      BoundedEntryRead._(bytes, null);

  factory BoundedEntryRead.refused(BoundedReadFailure failure) =>
      BoundedEntryRead._(null, failure);

  bool get isOk => bytes != null;

  @override
  String toString() => isOk
      ? 'BoundedEntryRead(${bytes!.length} bytes)'
      : 'BoundedEntryRead($failure)';
}

/// 一次读取流程的**共享**预算。
///
/// 嵌套归档（APK 里套 ZIP）必须共用同一个 ledger —— 否则每个子归档都能重新
/// 取得一份完整配额，总量失控。用法：为一次解包流程创建一个实例，所有读取
/// 都传它。
class BoundedReadLedger {
  /// 一次流程允许的**真实产出**总字节数。
  final int maxTotalBytes;

  int _produced = 0;

  BoundedReadLedger({required this.maxTotalBytes});

  /// 已累计的真实产出。
  int get producedBytes => _produced;

  int get remainingBytes =>
      _produced >= maxTotalBytes ? 0 : maxTotalBytes - _produced;

  void _add(int bytes) => _produced += bytes;
}

/// 超限时从 [OutputStream] 里抛出来，中止 zlib。
class _CapExceeded implements Exception {
  final int cap;
  final int observed;

  const _CapExceeded(this.cap, this.observed);

  @override
  String toString() => 'CapExceeded(cap=$cap observed=$observed)';
}

/// 一个**带上限**的 `OutputStream`：超限的那一块不写入，直接抛。
///
/// 只实现 `decompress` 真正会用到的那几个方法；`clear` / `flush` 是空实现，
/// 因为解压流程不会在中间清空输出。
class _CappedOutputStream extends OutputStream {
  _CappedOutputStream(this.cap) : super(byteOrder: ByteOrder.littleEndian);

  final int cap;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _written = 0;

  int get written => _written;

  void _reserve(int n) {
    final next = _written + n;
    if (next > cap) throw _CapExceeded(cap, next);
    _written = next;
  }

  @override
  int get length => _written;

  @override
  void clear() {}

  @override
  void flush() {}

  @override
  void writeByte(int value) {
    _reserve(1);
    _builder.addByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final n = length ?? bytes.length;
    _reserve(n);
    if (n == bytes.length) {
      _builder.add(bytes);
    } else {
      _builder.add(bytes.sublist(0, n));
    }
  }

  @override
  void writeStream(InputStream stream) => writeBytes(stream.toUint8List());

  @override
  Uint8List subset(int start, [int? end]) {
    final all = _builder.toBytes();
    return Uint8List.sublistView(all, start, end ?? all.length);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

/// 有界读取一个归档条目。
///
/// 三道闸，按顺序：
/// 1. **声明值**（`ArchiveFile.size`）超预算 → 不解压就拒绝；
/// 2. **压缩后大小**超预算 → 连原始数据都不读；
/// 3. **解压过程**中真实产出超预算 → 逐块中止（见库文档）。
///
/// 任何一道命中都返回 [BoundedReadFailure]，`bytes` 为 `null` ——
/// **绝不返回超限的内容**。
BoundedEntryRead readEntryBounded(
  ArchiveFile file, {
  required int maxEntryBytes,
  required BoundedReadLedger ledger,
}) =>
    _read(
      file,
      maxEntryBytes: maxEntryBytes,
      ledger: ledger,
      allowTruncation: false,
    );

/// 只读条目**开头**最多 [maxBytes] 字节（嗅探文件头用）。
///
/// 与 [readEntryBounded] 的关键区别：超限时**返回已产出的前缀**而不是拒绝。
/// 这是有意的 —— 调用方明确只要开头这么一点，因此 [maxBytes] 必须很小
/// （`HardeningScanner` 只要 8 字节，用 64 KiB 上限）。
///
/// **不要**用它读取需要完整内容的条目：它不保证内容完整。
BoundedEntryRead readEntryPrefix(
  ArchiveFile file, {
  required int maxBytes,
  required BoundedReadLedger ledger,
}) =>
    _read(
      file,
      maxEntryBytes: maxBytes,
      ledger: ledger,
      allowTruncation: true,
    );

BoundedEntryRead _read(
  ArchiveFile file, {
  required int maxEntryBytes,
  required BoundedReadLedger ledger,
  required bool allowTruncation,
}) {
  final name = file.name;

  // ---- 闸 1：声明值 ----
  //
  // **前缀读取跳过这一道**：调用方只要开头 8 字节，声明 200 MiB 也无所谓 ——
  // 真正约束产出的是闸 3 的上限。若在这里拒绝，「只嗅一个文件头」就会因为
  // 条目本身很大而失败。
  final declared = file.size;
  if (!allowTruncation && declared > maxEntryBytes) {
    return BoundedEntryRead.refused(BoundedReadFailure(
      entry: name,
      stage: BoundedReadStage.declaredSize,
      observedBytes: declared,
      limitBytes: maxEntryBytes,
    ));
  }

  final raw = file.rawContent;

  // 内存里手工构造的 `ArchiveFile`（测试 / 合成数据）没有 ZIP 元数据，
  // 内容本来就在内存里，量一下长度即可。
  if (raw is! ZipFile) {
    final List<int> content;
    try {
      content = file.content as List<int>;
    } catch (e) {
      return BoundedEntryRead.refused(BoundedReadFailure(
        entry: name,
        stage: BoundedReadStage.corrupt,
        observedBytes: 0,
        limitBytes: maxEntryBytes,
      ));
    }
    final bytes = content is Uint8List ? content : Uint8List.fromList(content);
    if (content.length > maxEntryBytes) {
      if (allowTruncation) {
        // 前缀读取：内存里已有完整内容，切前 maxEntryBytes 字节即可。
        ledger._add(maxEntryBytes);
        return BoundedEntryRead.ok(
          Uint8List.sublistView(bytes, 0, maxEntryBytes),
        );
      }
      return BoundedEntryRead.refused(BoundedReadFailure(
        entry: name,
        stage: BoundedReadStage.inflate,
        observedBytes: content.length,
        limitBytes: maxEntryBytes,
      ));
    }
    ledger._add(bytes.length);
    return BoundedEntryRead.ok(bytes);
  }

  // ---- 闸 2：压缩后大小 ----
  final compressed = raw.compressedSize;
  if (compressed > ZipBudgetLimits.maxSingleEntryCompressed) {
    return BoundedEntryRead.refused(BoundedReadFailure(
      entry: name,
      stage: BoundedReadStage.compressedSize,
      observedBytes: compressed,
      limitBytes: ZipBudgetLimits.maxSingleEntryCompressed,
    ));
  }

  // 加密条目拒绝而不是退回无界读取 —— APK / IPA 从不用 ZIP 加密。
  if ((raw.flags & 0x1) != 0) {
    return BoundedEntryRead.refused(BoundedReadFailure(
      entry: name,
      stage: BoundedReadStage.unsupported,
      observedBytes: compressed,
      limitBytes: maxEntryBytes,
    ));
  }

  // ---- 闸 3：逐块解压，超限即中止 ----
  //
  // 本次可用上限 = min(单条目上限, 共享预算剩余)。
  final cap = maxEntryBytes < ledger.remainingBytes
      ? maxEntryBytes
      : ledger.remainingBytes;
  final out = _CappedOutputStream(cap);
  // `ZipFile.decompress` 在**成功**路径上会自己把流位置还原，但超限时是从
  // `ZLibDecoder` 里抛出来的，那一步走不到。不还原的话，一次被拒绝的读取会
  // 把条目读到 EOF —— 之后同一个条目再读就是 0 字节。
  final rawStream = raw.getStream(decompress: false);
  final savedPosition = rawStream.position;
  try {
    raw.decompress(out);
  } on _CapExceeded catch (e) {
    if (allowTruncation) {
      // 前缀读取：调用方只要开头，已产出的这部分就是答案。
      ledger._add(out.written);
      return BoundedEntryRead.ok(out.takeBytes());
    }
    // 已产出的部分**丢弃**，不返回超限内容。
    return BoundedEntryRead.refused(BoundedReadFailure(
      entry: name,
      stage: BoundedReadStage.inflate,
      observedBytes: e.observed,
      limitBytes: cap,
    ));
  } catch (e) {
    return BoundedEntryRead.refused(BoundedReadFailure(
      entry: name,
      stage: BoundedReadStage.corrupt,
      observedBytes: out.written,
      limitBytes: cap,
    ));
  } finally {
    rawStream.setPosition(savedPosition);
  }

  ledger._add(out.written);
  return BoundedEntryRead.ok(out.takeBytes());
}

/// 与预算相关的常量（与 `ZipBudget` 共用，集中在一处便于审计）。
class ZipBudgetLimits {
  ZipBudgetLimits._();

  /// 单条目允许的**压缩后**字节数上限（512 MiB）。
  ///
  /// 声明值可以造假，但「压缩后多大」决定了要不要把它读进内存 ——
  /// 这一条挡的是「一个条目就 2 GiB 压缩数据」。
  static const int maxSingleEntryCompressed = 512 * 1024 * 1024;

  /// 一次读取流程允许的**压缩后**字节数总量（2 GiB）。
  ///
  /// 挡的是「几千个条目各自不大、加起来把整个文件读进内存」。正常 APK / IPA
  /// 的压缩后总量就是文件本身（几百 MB），这条不会误伤。
  static const int maxTotalCompressed = 2 * 1024 * 1024 * 1024;

  /// 一次读取流程允许的真实产出总量（1 GiB）。
  ///
  /// 与「归档声明总量 1 GiB」不是一回事：那个看声明，这个看**实际解出来的**。
  static const int maxSessionOutputBytes = 1024 * 1024 * 1024;
}
