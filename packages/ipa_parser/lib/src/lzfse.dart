// LZFSE 解码（Apple 的压缩格式，`Assets.car` 里的图像数据就是它）。
//
// ## 为什么要自己写
//
// `Assets.car` 的 `ISTC` 块把像素（BGRA / GA8 等原始格式）用 LZFSE 压过。
// Dart 侧没有任何实现，而 macOS 的 `libcompression` 在 Windows / Linux 上
// 不存在 —— 这个工具要跨平台构建，不能依赖它。
//
// ## 支持范围（有依据的取舍）
//
// | 块类型 | 魔数 | 支持 | 依据 |
// |---|---|---|---|
// | 未压缩 | `bvx-` | ✓ | 直接拷贝 |
// | LZFSE v2 | `bvx2` | ✓ | **实测 5 个系统 `Assets.car` 的 951 张光栅图全是它** |
// | 结束 | `bvx$` | ✓ | 4 字节魔数，没有附加字段 |
// | LZFSE v1 | `bvx1` | ✗ 明确报错 | 没有编码器产出它，也没有样本；无法独立验证 |
// | LZVN | `bvxn` | ✗ 明确报错 | 只出现在矢量载荷上（不提取像素），实测 0 张光栅图用它 |
//
// 后两种**不假装解出来**：抛 `LzfseException` 并说清是哪一种。凭猜写一个
// 实现只会得到「看起来能跑、结果是错的」—— 那是本项目最想避免的失败模式。
//
// ## 算法来源
//
// 按 Apple 开源实现（`lzfse`，APSL-2.0）的 `lzfse_decode_base.c` /
// `lzfse_fse.h` / `lzfse_fse.c` 移植：FSE 状态机 + 反向位流 + LZ 回溯。
// **频率表存在流里**（v2 头里用固定 Huffman 码压缩过），所以不需要嵌入任何
// 静态表 —— 这也是能纯 Dart 实现的前提。
//
// ## 期望值
//
// `test/fixtures/lzfse/` 下的夹具由 macOS 的 `libcompression`
// （`COMPRESSION_LZFSE`）**真实压缩**产出，原始字节就是解码的期望输出。
// 生成命令见该目录的 README。

import 'dart:typed_data';

/// 解码失败。
class LzfseException implements Exception {
  /// 稳定标识，便于上层分类（不随文案变）。
  final String code;

  /// 面向人的说明。
  final String message;

  const LzfseException(this.code, this.message);

  @override
  String toString() => 'LzfseException($code): $message';
}

/// 块魔数（小端 u32）。
class _Magic {
  static const int endOfStream = 0x24787662; // bvx$
  static const int uncompressed = 0x2d787662; // bvx-
  static const int compressedV1 = 0x31787662; // bvx1
  static const int compressedV2 = 0x32787662; // bvx2
  static const int lzvn = 0x6e787662; // bvxn
}

// 状态数 / 符号数（格式常量）。
const int _lStates = 64;
const int _lSymbols = 20;
const int _mStates = 64;
const int _mSymbols = 20;
const int _dStates = 256;
const int _dSymbols = 64;
const int _literalStates = 1024;
const int _literalSymbols = 256;

/// L / M / D 的「附加位」与「基值」（格式常量，不从流里读）。
const List<int> _lExtraBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 5, 8, //
];
const List<int> _lBaseValue = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 20, 28, 60, //
];
const List<int> _mExtraBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 5, 8, 11, //
];
const List<int> _mBaseValue = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 24, 56, 312, //
];
const List<int> _dExtraBits = [
  0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, //
  4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7,
  8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 11,
  12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 15,
];
const List<int> _dBaseValue = [
  0, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 28, 36, 44, 52, //
  60, 76, 92, 108, 124, 156, 188, 220, 252, 316, 380, 444, 508, 636, 764, 892,
  1020, 1276, 1532, 1788, 2044, 2556, 3068, 3580, 4092, 5116, 6140, 7164,
  8188, 10236, 12284, 14332, 16380, 20476, 24572, 28668, 32764, 40956, 49148,
  57340, 65532, 81916, 98300, 114684, 131068, 163836, 196604, 229372,
];

