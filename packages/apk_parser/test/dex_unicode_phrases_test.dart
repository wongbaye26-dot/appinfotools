// DEX 中文话术扫描的包级测试。
//
// 结构化通路（`string_ids` → `string_data` 的 MUTF-8）需要一个带中文
// string_data 的 DEX。仓库里的真实 DEX 夹具都是编译产物，没有中文话术，
// 所以复用 `support/minimal_dex.dart` 的最小结构容器：它不是「真实 App
// 样本」，期望值只是「放进去的原文能被解出来并命中」。真实包上的行为由
// 根项目 `test/android_unicode_phrase_scan_test.dart` 与真实 APK 夹具覆盖。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

import 'support/minimal_dex.dart';

DexUnicodePhraseScan _scan(List<String> strings, {int? maxStrings}) {
  final bytes = buildMinimalDex(strings);
  final structure = DexStructure.read('classes.dex', bytes);
  return DexUnicodePhraseScanner.scan(
    [DexBytes('classes.dex', bytes)],
    [structure],
    maxStrings: maxStrings ?? DexUnicodePhraseScanner.maxStrings,
  );
}

void main() {
  test('结构化扫描：从 string_ids 解出 MUTF-8 中文并命中', () {
    final result = _scan([
      '助记词',
      '客服解冻：资金冻结',
      '资金归集到归集地址',
      'MetaMask',
      'com.example.app',
    ]);
    expect(result.attemptedStrings, 5);
    expect(result.decodedStrings, 5);
    expect(result.truncated, isFalse);
    final ids = result.signals.hitIds;
    expect(ids, contains('phrase.mnemonic'));
    expect(ids, contains('phrase.frozen_funds'));
    expect(ids, contains('phrase.fund_sweep'));
    // 纯 ASCII 串不会进命中，但仍计入「已解码」。
    expect(ids, isNot(contains('phrase.private_key')));
  });

  test('预算截断：maxStrings 卡住时 truncated 为 true，且已解出的保留', () {
    final result = _scan(['助记词', '私钥', '资金归集'], maxStrings: 2);
    expect(result.truncated, isTrue);
    expect(result.decodedStrings, 2);
    expect(result.attemptedStrings, 3);
    expect(result.signals.hitIds, contains('phrase.mnemonic'));
  });

  test('结构不可信时整份记为没看，而不是「没有」', () {
    final bytes = Uint8List.fromList(List.filled(64, 0x41));
    final structure = DexStructure.read('broken.dex', bytes);
    final result = DexUnicodePhraseScanner.scan(
      [DexBytes('broken.dex', bytes)],
      [structure],
    );
    expect(result.attemptedStrings, 0);
    expect(result.untrustedDexes, ['broken.dex']);
    expect(result.hasContent, isTrue);
    expect(result.signals.isEmpty, isTrue);
  });

  test('收集器：样本与 DEX 来源有上限，密度门槛与 iOS 一致', () {
    final signals = DexUnicodePhraseSignals();
    for (var i = 0; i < 10; i++) {
      signals.collect('第$i次请输入助记词', 'classes$i.dex');
    }
    expect(signals.samples['phrase.mnemonic'], hasLength(3));
    expect(signals.dexNames['phrase.mnemonic'], hasLength(10));
    expect(signals.hasSeedPhrase, isTrue);
    // 只有一条 seed 话术：不挂卡片。
    expect(signals.shouldReport, isFalse);

    final social = DexUnicodePhraseSignals()..collect('账户资金冻结', 'classes.dex');
    expect(social.shouldReport, isTrue);
  });

  test('发现项：info + isMeta，命中原文进证据，三个 code 齐全', () {
    final result = _scan(['客服解冻', '资金冻结', '助记词']);
    final findings = buildAndroidUnicodePhraseFindings(result);
    expect(findings, hasLength(1));
    final f = findings.single;
    expect(f.ruleId, 'ANDROID-UNICODE-PHRASE');
    expect(f.platform, SecurityPlatform.android);
    expect(f.severity, SecuritySeverity.info);
    expect(f.isMeta, isTrue);
    expect(f.messageCode, 'android.unicode_phrase');
    expect(f.recommendationCode, 'android.unicode_phrase.review');
    expect(f.limitationCode, 'android.unicode_phrase.limitation');
    expect(f.evidence.map((e) => e.detail).join('\n'), contains('资金冻结'));
    expect(f.evidence.first.source, SecurityEvidenceSource.dexString);
  });

  test('截断会写进局限说明', () {
    final result = _scan(['客服解冻', '资金冻结'], maxStrings: 1);
    final f = buildAndroidUnicodePhraseFindings(result).single;
    expect(f.limitation, contains('scan budget'));
  });

  test('端到端：审计产出发现项、覆盖维度，并只把话术接到 source 段', () {
    final result = AndroidSecurityAudit.audit(
      meta: ApkMeta(),
      dexEntries: [
        DexBytes(
          'classes.dex',
          buildMinimalDex(['客服解冻', '资金冻结', '助记词']),
        ),
      ],
    );

    final finding = result.findings
        .where((f) => f.ruleId == 'ANDROID-UNICODE-PHRASE')
        .toList();
    expect(finding, hasLength(1));

    final coverage = result.coverage.entry('android.dex.unicodeStrings');
    expect(coverage, isNotNull);
    expect(coverage!.status, CoverageStatus.covered);
    expect(coverage.covered, 3);
    expect(coverage.limit, 3);
    expect(coverage.noteCode, 'android.dex.unicode_strings.scope');

    final source = result.cryptoTheft!.chain
        .firstWhere((e) => e.stage == ChainStage.source);
    expect(source.supported, isTrue);
    expect(source.evidence.map((e) => e.detail).join(' '),
        contains('unicode phrase'));
    // 一句中文话术不能把等级推到 suspicious / strongEvidence。
    expect(result.cryptoTheft!.level, isNot(CryptoTheftLevel.suspicious));
    expect(result.cryptoTheft!.level, isNot(CryptoTheftLevel.strongEvidence));
  });
}
