import 'package:analysis_model/analysis_model.dart';

import '../models.dart';
import 'dex_clue_scanner.dart';
import 'dex_method_scanner.dart';

/// 组合规则用到的**事实**：扫描结果的一次性归纳。
///
/// 抽这张表的直接动因是「顺序隐式依赖」：抽表前，规则 B 里算出的
/// `hasImageInput` 被规则 C / D / E 读取，于是**规则的书写顺序成了语义的一部分** ——
/// 调换两段就会改变结论，而读代码看不出来。
///
/// 现在每条规则只从**事实**里取输入，规则之间互不读取对方的产物，
/// 因此表里的顺序只影响输出顺序，不影响结论。
class AndroidRuleFacts {
  const AndroidRuleFacts({
    required this.meta,
    required this.scan,
    required this.methodScan,
    required this.effectivePhotoAccess,
    required this.broadStorage,
    required this.backgroundPermissions,
    required this.photoClues,
    required this.ocrClues,
    required this.uploadClues,
    required this.backgroundClues,
    required this.ocrCodeRefs,
    required this.uploadCodeRefs,
    required this.hasOcrCapability,
    required this.hasUploadCapability,
    required this.hasDexContent,
  });

  final ApkMeta meta;
  final DexScanResult scan;
  final DexMethodScanResult methodScan;

  /// 在当前 `targetSdk` 下**仍然生效**的相册 / 存储权限。
  final List<AndroidPermissionRequest> effectivePhotoAccess;

  /// 其中属于「广泛存储访问」的那部分（规则 A 的输入）。
  final List<AndroidPermissionRequest> broadStorage;

  final List<AndroidPermissionRequest> backgroundPermissions;

  final List<CodeClue> photoClues;
  final List<CodeClue> ocrClues;
  final List<CodeClue> uploadClues;
  final List<CodeClue> backgroundClues;

  final List<CodeReference> ocrCodeRefs;
  final List<CodeReference> uploadCodeRefs;

  final bool hasOcrCapability;
  final bool hasUploadCapability;

  /// 本次是否读到了 DEX 内容。影响规则 F 的置信度。
  final bool hasDexContent;

  /// 是否存在图像输入来源（权限或代码线索）。
  bool get hasImageInput =>
      effectivePhotoAccess.isNotEmpty || photoClues.isNotEmpty;

  /// 是否存在后台入口：后台权限、后台线索，或声明了 service / receiver 组件。
  bool get hasBackground =>
      backgroundPermissions.isNotEmpty ||
      backgroundClues.isNotEmpty ||
      meta.components.any((c) =>
          c.type == ComponentType.service || c.type == ComponentType.receiver);

  /// 是否存在明文流量配置。
  bool get allowsCleartext => meta.applicationUsesCleartextTraffic == true;

  /// 规则 D 的升级条件：明文流量**同时**存在图像 / 识别 / 上传 / 域名线索。
  bool get hasSensitiveAlongsideCleartext =>
      hasImageInput ||
      hasOcrCapability ||
      hasUploadCapability ||
      scan.domains.isNotEmpty;
}

/// 一条 Android 组合规则。
///
/// 规则是**数据**：`matches` 决定命中，`build` 构造发现项。加一条规则 =
/// 往 [androidSecurityRules] 里加一项，不需要动 `audit()` 的编排代码 ——
/// 与 [PermissionCatalog] 同一思路（那边是权限表，这边是组合规则表）。
///
/// **判定与构造分开**，是因为测试要能「逐条驱动」：对一份事实，
/// 可以直接问「哪几条规则命中」，而不必先把发现项造出来再按 id 去翻。
class AndroidSecurityRule {
  /// 稳定的规则 id。与 `SecurityFinding.ruleId` 一致（三元变体另见各规则注释）。
  final String id;

  /// 这条规则在**报告里**的说明（英文回退；本地化在呈现层按 ruleId 取）。
  ///
  /// 抽表前这段说明只存在于注释里，表化之后它成了可被测试读取的数据 ——
  /// 测试可以断言「每条规则都写了说明」，避免新加的规则只有代码没有解释。
  final String summary;

  final bool Function(AndroidRuleFacts facts) matches;

