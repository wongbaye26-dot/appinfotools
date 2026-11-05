import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

Uint8List _utf8(List<String> texts) => Uint8List.fromList([
      for (final t in texts) ...[...const Utf8Encoder().convert(t), 0],
    ]);

Uint8List _utf16(List<String> texts) => Uint8List.fromList([
      for (final t in texts) ...[
        for (final u in t.codeUnits) ...[u & 0xff, (u >> 8) & 0xff],
        0,
        0,
      ],
    ]);

void main() {
  test('UTF-8 .strings 命中话术', () {
    final s = scanIosStringsFiles([
      IosStringsFile('en.lproj/Localizable.strings', _utf8(['资金冻结', '刷单返利'])),
    ]);
    final findings = buildIosStringsUnicodePhraseFindings(s);
    expect(findings, hasLength(1));
    expect(findings.single.ruleId, 'IOS-STRINGS-UNICODE-PHRASE');
    expect(findings.single.severity, SecuritySeverity.info);
    expect(findings.single.evidence.map((e) => e.detail).join('\n'),
        contains('资金冻结'));
  });

  test('UTF-16 .strings 命中话术', () {
    final s = scanIosStringsFiles([
      IosStringsFile('zh.lproj/Localizable.strings', _utf16(['助记词', '人工客服'])),
    ]);
    expect(buildIosStringsUnicodePhraseFindings(s), isNotEmpty);
  });

  test('纯 ASCII 不报告', () {
    final s = scanIosStringsFiles([
      IosStringsFile('en.lproj/Localizable.strings', _utf8(['hello', 'world'])),
    ]);
    expect(buildIosStringsUnicodePhraseFindings(s), isEmpty);
  });
}
