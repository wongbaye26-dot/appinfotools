import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

import 'code_markers.dart';
import 'sdk_catalog.dart';

/// 一个待扫描的 DEX 文件：名字 + 字节。
///
/// 与容器层的 `DexEntry`（只有名字与声明大小）不是一回事：那个描述「归档里
/// 有什么」，这个携带「要扫的内容」。两者刻意分开 —— 扫描器的输入是内容，
/// 不是目录条目。
class DexBytes {
  /// 归档内名字，例如 `classes.dex`，同时是证据位置。
  final String name;

  final Uint8List bytes;

  const DexBytes(this.name, this.bytes);
}

/// 从字符串里命中的一类代码线索。
class CodeClue {
  /// 标记 id，例如 `ocr-mlkit`。与规则引擎的输入一一对应。
  final String markerId;

  final SecurityCategory category;

  /// 命中标记的说明（面向最终用户，例如「ML Kit 文字识别 SDK」）。
  final String description;

  /// 命中的原文（去重、限量）—— 这就是证据。
  final List<String> samples;

  /// 出现在哪些 DEX 里。
  final List<String> dexNames;

  const CodeClue({
    required this.markerId,
    required this.category,
    required this.description,
    required this.samples,
    required this.dexNames,
  });
}

/// DEX 字符串扫描结果。
/// 一条「被扫描预算挡掉」的记录。
///
/// [scannedBytes] 为 0 表示整份都没扫（总预算用尽）；大于 0 表示只扫了前
/// 这么多字节。
class DexBudgetSkip {
  final String name;
  final int scannedBytes;

  /// 该 DEX 的实际大小。
  final int totalBytes;

  const DexBudgetSkip({
    required this.name,
    required this.scannedBytes,
    required this.totalBytes,
  });

  /// 扫描覆盖率（0–100 的整数）。`totalBytes` 为 0 时按 0 算。
  ///
  /// **向下取整，且部分扫描绝不给 100%。** 一个比上限只大 22 字节的 DEX，
  /// 用 `round()` 会算出 100 —— 界面上就是「只扫了约 100%」，而它恰恰是
  /// 未覆盖的那一条。宁可显示 99。
  int get percent {
    if (totalBytes <= 0) return 0;
    if (scannedBytes >= totalBytes) return 100;
    final value = (scannedBytes * 100 / totalBytes).floor();
    return value >= 100 ? 99 : value;
  }

  @override
  String toString() => '$name scanned $scannedBytes of $totalBytes bytes';
}

class DexScanResult {
  final List<CodeClue> clues;

  /// 从字符串中提取到的 URL 主机名 / 裸域名（去重、限量）。
  final List<String> domains;

  /// 提取到的 IPv4 字面量。
  final List<String> ips;

  /// 实际扫描的 DEX 数与字节数。
  final int scannedDexCount;
  final int scannedBytes;

  /// 命中的第三方**服务类** SDK（见 `sdk_catalog.dart`）。
  ///
  /// 在**同一次字符串遍历**里累积：真实包的 DEX 合计 400+ MiB，
  /// 为了这一步再解码一遍不划算。
  final List<SdkHit> sdkHits;

  /// 因预算被跳过的 DEX。**必须**出现在报告的未覆盖范围里。
  ///
  /// 是结构化记录而不是一句英文 —— 界面上要按语言拼出「只扫了前 8 MiB（共
  /// 17.5 MB，约 47%）」，而拼接过的字符串没法再拆回去。
  final List<DexBudgetSkip> skippedForBudget;

  const DexScanResult({
    required this.clues,
    required this.domains,
    required this.ips,
    required this.scannedDexCount,
    required this.scannedBytes,
    required this.skippedForBudget,
    this.sdkHits = const [],
  });

  bool hasClue(String markerId) => clues.any((c) => c.markerId == markerId);

  /// 某类别下是否出现过线索。
  bool hasCategory(SecurityCategory category) =>
      clues.any((c) => c.category == category);
}