/// v2 头里频率表用的固定 Huffman 码（`lzfse_decode_v1_freq_value`）。
const List<int> _freqNbits = [
  2, 3, 2, 5, 2, 3, 2, 8, 2, 3, 2, 5, 2, 3, 2, 14, //
  2, 3, 2, 5, 2, 3, 2, 8, 2, 3, 2, 5, 2, 3, 2, 14,
];
const List<int> _freqValue = [
  0, 2, 1, 4, 0, 3, 1, -1, 0, 2, 1, 5, 0, 3, 1, -1, //
  0, 2, 1, 6, 0, 3, 1, -1, 0, 2, 1, 7, 0, 3, 1, -1,
];

/// 解压上限：256 MiB。
///
/// 单张图实测最大 4 MiB（1024×1024 BGRA），但一个 `Assets.car` 里可能有很多张。
/// 上限只用来拦住伪造 `n_raw_bytes` 的炸弹，不参与正常分配。
const int lzfseMaxOutputBytes = 256 * 1024 * 1024;

/// 解压一个 LZFSE 流。
///
/// 失败时抛 [LzfseException]。
Uint8List lzfseDecode(Uint8List src) => _Decoder(src).run();

/// `x` 的低 [n] 位（`n >= 64` 时原样返回）。
///
/// Dart 的 `int` 是 64 位有符号，`1 << 64` 会溢出成 0，必须单独处理。
/// 与参考实现的 65 项 `fse_mask_lsb64` 查表等价。
int _maskLsb(int x, int n) {
  if (n <= 0) return 0;
  if (n >= 64) return x;
  return x & ((1 << n) - 1);
}

/// 从 64 位字段里取 [offset] 起的 [nbits] 位（`get_field`）。
int _field(int value, int offset, int nbits) {
  if (nbits >= 64) return value >>> offset;
  return (value >>> offset) & ((1 << nbits) - 1);
}

/// 一个 FSE 解码表条目（字面量流）。
class _FseEntry {
  /// 要读的位数。
  final int k;

  /// 输出的符号。
  final int symbol;

  /// 下一个状态的基值：`state = delta + pull(k)`。
  final int delta;

  const _FseEntry(this.k, this.symbol, this.delta);
}

/// 一个 FSE「值」解码表条目（L / M / D 流）。
class _FseValueEntry {
  /// 状态位 + 附加值位。
  final int totalBits;

  /// 附加值位数。
  final int valueBits;

  /// 下一个状态的基值：`state = delta + (bits >>> valueBits)`。
  final int delta;

  /// 值的基值：`value = vbase + mask(bits, valueBits)`。
  final int vbase;

  const _FseValueEntry(this.totalBits, this.valueBits, this.delta, this.vbase);
}

/// 反向位流读取器（64 位累加器）。
///
/// LZFSE 的位流**从后往前**读：`pos` 递减，新字节进累加器高位。
/// 这不是实现细节 —— 参考实现的 `fse_in_checked_init64` 就是「往前退 8 字节」。
class _BitReader {
  final Uint8List buf;
  int pos;

  /// 下界：退到这儿之前就算越界。
  final int start;

  int accum = 0;
  int nbits = 0;

  _BitReader(this.buf, this.pos, this.start);

  /// 初始化（对应 `fse_in_checked_init64`）。
  ///
  /// [n] 是 v2 头里存的 `literal_bits` / `lmd_bits`（值域 `[-7, 0]`）。
  void init(int n) {
    if (n != 0) {
      if (pos - 8 < start) {
        throw const LzfseException(
            'stream.truncated', 'not enough bytes for the bit stream header');
      }
      pos -= 8;
      accum = _readU64(pos);
      nbits = n + 64;
    } else {
      if (pos - 7 < start) {
        throw const LzfseException(
            'stream.truncated', 'not enough bytes for the bit stream header');
      }
      pos -= 7;
      accum = _readU64(pos) & 0x00FFFFFFFFFFFFFF;
      nbits = 56;
    }
    if (nbits < 56 || nbits >= 64) {
      throw LzfseException('stream.bad_header',
          'the accumulator holds $nbits bits, expected [56, 64)');
    }
    if ((accum >>> nbits) != 0) {
      throw const LzfseException('stream.bad_header',
          'the bits above the accumulator are not zero (corrupt stream)');
    }
  }

