import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

CryptoTheftFacts facts({
  bool walletContext = false,
  bool keyMaterial = false,
  bool clipboardRead = false,
  bool clipboardWrite = false,
  bool addressLiteral = false,
  bool seedInput = false,
  bool specialAccess = false,
  bool webViewBridge = false,
  bool networkSink = false,
  bool dynamicLoading = false,
  bool danglingLoad = false,
  bool injectedDylib = false,
  bool suspiciousPayload = false,
  bool packed = false,
  bool coverageIncomplete = false,
  bool baselineMismatch = false,
  bool sealMismatch = false,
  String? baselineEntryId,
}) =>
    CryptoTheftFacts(
      platform: SecurityPlatform.android,
      walletContext: walletContext,
      keyMaterial: keyMaterial,
      clipboardRead: clipboardRead,
      clipboardWrite: clipboardWrite,
      addressLiteral: addressLiteral,
      seedInput: seedInput,
      specialAccess: specialAccess,
      webViewBridge: webViewBridge,
      networkSink: networkSink,
      dynamicLoading: dynamicLoading,
      danglingLoad: danglingLoad,
      injectedDylib: injectedDylib,
      suspiciousPayload: suspiciousPayload,
      packed: packed,
      coverageIncomplete: coverageIncomplete,
      baselineMismatch: baselineMismatch,
      sealMismatch: sealMismatch,
      baselineEntryId: baselineEntryId,
      blindSpots: packed ? const ['nativePacked'] : const [],
    );

void main() {
  test('无信号 → none/info，五段齐全且每段都有缺失环节', () {
    final a = CryptoTheftAssessor.assess(facts());
    expect(a.level, CryptoTheftLevel.none);
    expect(a.severity, SecuritySeverity.info);
    expect(a.confidence, SecurityConfidence.confirmed);
    expect(a.score, 0);
    expect(a.chain, hasLength(5));
    expect(a.missing, hasLength(5));
    expect(a.chain.map((e) => e.stage), ChainStage.values);
  });

  test('仅能力同现 → capabilityOnly/P3，不判 P2', () {
    final a = CryptoTheftAssessor.assess(facts(
      walletContext: true,
      keyMaterial: true,
      clipboardWrite: true,
    ));
    expect(a.level, CryptoTheftLevel.capabilityOnly);
    expect(a.severity, SecuritySeverity.p3);
    expect(a.confidence, SecurityConfidence.independentCapability);
    expect(a.missing.map((m) => m.stage), contains(ChainStage.injection));
  });

  test('钱包 + 剪贴板写 + 地址、无读来源 → suspicious/P2/noSource', () {
    final a = CryptoTheftAssessor.assess(facts(
      walletContext: true,
      clipboardWrite: true,
      addressLiteral: true,
    ));
    expect(a.level, CryptoTheftLevel.suspicious);
    expect(a.severity, SecuritySeverity.p2);
    expect(a.confidence, SecurityConfidence.suspected);
    expect(a.primaryTechnique, TheftTechnique.addressSwap);
    expect(
      a.missing.firstWhere((m) => m.stage == ChainStage.source).whyCode,
      'missing.noSource',
    );
    expect(
      a.chain.firstWhere((e) => e.stage == ChainStage.source).ruleIds,
      contains('ANDROID-CLIPBOARD-ADDRESS-SWAP'),
    );
    expect(
      a.chain.firstWhere((e) => e.stage == ChainStage.capability).ruleIds,
      contains('ANDROID-THEFT-CHAIN'),
    );
  });

  test('注入 + 载荷 + 钱包 → strongEvidence/P1，但 confidence 仍是 suspected', () {
    final a = CryptoTheftAssessor.assess(facts(
      walletContext: true,
      dynamicLoading: true,
      suspiciousPayload: true,
    ));
    expect(a.level, CryptoTheftLevel.strongEvidence);
    expect(a.severity, SecuritySeverity.p1);
    expect(a.confidence, SecurityConfidence.suspected);
    expect(a.hasFactLevelEvidence, isTrue);
  });

  test('仅悬空加载边 + 钱包 → suspicious/P2', () {
    final a = CryptoTheftAssessor.assess(facts(
      walletContext: true,
      danglingLoad: true,
    ));
    expect(a.level, CryptoTheftLevel.suspicious);
    expect(a.severity, SecuritySeverity.p2);
  });

  test('密钥材料 + 网络外发 + 钱包 → suspicious/P2', () {
    final a = CryptoTheftAssessor.assess(facts(
      walletContext: true,
      keyMaterial: true,
      networkSink: true,
    ));
    expect(a.level, CryptoTheftLevel.suspicious);
    expect(a.severity, SecuritySeverity.p2);
  });

  test('覆盖不全且无信号 → unknown/unknown，score=null', () {
    final a = CryptoTheftAssessor.assess(facts(coverageIncomplete: true));
    expect(a.level, CryptoTheftLevel.unknown);
    expect(a.severity, SecuritySeverity.unknown);
    expect(a.confidence, SecurityConfidence.unknown);
    expect(a.score, isNull);
  });

  test('加壳但无信号 → unknown，payload 缺失原因是 shellPacked', () {
    final a = CryptoTheftAssessor.assess(facts(
      packed: true,
      coverageIncomplete: true,
    ));
    expect(a.level, CryptoTheftLevel.unknown);
    expect(
      a.missing.firstWhere((m) => m.stage == ChainStage.payload).whyCode,
      'missing.shellPacked',
    );
  });

  test('官方基线不匹配 → strongEvidence/P1/confirmed，family 段被支撑', () {
    final a = CryptoTheftAssessor.assess(facts(
      walletContext: true,
      baselineMismatch: true,
      baselineEntryId: 'android.imtoken',
    ));
    expect(a.level, CryptoTheftLevel.strongEvidence);
    expect(a.severity, SecuritySeverity.p1);
    expect(a.confidence, SecurityConfidence.confirmed);
    expect(a.baselineEntryId, 'android.imtoken');
    expect(
      a.chain.firstWhere((e) => e.stage == ChainStage.family).supported,
      isTrue,
    );
  });

  test('score 归一化到 0–100，五段全支撑时为 100', () {
    final a = CryptoTheftAssessor.assess(facts(
      walletContext: true,
      clipboardRead: true,
      clipboardWrite: true,
      addressLiteral: true,
      dynamicLoading: true,
      suspiciousPayload: true,
      baselineMismatch: true,
    ));
    expect(a.score, 100);
  });

  test('缺失环节与未支撑段一一对应', () {
    final a = CryptoTheftAssessor.assess(facts(
      walletContext: true,
      dynamicLoading: true,
    ));
    for (final stage in ChainStage.values) {
      final supported = a.chain.firstWhere((e) => e.stage == stage).supported;
      final hasMissing = a.missing.any((m) => m.stage == stage);
      expect(hasMissing, !supported, reason: 'stage=$stage');
    }
  });

  test('id 随平台变化', () {
    final android = CryptoTheftAssessor.assess(facts());
    expect(android.id, 'android.crypto.theft');
    final ios = CryptoTheftAssessor.assess(const CryptoTheftFacts(
      platform: SecurityPlatform.ios,
    ));
    expect(ios.id, 'ios.crypto.theft');
  });

  test('密封摘要不一致 → strongEvidence/P1/confirmed，不依赖钱包语境', () {
    final a = CryptoTheftAssessor.assess(facts(sealMismatch: true));
    expect(a.level, CryptoTheftLevel.strongEvidence);
    expect(a.severity, SecuritySeverity.p1);
    expect(a.confidence, SecurityConfidence.confirmed);
  });
}
