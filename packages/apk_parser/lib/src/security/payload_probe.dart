import 'dart:math' as math;
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

/// 载荷探测：只看**有界头部字节**，回答「这段内容像什么」。
///
/// 边界（刻意守住）：
/// - **不执行、不解压、不落盘**：ZIP/APK/JAR 只认文件头，不展开条目；
/// - 只消化调用方已经读好的 [PayloadProbeInput.headBytes]（≤ `maxHeadBytes`），
///   本层不碰归档、不发起 IO —— 读多少、读哪个由调用方决定；
/// - 结论只到「像什么」+ 稳定 code，不判断恶意性。`payload.encrypted` 只
///   说明「头部高熵、可打印字符少」，加壳的正常库同样会命中。
///
/// 为什么按「候选清单 + 预算」而不是「遍历包内所有条目」：探测成本与条目数
/// 成正比，而报告必须能解释「哪些没看」。因此超出预算时 `complete=false`
/// 并给出 note code，而不是静默少看几条。
class PayloadProbe {
  PayloadProbe._();

  /// 最多探测多少条（默认 256）。
  static const int defaultMaxEntries = 256;

  /// 单条最多看多少头部字节（默认 4 KiB）。
  static const int defaultMaxHeadBytes = 4096;

  /// 全部条目合计最多看多少字节（默认 1 MiB）。
  ///
  /// 与 256 × 4 KiB 相等：上限之间不互相打架，否则「条数没超、字节超了」
  /// 这种组合会让默认值自相矛盾。
  static const int defaultMaxTotalBytes = 1024 * 1024;

  /// 条目数超限时的 note code。
  static const String entriesTruncatedCode = 'payload.entries_truncated';

  /// 字节预算超限时的 note code。
  static const String bytesTruncatedCode = 'payload.bytes_truncated';

  /// 头部读不出来（空字节）时的 note code。
  ///
  /// 与「探测了但没发现」分开：空头部说明**没看到内容**，不能算作阴性。
  static const String headUnavailableCode = 'payload.head_unavailable';

  /// 判为「高熵」的阈值（Shannon 熵，0–8）。
  static const double encryptedEntropyThreshold = 7.5;

  /// 判为「可打印 ASCII 少」的占比上限。
  ///
  /// 取 0.45 而不是更小的值：均匀随机字节里可打印 ASCII（0x20–0x7E）占
  /// 95/256 ≈ 37%，加上制表/换行/回车约 38% —— 阈值若设成 0.3，**真正的
  /// 加密载荷永远不会命中**。文本接近 100%，正常代码/库在 50%–70%，
  /// 因此 0.45 是「明显不像文本」的界线。
  static const double encryptedPrintableRatio = 0.45;

  /// 计算熵所需的最小头部长度。
  ///
  /// 256 字节的样本最多只能取到 8 bit/byte；更短的头部（例如 16 字节）
  /// 熵的上限由样本量决定（log2(16)=4），按 7.5 判会永远不命中。
  static const int minBytesForEntropy = 256;

  /// 路径是否落在 `assets/` 下（大小写不敏感，`assets/` 是包内固定目录）。
  static bool _inAssets(String path) =>
      path.toLowerCase().startsWith('assets/');

  /// 扫描一批有界头部，产出负载信号。
  ///
  /// 按 [inputs] 的**给定顺序**消费预算：调用方应按重要性排序（例如先
  /// `assets/` 下的可执行类），本层不做排序 —— 排序依据属于业务决策。
  static PayloadProbeResult scan(
    List<PayloadProbeInput> inputs, {
    int maxEntries = defaultMaxEntries,
    int maxHeadBytes = defaultMaxHeadBytes,
    int maxTotalBytes = defaultMaxTotalBytes,
  }) {
    final signals = <PayloadSignal>[];
    final noteCodes = <String>{};

    final entryLimit = maxEntries < 0 ? 0 : maxEntries;
    final headLimit = maxHeadBytes < 0 ? 0 : maxHeadBytes;
    final byteLimit = maxTotalBytes < 0 ? 0 : maxTotalBytes;

    var probed = 0;
    var consumedBytes = 0;
    var complete = true;

    for (final input in inputs) {
      if (probed >= entryLimit) {
        complete = false;
        noteCodes.add(entriesTruncatedCode);
        break;
      }
      if (input.headBytes.isEmpty) {
        // 没看到内容就不是阴性结论；不计入 entriesProbed。
        noteCodes.add(headUnavailableCode);
        continue;
      }
      // 调用方给的头部可能超过 maxHeadBytes：按上限截断。这里不额外记 note ——
      // 截断后的字节仍属于「预算允许看的部分」，而超预算的那部分由下面的
      // 字节预算负责表达。
      final length = input.headBytes.length < headLimit
          ? input.headBytes.length
          : headLimit;
      if (length == 0) {
        // headLimit 为 0：预算不允许看任何字节。
        complete = false;
        noteCodes.add(bytesTruncatedCode);
        break;
      }
      if (consumedBytes + length > byteLimit) {
        complete = false;
        noteCodes.add(bytesTruncatedCode);
        break;
      }
      consumedBytes += length;
      final head = length == input.headBytes.length
          ? input.headBytes
          : Uint8List.sublistView(input.headBytes, 0, length);
      probed++;
      _probeOne(input: input, head: head, out: signals);
    }

    return PayloadProbeResult(
      signals: signals,
      entriesProbed: probed,
      entriesTotal: inputs.length,
      complete: complete,
      noteCodes: noteCodes.toList()..sort(),
    );
  }

