/// Android DEX 侧的**中文话术**线索。
///
/// ## 为什么不在 `DexClueScanner` 的裸字节遍历上补
///
/// `DexClueScanner` 走的是 `AsciiStrings.extract`（只认 0x20–0x7E），
/// DEX 里的中文界面文案是 MUTF-8：一个汉字三个字节，第一个 ≥0x80 就被断开。
/// 设计方案 §8.6 给的正是另一条路 —— 走 `string_ids` / `string_data`，
/// 用现成的 `DexTables.string()` 解出**完整字符串**再匹配。
/// 这样既不会把机器码噪声当文本，也不会漏掉三字节汉字。
///
/// ## 口径（与 iOS 侧一致）
///
/// 中文词只是话术/能力线索，不是恶意判决：
/// - 不因为出现「助记词」就把包判成盗 U；正规钱包也有这些词；
/// - 只产出一条 `info` 级 `isMeta` 发现项，附命中原文供人工复核；
/// - 命中要过 [DexUnicodePhraseSignals.shouldReport] 的密度门槛；
/// - 判级仍只交给 `CryptoTheftAssessor`，本文件不碰 severity。
///
/// 词表在 `analysis_model/unicode_phrases.dart`，Android 与 iOS 共用一份。
library;

import 'package:analysis_model/analysis_model.dart';

import '../dex/dex_structure.dart';
import '../dex/dex_tables.dart';
import 'dex_clue_scanner.dart';

/// 从 DEX `string_ids` 收集到的中文话术信号。
class DexUnicodePhraseSignals {
  /// 标记 id → 命中原文（最多 [maxSamplesPerMarker] 条）。
  final Map<String, Set<String>> samples = {};

  /// 标记 id → 出现在哪些 DEX 里。
  final Map<String, Set<String>> dexNames = {};

  /// 实际解出来检查过的 `string_ids` 条数。
  int decodedStrings = 0;

  /// 预算或结构问题导致「没看全」时置位。
  bool truncated = false;

  static const int maxSamplesPerMarker = 3;
  static const int maxHits = 64;

  bool get isEmpty => samples.isEmpty;

  List<String> get hitIds => samples.keys.toList()..sort();

  bool get hasSeedPhrase => hitIds.any((id) => seedPhraseIds.contains(id));

  /// 与 iOS 侧同一条门槛：社工话术命中，或累计 ≥3 条不同话术。
  /// 一两条「助记词 / 收款地址」的正规钱包不挂卡片。
  bool get shouldReport =>
      hitIds.any((id) => socialPhraseIds.contains(id)) || hitIds.length >= 3;

  /// [text] 是已经由 `DexTables.string()` 解好的完整字符串。
  void collect(String text, String dexName) {
    decodedStrings++;
    if (text.length < 2 || samples.length >= maxHits) return;
    // 纯 ASCII 串占绝大多数，先用一个不建对象的码元扫描挡掉中文正则。
    var hasWide = false;
    for (final unit in text.codeUnits) {
      if ((unit >= 0x2E80 && unit <= 0x9FFF) ||
          (unit >= 0xAC00 && unit <= 0xD7AF) ||
          (unit >= 0xFF00 && unit <= 0xFFEF)) {
        hasWide = true;
        break;
      }
    }
    if (!hasWide || !_anyPattern.hasMatch(text)) return;
    for (final marker in unicodePhraseMarkers) {
      if (!text.contains(marker.literal)) continue;
      final bucket = samples.putIfAbsent(marker.id, () => <String>{});
      if (bucket.length < maxSamplesPerMarker) bucket.add(text);
      (dexNames[marker.id] ??= <String>{}).add(dexName);
    }
  }

  static final RegExp _anyPattern = RegExp(
    unicodePhraseMarkers.map((m) => RegExp.escape(m.literal)).join('|'),
  );
}

/// 一次 DEX Unicode 扫描的结果（含覆盖量，供覆盖率维度使用）。
class DexUnicodePhraseScan {
  final DexUnicodePhraseSignals signals;

  /// 头部声明、本次尝试遍历的 `string_ids` 条数之和。
  final int attemptedStrings;

  /// 预算被触发，或有字符串解不出来。
  final bool truncated;

  /// 结构不可信、因而**完全没看**的 DEX 名字。
  final List<String> untrustedDexes;

  const DexUnicodePhraseScan({
    required this.signals,
    required this.attemptedStrings,
    required this.truncated,
    this.untrustedDexes = const [],
  });

  int get decodedStrings => signals.decodedStrings;

  bool get hasContent => attemptedStrings > 0 || untrustedDexes.isNotEmpty;
}

/// 有界的 `string_ids` 遍历。
class DexUnicodePhraseScanner {
  DexUnicodePhraseScanner._();

