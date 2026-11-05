import 'security_finding.dart';

/// 盗 U 检测的**证据链与评估模型**。
///
/// 这一层只做「把平台事实组合成一条可解释的评估」：它不读文件、不判恶意，
/// 也不把能力同现说成行为。平台侧（`apk_parser` / `ipa_parser`）负责把各自
/// 的信号映射成 [CryptoTheftFacts]，再由 [CryptoTheftAssessor] 纯函数产出
/// [CryptoTheftAssessment]。
///
/// ## 五段链
///
/// `capability → source → injection → payload → family`。
/// 每一段只回答「这一环有没有**事实**支撑」；没有支撑的段必须同时有一条
/// [MissingLink]，说明缺的是哪一环。这样报告不会把「没查」写成「没有」。
///
/// ## 与 severity / confidence 的关系
///
/// 不扩展原有的 [SecuritySeverity] / [SecurityConfidence] 枚举：
/// - P1 只给事实级：官方基线不匹配（Phase E）、密封不匹配（Phase D）；
/// - 能力链最高 P2，且 confidence 为 `suspected`；
/// - 能力同现（钱包/剪贴板/地址）最高 P3，confidence 为
///   `independentCapability`；
/// - 必需维度被截断/加壳时输出 `unknown`，并必须伴随覆盖缺口。
class CryptoTheftAssessment {
  /// `android.crypto.theft` / `ios.crypto.theft`。
  final String id;

  final CryptoTheftLevel level;

  /// 主技术点；判不出时为 `null`（不是空串）。
  final TheftTechnique? primaryTechnique;

  /// 恰好 5 段，顺序固定：capability/source/injection/payload/family。
  final List<TechniqueEvidence> chain;

  /// 未支撑段对应的缺失环节。
  final List<MissingLink> missing;

  final SecurityConfidence confidence;
  final SecuritySeverity severity;

  /// 0–100；`null` = 未评分（例如 unknown）。
  final int? score;

  /// 评分口径版本；改权重/判级必须升它。
  final String scoringVersion;

  /// 命中的官方基线条目 id；未命中/无基线为 `null`。
  final String? baselineEntryId;

  const CryptoTheftAssessment({
    required this.id,
    required this.level,
    required this.primaryTechnique,
    required this.chain,
    required this.missing,
    required this.confidence,
    required this.severity,
    required this.score,
    required this.scoringVersion,
    this.baselineEntryId,
  });

  /// 五段里被支撑的段数。
  int get supportedStageCount => chain.where((entry) => entry.supported).length;

  /// 是否至少有事实级证据（官方基线/密封，本版本 Phase C 通常为 false）。
  bool get hasFactLevelEvidence =>
      level == CryptoTheftLevel.strongEvidence ||
      level == CryptoTheftLevel.knownFamily;

  @override
  String toString() => 'CryptoTheftAssessment($id, ${level.name}, '
      '${severity.name}/${confidence.name}, '
      'stages=$supportedStageCount/5)';
}

/// 评估等级。`knownFamily` 预留给 Phase E 的 IoC（当前不产出）。
enum CryptoTheftLevel {
  none,
  capabilityOnly,
  suspicious,
  strongEvidence,
  knownFamily,
  unknown;

  String get label => switch (this) {
        CryptoTheftLevel.none => 'none',
        CryptoTheftLevel.capabilityOnly => 'capability only',
        CryptoTheftLevel.suspicious => 'suspicious',
        CryptoTheftLevel.strongEvidence => 'strong evidence',
        CryptoTheftLevel.knownFamily => 'known family',
        CryptoTheftLevel.unknown => 'unknown',
      };
}

/// 盗 U 技术点。
enum TheftTechnique {
  addressSwap,
  clipboardHijack,
  mnemonicPhish,
  keyExfiltration,
  approvalPhish,
  unknown;

  String get label => switch (this) {
        TheftTechnique.addressSwap => 'address replacement',
        TheftTechnique.clipboardHijack => 'clipboard hijack',
        TheftTechnique.mnemonicPhish => 'mnemonic phishing',
        TheftTechnique.keyExfiltration => 'key exfiltration',
        TheftTechnique.approvalPhish => 'approval phishing',
        TheftTechnique.unknown => 'unknown',
      };
}