  /// 探测单条头部，把命中的稳定 code 追加进 [out]。
  static void _probeOne({
    required PayloadProbeInput input,
    required Uint8List head,
    required List<PayloadSignal> out,
  }) {
    final expected = _expectedKind(input.declaredExtension);
    final kind = _sniff(head, input.declaredExtension);
    final entropy = _entropy(head);
    final printableRatio = _printableRatio(head);
    final inAssets = _inAssets(input.path);
    // 声明大小可能撒谎（中央目录可伪造），信号里保留它并标注来源是「声明」；
    // 为 0 时退回头部长度，至少不给出「0 字节」的假事实。
    final sizeBytes = input.sizeBytes > 0 ? input.sizeBytes : head.length;

    void add(
      String code, {
      Map<String, Object> args = const {},
      PayloadKind? kindOverride,
    }) {
      out.add(PayloadSignal(
        path: input.path,
        kind: kindOverride ?? kind,
        code: code,
        sizeBytes: sizeBytes,
        entropy: entropy,
        args: args,
      ));
    }

    // 扩展名与魔数不符：只在一侧能确定时报告。
    // 「魔数认不出」（unknown）不算「不符」——加密/自研容器的头部本来就没有
    // 已知魔数，那种情况交给 `payload.encrypted` 表达。
    if (expected != null && kind != PayloadKind.unknown && kind != expected) {
      add('payload.magicMismatch', args: {
        'declared': expected.name,
        'detected': kind.name,
      });
    }

    // `assets/` 里的 ZIP/APK/JAR：包中包，常见于「释放到私有目录再加载」。
    if (inAssets &&
        (kind == PayloadKind.zip ||
            kind == PayloadKind.apk ||
            kind == PayloadKind.jar)) {
      add('payload.nestedArchive');
    }

    // 高熵 + 可打印字符少：加密/压缩过的载荷（或加壳的库）。
    if (head.length >= minBytesForEntropy &&
        entropy >= encryptedEntropyThreshold &&
        printableRatio <= encryptedPrintableRatio) {
      add('payload.encrypted', args: {
        'entropy': double.parse(entropy.toStringAsFixed(2)),
        'printableRatio': double.parse(printableRatio.toStringAsFixed(2)),
        'headBytes': head.length,
      });
    }

    // `assets/` 下的可执行内容：DEX/ELF/Mach-O/脚本。它们在包里却不在
    // 代码该在的位置，加载它们必然要经过文件写入或内存映射。
    if (inAssets &&
        (kind == PayloadKind.dex ||
            kind == PayloadKind.elf ||
            kind == PayloadKind.machO ||
            kind == PayloadKind.script)) {
      add('payload.executableInAssets');
    }
  }

  /// 按魔数判断内容类型。
  ///
  /// ZIP 系（ZIP/APK/JAR）的细分只能靠扩展名 —— 三者内容上无法区分；
  /// 这也是 `payload.magicMismatch` 对 `.apk` 出现 ZIP 头不报错的原因。
  static PayloadKind _sniff(Uint8List head, String? extension) {
    if (_isDex(head)) return PayloadKind.dex;
    if (_startsWith(head, const [0x50, 0x4B, 0x03, 0x04])) {
      return switch (extension?.toLowerCase()) {
        '.apk' => PayloadKind.apk,
        '.jar' => PayloadKind.jar,
        _ => PayloadKind.zip,
      };
    }
    if (_startsWith(head, const [0x7F, 0x45, 0x4C, 0x46])) {
      return PayloadKind.elf;
    }
    if (_isMachO(head)) return PayloadKind.machO;
    // `#!`：shell / python / perl 脚本的第一行都是 shebang。
    if (_startsWith(head, const [0x23, 0x21])) return PayloadKind.script;
    return PayloadKind.unknown;
  }