  final SecurityFinding Function(AndroidRuleFacts facts) build;

  const AndroidSecurityRule({
    required this.id,
    required this.summary,
    required this.matches,
    required this.build,
  });
}

/// 全部组合规则。**顺序即报告里的输出顺序**，与抽表前一致。
const List<AndroidSecurityRule> androidSecurityRules = [
  AndroidSecurityRule(
    id: 'ANDROID-RULE-A',
    summary: '广泛相册 / 存储访问，但未见对应的图片业务用途线索。',
    matches: _matchesRuleA,
    build: _buildRuleA,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-B',
    summary: '图像输入来源与文字识别能力同现。',
    matches: _matchesRuleB,
    build: _buildRuleB,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-C',
    summary: '图像输入 + 文字识别 + 上传调用三段同现，疑似外传链路。',
    matches: _matchesRuleC,
    build: _buildRuleC,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-D',
    summary: '允许明文流量；同时存在敏感线索时升级（ruleId 加 `-ESCALATED`）。',
    matches: _matchesRuleD,
    build: _buildRuleD,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-E',
    summary: '后台入口 + 敏感数据 + 上传三者齐备。',
    matches: _matchesRuleE,
    build: _buildRuleE,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-F',
    summary: '未发现上传特征时的显式「未发现」结论（不得读成「安全」）。',
    matches: _matchesRuleF,
    build: _buildRuleF,
  ),
];

// ---------------------------------------------------------------------------
// 各规则的判定
// ---------------------------------------------------------------------------

bool _matchesRuleA(AndroidRuleFacts f) => f.broadStorage.isNotEmpty;

bool _matchesRuleB(AndroidRuleFacts f) => f.hasImageInput && f.hasOcrCapability;

bool _matchesRuleC(AndroidRuleFacts f) =>
    f.hasImageInput && f.hasOcrCapability && f.hasUploadCapability;

bool _matchesRuleD(AndroidRuleFacts f) => f.allowsCleartext;

bool _matchesRuleE(AndroidRuleFacts f) =>
    f.hasBackground &&
    (f.hasImageInput || f.hasOcrCapability) &&
    f.hasUploadCapability;

/// 规格规则 F：**没有上传线索时必须显式产出这一条**，而不是留一个空列表
/// 让人以为查过了就等于安全。
bool _matchesRuleF(AndroidRuleFacts f) => f.uploadClues.isEmpty;

// ---------------------------------------------------------------------------
// 各规则的构造
// ---------------------------------------------------------------------------

SecurityFinding _buildRuleA(AndroidRuleFacts f) {
  final broadStorage = f.broadStorage;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-A',
    platform: SecurityPlatform.android,
    category: SecurityCategory.photoAccess,
    severity: SecuritySeverity.p2,
    confidence: SecurityConfidence.suspected,
    finding: 'Broad storage / photo library access found: '
        '${broadStorage.map((r) => r.shortName).join(', ')}, listed as a '
        'medium-risk candidate for manual review. This analysis found no '
        'obvious image-related feature clues in the package that would '
        'explain it (such as system photo picker calls or image list '
        'screens).',
    messageCode: 'android.rule_a',
    messageArgs: {
      'names': broadStorage.map((r) => r.shortName).toList(),
    },
    evidence: [
      for (final request in broadStorage) manifestEvidence(request),
    ],
    limitation: '"The business purpose is missing" is a static '
        'inference: the business code may live in unscanned native '
        'libraries, a hardened shell or a dynamically loaded module.',
    limitationCode: 'android.rule_a.limitation',
    recommendation: 'Manually check whether the app really needs '
        'whole-disk file access; if not, consider the system photo picker '
        '(Photo Picker) instead. This item is a candidate for review, not '
        'a malicious verdict.',
    recommendationCode: 'android.rule_a.manual_review',
  );
}