  /// 补满位（对应 `fse_in_checked_flush64`）。
  void flush() {
    final n = (63 - nbits) & ~7;
    if (n <= 0) return;
    final next = pos - (n >> 3);
    if (next < start) {
      throw const LzfseException(
          'stream.truncated', 'the bit stream ran past its start');
    }
    pos = next;
    accum = (accum << n) | _maskLsb(_readU64(pos), n);
    nbits += n;
  }

  /// 取出 [n] 位（对应 `fse_in_pull64`）。
  int pull(int n) {
    if (n > nbits) {
      throw LzfseException(
          'stream.truncated', 'needed $n bits but only $nbits are buffered');
    }
    nbits -= n;
    final result = accum >>> nbits;
    accum = _maskLsb(accum, nbits);
    return result;
  }

  /// 从 [at] 读 8 字节小端。
  ///
  /// **越界部分按 0 处理**：参考实现用 `memcpy` 读 8 字节，越界是未定义行为，
  /// 合法流里不会发生。这里显式补 0，让畸形流得到确定结果（后续校验会失败），
  /// 而不是靠运气。
  int _readU64(int at) {
    var value = 0;
    for (var i = 7; i >= 0; i--) {
      final index = at + i;
      value =
          (value << 8) | ((index >= 0 && index < buf.length) ? buf[index] : 0);
    }
    return value;
  }
}

/// 四张频率表。
class _FreqTables {
  final List<int> l;
  final List<int> m;
  final List<int> d;
  final List<int> literal;

  const _FreqTables(this.l, this.m, this.d, this.literal);
}

/// 按 `fse_init_decoder_table` 建表。
///
/// 频率和必须**恰好**等于 `nstates` —— 归一化的表一定满足；不等说明流坏了。
List<_FseEntry> _initDecoderTable(int nstates, int nsymbols, List<int> freq) {
  final table = List<_FseEntry>.filled(nstates, const _FseEntry(0, 0, 0),
      growable: false);
  final nClz = 32 - nstates.bitLength;
  var sum = 0;
  var index = 0;
  for (var symbol = 0; symbol < nsymbols; symbol++) {
    final f = freq[symbol];
    if (f == 0) continue;
    sum += f;
    if (sum > nstates) {
      throw LzfseException('block.bad_freq',
          'frequency sum exceeds $nstates states (corrupt header)');
    }
    final k = (32 - f.bitLength) - nClz;
    final j0 = ((2 * nstates) >>> k) - f;
    for (var j = 0; j < f; j++) {
      if (index >= nstates) {
        throw const LzfseException(
            'block.bad_freq', 'the decoder table overflowed');
      }
      table[index++] = j < j0
          ? _FseEntry(k, symbol, ((f + j) << k) - nstates)
          : _FseEntry(k - 1, symbol, (j - j0) << (k - 1));
    }
  }
  if (index != nstates) {
    throw LzfseException(
        'block.bad_freq', 'frequency sum is $index, expected exactly $nstates');
  }
  return table;
}

/// 按 `fse_init_value_decoder_table` 建表。
List<_FseValueEntry> _initValueTable(
  int nstates,
  int nsymbols,
  List<int> freq,
  List<int> symbolVBits,
  List<int> symbolVBase,
) {
  final table = List<_FseValueEntry>.filled(
      nstates, const _FseValueEntry(0, 0, 0, 0),
      growable: false);
  final nClz = 32 - nstates.bitLength;
  var index = 0;
  for (var symbol = 0; symbol < nsymbols; symbol++) {
    final f = freq[symbol];
    if (f == 0) continue;
    final k = (32 - f.bitLength) - nClz;
    final j0 = ((2 * nstates) >>> k) - f;
    final valueBits = symbolVBits[symbol];
    final vbase = symbolVBase[symbol];
    for (var j = 0; j < f; j++) {
      if (index >= nstates) {
        throw const LzfseException(
            'block.bad_freq', 'the value decoder table overflowed');
      }
      table[index++] = j < j0
          ? _FseValueEntry(
              k + valueBits, valueBits, ((f + j) << k) - nstates, vbase)
          : _FseValueEntry(
              k - 1 + valueBits, valueBits, (j - j0) << (k - 1), vbase);
    }
  }
  if (index != nstates) {
    throw LzfseException(
        'block.bad_freq', 'frequency sum is $index, expected exactly $nstates');
  }
  return table;
}

class _Decoder {
  final Uint8List src;
  int pos = 0;