/// 一个待匹配的字符串标记。
///
/// 标记表已抽到 [codeMarkers]（`code_markers.dart`）—— 方法引用扫描器要用
/// 同一份。两边各写一份必然漂移：加了新标记却只改一处，就会得出「字符串里
/// 命中了、代码引用里没命中」这种自相矛盾的结论。
///
/// 有界的 DEX 字符串线索扫描器。
///
/// 规格 3.3 明确要求「避免只依赖关键词搜索」，因此这里只做**第一层取证**：
/// 找出 OCR / 上传 / 网络库 / 后台 / 截图等能力痕迹与其中的证据原文，
/// 关联与定级交给规则引擎（那里会结合权限、输入源、去路同现，并标注
/// 「疑似关联」「未证实数据流」）。把这一步的结果直接当结论用是错的。
///
/// 安全边界（规格第八章）：
/// - 单个 DEX 最多扫 [maxBytesPerDex] 字节，超限记入 [DexScanResult.skippedForBudget]；
/// - 字符串总量、每类线索的样本数、域名数都有上限，防恶意 DEX 用超长字符串
///   或天文数字的 URL 把内存吃光；
/// - 只读字节、不解压、不执行。
class DexClueScanner {
  DexClueScanner._();

  static const String scannerVersion = 'dex-strings-2026.10.1';

  /// 单个 DEX 的扫描预算。正常 classes.dex 在 1–12 MiB，8 MiB 已覆盖多数
  /// 真实应用；超限的 DEX 如实记为未覆盖，而不是悄悄少扫。
  static const int maxBytesPerDex = 8 * 1024 * 1024;

  /// 一次分析覆盖的 DEX 总字节预算。
  static const int maxTotalBytes = 48 * 1024 * 1024;

  /// 可提取字符串的最短长度。太短的串（`ok`、`ab`）噪音远大于信息量。
  static const int minStringLength = 6;

  /// 单个字符串的最大保留长度，超长串只留头尾（域名/标识符不会超长，
  /// 超长的基本是 base64/blob）。
  static const int maxStringKeep = 200;

  /// 每个标记最多保留多少条不同样本。
  static const int maxSamplesPerMarker = 5;

  /// 域名 / IP 最多保留多少条。
  static const int maxEndpoints = 50;

  /// URL 主机名提取：`scheme://host[:port]/…`。
  static final RegExp _urlPattern =
      RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://([a-zA-Z0-9.-]+)');

  /// 裸域名（常见 TLD，避免把普通英文单词误判成域名）。
  ///
  /// 字符类里刻意不放引号：Dart 的原始字符串无法转义与自身相同的引号，
  /// 而这里排除空白与尖括号已经足够截断 URL —— 引号由调用方展示时
  /// 本就会被证据上下文包围。
  static final RegExp _bareDomainPattern = RegExp(
    r'\b([a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+'
    r'(com|cn|net|org|io|co|ai|dev|app|info|me|tv|xyz|top|cloud|gov|edu)'
    r'(?::\d{2,5})?(?:/[^\s<>]*)?',
    caseSensitive: true,
  );

  /// IPv4 字面量。
  static final RegExp _ipPattern = RegExp(r'\b(\d{1,3}\.){3}\d{1,3}\b');

  /// [maxBytesPerDex] / [maxTotalBytes] 可覆盖（探针与测试用）。
  ///
  /// 默认值就是上面两个常量 —— 调用方不传时行为与之前完全一致。做成参数是
  /// 因为「预算到底卡掉了多少」只能靠实测回答：拿同一个包分别按 8 / 32 MiB
  /// 扫一遍，才知道多扫出来的字节有没有换来新线索。
  /// SDK 引用数下限：低于这个值的当作噪声。
  ///
  /// 实测区分度：真打包进来的 SDK 在**几百到几千**（`com/adjust/sdk` 215、
  /// `cn/jpush` 336、`com/tencent/bugly` 974），而「只在某个配置字符串里
  /// 提了一句」的通常是个位数到几十（`com/huawei/hms` 8）。
  static const int minSdkOccurrences = 20;

  /// 前缀索引：`L` 之后的**前两段** → 对应的 SDK 目录项。
  ///
  /// 为什么按两段：24 个前缀逐个对几百万条字符串做 `startsWith`，
  /// 真实包上是几十亿次比较。算一次 key 再查表，每个字符串只多一次
  /// `indexOf` 与一次哈希。
  static _SdkIndex _buildSdkIndex() => _SdkIndex.build();