SecurityFinding _buildRuleB(AndroidRuleFacts f) {
  final effectivePhotoAccess = f.effectivePhotoAccess;
  final photoClues = f.photoClues;
  final ocrClues = f.ocrClues;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-B',
    platform: SecurityPlatform.android,
    category: SecurityCategory.ocrImage,
    severity: SecuritySeverity.p2,
    confidence: SecurityConfidence.suspected,
    finding: 'Both an image input source and text recognition capability '
        'were found: permission/code clues '
        '(${[
      ...effectivePhotoAccess.map((r) => r.shortName),
      ...photoClues.map((c) => c.description),
    ].join(', ')}) and recognition capability '
        '(${ocrClues.map((c) => c.description).join(', ')}). This '
        'combination may correspond to a normal feature (document '
        'scanning, translation, business card reading).',
    messageCode: 'android.rule_b',
    messageArgs: {
      'inputClues': [
        ...effectivePhotoAccess.map((r) => r.shortName),
        ...photoClues.map((c) => c.description),
      ],
      'ocrClues': ocrClues.map((c) => c.description).toList(),
    },
    evidence: [
      for (final request in effectivePhotoAccess) manifestEvidence(request),
      ...referenceEvidence(f.ocrCodeRefs),
      ...clueEvidence([...photoClues, ...ocrClues]),
    ],
    relationship: 'Image input → text recognition: the two clues '
        'co-occur, but they are not proven to lie on the same call path.',
    relationshipCode: 'android.rule_b.relationship',
    limitation: 'No disassembly was performed, so it cannot be determined '
        'whether the recognition module actually handles user-selected '
        'images or batch-scanned media files.',
    limitationCode: 'android.rule_b.limitation',
    recommendation: 'Confirm the recognition input source and how the '
        'user authorises it (whether it goes through the system photo '
        'picker).',
    recommendationCode: 'android.rule_b.confirm_pipeline',
  );
}

SecurityFinding _buildRuleC(AndroidRuleFacts f) {
  // 关联说明有两种措辞（同方法体 / 整包层面），因此先把 code 与回退
  // 一起算出来 —— 引擎不能只产出一句中文再让呈现层猜。
  final note = coOccurrenceNote(f.methodScan, f.ocrCodeRefs, f.uploadCodeRefs);
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-C',
    platform: SecurityPlatform.android,
    category: SecurityCategory.dataExfiltration,
    severity: SecuritySeverity.p1,
    confidence: SecurityConfidence.suspected,
    finding: 'Image input, text recognition and upload call clues all '
        'appear together: a suspected path for sensitive data leaving '
        'the device. This is a high-risk **candidate**; static analysis '
        'could not prove that data actually flows into an upload '
        'request.',
    messageCode: 'android.rule_c',
    evidence: [
      for (final request in f.effectivePhotoAccess) manifestEvidence(request),
      ...referenceEvidence([...f.ocrCodeRefs, ...f.uploadCodeRefs]),
      ...clueEvidence([...f.ocrClues, ...f.uploadClues]),
    ],
    dataSource: '照片/媒体文件与其中的识别文本',
    // 中间跳：同方法体时是那个方法；整包层面时留空（不编造）。
    dataTransform: note.caller,
    dataSink: '上传请求（multipart / upload API）',
    relationship: note.fallback,
    relationshipCode: note.code,
    relationshipArgs: note.args,
    limitation: 'The association comes from multiple markers co-occurring, '
        'not from call-graph analysis; reflection, dynamic loading and '
        'hardening may all make the real path different.',
    limitationCode: 'android.rule_c.limitation',
    recommendation: 'Review manually first; you can capture and verify '
        'the actual outbound content in an isolated environment '
        '(requires dynamic testing, not provided in this version).',
    recommendationCode: 'android.rule_c.manual_review',
  );
}

