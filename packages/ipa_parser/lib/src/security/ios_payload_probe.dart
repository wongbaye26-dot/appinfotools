import 'dart:math' as math;
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

/// IPA 载荷探测：只看**有界头部字节**的类型/熵判定。
///
/// ## 与制品清单的分工
///
/// 清单（`IosArtifactInventoryScanner`）回答「有哪些文件、在哪」；
/// 这里回答「文件内容像什么」。两者都不读整文件：调用方只提供最多
/// [defaultMaxHeadBytes] 字节的头部，本类既不打开归档也不解压。
///
/// ## 与 Android 侧同一套判据
///
/// 稳定 code、note code、熵阈值、可打印字符门槛、参数名都与
/// `apk_parser` 的 `PayloadProbe` 一致 —— 规则层要能对两端用同一套判断：
///
/// * `payload.magicMismatch`（`declared` / `detected`）
/// * `payload.nestedArchive`（**只在 `assets/` 下**产出，与 Android 同口径）
/// * `payload.encrypted`（`entropy` / `printableRatio` / `headBytes`）
/// * `payload.executableInAssets`（DEX/ELF/Mach-O/脚本）
/// * note：`payload.entries_truncated` / `payload.bytes_truncated` /
///   `payload.head_unavailable`
///
/// ## iOS 的事实边界
///
/// * iOS **没有 DEX 字节码**：`PayloadKind.dex` 在 IPA 里只可能是夹带的
///   Android 载荷（跨平台投递/打包工具残留），出现即值得看，但它不是这台
///   设备上会被执行的东西。
/// * `cryptid`（Mach-O 加密标志）在 `LC_ENCRYPTION_INFO` 里，属于
///   `MachOParser` 的 load command 解析，本类只看头部，**不声称**能判
///   「App Store 加密/加壳」；`payload.encrypted` 只说明「这块字节看不清」。
/// * `assets/` 的判定按**路径段**而不是前缀：IPA 里它在
///   `Payload/Foo.app/assets/…`（Android 的 assets 在归档根）。
/// * 正常 ZIP/压缩资源的头部同样可能命中 `payload.encrypted`（4 KiB 压缩
///   流的熵本来就接近 8）。它只是弱信号，规则层不得单独据此判级。
class IosPayloadProbe {
  IosPayloadProbe._();

  /// 最多探测多少条（默认 256），与 Android 侧一致。
  static const int defaultMaxEntries = 256;

  /// 单条最多看多少头部字节（默认 4 KiB）。
  static const int defaultMaxHeadBytes = 4096;

  /// 全部条目合计最多看多少字节（默认 1 MiB）。
  ///
  /// 与 256 × 4 KiB 相等：两个上限不互相打架。
  static const int defaultMaxTotalBytes = 1024 * 1024;

  /// 条目数超限时的 note code。
  static const String entriesTruncatedCode = 'payload.entries_truncated';

  /// 字节预算超限（或预算为 0）时的 note code。
  static const String bytesTruncatedCode = 'payload.bytes_truncated';

  /// 头部读不出来（空字节）时的 note code。
  ///
  /// 与「探测了但没发现」分开：空头部说明**没看到内容**，不能算作阴性。
  static const String headUnavailableCode = 'payload.head_unavailable';

  /// 判为「高熵」的阈值（Shannon 熵，0–8），与 Android 侧一致。
  static const double encryptedEntropyThreshold = 7.5;

  /// 判为「可打印 ASCII 少」的占比上限，与 Android 侧一致。
  ///
  /// 均匀随机字节里可打印 ASCII 约占 37%，文本接近 100%，正常代码/库在
  /// 50%–70%：0.45 是「明显不像文本」的界线。
  static const double encryptedPrintableRatio = 0.45;

  /// 计算熵所需的最小头部长度（更短的样本熵上限由样本量决定）。
  static const int minBytesForEntropy = 256;

  /// 探测给定的头部字节，产出信号。
  ///
  /// 按 [inputs] 的**给定顺序**消费预算：调用方应按重要性排序，本层不排序。
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
    // 声明大小可能撒谎；为 0 时退回头部长度，至少不给出「0 字节」的假事实。
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
    // 「魔数认不出」（unknown）不算「不符」—— 加密/自研容器的头部本来就没有
    // 已知魔数，那种情况交给 `payload.encrypted` 表达。
    if (expected != null && kind != PayloadKind.unknown && kind != expected) {
      add('payload.magicMismatch', args: {
        'declared': expected.name,
        'detected': kind.name,
      });
    }

    // `assets/` 里的 ZIP/APK/JAR：包中包，常见于「释放到私有目录再加载」。
    // 与 Android 同口径：只在 assets 下产出（`Frameworks/` 里的资源归档
    // 不标，避免把正常的压缩资源算成载荷）。
    if (inAssets &&
        (kind == PayloadKind.zip ||
            kind == PayloadKind.apk ||
            kind == PayloadKind.jar)) {
      add('payload.nestedArchive');
    }