/// 证据链阶段。
enum ChainStage {
  capability,
  source,
  injection,
  payload,
  family;

  /// 稳定字符串 id。
  ///
  /// 不用 `.name`：在个别测试/隔离环境的运行时里枚举的 `name` getter 不可用
  /// （实测 `flutter test` 下会抛 NoSuchMethodError）；报告 JSON 依赖这个 id，
  /// 不能把稳定性押在运行时扩展上。
  String get code => switch (this) {
        ChainStage.capability => 'capability',
        ChainStage.source => 'source',
        ChainStage.injection => 'injection',
        ChainStage.payload => 'payload',
        ChainStage.family => 'family',
      };
}

/// 证据强度（比 confidence 更细，用于呈现「这是字符串还是调用点」）。
enum TechniqueStrength {
  stringOnly,
  codeReference,
  callSite,
  artifact,
  baseline,
  knownFamily;

  String get label => switch (this) {
        TechniqueStrength.stringOnly => 'string only',
        TechniqueStrength.codeReference => 'code reference',
        TechniqueStrength.callSite => 'call site',
        TechniqueStrength.artifact => 'artifact',
        TechniqueStrength.baseline => 'official baseline',
        TechniqueStrength.knownFamily => 'known family',
      };
}

/// 五段链中的一段。
class TechniqueEvidence {
  final TheftTechnique technique;
  final ChainStage stage;
  final String signalId;
  final TechniqueStrength strength;
  final bool supported;
  final List<SecurityEvidence> evidence;
  final List<String> noteCodes;

  /// 与该段对应的规则 id（C-4）。
  ///
  /// 不把 10 条规则拆成 10 张重复的 finding：评估卡已经按五段链呈现同一批
  /// 事实，再拆 finding 会与旧 `*-CRYPTO-THEFT-RISK` 重复。规则 id 放在链
  /// 条目上，JSON/报告可以按规则检索，UI 也不必堆十张卡片。
  final List<String> ruleIds;

  const TechniqueEvidence({
    required this.technique,
    required this.stage,
    required this.signalId,
    required this.strength,
    required this.supported,
    this.evidence = const [],
    this.noteCodes = const [],
    this.ruleIds = const [],
  });
}

/// 缺失环节。
class MissingLink {
  final ChainStage stage;

  /// 稳定 code：`missing.noSource` / `missing.noSink` /
  /// `missing.payloadEncrypted` / `missing.shellPacked` / `missing.noBaseline`…
  final String whyCode;

  final Map<String, Object> args;

  const MissingLink({
    required this.stage,
    required this.whyCode,
    this.args = const {},
  });
}

/// 平台侧映射后的**归一化事实**。
///
/// 所有字段都是「观察到/未观察到」的布尔或证据列表；不包含恶意判断。
/// 平台侧不应为了凑满字段而把「没查」填成 `false` —— 没查请用
/// [coverageIncomplete] + [blindSpots] 表达。
class CryptoTheftFacts {
  final SecurityPlatform platform;

  /// 钱包/链上资产语境（钱包 SDK/框架）。
  final bool walletContext;

  /// 助记词/BIP39/私钥处理证据。
  final bool keyMaterial;

  /// 剪贴板读（地址/文本来源）。
  final bool clipboardRead;

  /// 剪贴板写（地址替换的落点）。
  final bool clipboardWrite;

  /// 包内存在链上地址字面量。
  final bool addressLiteral;

  /// 助记词/私钥输入 UI 证据。
  final bool seedInput;

  /// Android 无障碍/悬浮窗/通知监听等特殊访问能力。
  final bool specialAccess;

  /// WebView JS 桥 / 注入能力。
  final bool webViewBridge;

  /// 网络外发能力（上传接口/网络库）。
  final bool networkSink;

  /// 动态加载 API 证据。
  final bool dynamicLoading;

  /// 加载链有目标不在包内的边。
  final bool danglingLoad;

  /// iOS 注入 dylib（布局事实）或等价注入证据。
  final bool injectedDylib;

  /// 可疑载荷（伪装/加密/嵌套归档）。
  final bool suspiciousPayload;

  /// 壳/加密导致关键内容不可见。
  final bool packed;