  /// 一次分析最多解多少条字符串（设计 §8.6 建议 20 万条）。
  static const int maxStrings = 200000;

  /// 解出来的文本总量上限（避免一个 DEX 用超长字符串吃内存）。
  static const int maxTextChars = 16 * 1024 * 1024;

  /// [structures] 由调用方（`AndroidSecurityAudit`）复用已经解析好的那一份，
  /// 不为这一步再算一次 adler32 校验和。按名字对齐，缺哪个就记哪个没看。
  static DexUnicodePhraseScan scan(
    List<DexBytes> entries,
    List<DexStructure> structures, {
    int maxStrings = DexUnicodePhraseScanner.maxStrings,
    int maxTextChars = DexUnicodePhraseScanner.maxTextChars,
  }) {
    final byName = <String, DexStructure>{
      for (final s in structures) s.name: s,
    };
    final signals = DexUnicodePhraseSignals();
    final untrusted = <String>[];
    var attempted = 0;
    var textChars = 0;
    var strings = 0;
    var truncated = false;

    outer:
    for (final entry in entries) {
      final structure = byName[entry.name];
      if (structure == null || !structure.isTraversable) {
        untrusted.add(entry.name);
        continue;
      }
      final section = structure.section('string_ids');
      if (section == null) {
        untrusted.add(entry.name);
        continue;
      }
      attempted += section.size;
      final tables = DexTables(entry.bytes, structure);
      for (var i = 0; i < section.size; i++) {
        if (strings >= maxStrings || textChars >= maxTextChars) {
          truncated = true;
          break outer;
        }
        final text = tables.string(i);
        if (text == null) {
          // 解不出来不等于「没有」—— 如实计入未覆盖。
          truncated = true;
          continue;
        }
        strings++;
        textChars += text.length;
        signals.collect(text, entry.name);
      }
    }

    signals.truncated = truncated;
    return DexUnicodePhraseScan(
      signals: signals,
      attemptedStrings: attempted,
      truncated: truncated || untrusted.isNotEmpty,
      untrustedDexes: untrusted,
    );
  }
}

/// 产出一条**元信息**发现项：只陈述「看到了哪些中文话术 + 原文」。
///
/// 没有命中或没过密度门槛时返回空列表 —— 不编「未发现」的结论，
/// 那由 `android.dex.unicodeStrings` 覆盖维度回答。
List<SecurityFinding> buildAndroidUnicodePhraseFindings(
  DexUnicodePhraseScan scan,
) {
  final s = scan.signals;
  if (s.isEmpty || !s.shouldReport) return const [];

  final ids = s.hitIds;
  final evidence = <SecurityEvidence>[
    for (final id in ids.take(12))
      for (final sample in (s.samples[id] ?? const <String>{}).take(2))
        SecurityEvidence(
          source: SecurityEvidenceSource.dexString,
          location: (s.dexNames[id] ?? const <String>{}).join(', '),
          detail: '$id: $sample',
        ),
  ];

  return [
    SecurityFinding(
      ruleId: 'ANDROID-UNICODE-PHRASE',
      platform: SecurityPlatform.android,
      isMeta: true,
      category: SecurityCategory.cryptoAsset,
      severity: SecuritySeverity.info,
      // 字符串确实存在于 DEX 里，这是事实；「它在骗人」不是本条结论。
      confidence: SecurityConfidence.confirmed,
      finding: 'Found ${ids.length} Chinese wallet / social-engineering '
          'phrase(s) in DEX string constants (${scan.decodedStrings} decoded '
          'strings examined). These are UI copy clues: legitimate wallets '
          'contain many of the same words, so presence is **not a verdict**. '
          'The matched original text is attached as evidence.',
      messageCode: 'android.unicode_phrase',
      messageArgs: {
        'count': ids.length,
        'phrases': ids,
        'strings': scan.decodedStrings,
      },
      evidence: evidence,
      limitation: 'Only string constants reachable through DEX string_ids '
          'were decoded (MUTF-8). Text in resources/ and assets/, native '
          'libraries, hardened or packed shells, runtime-downloaded copy '
          'and strings assembled at runtime are outside this scan. Chinese '
          'wording alone says nothing about whether any transfer or upload '
          'actually happens.'
          '${scan.truncated ? ' Some string entries could not be decoded or '
              'were beyond the scan budget; the unexamined part is unknown.' : ''}',
      limitationCode: 'android.unicode_phrase.limitation',
      recommendation: 'Read the attached original strings in context: do they '
          'ask for a seed phrase, promise an airdrop, demand a deposit to '
          'unfreeze funds, or instruct a fund sweep? Combine this with the '
          'signature / baseline and load-chain evidence before concluding '
          'anything about intent.',
      recommendationCode: 'android.unicode_phrase.review',
    ),
  ];
}
