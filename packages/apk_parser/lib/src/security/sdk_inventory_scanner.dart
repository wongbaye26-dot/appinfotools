// SDK 盘点的**独立扫描器**：按 DEX 的 `string_ids` 精确访问。
//
// ## 为什么不复用 `DexClueScanner` 的字符串提取
//
// 试过，`DexClueScanner` 的实现是**暴力扫全部字节**、按「可打印 ASCII」切串。
// 它有两个上限：单 DEX 8 MiB、总计 48 MiB。实测抖音（55 个 DEX / 437 MiB）：
//
// | `maxTotalBytes` | 耗时 | 命中的服务类 SDK |
// |---|---|---|
// | 48 MiB（生产默认） | 1.9 s | **0 个** |
// | 128 MiB | 5.2 s | 2 个 |
// | 512 MiB | 14.4 s | 3 个 |
//
// 而直接搜原始字节能找到 175 次 `com/tencent/mm/opensdk`。原因是 DEX 的
// **`string_data` 在文件后半部分**（头 → id 表 → class_defs → data），
// 单文件 8 MiB 的上限把它整段截掉了。抖音的 DEX 平均就有 8 MiB ——
// 也就是说**在最需要这个功能的包上，它返回 0**。
//
// ## 正解：按 `string_ids` 跳着读
//
// DEX 头里有 `string_ids_size` / `string_ids_off`，每个 `string_id_item`
// 是 4 字节的偏移。按偏移直接跳到 `string_data_item` 读前缀，就**不需要
// 扫全部字节**，也不受「字符串在文件哪一段」影响。
//
// 但仍然要把 DEX 读进内存才能按偏移随机访问 —— 这是本文件的单文件上限
// （[maxDexBytes]）存在的原因。它与 `DexClueScanner` 的 8 MiB 是**两个不同的
// 预算**，服务于两个不同的目的，不要合并。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

import 'sdk_catalog.dart';

/// 一个 DEX 的扫描结果。
class SdkDexScan {
  final String dexName;

  /// 命中的 SDK id → 引用数。
  final Map<String, int> counts;

  /// 是否因为超出 [SdkInventoryScanner.maxDexBytes] 而只扫了前一段。
  final bool truncated;

  /// 头部读不出时的原因（不是 DEX、偏移越界等）。
  final String? failure;

  const SdkDexScan({
    required this.dexName,
    this.counts = const {},
    this.truncated = false,
    this.failure,
  });

  bool get parsed => failure == null;
}

/// 整个包的 SDK 盘点结果。
class SdkInventory {
  /// 命中的 SDK（已按引用数降序）。
  final List<SdkHit> hits;

  /// 真正解析成功的 DEX 数。
  final int scannedDexCount;

  /// DEX 总数（含失败与截断的）。
  final int totalDexCount;

  /// 被截断的 DEX 名（只扫了前 [SdkInventoryScanner.maxDexBytes] 字节）。
  final List<String> truncated;

  /// 读不出的 DEX（名 → 原因）。
  final Map<String, String> failures;

  const SdkInventory({
    this.hits = const [],
    this.scannedDexCount = 0,
    this.totalDexCount = 0,
    this.truncated = const [],
    this.failures = const {},
  });

  bool get isEmpty => hits.isEmpty;

  /// 这次盘点是否**完整**：所有 DEX 都读过、且没有被截断的。
  bool get complete =>
      failures.isEmpty && truncated.isEmpty && scannedDexCount == totalDexCount;
}

/// 按 `string_ids` 扫 DEX 里的类名前缀，统计 SDK 引用数。
class SdkInventoryScanner {
  SdkInventoryScanner._();

  /// 单个 DEX 的读入上限。
  ///
  /// 64 MiB 是「比任何真实 DEX 都大」的值（实测抖音最大的 DEX 在
  /// 8–30 MiB 之间），同时仍然是**有界**的 —— 不可信的长度不能决定内存分配。
  static const int maxDexBytes = 64 * 1024 * 1024;

  /// 引用数下限：低于它的当作噪声。
  ///
  /// 实测区分度：真打包进来的 SDK 在**几百到几千**，而「只在某个配置
  /// 字符串里提了一句」的通常是个位数。
  static const int minOccurrences = 20;

  /// 一次读多少字节就够判断前缀。
  ///
  /// 最长前缀是 `com/tencent/mm/opensdk`（22 字符），加 `L` 与前导
  /// ULEB128 长度（最多 5 字节）后再留余量 → 48 足够。
  static const int _prefixWindow = 48;

