// iOS 中文话术表与收集器的漂移守卫。
//
// 这类表最容易出的毛病不是「写错一条」，而是**写了永远命中不了的字面量**：
// Unicode 提取器只认非 ASCII 文本、长度门槛 2，中文词一旦被写成 ASCII
// 或单字就会变成死规则（DEX 侧 `CodeMarker` 已经踩过一次）。所以这里直接
// 用两个提取器逐条驱动整张表，任何一条捞不出来就红。

import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

Uint8List _utf8CString(String text) => Uint8List.fromList([
      ...const Utf8Encoder().convert(text),
      0,
    ]);

Uint8List _utf16(String text, {required bool bigEndian}) {
  final out = <int>[];
  for (final unit in text.codeUnits) {
    final low = unit & 0xff;
    final high = (unit >> 8) & 0xff;
    out.addAll(bigEndian ? [high, low] : [low, high]);
  }
  return Uint8List.fromList([...out, 0, 0]);
}

void main() {
  test('话术表本身：全是非 ASCII、无重复、任意两条互不嵌套', () {
    expect(iosPhraseMarkers, isNotEmpty);
    final ids = <String>[];
    final literals = <String>[];
    for (final marker in iosPhraseMarkers) {
      expect(marker.id, isNotEmpty);
      expect(marker.literal.length, greaterThanOrEqualTo(2),
          reason: '${marker.id} 太短，会被 minLength 挡掉');
      expect(
        marker.literal.runes.every((r) => r >= 0x80),
        isTrue,
        reason: '${marker.id} 含 ASCII —— 那该写进 ASCII 标记表而不是这里',
      );
      ids.add(marker.id);
      literals.add(marker.literal);
    }
    expect(ids.toSet(), hasLength(ids.length), reason: '标记 id 重复');
    expect(literals.toSet(), hasLength(literals.length), reason: '字面量重复');
    for (final a in iosPhraseMarkers) {
      for (final b in iosPhraseMarkers) {
        if (identical(a, b)) continue;
        expect(b.literal.contains(a.literal), isFalse,
            reason: '${a.literal} 是 ${b.literal} 的子串，同一句会重复命中');
      }
    }
  });

  test('逐条驱动：每条话术都能被 UTF-8 与 UTF-16 LE/BE 提取器捞到', () {
    for (final marker in iosPhraseMarkers) {
      expect(
        Utf8Strings.extract(
          _utf8CString(marker.literal),
          minLength: 2,
          minCjkChars: 2,
        ),
        contains(marker.literal),
        reason: '${marker.id} 在 UTF-8 路径上是死规则',
      );
      for (final bigEndian in const [false, true]) {
        expect(
          Utf16Strings.extractAll(
            _utf16(marker.literal, bigEndian: bigEndian),
            minLength: 2,
          ),
          contains(marker.literal),
          reason: '${marker.id} 在 UTF-16 '
              '${bigEndian ? 'BE' : 'LE'} 路径上是死规则',
        );
      }
    }
  });

  test('收集器：记录原文与来源，样本数有上限', () {
    final s = IosUnicodePhraseSignals();
    for (var i = 0; i < 10; i++) {
      s.collect('第$i次请输入助记词', 'Payload/App.app/App', unicode: true);
    }
    expect(s.hitIds, ['phrase.mnemonic']);
    expect(s.hasSeedPhrase, isTrue);
    expect(s.samples['phrase.mnemonic'], hasLength(3));
    expect(s.sources['phrase.mnemonic'], contains('Payload/App.app/App'));
    expect(s.unicodeStrings, 10);
  });

  test('ASCII 串不计入 Unicode 覆盖量，也不误命中', () {
    final s = IosUnicodePhraseSignals();
    s.collect('MetaMask UIPasteboard', 'Payload/App.app/App');
    expect(s.unicodeStrings, 0);
    expect(s.isEmpty, isTrue);
  });

  test('密度门槛：一两条正规钱包用语不挂卡片，社工话术或 ≥3 条才报', () {
    final onlyNormal = IosUnicodePhraseSignals()
      ..collect('请输入助记词', 'p', unicode: true)
      ..collect('收款地址', 'p', unicode: true);
    expect(onlyNormal.shouldReport, isFalse);
    expect(buildIosUnicodePhraseFindings(onlyNormal), isEmpty);

    final social = IosUnicodePhraseSignals()
      ..collect('账户资金冻结，联系人工客服', 'p', unicode: true);
    expect(social.hitsOf(IosPhraseKind.social), isNotEmpty);
    expect(social.shouldReport, isTrue);

    final dense = IosUnicodePhraseSignals()
      ..collect('助记词 私钥 导入钱包', 'p', unicode: true);
    expect(dense.hitIds.length, greaterThanOrEqualTo(3));
    expect(dense.shouldReport, isTrue);
  });

  test('发现项：info + isMeta，命中原文进证据，四个 code 齐全', () {
    final s = IosUnicodePhraseSignals()
      ..collect('客服解冻：资金冻结', 'Payload/App.app/App', unicode: true)
      ..collect('请输入助记词', 'Payload/App.app/App', unicode: true);
    final findings = buildIosUnicodePhraseFindings(s);
    expect(findings, hasLength(1));
    final f = findings.single;
    expect(f.ruleId, 'IOS-UNICODE-PHRASE');
    expect(f.severity, SecuritySeverity.info);
    expect(f.isMeta, isTrue);
    expect(f.messageCode, 'ios.unicode_phrase');
    expect(f.recommendationCode, 'ios.unicode_phrase.review');
    expect(f.limitationCode, 'ios.unicode_phrase.limitation');
    expect(f.messageArgs['count'], isA<int>());
    final text = f.evidence.map((e) => e.detail).join('\n');
    expect(text, contains('资金冻结'));
    expect(text, contains('助记词'));
  });

  test('截断标记会写进局限说明，不能把「没找到」读成「没有」', () {
    final s = IosUnicodePhraseSignals()
      ..collect('资金冻结', 'p', unicode: true)
      ..noteTruncation();
    final f = buildIosUnicodePhraseFindings(s).single;
    expect(f.limitation, contains('exceeded the scan budget'));
  });

  test('中文话术只支撑盗 U 链的 source 段，不单独把等级推到 P2', () {
    final phrases = IosUnicodePhraseSignals()
      ..collect('请输入助记词', 'Payload/App.app/App', unicode: true);
    final a = IosCryptoTheftChain.assess(
      signals: IosCryptoSignals(),
      phrases: phrases,
    );
    final source = a.chain.firstWhere((e) => e.stage == ChainStage.source);
    expect(source.supported, isTrue);
    expect(source.evidence.map((e) => e.detail).join(' '),
        contains('unicode phrase'));
    expect(a.level, isNot(CryptoTheftLevel.suspicious));
    expect(a.level, isNot(CryptoTheftLevel.strongEvidence));
  });
}