SecurityFinding _buildRuleD(AndroidRuleFacts f) {
  final withSensitive = f.hasSensitiveAlongsideCleartext;
  return SecurityFinding(
    ruleId: withSensitive ? 'ANDROID-RULE-D-ESCALATED' : 'ANDROID-RULE-D',
    platform: SecurityPlatform.android,
    category: SecurityCategory.configuration,
    severity: withSensitive ? SecuritySeverity.p1 : SecuritySeverity.p2,
    confidence: SecurityConfidence.confirmed,
    finding: withSensitive
        ? 'The app allows cleartext traffic '
            '(usesCleartextTraffic=true), and image / recognition / '
            'upload clues are present at the same time: sensitive data '
            'may travel over an unencrypted channel.'
        : 'The app allows cleartext traffic '
            '(usesCleartextTraffic=true).',
    messageCode: withSensitive ? 'android.rule_d_escalated' : 'android.rule_d',
    evidence: [
      const SecurityEvidence(
        source: SecurityEvidenceSource.manifest,
        location: 'AndroidManifest.xml / manifest / application',
        detail: 'android:usesCleartextTraffic="true"',
      ),
    ],
    limitation: 'Allowing cleartext in the configuration is not the same '
        'as actually using cleartext; the specific requests would need '
        'packet capture to confirm. The exception domains in '
        'networkSecurityConfig are not expanded.',
    limitationCode: 'android.rule_d.limitation',
    recommendation: 'Confirm whether cleartext requests actually exist; '
        'turn the switch off if it is not needed.',
    recommendationCode: 'android.rule_d.manual_review',
  );
}

SecurityFinding _buildRuleE(AndroidRuleFacts f) {
  final backgroundClues = f.backgroundClues;
  final backgroundPermissions = f.backgroundPermissions;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-E',
    platform: SecurityPlatform.android,
    category: SecurityCategory.backgroundTask,
    severity: SecuritySeverity.p1,
    confidence: SecurityConfidence.suspected,
    finding: 'Background task, sensitive data access and upload call '
        'clues all appear together and corroborate each other: further '
        'verification at runtime is needed. Finding only a background '
        'task or a network permission is not malicious evidence.',
    messageCode: 'android.rule_e',
    evidence: [
      for (final clue in backgroundClues)
        SecurityEvidence(
          source: SecurityEvidenceSource.dexString,
          location: clue.dexNames.join(', '),
          detail: '${clue.markerId}: ${clue.samples.join(' | ')}',
        ),
      if (backgroundPermissions.isNotEmpty)
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'AndroidManifest.xml / manifest / uses-permission',
          detail:
              backgroundPermissions.map((r) => r.shortName).take(8).join(', '),
        ),
      for (final request in f.effectivePhotoAccess) manifestEvidence(request),
    ],
    relationship: 'Background entry point + sensitive data source + '
        'upload sink: the three kinds of evidence co-occur, but "whether '
        'the app actually processes and uploads media data in the '
        'background" is not proven.',
    relationshipCode: 'android.rule_e.relationship',
    limitation: 'No dynamic analysis was run, so the actual triggering '
        'and execution of background tasks cannot be observed.',
    limitationCode: 'android.rule_e.limitation',
    recommendation: 'Run it in an isolated environment and confirm after '
        'observing the network behaviour.',
    recommendationCode: 'android.rule_e.manual_review',
  );
}

SecurityFinding _buildRuleF(AndroidRuleFacts f) {
  final noDex = !f.hasDexContent;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-F',
    platform: SecurityPlatform.android,
    category: SecurityCategory.dataExfiltration,
    severity: SecuritySeverity.info,
    confidence:
        noDex ? SecurityConfidence.unknown : SecurityConfidence.confirmed,
    finding: 'No upload-related code characteristics were found within '
        'the current analysis scope (no hits for multipart upload, file '
        'upload APIs or similar markers). This does not mean the app has '
        'no upload behaviour — it only means this static scan found none.',
    messageCode: 'android.rule_f',
    evidence: const [],
    limitation: noDex
        ? 'No DEX content was read this time, so the confidence of the '
            '"not found" conclusion is incomplete.'
        : 'String scanning does not cover native libraries, resources or '
            'code inside a hardened shell.',
    limitationCode: noDex
        ? 'android.rule_f.limitation_no_dex'
        : 'android.rule_f.limitation_scope',
    recommendation: 'To rule out upload behaviour, combine this with '
        'dynamic traffic observation (not provided in this version).',
    recommendationCode: 'android.rule_f.runtime_traffic',
  );
}

// ---------------------------------------------------------------------------
// 证据构造（规则与编排共用，因此是**包内可见**的顶层函数）
// ---------------------------------------------------------------------------

/// 把一条权限请求转成证据条目。
SecurityEvidence manifestEvidence(AndroidPermissionRequest request) {
  return SecurityEvidence(
    source: SecurityEvidenceSource.manifest,
    location: 'AndroidManifest.xml / manifest / uses-permission'
        '[@name="${request.name}"]',
    detail: '$request',
  );
}