  /// 必需维度的覆盖被截断。
  final bool coverageIncomplete;

  /// 官方基线不匹配（Phase E 才会为 true）。
  final bool baselineMismatch;

  /// 密封摘要不一致（Phase D）：内容与签名块/CodeResources 记录不符。
  ///
  /// 事实级 P1，不依赖钱包语境；`false` 包括“未做/无密封清单”。
  final bool sealMismatch;

  final String? baselineEntryId;

  /// 稳定盲区 code。
  final List<String> blindSpots;

  /// 每段证据；没有的段用空列表。
  final Map<ChainStage, List<SecurityEvidence>> evidence;

  /// 每段的说明 code。
  final Map<ChainStage, List<String>> noteCodes;

  const CryptoTheftFacts({
    required this.platform,
    this.walletContext = false,
    this.keyMaterial = false,
    this.clipboardRead = false,
    this.clipboardWrite = false,
    this.addressLiteral = false,
    this.seedInput = false,
    this.specialAccess = false,
    this.webViewBridge = false,
    this.networkSink = false,
    this.dynamicLoading = false,
    this.danglingLoad = false,
    this.injectedDylib = false,
    this.suspiciousPayload = false,
    this.packed = false,
    this.coverageIncomplete = false,
    this.baselineMismatch = false,
    this.sealMismatch = false,
    this.baselineEntryId,
    this.blindSpots = const [],
    this.evidence = const {},
    this.noteCodes = const {},
  });

  List<SecurityEvidence> evidenceFor(ChainStage stage) =>
      evidence[stage] ?? const [];

  List<String> noteCodesFor(ChainStage stage) => noteCodes[stage] ?? const [];
}

/// 纯函数评估器。
///
/// 判级规则（与契约 §7.3 对齐，Phase C 不含 D/E 的事实级规则）：
/// - 五段里 ≥3 段且含 injection/payload → `suspicious` P2；
/// - injection + payload + walletContext → `strongEvidence` P1（仍是
///   `suspected`，不是「已证实行为」）；
/// - 钱包 + 剪贴板写 + 地址字面量且无读来源 → `suspicious` P2；
/// - 密钥材料 + 网络外发 + 钱包语境 → `suspicious` P2；
/// - 仅能力同现 → `capabilityOnly` P3；
/// - 覆盖被截断且没有足够证据 → `unknown`（severity/confidence 都 unknown）。
///
/// **注意**：这里没有 `ANDROID/IOS-*-BOOTSTRAP` 之类的“规则 ID”概念；
/// 规则层负责把 assessment 转成 finding。评估器只保证 level/severity/
/// confidence/score/missing 的一致性。
class CryptoTheftAssessor {
  CryptoTheftAssessor._();

  static const String scoringVersion = 'theft-1.0';

  /// 五段权重；总和 120，最后归一化到 0–100。
  static const Map<ChainStage, int> _weights = {
    ChainStage.capability: 10,
    ChainStage.source: 20,
    ChainStage.injection: 30,
    ChainStage.payload: 25,
    ChainStage.family: 35,
  };

