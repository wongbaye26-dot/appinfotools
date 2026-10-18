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

import 'dart:io' show ZLibCodec;
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

  /// 「打开一个包」这一级流程的默认预算（[ZipBudgetLimits.maxSessionOutputBytes]）。
  ///
  /// 真实解析路径上应当**每次打开只建一个**，然后传给所有读取点 —— 每个读取点
  /// 各建一个，等于每个条目都能重新领一份完整配额，累计上限形同虚设。
  factory BoundedReadLedger.session() =>
      BoundedReadLedger(maxTotalBytes: ZipBudgetLimits.maxSessionOutputBytes);

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

/// 一个**带上限**的 `OutputStream`：超限的那一块**只写入放得下的部分**，然后抛。
///
/// 为什么不是「整块丢掉再抛」：zlib 不保证按小块交付输出。实测一个 1 MiB 的
/// 全零条目在 `writeBytes` 里是**一次**交过来的 —— 整块丢掉的话，
/// [readEntryPrefix]（调用方只要开头几 KiB）会得到 0 字节，而调用方无从知道
/// 这是「被上限截断」还是「条目本来是空的」。先填满到 cap 再抛，前缀读取
/// 拿到正好 cap 字节，非前缀读取反正要丢弃，两边都对。
class _CappedOutputStream extends OutputStream {
  _CappedOutputStream(this.cap) : super(byteOrder: ByteOrder.littleEndian);

  final int cap;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _written = 0;

  int get written => _written;

  @override
  int get length => _written;

  @override
  void clear() {}

  @override
  void flush() {}

  @override
  void writeByte(int value) {
    final next = _written + 1;
    if (next > cap) throw _CapExceeded(cap, next);
    _builder.addByte(value);
    _written = next;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final n = length ?? bytes.length;
    final next = _written + n;
    if (next > cap) {
      // 放得下的那部分留下（前缀读取要用），然后带上「本来想写多少」抛出。
      final room = cap - _written;
      if (room > 0) {
        _builder.add(bytes.sublist(0, room));
        _written = cap;
      }
      throw _CapExceeded(cap, next);
    }
    if (n == bytes.length) {
      _builder.add(bytes);
    } else {
      _builder.add(bytes.sublist(0, n));
    }
    _written = next;
  }

  /// 分块搬运输入流。
  ///
  /// **不能写成 `writeBytes(stream.toUint8List())`**：`ZipFile.decompress` 对
  /// STORE（未压缩）条目就是 `output.writeStream(全部内容)`，而
  /// `toUint8List()` 会把**整条条目**物化成一个 `Uint8List` —— 上限一点没拦住，
  /// 峰值内存等于条目大小。343 MB 的包上实测：加固扫描读 .so 头时整条复制，
  /// 1177 ms（分块后回落到十几毫秒）。
  @override
  void writeStream(InputStream stream) {
    const chunkSize = 64 * 1024;
    while (!stream.isEOS) {
      final left = stream.length;
      if (left <= 0) break;
      final take = left < chunkSize ? left : chunkSize;
      writeBytes(stream.readBytes(take).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final all = _builder.toBytes();
    return Uint8List.sublistView(all, start, end ?? all.length);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

/// 把 [out] 当作 `Sink` 交给 `dart:io` 的 zlib 解码器。
///
/// **不能直接用 `ChunkedConversionSink.withCallback`**：那个 sink 会把解压
/// 结果**先全部攒起来**，到 `close()` 才一次性交给回调 —— 上限根本来不及
/// 生效。实测（V2.4.12 收尾，256 MiB 全零条目、上限 1 MiB）：走
/// `ZipFile.decompress()` 时 `ΔRSS` 72 MiB、耗时 29 ms，内存随**条目大小**
/// 涨；换成这个 sink 后 `ΔRSS` 1.2 MiB、耗时 0 ms，随**上限**涨。
class _CappedSink implements Sink<List<int>> {
  _CappedSink(this._out);

  final _CappedOutputStream _out;

  @override
  void add(List<int> data) => _out.writeBytes(data);

  @override
  void close() {}
}

/// 有界地解一条 **raw deflate** 流。
///
/// 输入按 1 KiB 一块喂（与 `archive` 自己的循环一致）：每一块解出的输出量
/// 由压缩比决定，因此超限时**最多**多出一块的产物，随后在 [Sink.add] 里抛出，
/// 循环立刻停下。
void _inflateRawBounded(InputStream input, _CappedOutputStream out) {
  final inSink = ZLibCodec(raw: true).decoder.startChunkedConversion(
        _CappedSink(out),
      );
  const chunkSize = 1024;
  while (!input.isEOS) {
    final left = input.length;
    final take = left < chunkSize ? left : chunkSize;
    inSink.add(input.readBytes(take).toUint8List());
  }
  inSink.close();
}

/// 解压一条条目，**真实产出**受 [out] 的上限约束。
///
/// deflate 走自己喂输入的有界路径；其余形态（STORE / bzip2）沿用
/// `ZipFile.decompress` —— STORE 是 `writeStream`，已经分块；bzip2 在本项目
/// 处理的对象（APK / IPA）里不会出现，保留原路径而不是为它写一份实现。
///
/// 加密条目在上游就被拒绝了（见 [_read] 的 `flags & 0x1` 判断），这里不再
/// 处理 AES —— 走到这里说明是加密 + deflate 的组合，解出来必然是
/// `FormatException`，按 `corrupt` 报告即可。
void _decompressBounded(ZipFile raw, _CappedOutputStream out) {
  if (raw.compressionMethod == CompressionType.deflate) {
    _inflateRawBounded(raw.getStream(decompress: false), out);
    return;
  }
  raw.decompress(out);
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
    _decompressBounded(raw, out);
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

  // ---- 完整性：产出少于声明值 = 数据被截断，不许当正常内容返回 ----
  //
  // 实测（V2.4.12）：把中央目录里的 `compressedSize` 改小一半，`archive` 的
  // 流式解压**不报错**，只是提前结束 —— 于是「返回半截内容」和「返回完整
  // 内容」在调用方看来一模一样。这对安全分析尤其危险：半截的 DEX / Mach-O
  // 会被当成完整的来判定。
  //
  // 只判「少」，不判「多」：加固包会故意把 `uncompressedSize` 报小（见
  // V2.4.10 的零填充清单），产出多于声明值是**已知的合法形态**。
  if (!allowTruncation && out.written < declared) {
    return BoundedEntryRead.refused(BoundedReadFailure(
      entry: name,
      stage: BoundedReadStage.corrupt,
      observedBytes: out.written,
      limitBytes: declared,
    ));
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