    // 高熵 + 可打印字符少：加密/压缩过的载荷（或加壳的库）。弱信号。
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
  /// ZIP 系（ZIP/APK/JAR）内容上无法区分，细分优先看首个本地文件头里的
  /// 条目名（`AndroidManifest.xml` / `META-INF/`），再看声明扩展名 ——
  /// 这样无扩展名的 APK 夹带也能被认出来；扩展名一致时不会被误判。
  static PayloadKind _sniff(Uint8List head, String? extension) {
    final declared = _normalizeExtension(extension);
    if (_isDex(head)) return PayloadKind.dex;
    if (_isZip(head)) {
      final firstEntry = _firstZipEntryName(head);
      if (firstEntry != null) {
        if (firstEntry.startsWith('AndroidManifest.xml')) {
          return PayloadKind.apk;
        }
        if (firstEntry.startsWith('META-INF/')) return PayloadKind.jar;
      }
      return switch (declared) {
        'apk' => PayloadKind.apk,
        'jar' => PayloadKind.jar,
        _ => PayloadKind.zip,
      };
    }
    if (_startsWith(head, const [0x7F, 0x45, 0x4C, 0x46])) {
      return PayloadKind.elf;
    }
    if (_isMachO(head)) return PayloadKind.machO;
    // `#!`：shell / python / perl / node 脚本的第一行都是 shebang。
    if (_startsWith(head, const [0x23, 0x21])) return PayloadKind.script;
    // 没有 shebang 的 `.js`：内容是文本才认脚本，避免把二进制误当脚本。
    if (declared != null &&
        _scriptExtensions.contains(declared) &&
        _looksLikeText(head)) {
      return PayloadKind.script;
    }
    return PayloadKind.unknown;
  }

  /// 扩展名「应该」对应哪种内容；未登记扩展名时为 `null`（不做不符判定）。
  static PayloadKind? _expectedKind(String? extension) {
    return switch (_normalizeExtension(extension)) {
      'dex' => PayloadKind.dex,
      'zip' => PayloadKind.zip,
      'apk' => PayloadKind.apk,
      'jar' => PayloadKind.jar,
      'so' || 'elf' => PayloadKind.elf,
      'dylib' || 'o' || 'macho' || 'bundle' => PayloadKind.machO,
      // 与 Android 侧同一份脚本扩展名清单（`.js` 等按脚本预期）。
      'sh' ||
      'bash' ||
      'py' ||
      'lua' ||
      'pl' ||
      'rb' ||
      'js' =>
        PayloadKind.script,
      _ => null,
    };
  }

  /// 路径是否落在 `assets/` 下（按**路径段**判：IPA 里 assets 在 bundle 内）。
  static bool _inAssets(String path) {
    for (final segment in path.split('/')) {
      if (segment.toLowerCase() == 'assets') return true;
    }
    return false;
  }

  static String? _normalizeExtension(String? value) {
    if (value == null) return null;
    var ext = value.trim().toLowerCase();
    if (ext.startsWith('.')) ext = ext.substring(1);
    return ext.isEmpty ? null : ext;
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

  static bool _isZip(Uint8List head) {
    if (head.length < 4) return false;
    if (head[0] != 0x50 || head[1] != 0x4B) return false;
    // 0x0304 普通条目、0x0506 空归档、0x0708 流式条目。
    return (head[2] == 0x03 && head[3] == 0x04) ||
        (head[2] == 0x05 && head[3] == 0x06) ||
        (head[2] == 0x07 && head[3] == 0x08);
  }

  /// Mach-O（含 fat 容器）。
  static bool _isMachO(Uint8List head) {
    for (final magic in _machOMagics) {
      if (_startsWith(head, magic)) return true;
    }
    if (_startsWith(head, const [0xCA, 0xFE, 0xBA, 0xBE])) {
      // 这个 magic 同时属于 Java class。Mach-O fat 紧随其后的是架构条数
      // （1..几十），Java class 的下一个 u32 是 minor_version（几乎总是 0）。
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
  static bool _fatArchCount(
    Uint8List head,
    int offset, {
    required bool bigEndian,
  }) {
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

  /// ZIP 首个本地文件头里的条目名；不是本地文件头或越界时返回 `null`。
  ///
  /// 只用于把 ZIP 家族细分成 apk/jar/zip，**不**遍历中央目录
  /// （那需要整文件，超出本类「只看头部」的边界）。
  static String? _firstZipEntryName(Uint8List head) {
    if (head.length < 30) return null;
    if (!(head[0] == 0x50 &&
        head[1] == 0x4B &&
        head[2] == 0x03 &&
        head[3] == 0x04)) {
      return null;
    }
    final nameLength = head[26] | (head[27] << 8);
    final end = 30 + nameLength;
    if (nameLength == 0 || end > head.length) return null;
    // 条目名是字节串；这里只做前缀比较，用 Latin-1 逐字节映射即可。
    return String.fromCharCodes(head.sublist(30, end));
  }

  /// 文本粗判：可打印字节占比高、且没有 NUL。
  static bool _looksLikeText(Uint8List head) {
    final limit = math.min(head.length, 512);
    if (limit == 0) return false;
    for (var i = 0; i < limit; i++) {
      if (head[i] == 0) return false;
    }
    return _printableRatio(Uint8List.sublistView(head, 0, limit)) >= 0.9;
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

  static const Set<String> _scriptExtensions = {
    'js',
    'mjs',
    'cjs',
    'ts',
    'lua',
    'py',
    'rb',
    'pl',
    'php',
    'sh',
    'bash',
    'zsh',
    'ps1',
    'bat',
    'cmd',
  };
}