  static CryptoTheftAssessment assess(CryptoTheftFacts f) {
    final supported = <ChainStage, bool>{
      ChainStage.capability: f.walletContext ||
          f.keyMaterial ||
          f.clipboardWrite ||
          f.specialAccess ||
          f.webViewBridge,
      ChainStage.source: f.clipboardRead || f.seedInput,
      ChainStage.injection:
          f.dynamicLoading || f.danglingLoad || f.injectedDylib,
      ChainStage.payload: f.suspiciousPayload,
      ChainStage.family: f.baselineMismatch,
    };

    final stageCount = supported.values.where((v) => v).length;
    final hasWalletChain = f.walletContext;
    final hasInjection = supported[ChainStage.injection]!;
    final hasPayload = supported[ChainStage.payload]!;

    final (level, severity, confidence) = _levelOf(
      f: f,
      supported: supported,
      stageCount: stageCount,
      hasWalletChain: hasWalletChain,
      hasInjection: hasInjection,
      hasPayload: hasPayload,
    );

    final evidence = <ChainStage, List<SecurityEvidence>>{};
    final notes = <ChainStage, List<String>>{};
    final missing = <MissingLink>[];
    for (final stage in ChainStage.values) {
      final isSupported = supported[stage]!;
      if (isSupported) {
        evidence[stage] = f.evidenceFor(stage);
        notes[stage] = f.noteCodesFor(stage);
        continue;
      }
      final why = _whyMissing(stage, f);
      missing.add(MissingLink(
        stage: stage,
        whyCode: why,
        args: {
          if (stage == ChainStage.family && f.baselineEntryId == null)
            'reason': 'no official baseline match',
          if (stage == ChainStage.payload && f.packed)
            'reason': 'packed/encrypted',
          if (f.coverageIncomplete) 'coverageIncomplete': true,
        },
      ));
    }

    final score = _score(supported, level);
    return CryptoTheftAssessment(
      id: f.platform == SecurityPlatform.android
          ? 'android.crypto.theft'
          : 'ios.crypto.theft',
      level: level,
      primaryTechnique: _primaryTechnique(f),
      chain: [
        for (final stage in ChainStage.values)
          TechniqueEvidence(
            technique: _techniqueForStage(stage, f),
            stage: stage,
            signalId: _signalIdFor(stage, f),
            strength: _strengthFor(stage, supported[stage]!),
            supported: supported[stage]!,
            evidence: evidence[stage] ?? const [],
            noteCodes: notes[stage] ?? const [],
            ruleIds: _ruleIdsFor(stage, f),
          ),
      ],
      missing: missing,
      confidence: confidence,
      severity: severity,
      score: score,
      scoringVersion: scoringVersion,
      baselineEntryId: f.baselineEntryId,
    );
  }

  /// 段 → 规则 id。规则 id 是稳定的机器标识，不随文案变化。
  static List<String> _ruleIdsFor(ChainStage stage, CryptoTheftFacts f) {
    final android = f.platform == SecurityPlatform.android;
    final chain = android ? 'ANDROID-THEFT-CHAIN' : 'IOS-THEFT-CHAIN';
    return switch (stage) {
      ChainStage.capability => [
          chain,
          if (android && f.specialAccess) 'ANDROID-ACCESSIBILITY-ABUSE',
        ],
      ChainStage.source => [
          // 地址字面量 + 任一剪贴板方向就足以把这一段落映射到地址替换规则；
          // 不再额外要求 walletContext —— 否则 source 已支撑、ruleIds 却是空。
          if (f.addressLiteral && (f.clipboardRead || f.clipboardWrite))
            android
                ? 'ANDROID-CLIPBOARD-ADDRESS-SWAP'
                : 'IOS-CLIPBOARD-ADDRESS-SWAP',
          if (f.keyMaterial && f.networkSink)
            android ? 'ANDROID-MNEMONIC-EXFIL' : 'IOS-MNEMONIC-EXFIL',
        ],
      ChainStage.injection => [
          if (android && f.danglingLoad) 'ANDROID-LOAD-GRAPH-DANGLING',
          if (android && f.dynamicLoading) 'ANDROID-PAYLOAD-DROPPED',
          if (!android && f.injectedDylib) 'IOS-INJECTED-DYLIB-LOADED',
          if (!android && f.danglingLoad) 'IOS-DANGLING-LOAD',
        ],
      ChainStage.payload => [
          if (f.suspiciousPayload)
            android ? 'ANDROID-PAYLOAD-DROPPED' : 'IOS-INJECTED-DYLIB-LOADED',
        ],
      ChainStage.family => [chain],
    };
  }

