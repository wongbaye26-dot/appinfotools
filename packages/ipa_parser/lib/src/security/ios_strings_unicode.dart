/// iOS `.strings` / 本地化文件里的中文话术线索。
///
/// 与可执行文件扫描分开：`.strings` 不在 Mach-O 里，而是归档里的文本资源；
/// 用 UTF-8 + UTF-16 四条组合解码后复用同一张话术词表与密度门槛。
library;

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

class IosStringsFile {
  final String path;
  final Uint8List bytes;
  const IosStringsFile(this.path, this.bytes);
}

class IosStringsUnicodeSignals {
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

IosStringsUnicodeSignals scanIosStringsFiles(
  List<IosStringsFile> files, {
  int maxStrings = 200000,
}) {
  final signals = IosStringsUnicodeSignals();
  var n = 0;
  for (final file in files) {
    for (final text in Utf8Strings.extract(
      file.bytes,
      minLength: 2,
      minCjkChars: 2,
    )) {
      if (n++ >= maxStrings) {
        signals.truncated = true;
        return signals;
      }
      signals.collect(text, file.path);
    }
    for (final bigEndian in const [false, true]) {
      for (final alignment in const [0, 1]) {
        for (final text in Utf16Strings.extract(
          file.bytes,
          minLength: 2,
          bigEndian: bigEndian,
          alignment: alignment,
          requireWide: true,
        )) {
          if (n++ >= maxStrings) {
            signals.truncated = true;
            return signals;
          }
          signals.collect(text, file.path);
        }
      }
    }
  }
  return signals;
}

List<SecurityFinding> buildIosStringsUnicodePhraseFindings(
  IosStringsUnicodeSignals s,
) {
  if (s.isEmpty || !s.shouldReport) return const [];
  final ids = s.hitIds.toList()..sort();
  return [
    SecurityFinding(
      ruleId: 'IOS-STRINGS-UNICODE-PHRASE',
      platform: SecurityPlatform.ios,
      isMeta: true,
      category: SecurityCategory.cryptoAsset,
      severity: SecuritySeverity.info,
      confidence: SecurityConfidence.confirmed,
      finding: 'Found ${ids.length} Chinese wallet / social-engineering '
          'phrase(s) in .strings / localization files (${s.examinedStrings} '
          'candidate strings examined). These are UI copy clues, not a verdict.',
      messageCode: 'ios.strings_unicode_phrase',
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
      limitation: 'Only .strings / localization text files inside the archive '
          'were examined. Swift small-string constants, binary plists, '
          'runtime-downloaded copy and strings assembled at runtime are '
          'outside this scan. Chinese wording alone says nothing about '
          'whether any transfer or upload actually happens.'
          '${s.truncated ? ' The input exceeded the scan budget; the '
              'unexamined part is unknown.' : ''}',
      limitationCode: 'ios.strings_unicode_phrase.limitation',
      recommendation: 'Read the attached original strings in context: do they '
          'ask for a seed phrase, promise an airdrop, demand a deposit to '
          'unfreeze funds, or instruct a fund sweep? Combine this with the '
          'signature / baseline and load-chain evidence before concluding '
          'anything about intent.',
      recommendationCode: 'ios.strings_unicode_phrase.review',
    ),
  ];
}