  /// 扩展名「应该」对应哪种内容；未登记扩展名时为 `null`（不做不符判定）。
  static PayloadKind? _expectedKind(String? extension) {
    return switch (extension?.toLowerCase()) {
      '.dex' => PayloadKind.dex,
      '.zip' => PayloadKind.zip,
      '.apk' => PayloadKind.apk,
      '.jar' => PayloadKind.jar,
      '.so' || '.elf' => PayloadKind.elf,
      '.dylib' => PayloadKind.machO,
      '.sh' ||
      '.bash' ||
      '.py' ||
      '.lua' ||
      '.pl' ||
      '.rb' ||
      '.js' =>
        PayloadKind.script,
      _ => null,
    };
  }

  /// `dex\n0xx\0`。
  static bool _isDex(Uint8List head) {
    if (head.length < 4) return false;
    if (!(head[0] == 0x64 && head[1] == 0x65 && head[2] == 0x78)) return false;
    if (head[3] != 0x0A) return false;
    // 版本三位数字 + NUL；头部不足 8 字节时只看前缀（截断的输入不算错）。
    if (head.length < 8) return true;
    if (head[7] != 0x00) return false;
    for (var i = 4; i < 7; i++) {
      if (head[i] < 0x30 || head[i] > 0x39) return false;
    }
    return true;
  }

  /// Mach-O（含 fat 容器）。
  static bool _isMachO(Uint8List head) {
    for (final magic in _machOMagics) {
      if (_startsWith(head, magic)) return true;
    }
    if (_startsWith(head, const [0xCA, 0xFE, 0xBA, 0xBE])) {
      // 这个 magic 同时属于 Java class。Mach-O fat 紧随其后的是架构条数
      // （1..几十），Java class 的下一个 u32 是 minor_version（几乎总是 0）。
      // 只在条数看起来合理时才认 fat，避免把 .class 当成 Mach-O。
      return _fatArchCount(head, 4, bigEndian: true);
    }
    if (_startsWith(head, const [0xBE, 0xBA, 0xFE, 0xCA])) {
      return _fatArchCount(head, 4, bigEndian: false);
    }
    return false;
  }

  static const List<List<int>> _machOMagics = [
    [0xFE, 0xED, 0xFA, 0xCE], // MH_MAGIC（32 位，大端）
    [0xFE, 0xED, 0xFA, 0xCF], // MH_MAGIC_64
    [0xCE, 0xFA, 0xED, 0xFE], // MH_CIGAM（32 位，小端）
    [0xCF, 0xFA, 0xED, 0xFE], // MH_CIGAM_64
  ];

  /// fat 头里的 `nfat_arch` 是否落在合理区间（1..30）。
  static bool _fatArchCount(Uint8List head, int offset,
      {required bool bigEndian}) {
    if (offset + 4 > head.length) return false;
    final count = bigEndian
        ? (head[offset] << 24) |
            (head[offset + 1] << 16) |
            (head[offset + 2] << 8) |
            head[offset + 3]
        : (head[offset + 3] << 24) |
            (head[offset + 2] << 16) |
            (head[offset + 1] << 8) |
            head[offset];
    return count >= 1 && count <= 30;
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  /// 头部字节的 Shannon 熵（0–8）。空输入为 0。
  static double _entropy(Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    final counts = List<int>.filled(256, 0);
    for (final byte in bytes) {
      counts[byte]++;
    }
    var value = 0.0;
    for (final count in counts) {
      if (count == 0) continue;
      final probability = count / bytes.length;
      value -= probability * (math.log(probability) / math.ln2);
    }
    return value;
  }

  /// 可打印 ASCII（含制表/换行/回车）占比。
  static double _printableRatio(Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    var printable = 0;
    for (final byte in bytes) {
      if ((byte >= 0x20 && byte <= 0x7E) ||
          byte == 0x09 ||
          byte == 0x0A ||
          byte == 0x0D) {
        printable++;
      }
    }
    return printable / bytes.length;
  }
}