  /// 扫描一批 DEX。
  ///
  /// [readDex] 按条目名返回**完整字节**（由调用方决定怎么读、是否受别处预算
  /// 约束）。返回 `null` 表示读不出。
  static SdkInventory scan(
    List<String> dexNames,
    Uint8List? Function(String name) readDex,
  ) {
    final counts = <String, int>{};
    final dexes = <String, Set<String>>{};
    final truncated = <String>[];
    final failures = <String, String>{};
    var scanned = 0;

    for (final name in dexNames) {
      final bytes = readDex(name);
      if (bytes == null) {
        failures[name] = 'entry could not be read';
        continue;
      }
      final result = scanDex(name, bytes);
      if (!result.parsed) {
        failures[name] = result.failure!;
        continue;
      }
      scanned++;
      if (result.truncated) truncated.add(name);
      result.counts.forEach((id, count) {
        counts[id] = (counts[id] ?? 0) + count;
        (dexes[id] ??= <String>{}).add(name);
      });
    }

    final byId = {for (final d in sdkCatalog) d.id: d};
    final hits = <SdkHit>[
      for (final entry in counts.entries)
        if (entry.value >= minOccurrences && byId.containsKey(entry.key))
          SdkHit(
            descriptor: byId[entry.key]!,
            occurrences: entry.value,
            dexNames: (dexes[entry.key] ?? const <String>{}).toList()..sort(),
          ),
    ]..sort((a, b) => b.occurrences.compareTo(a.occurrences));

    return SdkInventory(
      hits: hits,
      scannedDexCount: scanned,
      totalDexCount: dexNames.length,
      truncated: truncated,
      failures: failures,
    );
  }

  /// 扫单个 DEX。
  static SdkDexScan scanDex(String name, Uint8List bytes) {
    if (bytes.length < 0x70) {
      return SdkDexScan(dexName: name, failure: 'file is too small for a DEX');
    }
    // `dex\n0xx\0`
    if (!(bytes[0] == 0x64 &&
        bytes[1] == 0x65 &&
        bytes[2] == 0x78 &&
        bytes[3] == 0x0A)) {
      return SdkDexScan(dexName: name, failure: 'not a DEX file');
    }
    final data = ByteData.sublistView(bytes);
    final stringIdsSize = data.getUint32(0x38, Endian.little);
    final stringIdsOff = data.getUint32(0x3C, Endian.little);
    if (stringIdsSize == 0) {
      // 没有字符串池，正常但无处可扫。
      return SdkDexScan(dexName: name);
    }
    final tableEnd = stringIdsOff + stringIdsSize * 4;
    if (stringIdsOff < 0x70 || tableEnd > bytes.length) {
      return SdkDexScan(
        dexName: name,
        failure: 'string_ids table is out of range '
            '(offset $stringIdsOff, $stringIdsSize entries, '
            'file ${bytes.length})',
      );
    }

    final index = _SdkPrefixIndex.build();
    final counts = <String, int>{};
    final truncated = bytes.length > maxDexBytes;

    for (var i = 0; i < stringIdsSize; i++) {
      final offset = data.getUint32(stringIdsOff + i * 4, Endian.little);
      if (offset <= 0 || offset >= bytes.length) continue;
      final id = _matchAt(bytes, offset, index);
      if (id != null) counts[id] = (counts[id] ?? 0) + 1;
    }
    return SdkDexScan(
      dexName: name,
      counts: counts,
      truncated: truncated,
    );
  }

  /// 从 `string_data_item`（`uleb128 长度 + MUTF-8 + \0`）的 [offset] 起，
  /// 判断它是不是某个 SDK 的类名描述符。
  ///
  /// 返回命中的 SDK id；不是类名或不匹配时返回 `null`。
  static String? _matchAt(Uint8List bytes, int offset, _SdkPrefixIndex index) {
    var cursor = offset;
    // 跳过 ULEB128 的 utf16_size（最多 5 字节）。
    for (var i = 0; i < 5; i++) {
      if (cursor >= bytes.length) return null;
      final b = bytes[cursor];
      cursor++;
      if (b & 0x80 == 0) break;
    }
    // 类名描述符必须以 'L' 开头。
    if (cursor >= bytes.length || bytes[cursor] != 0x4C) return null;
    final start = cursor;
    final windowEnd = start + _prefixWindow < bytes.length
        ? start + _prefixWindow
        : bytes.length;
    final value = String.fromCharCodes(bytes, start, windowEnd);
    final key = _twoSegmentKey(value);
    if (key == null) return null;
    final candidates = index.byKey[key];
    if (candidates == null) return null;
    for (final descriptor in candidates) {
      final prefix = descriptor.packagePrefix;
      final end = 1 + prefix.length;
      if (value.length <= end) continue;
      final boundary = value.codeUnitAt(end);
      // 只认 `L<prefix>/` 与 `L<prefix>;`：否则 `com/tencent/mm` 会吃掉
      // `com/tencent/mmkv`。
      if (boundary != 0x2F && boundary != 0x3B) continue;
      if (!value.startsWith(prefix, 1)) continue;
      return descriptor.id;
    }
    return null;
  }