  /// 输出缓冲。
  ///
  /// **必须是跨块共享的一整块** —— LZFSE 的匹配距离可以指向**前面块**的输出。
  /// 实测 Chess.app 的 1024×1024 图标：第二块的第一个符号是 `L=4 D=12339`，
  /// 而该块自身的输出才写了 4 字节；只有在「整个流是一块连续输出」的前提下
  /// 这个距离才合法。按块独立缓冲会把这一步误判成越界。
  Uint8List _output = Uint8List(0);
  int _length = 0;

  _Decoder(this.src);

  Uint8List run() {
    // 首块大小未知，先给一个不算大的起点，之后按需翻倍。
    _output = Uint8List(64 * 1024);
    while (true) {
      if (pos + 4 > src.length) {
        throw const LzfseException('stream.truncated',
            'the stream ended without an end-of-stream block');
      }
      final magic = _readU32(pos);
      switch (magic) {
        case _Magic.endOfStream:
          pos += 4;
          return Uint8List.sublistView(_output, 0, _length);
        case _Magic.uncompressed:
          _decodeUncompressed();
        case _Magic.compressedV2:
          _decodeCompressedV2();
        case _Magic.compressedV1:
          throw const LzfseException(
              'block.unsupported_v1',
              'this stream uses a `bvx1` block (LZFSE with uncompressed '
                  'tables). No tool in the wild emits it and no sample was '
                  'available to verify an implementation, so it is reported '
                  'instead of guessed at');
        case _Magic.lzvn:
          throw const LzfseException(
              'block.unsupported_lzvn',
              'this stream uses a `bvxn` block (LZVN, a different algorithm). '
                  'In real Assets.car files only vector payloads used it; none of '
                  'the raster images in the samples did');
        default:
          throw LzfseException('block.bad_magic',
              'unknown block magic 0x${magic.toRadixString(16)} at $pos');
      }
      if (_length > lzfseMaxOutputBytes) {
        throw LzfseException('output.too_large',
            'the decoded output exceeded $lzfseMaxOutputBytes bytes');
      }
    }
  }

  /// 扩到至少 [need] 字节。
  void _ensure(int need) {
    if (need <= _output.length) return;
    if (need > lzfseMaxOutputBytes) {
      throw LzfseException('output.too_large',
          'the decoded output would exceed $lzfseMaxOutputBytes bytes');
    }
    var capacity = _output.isEmpty ? 64 * 1024 : _output.length;
    while (capacity < need) {
      capacity *= 2;
    }
    if (capacity > lzfseMaxOutputBytes) capacity = need;
    final next = Uint8List(capacity);
    next.setRange(0, _length, _output);
    _output = next;
  }

  /// `bvx-`：`u32 n_raw_bytes` 后跟原始字节。
  void _decodeUncompressed() {
    if (pos + 8 > src.length) {
      throw const LzfseException(
          'stream.truncated', 'an uncompressed block header is truncated');
    }
    final n = _readU32(pos + 4);
    final start = pos + 8;
    if (start + n > src.length) {
      throw LzfseException(
          'stream.truncated',
          'an uncompressed block declares $n bytes but only '
              '${src.length - start} remain');
    }
    _ensure(_length + n);
    _output.setRange(_length, _length + n, src, start);
    _length += n;
    pos = start + n;
  }

