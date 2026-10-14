import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

import 'code_markers.dart';

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
class DexScanResult {
  final List<CodeClue> clues;

  /// 从字符串中提取到的 URL 主机名 / 裸域名（去重、限量）。
  final List<String> domains;

  /// 提取到的 IPv4 字面量。
  final List<String> ips;

  /// 实际扫描的 DEX 数与字节数。
  final int scannedDexCount;
  final int scannedBytes;

  /// 因预算被跳过的 DEX（名字 + 大小）。**必须**出现在报告的未覆盖范围里。
  final List<String> skippedForBudget;

  const DexScanResult({
    required this.clues,
    required this.domains,
    required this.ips,
    required this.scannedDexCount,
    required this.scannedBytes,
    required this.skippedForBudget,
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

  static DexScanResult scan(List<DexBytes> entries) {
    final domains = <String>{};
    final ips = <String>{};
    final markerSamples = <String, Set<String>>{};
    final markerDexes = <String, Set<String>>{};
    final skipped = <String>[];

    var scannedDexCount = 0;
    var scannedBytes = 0;
    var totalSeen = 0;

    for (final entry in entries) {
      if (totalSeen >= maxTotalBytes) {
        skipped.add('${entry.name} (total budget reached)');
        continue;
      }
      if (entry.bytes.length > maxBytesPerDex) {
        // 只扫前 maxBytesPerDex 字节，并明确记录「这是部分扫描」——
        // 悄悄扫一半比不扫更糟：报告会看起来是完整的。
        skipped.add('${entry.name} scanned partially '
            '(${maxBytesPerDex ~/ 1024} KiB of ${entry.bytes.length} bytes)');
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

    return DexScanResult(
      clues: clues,
      domains: domains.take(maxEndpoints).toList()..sort(),
      ips: ips.take(maxEndpoints).toList()..sort(),
      scannedDexCount: scannedDexCount,
      scannedBytes: scannedBytes,
      skippedForBudget: skipped,
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