  static void _markSdk(
    String str,
    String dexName,
    _SdkIndex index,
    Map<String, int> counts,
    Map<String, Set<String>> dexes,
  ) {
    if (str.isEmpty || str.codeUnitAt(0) != 0x4C) return; // 只认 'L' 开头
    final key = _twoSegmentKey(str);
    if (key == null) return;
    final candidates = index.byKey[key];
    if (candidates == null) return;
    for (final descriptor in candidates) {
      final prefix = descriptor.packagePrefix;
      // key 只保证前两段相同，这里补一次精确的边界检查：
      // `L<prefix>/` 或 `L<prefix>;`，否则 `com/tencent/mm` 会吃掉
      // `com/tencent/mmkv`。
      final end = 1 + prefix.length;
      if (str.length <= end) {
        if (str.length == end && str.codeUnitAt(0) == 0x4C) {
          // 极短串，不可能命中
        }
        continue;
      }
      if (str.codeUnitAt(end) != 0x2F && str.codeUnitAt(end) != 0x3B) {
        continue;
      }
      if (!str.startsWith(prefix, 1)) continue;
      counts[descriptor.id] = (counts[descriptor.id] ?? 0) + 1;
      (dexes[descriptor.id] ??= <String>{}).add(dexName);
      return;
    }
  }

  /// 取 `L` 之后的前两段路径，例如：
  ///   `Lcom/adjust/sdk/Foo;` → `com/adjust`
  ///   `Lcom/adjust;`          → `com/adjust`
  ///   `Lokhttp3/Request;`     → `okhttp3/Request`（单段时退化为两段含第二段）
  ///
  /// 单段前缀（如 `okhttp3`）在当前目录里没有，但保留退化行为以免以后加
  /// 单段前缀时静默不命中。
  static String? _twoSegmentKey(String str) {
    final slash1 = str.indexOf('/', 1);
    if (slash1 < 0) return null;
    final slash2 = str.indexOf('/', slash1 + 1);
    final end = slash2 < 0 ? str.length : slash2;
    // 去掉尾部的 ';'
    final stop = (end > 1 && str.codeUnitAt(end - 1) == 0x3B) ? end - 1 : end;
    if (stop <= 1) return null;
    return str.substring(1, stop);
  }

  static DexScanResult scan(
    List<DexBytes> entries, {
    int maxBytesPerDex = DexClueScanner.maxBytesPerDex,
    int maxTotalBytes = DexClueScanner.maxTotalBytes,
  }) {
    final domains = <String>{};
    final ips = <String>{};
    final markerSamples = <String, Set<String>>{};
    final markerDexes = <String, Set<String>>{};
    final skipped = <DexBudgetSkip>[];

    var scannedDexCount = 0;
    var scannedBytes = 0;
    var totalSeen = 0;

    // SDK 计数：key 是「L 之后的前两段」，值是命中数。
    //
    // 为什么要这个索引：24 个前缀逐个对**几百万条**字符串做 startsWith，
    // 在 400 MiB 的包上是几十亿次比较。按前两段索引后，每条字符串只需要
    // 算一次 key、查一次表。
    final sdkIndex = _buildSdkIndex();
    final sdkCounts = <String, int>{};
    final sdkDexes = <String, Set<String>>{};

    for (final entry in entries) {
      if (totalSeen >= maxTotalBytes) {
        skipped.add(DexBudgetSkip(
          name: entry.name,
          scannedBytes: 0,
          totalBytes: entry.bytes.length,
        ));
        continue;
      }
      if (entry.bytes.length > maxBytesPerDex) {
        // 只扫前 maxBytesPerDex 字节，并明确记录「这是部分扫描」——
        // 悄悄扫一半比不扫更糟：报告会看起来是完整的。
        skipped.add(DexBudgetSkip(
          name: entry.name,
          scannedBytes: maxBytesPerDex,
          totalBytes: entry.bytes.length,
        ));
      }
      final limit = entry.bytes.length < maxBytesPerDex
          ? entry.bytes.length
          : maxBytesPerDex;
      totalSeen += limit;
      scannedDexCount++;
      scannedBytes += limit;

      for (final str in _extractStrings(entry.bytes, limit)) {
        _markString(str, entry.name, markerSamples, markerDexes);
        _collectEndpoints(str, domains, ips);
        _markSdk(str, entry.name, sdkIndex, sdkCounts, sdkDexes);
      }
    }

    final clues = <CodeClue>[];
    for (final marker in codeMarkers) {
      final samples = markerSamples[marker.id];
      if (samples == null || samples.isEmpty) continue;
      final dexes = markerDexes[marker.id]!;
      clues.add(CodeClue(
        markerId: marker.id,
        category: marker.category,
        description: marker.description,
        samples: samples.take(maxSamplesPerMarker).toList(),
        dexNames: dexes.toList()..sort(),
      ));
    }
    // 稳定排序：先按类别、再按 id，报告输出才可复现。
    clues.sort((a, b) {
      final byCategory = a.category.name.compareTo(b.category.name);
      return byCategory != 0 ? byCategory : a.markerId.compareTo(b.markerId);
    });

    // SDK 命中：按引用数过滤掉「只在配置字符串里提了一句」的噪声。
    final sdkHits = <SdkHit>[
      for (final entry in sdkCounts.entries)
        if (entry.value >= minSdkOccurrences)
          SdkHit(
            descriptor: sdkIndex.byId[entry.key]!,
            occurrences: entry.value,
            dexNames: (sdkDexes[entry.key] ?? const <String>{}).toList()
              ..sort(),
          ),
    ]..sort((a, b) => b.occurrences.compareTo(a.occurrences));

    return DexScanResult(
      clues: clues,
      domains: domains.take(maxEndpoints).toList()..sort(),
      ips: ips.take(maxEndpoints).toList()..sort(),
      scannedDexCount: scannedDexCount,
      scannedBytes: scannedBytes,
      skippedForBudget: skipped,
      sdkHits: sdkHits,
    );
  }