  /// `bvx2`：解析头（含压缩的频率表），再解字面量流与 L/M/D 流。
  void _decodeCompressedV2() {
    const headerFixed = 8 + 24; // magic + n_raw_bytes + packed_fields[3]
    if (pos + headerFixed > src.length) {
      throw const LzfseException(
          'stream.truncated', 'a compressed block header is truncated');
    }
    final blockStart = pos;
    final nRawBytes = _readU32(blockStart + 4);
    final pf0 = _readU64(blockStart + 8);
    final pf1 = _readU64(blockStart + 16);
    final pf2 = _readU64(blockStart + 24);

    final nLiterals = _field(pf0, 0, 20);
    final nLiteralPayloadBytes = _field(pf0, 20, 20);
    final nMatches = _field(pf0, 40, 20);
    final literalBits = _field(pf0, 60, 3) - 7;
    final literalStates = [
      _field(pf1, 0, 10),
      _field(pf1, 10, 10),
      _field(pf1, 20, 10),
      _field(pf1, 30, 10),
    ];
    final nLmdPayloadBytes = _field(pf1, 40, 20);
    final lmdBits = _field(pf1, 60, 3) - 7;
    final headerSize = _field(pf2, 0, 32);
    var lState = _field(pf2, 32, 10);
    var mState = _field(pf2, 42, 10);
    var dState = _field(pf2, 52, 10);

    if (headerSize < headerFixed || headerSize > src.length - blockStart) {
      throw LzfseException(
          'block.bad_header',
          'the header declares $headerSize bytes, which does not fit the block '
              '(stream has ${src.length - blockStart})');
    }
    final literalsStart = blockStart + headerSize;
    final lmdStart = literalsStart + nLiteralPayloadBytes;
    final blockEnd = lmdStart + nLmdPayloadBytes;
    if (blockEnd > src.length) {
      throw LzfseException('stream.truncated',
          'the block payloads end at $blockEnd, past the stream (${src.length})');
    }
    if (nRawBytes > lzfseMaxOutputBytes) {
      throw LzfseException('block.too_large',
          'the block declares $nRawBytes decoded bytes, above the cap');
    }
    if (nLiterals % 4 != 0) {
      throw LzfseException(
          'block.bad_header',
          'n_literals=$nLiterals is not a multiple of 4 (the literal stream is '
              'interleaved four ways)');
    }
    if (nLiterals > nRawBytes) {
      throw LzfseException('block.bad_header',
          'n_literals=$nLiterals exceeds n_raw_bytes=$nRawBytes');
    }

    final freq =
        _readFreqTables(blockStart + headerFixed, blockStart + headerSize);

    final literalTable =
        _initDecoderTable(_literalStates, _literalSymbols, freq.literal);
    final lTable =
        _initValueTable(_lStates, _lSymbols, freq.l, _lExtraBits, _lBaseValue);
    final mTable =
        _initValueTable(_mStates, _mSymbols, freq.m, _mExtraBits, _mBaseValue);
    final dTable =
        _initValueTable(_dStates, _dSymbols, freq.d, _dExtraBits, _dBaseValue);

    for (var i = 0; i < 4; i++) {
      if (literalStates[i] >= _literalStates) {
        throw LzfseException('block.bad_header',
            'literal state ${literalStates[i]} is out of range');
      }
    }
    if (lState >= _lStates || mState >= _mStates || dState >= _dStates) {
      throw const LzfseException(
          'block.bad_header', 'an L/M/D initial state is out of range');
    }

    // ---- 字面量流（四个状态交错，每次 flush 后解四个符号）----
    final literals = Uint8List(nLiterals);
    final literalReader = _BitReader(src, lmdStart, 0)..init(literalBits);
    final states = List<int>.of(literalStates);
    for (var i = 0; i < nLiterals; i += 4) {
      literalReader.flush();
      for (var k = 0; k < 4; k++) {
        final entry = literalTable[states[k]];
        states[k] = entry.delta + literalReader.pull(entry.k);
        if (states[k] >= _literalStates || states[k] < 0) {
          throw const LzfseException(
              'stream.corrupt', 'a literal state moved out of range');
        }
        literals[i + k] = entry.symbol;
      }
    }

    // ---- L/M/D 流 ----
    //
    // `dst` 是**整个输出流**的偏移，不是块内偏移：匹配距离可以指向前面块的
    // 输出（实测 Chess 的图标第二块首个符号就是 `L=4 D=12339`）。
    final blockStartOut = _length;
    _ensure(blockStartOut + nRawBytes);
    final lmdReader = _BitReader(src, blockEnd, lmdStart)..init(lmdBits);
    var dst = blockStartOut;
    var lit = 0;
    var distance = -1;

    for (var symbol = 0; symbol < nMatches; symbol++) {
      lmdReader.flush();

      // L
      final lEntry = lTable[lState];
      final lBits = lmdReader.pull(lEntry.totalBits);
      final l = lEntry.vbase + _maskLsb(lBits, lEntry.valueBits);
      lState = lEntry.delta + (lBits >>> lEntry.valueBits);

      // M
      final mEntry = mTable[mState];
      final mBits = lmdReader.pull(mEntry.totalBits);
      final m = mEntry.vbase + _maskLsb(mBits, mEntry.valueBits);
      mState = mEntry.delta + (mBits >>> mEntry.valueBits);

      // D（0 表示沿用上一个距离）
      final dEntry = dTable[dState];
      final dBits = lmdReader.pull(dEntry.totalBits);
      final newD = dEntry.vbase + _maskLsb(dBits, dEntry.valueBits);
      dState = dEntry.delta + (dBits >>> dEntry.valueBits);
      if (newD != 0) distance = newD;

      if (lState >= _lStates || mState >= _mStates || dState >= _dStates) {
        throw const LzfseException(
            'stream.corrupt', 'an L/M/D state moved out of range');
      }
      if (l < 0 || m < 0) {
        throw const LzfseException('stream.corrupt', 'a negative L or M value');
      }
      if (lit + l > nLiterals) {
        throw LzfseException(
            'stream.corrupt',
            'the match stream consumes more literals than the block holds '
                '(${lit + l} > $nLiterals)');
      }
      // 上界用**全局** dst：允许回溯到前面块的输出。
      if (distance <= 0 || distance > dst + l) {
        throw LzfseException('stream.corrupt',
            'match distance $distance is out of range at output offset $dst');
      }
      if (dst + l + m > blockStartOut + nRawBytes) {
        throw LzfseException('block.size_mismatch',
            'the match stream writes past the declared $nRawBytes decoded bytes');
      }
      _output.setRange(dst, dst + l, literals, lit);
      dst += l;
      lit += l;
      // 逐字节回溯：距离可能小于长度（重叠拷贝），不能用 setRange。
      for (var i = 0; i < m; i++) {
        _output[dst] = _output[dst - distance];
        dst++;
      }
    }

    if (dst - blockStartOut != nRawBytes) {
      throw LzfseException(
          'block.size_mismatch',
          'the block decoded ${dst - blockStartOut} bytes but declared '
              '$nRawBytes');
    }
    _length = dst;
    pos = blockEnd;
  }

