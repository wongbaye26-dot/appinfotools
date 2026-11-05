/// Android `resources.arsc` / `assets/**` 里的中文话术线索。
///
/// 与 DEX 扫描同一张词表、同一密度门槛；但证据来源是资源表/文本资源，
/// 所以单独一条元发现项，不伪装成 DEX 字符串。
library;

import 'package:analysis_model/analysis_model.dart';

class AndroidResourceUnicodePhraseSignals {
  final Map<String, Set<String>> samples = {};
  final Map<String, Set<String>> sources = {};
  final Set<String> hitIds = {};
  int examinedStrings = 0;
  bool truncated = false;

  static const int maxSamplesPerMarker = 3;
  static const int maxHits = 64;

  bool get isEmpty => samples.isEmpty;

  bool get shouldReport =>
      hitIds.any(socialPhraseIds.contains) || hitIds.length >= 3;

  void collect(String text, String source) {
    examinedStrings++;
    if (text.length < 2 || samples.length >= maxHits) return;
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
    for (final marker in unicodePhraseMarkers) {
      if (!text.contains(marker.literal)) continue;
      hitIds.add(marker.id);
      final bucket = samples.putIfAbsent(marker.id, () => <String>{});
      if (bucket.length < maxSamplesPerMarker) bucket.add(text);
      (sources[marker.id] ??= <String>{}).add(source);
    }
  }
}

/// 从资源/文本资源字符串里收集话术；[maxStrings] 限制总输入。
AndroidResourceUnicodePhraseSignals scanAndroidResourcePhrases(
  Iterable<String> strings, {
  String source = 'resources.arsc',
  int maxStrings = 200000,
}) {
  final signals = AndroidResourceUnicodePhraseSignals();
  var n = 0;
  for (final text in strings) {
    if (n >= maxStrings) {
      signals.truncated = true;
      break;
    }
    n++;
    signals.collect(text, source);
  }
  return signals;
}

List<SecurityFinding> buildAndroidResourceUnicodePhraseFindings(
  AndroidResourceUnicodePhraseSignals s,
) {
  if (s.isEmpty || !s.shouldReport) return const [];
  final ids = s.hitIds.toList()..sort();
  return [
    SecurityFinding(
      ruleId: 'ANDROID-RESOURCE-UNICODE-PHRASE',
      platform: SecurityPlatform.android,
      isMeta: true,
      category: SecurityCategory.cryptoAsset,
      severity: SecuritySeverity.info,
      confidence: SecurityConfidence.confirmed,
      finding: 'Found ${ids.length} Chinese wallet / social-engineering '
          'phrase(s) in resource strings (${s.examinedStrings} strings '
          'examined). These are UI copy clues, not a verdict.',
      messageCode: 'android.resource_unicode_phrase',
      messageArgs: {
        'count': ids.length,
        'phrases': ids,
        'strings': s.examinedStrings,
      },
      evidence: [
        for (final id in ids.take(12))
          for (final sample in (s.samples[id] ?? const <String>{}).take(2))
            SecurityEvidence(
              source: SecurityEvidenceSource.other,
              location: (s.sources[id] ?? const <String>{}).join(', '),
              detail: '$id: $sample',
            ),
      ],
      limitation: 'Only string constants from resources.arsc global pool and '
          'text-like assets were examined. Binary assets, native libraries, '
          'runtime-downloaded copy and strings assembled at runtime are '
          'outside this scan. Chinese wording alone says nothing about '
          'whether any transfer or upload actually happens.'
          '${s.truncated ? ' The input exceeded the scan budget; the '
              'unexamined part is unknown.' : ''}',
      limitationCode: 'android.resource_unicode_phrase.limitation',
      recommendation: 'Read the attached original strings in context: do they '
          'ask for a seed phrase, promise an airdrop, demand a deposit to '
          'unfreeze funds, or instruct a fund sweep? Combine this with the '
          'signature / baseline and load-chain evidence before concluding '
          'anything about intent.',
      recommendationCode: 'android.resource_unicode_phrase.review',
    ),
  ];
}