  /// 提取 [bytes] 前 [limit] 字节内的字符串。
  ///
  /// 提取规则与 iOS 侧共用 [AsciiStrings]（放在 analysis_model）——
  /// 两边各写一遍必然漂移。预算参数由调用方按上文常量给出。
  static Iterable<String> _extractStrings(Uint8List bytes, int limit) {
    return AsciiStrings.extract(
      bytes,
      limit: limit,
      minLength: minStringLength,
      maxKeep: maxStringKeep,
    );
  }

  static void _markString(
    String value,
    String dexName,
    Map<String, Set<String>> samples,
    Map<String, Set<String>> dexes,
  ) {
    // DEX 里同一个 SDK 有两种写法：类型描述符用 `/` 分隔
    // （`Lcom/google/mlkit/vision/text/TextRecognizer;`），字符串字面量用
    // 点号（`com.google.mlkit.vision.text`）。匹配前把 `/` 归一成 `.`，
    // 否则换一种写法就整类漏掉 —— 真实的加固样本里两种形态都出现过。
    //
    // 归一化与匹配逻辑在 [matchCodeMarkers] 里，与方法引用扫描器共用。
    for (final marker in matchCodeMarkers(value)) {
      (samples[marker.id] ??= <String>{}).add(value);
      (dexes[marker.id] ??= <String>{}).add(dexName);
    }
  }

  static void _collectEndpoints(
      String value, Set<String> domains, Set<String> ips) {
    if (domains.length >= maxEndpoints && ips.length >= maxEndpoints) return;
    for (final match in _urlPattern.allMatches(value)) {
      domains.add(match.group(1)!);
    }
    for (final match in _bareDomainPattern.allMatches(value)) {
      domains.add(match.group(0)!);
    }
    for (final match in _ipPattern.allMatches(value)) {
      ips.add(match.group(0)!);
    }
  }
}

/// SDK 前缀的两段索引。
class _SdkIndex {
  final Map<String, List<SdkDescriptor>> byKey;
  final Map<String, SdkDescriptor> byId;

  const _SdkIndex(this.byKey, this.byId);

  static _SdkIndex build() {
    final byKey = <String, List<SdkDescriptor>>{};
    for (final descriptor in sdkCatalog) {
      final parts = descriptor.packagePrefix.split('/');
      final key = parts.length >= 2 ? '${parts[0]}/${parts[1]}' : parts[0];
      (byKey[key] ??= <SdkDescriptor>[]).add(descriptor);
    }
    return _SdkIndex(
      byKey,
      {for (final d in sdkCatalog) d.id: d},
    );
  }
}
