import 'package:analysis_model/analysis_model.dart';

/// iOS 可执行文件里的**中文/Unicode 话术**线索。
///
/// ## 为什么单独一张表
///
/// `AsciiStrings` 只认 0x20–0x7E，`__cstring` 里的 UTF-8 中文界面文案会被
/// 切成碎片；`Utf16Strings` 虽然已经在扫 `__ustring`，但下游收集器只认
/// ASCII 标记（框架名、选择器、地址），中文词一条也匹配不上。结果就是：
/// 「客服解冻」「刷单返利」「资金归集」这类**只有在中文里才出现**的社工话术，
/// 在旧链路上完全不可见。
///
/// ## 口径（与设计方案 §8.6 一致）
///
/// 中文词只是**话术/能力线索**，不是恶意判决：
/// - 不因为出现「助记词」就把包判成盗 U；正规钱包也有这些词；
/// - 只产出一条 `info` 级 `isMeta` 发现项，附**命中原文**供人工复核；
/// - 命中还要满足 [IosUnicodePhraseSignals.shouldReport] 的密度门槛，
///   避免每个中文 App 都挂一条卡片；
/// - 判级仍只交给 `CryptoTheftAssessor`，本文件不碰 severity。
///
/// ## 词表下沉到 `analysis_model`
///
/// Android DEX 的 MUTF-8 与 iOS 的 Unicode 用的是**同一批中文词**，两侧各存
/// 一份必然漂移。表与漂移守卫现在放在 `analysis_model/unicode_phrases.dart`，
/// 这里只保留旧名字的别名（已有报告消费者按 `iosPhraseMarkers` 取表），
/// 字面量约束（全非 ASCII、互不嵌套）由共享守卫统一钉住。
typedef IosPhraseKind = UnicodePhraseKind;
typedef IosPhraseMarker = UnicodePhraseMarker;

const List<IosPhraseMarker> iosPhraseMarkers = unicodePhraseMarkers;

/// Unicode 扫描收集到的中文话术信号。
class IosUnicodePhraseSignals {
  /// 标记 id → 命中原文（最多 [maxSamplesPerMarker] 条）。
  final Map<String, Set<String>> samples = {};

  /// 标记 id → 出现在哪些可执行文件里。
  final Map<String, Set<String>> sources = {};

  /// 一共看过多少条**非 ASCII 候选串**（用于覆盖说明，不是风险指标）。
  int unicodeStrings = 0;

  /// 扫描预算是否截断过：截断后「没找到」不能读成「没有」。
  bool truncated = false;

  static const int maxSamplesPerMarker = 3;
  static const int maxHits = 64;

  bool get isEmpty => samples.isEmpty;

  /// 命中的标记 id（稳定顺序，便于报告比对）。
  List<String> get hitIds => samples.keys.toList()..sort();

  List<String> hitsOf(IosPhraseKind kind) => [
        for (final marker in iosPhraseMarkers)
          if (marker.kind == kind && samples.containsKey(marker.id)) marker.id,
      ];

  bool get hasSeedPhrase => hitsOf(IosPhraseKind.seed).isNotEmpty;

  /// 只凭中文话术**不判级**：这里只决定要不要把线索摆到界面上。
  ///
  /// 两条触发路径：
  /// 1. 命中任一社工话术（仿冒包相对正规钱包最有区分度的一组）；
  /// 2. 命中 ≥3 条不同话术（线索密度够高，值得人工看一眼原文）。
  ///
  /// 只有一两条「助记词 / 收款地址」的正规钱包不会挂卡片。
  bool get shouldReport =>
      hitsOf(IosPhraseKind.social).isNotEmpty || hitIds.length >= 3;

  void noteTruncation() => truncated = true;