  static (CryptoTheftLevel, SecuritySeverity, SecurityConfidence) _levelOf({
    required CryptoTheftFacts f,
    required Map<ChainStage, bool> supported,
    required int stageCount,
    required bool hasWalletChain,
    required bool hasInjection,
    required bool hasPayload,
  }) {
    if (f.sealMismatch || f.baselineMismatch) {
      return (
        CryptoTheftLevel.strongEvidence,
        SecuritySeverity.p1,
        SecurityConfidence.confirmed,
      );
    }
    if (hasInjection && hasPayload && hasWalletChain) {
      return (
        CryptoTheftLevel.strongEvidence,
        SecuritySeverity.p1,
        // 仍然是「强证据」，不是「看见它偷了」。
        SecurityConfidence.suspected,
      );
    }
    if ((hasInjection && hasPayload) || (f.danglingLoad && hasWalletChain)) {
      return (
        CryptoTheftLevel.suspicious,
        SecuritySeverity.p2,
        SecurityConfidence.suspected,
      );
    }
    if (hasWalletChain && f.clipboardWrite && f.addressLiteral) {
      return (
        CryptoTheftLevel.suspicious,
        SecuritySeverity.p2,
        SecurityConfidence.suspected,
      );
    }
    if (hasWalletChain && f.keyMaterial && f.networkSink) {
      return (
        CryptoTheftLevel.suspicious,
        SecuritySeverity.p2,
        SecurityConfidence.suspected,
      );
    }
    if (hasWalletChain &&
        (f.keyMaterial || f.clipboardWrite || f.addressLiteral)) {
      return (
        CryptoTheftLevel.capabilityOnly,
        SecuritySeverity.p3,
        SecurityConfidence.independentCapability,
      );
    }
    if (supported[ChainStage.capability]! || stageCount > 0) {
      return (
        CryptoTheftLevel.capabilityOnly,
        SecuritySeverity.p3,
        SecurityConfidence.independentCapability,
      );
    }
    if (f.coverageIncomplete) {
      return (
        CryptoTheftLevel.unknown,
        SecuritySeverity.unknown,
        SecurityConfidence.unknown,
      );
    }
    return (
      CryptoTheftLevel.none,
      SecuritySeverity.info,
      SecurityConfidence.confirmed,
    );
  }

  static int? _score(Map<ChainStage, bool> supported, CryptoTheftLevel level) {
    if (level == CryptoTheftLevel.unknown) return null;
    var weighted = 0;
    for (final stage in ChainStage.values) {
      if (supported[stage] ?? false) weighted += _weights[stage]!;
    }
    return ((weighted / 120) * 100).round().clamp(0, 100);
  }

  static String _whyMissing(ChainStage stage, CryptoTheftFacts f) {
    return switch (stage) {
      ChainStage.capability => 'missing.noCapability',
      ChainStage.source => 'missing.noSource',
      ChainStage.injection => 'missing.noInjection',
      ChainStage.payload =>
        f.packed ? 'missing.shellPacked' : 'missing.noPayload',
      ChainStage.family => 'missing.noBaseline',
    };
  }

  static String _signalIdFor(ChainStage stage, CryptoTheftFacts f) {
    return switch (stage) {
      ChainStage.capability => f.walletContext ? 'walletContext' : 'capability',
      ChainStage.source => f.clipboardRead ? 'clipboard-read' : 'seed-input',
      ChainStage.injection => f.injectedDylib
          ? 'injected-dylib'
          : f.danglingLoad
              ? 'load-graph-dangling'
              : 'dynamic-loading',
      ChainStage.payload => f.suspiciousPayload ? 'payload' : 'no-payload',
      ChainStage.family => f.baselineMismatch ? 'baseline' : 'no-baseline',
    };
  }

  static TechniqueStrength _strengthFor(ChainStage stage, bool supported) {
    if (!supported) return TechniqueStrength.stringOnly;
    return switch (stage) {
      ChainStage.capability => TechniqueStrength.codeReference,
      ChainStage.source => TechniqueStrength.callSite,
      ChainStage.injection => TechniqueStrength.artifact,
      ChainStage.payload => TechniqueStrength.artifact,
      ChainStage.family => TechniqueStrength.baseline,
    };
  }

  static TheftTechnique? _primaryTechnique(CryptoTheftFacts f) {
    if (f.clipboardWrite || f.addressLiteral) {
      return TheftTechnique.addressSwap;
    }
    if (f.keyMaterial || f.seedInput) return TheftTechnique.mnemonicPhish;
    if (f.webViewBridge) return TheftTechnique.approvalPhish;
    if (f.clipboardRead) return TheftTechnique.clipboardHijack;
    return TheftTechnique.unknown;
  }

  static TheftTechnique _techniqueForStage(
    ChainStage stage,
    CryptoTheftFacts f,
  ) {
    return _primaryTechnique(f) ?? TheftTechnique.unknown;
  }
}