  static String? _twoSegmentKey(String value) {
    final slash1 = value.indexOf('/', 1);
    if (slash1 < 0) return null;
    final slash2 = value.indexOf('/', slash1 + 1);
    var end = slash2 < 0 ? value.length : slash2;
    if (end > 1 && value.codeUnitAt(end - 1) == 0x3B) end--;
    if (end <= 1) return null;
    return value.substring(1, end);
  }
}

/// 前缀索引：`L` 之后的前两段 → 候选 SDK。
///
/// 为什么要索引：24 个前缀逐个对几百万条字符串做 `startsWith` 是几十亿次
/// 比较；算一次 key 再查表，每条字符串只多一次 `indexOf` 与一次哈希。
class _SdkPrefixIndex {
  final Map<String, List<SdkDescriptor>> byKey;

  const _SdkPrefixIndex(this.byKey);

  static _SdkPrefixIndex build() {
    final byKey = <String, List<SdkDescriptor>>{};
    for (final descriptor in sdkCatalog) {
      final parts = descriptor.packagePrefix.split('/');
      final key = parts.length >= 2 ? '${parts[0]}/${parts[1]}' : parts[0];
      (byKey[key] ??= <SdkDescriptor>[]).add(descriptor);
    }
    return _SdkPrefixIndex(byKey);
  }
}

/// 把盘点结果转成一条**信息级**发现。
///
/// 用 `info` + `independentCapability`：这是**清单**，不是风险。
/// 「用了 Adjust」本身不是缺陷 —— 它是「这个应用的数据会流向 Adjust」这个
/// 事实，是否可接受取决于场景。
///
/// 调用方保证 `inventory.hits` 非空。
SecurityFinding buildSdkInventoryFinding(SdkInventory inventory) {
  final hits = inventory.hits;
  final grouped = groupByCategory(hits);
  final names = [for (final hit in hits) hit.displayName];
  return SecurityFinding(
    ruleId: 'ANDROID-THIRD-PARTY-SDK',
    platform: SecurityPlatform.android,
    category: SecurityCategory.thirdPartySdk,
    severity: SecuritySeverity.info,
    confidence: SecurityConfidence.independentCapability,
    finding: '${hits.length} third-party service SDK(s) were found in the '
        'code: ${names.join(', ')}. These libraries send data to their own '
        'servers; the list itself is an inventory, not a risk verdict.',
    messageCode: 'android.third_party_sdk',
    messageArgs: {
      'count': hits.length,
      'names': names,
      'categories': [
        for (final entry in grouped.entries)
          '${entry.key.id}:${entry.value.length}',
      ],
    },
    evidence: [
      for (final entry in grouped.entries)
        SecurityEvidence(
          source: SecurityEvidenceSource.dexString,
          location: 'DEX classes / ${entry.key.label}',
          detail: entry.value
              .map((h) => '${h.displayName} (${h.occurrences} references)')
              .join(', '),
        ),
    ],
    limitation: 'Only class-name prefixes are matched, and only for the '
        'service SDKs in this catalogue: basic libraries (HTTP client, JSON, '
        'UI, animation) are deliberately excluded because they appear in '
        'almost every app. The reference count is the number of class names '
        'with that prefix, not the number of calls. An obfuscated or '
        'repackaged SDK will not be recognised. Only the DEX files that were '
        'read are covered — see the coverage entry for how many.',
    limitationCode: 'android.third_party_sdk.limitation',
    recommendation: 'Check each SDK against the app\'s privacy policy: what '
        'data does it collect, and where does it send it. Remove the ones '
        'the app does not actually need.',
    recommendationCode: 'android.third_party_sdk.review',
  );
}