  /// 从一条字符串里收集信号。[source] 是可执行文件路径（证据位置）。
  ///
  /// [unicode] 表示这条串来自 UTF-8 / UTF-16 的 Unicode 提取器；纯 ASCII
  /// 串也会走同一个 `consume()`，但不该计入 Unicode 覆盖量。
  void collect(String text, String source, {bool unicode = false}) {
    if (unicode) unicodeStrings++;
    if (text.length < 2 || samples.length >= maxHits) return;
    // 纯 ASCII 串在 Mach-O 里占绝大多数（实测一个 34 MiB 主二进制的
    // UTF-16 遍历能产出 72 万条串），先用一个不建对象的码元扫描挡掉，
    // 再跑那条 29 路中文正则 —— 否则每条串都要过一次正则引擎。
    var hasWide = false;
    for (final unit in text.codeUnits) {
      if ((unit >= 0x2E80 && unit <= 0x9FFF) ||
          (unit >= 0xAC00 && unit <= 0xD7AF) ||
          (unit >= 0xFF00 && unit <= 0xFFEF)) {
        hasWide = true;
        break;
      }
    }
    if (!hasWide) return;
    // 预筛：有宽字符也不一定命中话术，省掉全表 29 次 contains。
    if (!_anyPattern.hasMatch(text)) return;
    for (final marker in iosPhraseMarkers) {
      if (!text.contains(marker.literal)) continue;
      final bucket = samples.putIfAbsent(marker.id, () => <String>{});
      if (bucket.length < maxSamplesPerMarker) bucket.add(text);
      (sources[marker.id] ??= <String>{}).add(source);
    }
  }

  static final RegExp _anyPattern = RegExp(
    iosPhraseMarkers.map((m) => RegExp.escape(m.literal)).join('|'),
  );
}

/// 产出一条**元信息**发现项：只陈述「看到了哪些中文话术 + 原文」。
///
/// 没有命中或没过密度门槛时返回空列表 —— 不编「未发现」的结论，
/// 那由 `ios.unicodeStrings` 覆盖维度回答。
List<SecurityFinding> buildIosUnicodePhraseFindings(
  IosUnicodePhraseSignals s,
) {
  if (s.isEmpty || !s.shouldReport) return const [];

  final ids = s.hitIds;
  final evidence = <SecurityEvidence>[
    for (final id in ids.take(12))
      for (final sample in (s.samples[id] ?? const <String>{}).take(2))
        SecurityEvidence(
          source: SecurityEvidenceSource.machoSymbol,
          location: (s.sources[id] ?? const <String>{}).join(', '),
          detail: '$id: $sample',
        ),
  ];

  return [
    SecurityFinding(
      ruleId: 'IOS-UNICODE-PHRASE',
      platform: SecurityPlatform.ios,
      isMeta: true,
      category: SecurityCategory.cryptoAsset,
      severity: SecuritySeverity.info,
      // 字符串确实存在于文件里，这是事实；但「它在骗人」不是本条结论。
      confidence: SecurityConfidence.confirmed,
      finding: 'Found ${ids.length} Chinese wallet / social-engineering '
          'phrase(s) in Unicode string literals (${s.unicodeStrings} Unicode '
          'candidate strings examined). These are UI copy clues: legitimate '
          'wallets contain many of the same words, so presence is **not a '
          'verdict**. The matched original text is attached as evidence.',
      messageCode: 'ios.unicode_phrase',
      messageArgs: {
        'count': ids.length,
        'phrases': ids,
        'unicodeStrings': s.unicodeStrings,
      },
      evidence: evidence,
      limitation: 'Only UTF-8 text and UTF-16 literals in the scanned '
          'executable bytes were examined. Swift small-string constants '
          'embedded in instructions, .strings / localization resources, '
          'runtime-downloaded text and symbols in the dyld shared cache are '
          'outside this scan. Chinese wording alone says nothing about whether '
          'any transfer or upload actually happens.'
          '${s.truncated ? ' Some executables exceeded the scan budget; '
              'Unicode strings past that point were not examined.' : ''}',
      limitationCode: 'ios.unicode_phrase.limitation',
      recommendation: 'Read the attached original strings in context: do they '
          'ask for a seed phrase, promise an airdrop, demand a deposit to '
          'unfreeze funds, or instruct a fund sweep? Combine this with the '
          'signature / baseline and load-chain evidence before concluding '
          'anything about intent.',
      recommendationCode: 'ios.unicode_phrase.review',
    ),
  ];
}