  _FreqTables _readFreqTables(int from, int to) {
    const total = _lSymbols + _mSymbols + _dSymbols + _literalSymbols; // 360
    final flat = List<int>.filled(total, 0);
    if (to == from) {
      // 表被省略：全 0 频率。归一化表不会这样，直接判坏更安全。
      throw const LzfseException(
          'block.bad_freq', 'the frequency tables are missing from the header');
    }
    var accum = 0;
    var accumNbits = 0;
    var cursor = from;
    for (var i = 0; i < total; i++) {
      while (cursor < to && accumNbits + 8 <= 32) {
        accum |= src[cursor] << accumNbits;
        accumNbits += 8;
        cursor++;
      }
      final b = accum & 31;
      final nbits = _freqNbits[b];
      final int value;
      if (nbits == 8) {
        value = 8 + ((accum >>> 4) & 0xf);
      } else if (nbits == 14) {
        value = 24 + ((accum >>> 4) & 0x3ff);
      } else {
        value = _freqValue[b];
      }
      if (nbits > accumNbits) {
        throw const LzfseException(
            'block.bad_freq', 'the frequency table ran out of bits');
      }
      flat[i] = value;
      accum = accum >>> nbits;
      accumNbits -= nbits;
    }
    if (accumNbits >= 8 || cursor != to) {
      throw LzfseException(
          'block.bad_freq',
          'the frequency tables did not end exactly at the header boundary '
              '($accumNbits bits left, ${to - cursor} bytes left)');
    }
    return _FreqTables(
      flat.sublist(0, _lSymbols),
      flat.sublist(_lSymbols, _lSymbols + _mSymbols),
      flat.sublist(_lSymbols + _mSymbols, _lSymbols + _mSymbols + _dSymbols),
      flat.sublist(_lSymbols + _mSymbols + _dSymbols),
    );
  }

  int _readU32(int at) {
    if (at + 4 > src.length) {
      throw const LzfseException(
          'stream.truncated', 'a 32-bit field is truncated');
    }
    return src[at] |
        (src[at + 1] << 8) |
        (src[at + 2] << 16) |
        (src[at + 3] << 24);
  }

  int _readU64(int at) {
    var value = 0;
    for (var i = 7; i >= 0; i--) {
      final index = at + i;
      value =
          (value << 8) | ((index >= 0 && index < src.length) ? src[index] : 0);
    }
    return value;
  }
}