/// 把字符串线索转成证据条目。
List<SecurityEvidence> clueEvidence(List<CodeClue> clues) {
  return [
    for (final clue in clues)
      SecurityEvidence(
        source: SecurityEvidenceSource.dexString,
        location: clue.dexNames.join(', '),
        detail: '${clue.markerId}: ${clue.samples.join(' | ')}',
      ),
  ];
}

/// 把方法引用转成证据条目。
///
/// **引用与调用点分成两条证据**，因为它们回答的不是同一个问题：
/// - 「引用」来自 `method_ids`，只说明字节码引用过这个方法（也可能只是
///   方法签名）；
/// - 「调用点」来自 `code_item` 的 `invoke-*` 指令，能落到具体方法名与
///   指令偏移。
///
/// 合成一条会丢掉「是引用还是真的有一条调用指令」这个区别。
List<SecurityEvidence> referenceEvidence(List<CodeReference> references) {
  return [
    for (final reference in references) ...[
      if (reference.samples.isNotEmpty)
        SecurityEvidence(
          source: SecurityEvidenceSource.dexMethodReference,
          location: reference.dexNames.join(', '),
          detail: '${reference.markerId} (reference): '
              '${reference.samples.join(' | ')}',
          detailCode: 'code.reference',
          detailArgs: {
            'marker': reference.markerId,
            'samples': reference.samples.join(' | '),
          },
        ),
      if (reference.callSiteSamples.isNotEmpty)
        SecurityEvidence(
          source: SecurityEvidenceSource.dexMethodReference,
          location: reference.dexNames.join(', '),
          detail: '${reference.markerId} (call site): '
              '${reference.callSiteSamples.join(' | ')}',
          detailCode: 'code.call_site',
          detailArgs: {
            'marker': reference.markerId,
            'samples': reference.callSiteSamples.join(' | '),
          },
        ),
    ],
  ];
}

/// 描述「识别与上传的调用指令是否位于同一个方法体内」。
///
/// 这是调用点分析带来的新信息：字符串同现只能说「两个词都出现在这个包里」。
/// 但措辞必须守住界线 —— **同一个方法里既有识别又有上传，不等于识别结果被
/// 送进了上传请求**，那要看寄存器与参数传递，属于数据流分析。
///
/// 返回 `(code, fallback, args)` 三元组：引擎产不出本地化文案，只给稳定 id
/// 与英文回退，由呈现层按语言取文案。
({
  String code,
  String fallback,
  Map<String, Object> args,
  // 中间跳的**机器可读定位**：识别与上传的调用指令都落在哪个方法里。
  // 整包层面（不在同一方法体）时为 `null` —— 不编造一个「大概是这里」。
  String? caller,
}) coOccurrenceNote(
  DexMethodScanResult scan,
  List<CodeReference> ocrReferences,
  List<CodeReference> uploadReferences,
) {
  final occurrence = scan.firstCoOccurrenceAcross(
    ocrReferences.map((r) => r.markerId),
    uploadReferences.map((r) => r.markerId),
  );
  if (occurrence == null) {
    return (
      code: 'android.rule_c.relationship_package',
      fallback: 'The call instructions for text recognition and upload are '
          '**not in the same method body** (the co-occurrence is at the '
          'whole-package level). Reading a photo → image text recognition → '
          'building an upload request: there is evidence for each of the '
          'three stages, but "the data flow along the same code path" is '
          'not proven — the unproven hop is the recognition result entering '
          'the upload request.',
      args: const {},
      caller: null,
    );
  }
  return (
    code: 'android.rule_c.relationship_method',
    fallback: 'The call instructions for text recognition and upload '
        'appear **in the same method body** '
        '(${occurrence.callerDisplayName}); but co-occurrence within one '
        'method is not data flow: whether the recognition result is fed '
        'into the upload request is not proven. Reading a photo → image '
        'text recognition → building an upload request: there is evidence '
        'for each of the three stages, but "the data flow along the same '
        'code path" is not proven.',
    args: {'caller': occurrence.callerDisplayName},
    caller: occurrence.callerDisplayName,
  );
}
