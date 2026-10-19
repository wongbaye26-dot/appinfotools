/// 安全检测引擎的**平台中立**数据模型。
///
/// 与 `FieldValue` 同属一类东西：描述「我们观察到了什么、证据在哪、有多确定」，
/// 不含任何 Android / iOS 格式概念。两个平台的审计器各自产出 [SecurityFinding]，
/// 应用层的规则引擎、UI 与报告只面对这一套类型。
///
/// 三条设计约束，来自规格本身，不是偏好：
///
/// 1. **等级不是权限数量决定的**。规则引擎要考虑证据强度、业务合理性、数据
///    敏感程度、用户参与方式与数据流关联程度，因此 severity 与 finding 分离：
///    同一条权限在不同组合里可以落在不同等级。
/// 2. **「没有找到」不等于「安全」**。[SecurityAnalysisResult] 因此把
///    `limitations`（未覆盖、被截断、加固读不到）与 `findings` 并列，
///    「未发现相关特征」必须由规则 F 显式产出一条 INFO，而不是靠空列表暗示。
/// 3. **没有证据的字段必须留空或标 unknown**，不允许为了让报告显得完整而猜测。
library;

import 'analysis_coverage.dart';
import 'network_facts.dart';

/// 平台。
enum SecurityPlatform {
  android,
  ios;

  String get displayName => switch (this) {
        SecurityPlatform.android => 'Android',
        SecurityPlatform.ios => 'iOS',
      };
}

/// 风险等级。规格第五章。
///
/// [rank] 越小越严重，用于「取最严重的一条」。UNKNOWN 单独一类：它不是「没风险」，
/// 而是「没法给结论」，与 P3（低风险）有本质区别。
enum SecuritySeverity {
  p0('Severe'),
  p1('High'),
  p2('Medium'),
  p3('Low'),
  info('Info'),
  unknown('Unknown');

  const SecuritySeverity(this.label);

  final String label;

  /// 排序权重：0 最严重，5 是「无法确认」。
  int get rank => switch (this) {
        SecuritySeverity.p0 => 0,
        SecuritySeverity.p1 => 1,
        SecuritySeverity.p2 => 2,
        SecuritySeverity.p3 => 3,
        SecuritySeverity.info => 4,
        SecuritySeverity.unknown => 5,
      };

  /// 是否属于「需要关注的风险档位」（P0–P3）。
  bool get isRisk =>
      this == SecuritySeverity.p0 ||
      this == SecuritySeverity.p1 ||
      this == SecuritySeverity.p2 ||
      this == SecuritySeverity.p3;

  /// 该等级是否意味着「覆盖不足 / 无法得出结论」。
  ///
  /// UI 见到它必须渲染成「暂不能作出完整结论」而不是绿色。
  bool get isInconclusive => this == SecuritySeverity.unknown;
}

/// 证据置信度 / 关联状态。规格 7.3 的四态。
///
/// 四态必须分开渲染：把「仅发现独立能力」显示成「已证实关联」是最危险的误导 ——
/// 用户会以为数据流已经被追踪到了。
enum SecurityConfidence {
  /// 已证实：同一可追踪路径上的证据，或受信任工具的明确结论。
  confirmed,

  /// 疑似关联：多个线索同时存在，但静态分析未能证实数据流向。
  suspected,

  /// 仅发现独立能力：例如只看到 OCR SDK，没有输入源也没有去路。
  independentCapability,

  /// 无法确认：加固、混淆、加密、解析失败或检测范围之外。
  unknown;

  String get label => switch (this) {
        SecurityConfidence.confirmed => 'confirmed',
        SecurityConfidence.suspected => 'suspected association',
        SecurityConfidence.independentCapability =>
          'independent capability only',
        SecurityConfidence.unknown => 'unknown',
      };
}

/// 发现项类别。规格 3.x / 4.x 的检测主题。
enum SecurityCategory {
  /// 照片、视频、存储等媒体访问。
  photoAccess,

  /// OCR、图像处理、截图分析。
  ocrImage,

  /// 敏感数据向网络请求 / 上传接口 / 第三方服务的汇聚。
  dataExfiltration,

  /// 网络能力、域名、明文通信。
  network,

  /// 第三方 SDK 与依赖。
  thirdPartySdk,

  /// 后台任务、动态加载、危险组件。
  backgroundTask,

  /// 设备标识、应用列表等其它敏感数据来源。
  deviceData,

  /// 配置类问题（明文流量、危险开关）。
  configuration,

  /// 未归类。
  other;

  String get label => switch (this) {
        SecurityCategory.photoAccess => 'photo & media access',
        SecurityCategory.ocrImage => 'OCR & image processing',
        SecurityCategory.dataExfiltration => 'data collection & exfiltration',
        SecurityCategory.network => 'network behaviour',
        SecurityCategory.thirdPartySdk => 'third-party SDK',
        SecurityCategory.backgroundTask => 'background tasks',
        SecurityCategory.deviceData => 'device data',
        SecurityCategory.configuration => 'configuration',
        SecurityCategory.other => 'other',
      };
}

/// 证据的来源类型。规格 7.5 要求报告注明「证据是来自 Manifest、Info.plist、
/// 隐私清单、DEX 字符串、Mach-O 符号、静态调用分析还是实际运行时记录」。
enum SecurityEvidenceSource {
  /// Android `AndroidManifest.xml`。
  manifest,

  /// Android `res/xml/network_security_config.xml`。
  ///
  /// 与 [manifest] 分开，是因为它**会被清单引用但不等同于清单**：
  /// API 24 起只要声明了 NSC，`android:usesCleartextTraffic` 就被平台忽略，
  /// 明文策略完全由这份 XML 决定。拿 `manifest` 当它的来源，界面上会打出
  /// 「AndroidManifest.xml」的标签，而证据行写的是 `res/8G.xml` ——
  /// 读者第一反应是「到底哪个说的算」。
  networkSecurityConfig,

  /// iOS `Info.plist`。
  infoPlist,

  /// iOS `PrivacyInfo.xcprivacy`。
  privacyInfo,

  /// DEX 字符串。
  dexString,

  /// DEX 方法引用（`method_ids` 里的条目）。
  ///
  /// 与 [dexString] 刻意分开：字符串常量可以随便写（`"okhttp3"` 出现在一句
  /// 注释式的字面量里也会被扫到），而 `method_ids` 的条目来自字节码的 invoke
  /// 指令、方法签名或方法句柄 —— 它回答的是「代码引用了这个方法」，
  /// 比「字符串里提到了这个词」强得多。
  ///
  /// 但**仍然不等于「调用了」**：`method_ids` 只说明引用存在，
  /// 没有回答「在哪个方法里、被调了几次」。
  dexMethodReference,

  /// Mach-O 符号 / 字符串。
  machoSymbol,

  /// 原生库（ELF / Mach-O）的**符号表**条目。
  ///
  /// 与 [machoSymbol] 分开：那个目前用于 iOS 侧的符号/字符串线索，
  /// 这个专指「从 ELF `.dynsym` 读出的导入/导出符号」—— 符号名是精确的
  /// 标识符（`system`、`dlopen`、`ptrace`），比字符串命中确定得多。
  nativeSymbol,

  /// 归档条目名或结构（ZIP 目录）。
  zipEntry,

  /// 描述文件 / Entitlements。
  provisioning,

  /// 运行时观察（本版本不产出，枚举先行占位）。
  runtime,

  /// 其它 / 未能归类。
  other;

  String get label => switch (this) {
        SecurityEvidenceSource.manifest => 'AndroidManifest.xml',
        SecurityEvidenceSource.networkSecurityConfig =>
          'network security config',
        SecurityEvidenceSource.infoPlist => 'Info.plist',
        SecurityEvidenceSource.privacyInfo => 'PrivacyInfo.xcprivacy',
        SecurityEvidenceSource.dexString => 'DEX strings',
        SecurityEvidenceSource.dexMethodReference => 'DEX method references',
        SecurityEvidenceSource.machoSymbol => 'Mach-O symbols',
        SecurityEvidenceSource.nativeSymbol => 'native library symbols',
        SecurityEvidenceSource.zipEntry => 'archive entry',
        SecurityEvidenceSource.provisioning => 'provisioning / entitlements',
        SecurityEvidenceSource.runtime => 'runtime observation',
        SecurityEvidenceSource.other => 'other',
      };
}

/// 一条原始证据。
///
/// [location] 必须能指回文件里的具体位置（例如
/// `AndroidManifest.xml / manifest / uses-permission[@name=…]`），
/// [detail] 是原文或原文摘录 —— 「有证据」的最低标准就是别人能按这个地址复现。
class SecurityEvidence {
  final SecurityEvidenceSource source;

  /// 证据在文件中的位置描述。
  ///
  /// 绝大多数位置是**机器可读的事实**（`AndroidManifest.xml / manifest`、
  /// `Payload/App.app/Info.plist`），不需要本地化。少数是给人读的描述
  /// （如「N 个 DEX 的字符串」）—— 那些带 [locationCode]。
  final String location;

  /// [location] 的稳定标识与参数；`null` 表示无需本地化（直接显示原文）。
  final String? locationCode;
  final Map<String, Object> locationArgs;

  /// 原文或摘录（可能很长，由产出方自行截断，但不得改写含义）。
  ///
  /// **迁移中**：带 [detailCode] 时这里放**英文回退**，呈现层用本地化文案
  /// （`AnalysisReport.detailText`）。没填 code 的条目继续按原文渲染 ——
  /// 与 `SecurityFinding.finding` 同一套增量机制。
  final String detail;

  /// [detail] 的稳定标识与参数；`null` 表示尚未迁移。
  ///
  /// 需要它是因为详情里的**标签**也是给人读的：「引用」「调用点」「导入」
  /// 此前由引擎直接写成中文括号，英文界面里就出现 `（引用）`。
  final String? detailCode;
  final Map<String, Object> detailArgs;

  const SecurityEvidence({
    required this.source,
    required this.location,
    required this.detail,
    this.locationCode,
    this.locationArgs = const {},
    this.detailCode,
    this.detailArgs = const {},
  });

  @override
  String toString() => 'SecurityEvidence(${source.label} @ $location: $detail)';
}

/// 一条安全发现项。规格第六章的统一数据模型。
///
/// 刻意不用「拼接好的段落」而是结构化字段：UI 要按类别筛选、报告要按证据
/// 追溯、规则引擎要能比较等级与置信度 —— 三者都要求字段可寻址。
class SecurityFinding {
  /// 规则编号，例如 `ANDROID-RULE-B`。同一规则重复命中时应复用同一编号，
  /// 便于统计与规则库版本对照。
  final String ruleId;

  final SecurityPlatform platform;

  final SecurityCategory category;

  final SecuritySeverity severity;

  final SecurityConfidence confidence;

  /// 发现内容（一句话结论）。措辞受规格约束：
  /// 未证实的数据流只能用「疑似」「可能」「发现……线索」。
  final String finding;

  /// 支撑该结论的原始证据。空列表意味着这条发现没有依据 —— 不允许出现。
  final List<SecurityEvidence> evidence;

  /// 可能的数据来源（照片、OCR 文本、设备标识……）；没有则为 `null`。
  ///
  /// 留空而不是填「未知」占位：没有证据的来源写上去就是编造。
  final String? dataSource;

  /// 可能的数据去向（上传请求、第三方域名……）；没有则为 `null`。
  final String? dataSink;

  /// 来源与去向之间的**中间跳**（处理环节）；没有则为 `null`。
  ///
  /// 目前唯一的产出方是 `ANDROID-RULE-C` 的「同一方法体」分支：此时中间跳
  /// 就是**那个方法**（识别与上传的调用指令都在它里面），值形如
  /// `Lcom/example/Pipeline;.run(Landroid/graphics/Bitmap;)V`。
  ///
  /// **刻意是自由文本而不是结构化 hop 列表**：静态分析能确定到「哪个方法」
  /// 这一级，确定不到「哪个寄存器、哪次赋值」。把 hop 做成结构化数组会让人
  /// 以为逐跳都验证过了 —— 那是另一回事（数据流分析，本版本不做）。
  ///
  /// 与 [relationship] 的分工：这里是**机器可读的定位**（可以拿去搜代码），
  /// relationship 是**给人读的说明**（包含「哪一段没证实」）。
  final String? dataTransform;

  /// 来源 → 处理 → 去向之间的关联情况说明。
  ///
  /// 未证实时要**明确展示未能证实的环节**，不得补全不存在的证据。
  final String? relationship;

  /// 该发现的检测局限（例如「未反汇编，关联来自标记同现」）。
  final String? limitation;

  /// 建议的人工核查或整改措施。
  final String recommendation;

  /// [finding] 的**稳定标识**与占位符实参；`null` 表示尚未迁移。
  ///
  /// 引擎层（`apk_parser` / `ipa_parser`）不依赖 slang，产不出本地化文案，
  /// 因此逐步迁移成「稳定 code + 英文回退 + 参数」，由呈现层
  ///（`AnalysisReport.findingText`）本地化。
  ///
  /// **刻意是可选的**：迁移是增量的，没填 code 的发现项继续按原文渲染 ——
  /// 这样任何时刻都不会出现「一半中文一半英文」的中间态。
  final String? messageCode;
  final Map<String, Object> messageArgs;

  /// [recommendation] 的稳定标识与参数，语义同 [messageCode]。
  ///
  /// 与 [messageCode] 分开是因为两者是**两句独立的话**，各有各的占位符。
  final String? recommendationCode;
  final Map<String, Object> recommendationArgs;

  /// [relationship] 的稳定标识，语义同 [messageCode]。
  ///
  /// 与 [messageCode] 分开的理由同上：关联说明是**独立的一句话**。
  ///
  /// 起初刻意没配参数表（「加了没人读的参数表只会让漏传编译通过」）。
  /// Android 规则 C 的关联说明要嵌「识别与上传的调用指令出现在哪个方法体里」，
  /// 于是补上了 [relationshipArgs] —— **有真实消费者才加**，不是预留。
  final String? relationshipCode;
  final Map<String, Object> relationshipArgs;

  /// [limitation] 的稳定标识与参数，语义同 [relationshipCode]。
  final String? limitationCode;
  final Map<String, Object> limitationArgs;

  const SecurityFinding({
    required this.ruleId,
    required this.platform,
    required this.category,
    required this.severity,
    required this.confidence,
    required this.finding,
    required this.evidence,
    this.dataSource,
    this.dataSink,
    this.dataTransform,
    this.relationship,
    this.limitation,
    required this.recommendation,
    this.messageCode,
    this.messageArgs = const {},
    this.recommendationCode,
    this.recommendationArgs = const {},
    this.relationshipCode,
    this.relationshipArgs = const {},
    this.limitationCode,
    this.limitationArgs = const {},
  });

  /// 去掉**本 finding 内**完全相同的证据条目，返回新的 finding。
  ///
  /// 判重键是「来源 + 位置 + 摘要」三元组 —— 三者相同才算重复。
  ///
  /// **跨 finding 的重复刻意保留**：规则 A 与规则 B 都引用「相册权限」是
  /// 合理的，它们本就都基于这条证据。强行跨 finding 去重会让读者无法从
  /// 单条发现看出完整依据，反而更难复核。
  SecurityFinding withDedupedEvidence() {
    final seen = <String>{};
    final unique = <SecurityEvidence>[];
    for (final e in evidence) {
      final key = '${e.source.name}\u0000${e.location}\u0000${e.detail}';
      if (seen.add(key)) unique.add(e);
    }
    if (unique.length == evidence.length) return this;
    return SecurityFinding(
      ruleId: ruleId,
      platform: platform,
      category: category,
      severity: severity,
      confidence: confidence,
      finding: finding,
      evidence: unique,
      dataSource: dataSource,
      dataSink: dataSink,
      dataTransform: dataTransform,
      relationship: relationship,
      limitation: limitation,
      recommendation: recommendation,
      // 迁移用的 code **必须一起带上**：漏掉它们会让去重后的发现项
      // 悄悄退回原文（Android 侧对每条发现都调这个方法）。
      messageCode: messageCode,
      messageArgs: messageArgs,
      recommendationCode: recommendationCode,
      recommendationArgs: recommendationArgs,
      relationshipCode: relationshipCode,
      relationshipArgs: relationshipArgs,
      limitationCode: limitationCode,
      limitationArgs: limitationArgs,
    );
  }

  @override
  String toString() => 'SecurityFinding($ruleId, ${severity.name}/'
      '${confidence.name}${category.name}: $finding)';
}

/// 一条**结果级局限**：稳定 code + 英文回退 + 参数。
///
/// 与 `CoverageEntry.noted` 的三件套同构：引擎层不依赖 slang，产不出本地化
/// 文案，因此给的是**可映射的 id + 英文回退**；呈现层按 [code] 取本地化文本
///（`AnalysisReport.limitationNoteText`），认不出来才回退到 [fallback]。
///
/// 此前这里是裸 `String` 且写的是中文 —— 英文/日文/韩文报告里会混进中文。
class AnalysisNote {
  /// 稳定标识（`ios.offline_static_analysis` 这类），给程序读。
  final String code;

  /// 英文回退，给人读。呈现层认不出 [code] 时用它。
  final String fallback;

  /// 占位符实参。
  final Map<String, Object> args;

  const AnalysisNote(this.code, this.fallback, [this.args = const {}]);

  /// 返回英文回退 —— 日志与调试输出不该出现 `Instance of ...`。
  @override
  String toString() => fallback;
}

/// 一次安全分析的结果。
///
/// 与 findings 并列的 [limitations] 是关键设计：规格第十章要求「无法解析、加固或
/// 加密的样本应明确标记检测覆盖不足，而不是显示全绿」。若没有这个字段，
/// 「没发现」与「没查」在界面上长得一模一样。
class SecurityAnalysisResult {
  /// 检测引擎版本。
  final String engineVersion;

  /// 规则库版本。规则是数据驱动的，改规则必须升这个版本号，
  /// 否则两份报告无法对照。
  final String rulesVersion;

  final List<SecurityFinding> findings;

  /// 未覆盖范围、被预算截断的部分、以及「因为加固/混淆读不到」的说明。
  ///
  /// 每一条是 [AnalysisNote]（稳定 code + 英文回退 + 参数），由呈现层本地化。
  final List<AnalysisNote> limitations;

  /// 本版本是否包含运行时证据。当前恒为 `false`（规格：不得把未实现的
  /// 动态检测包装成已实现功能）。
  final bool includesRuntimeEvidence;

  /// **结构化**的覆盖情况。
  ///
  /// 与 [limitations] 的分工：[limitations] 是给人读的句子（措辞会变），
  /// 这里是给程序读的数据（id 稳定、状态可判定）。UI 与报告都读这一份，
  /// 不再各自从 `limitations` 的文本里猜。
  ///
  /// 默认空表示「本引擎没有产出结构化覆盖」—— 那是「没报」，不是「全覆盖」。
  final AnalysisCoverage coverage;

  /// 静态提取到的网络端点。
  ///
  /// 单列成一级字段，而不是只藏在发现项的证据里：报告要能回答「包里写了哪些
  /// 域名」，而这个问题的答案不该要求消费者去解析证据文本。
  ///
  /// **空表示本次没有提取到（或没有做这一步）**，不表示「没有网络行为」。
  final NetworkFacts network;

  const SecurityAnalysisResult({
    required this.engineVersion,
    required this.rulesVersion,
    this.findings = const [],
    this.limitations = const [],
    this.includesRuntimeEvidence = false,
    this.coverage = const AnalysisCoverage(),
    this.network = const NetworkFacts(),
  });

  /// 各等级发现数量。
  Map<SecuritySeverity, int> countBySeverity() {
    final counts = <SecuritySeverity, int>{};
    for (final finding in findings) {
      counts[finding.severity] = (counts[finding.severity] ?? 0) + 1;
    }
    return counts;
  }

  /// 追加一条覆盖不足说明，返回新的结果。
  ///
  /// 用于「审计本身跑完了，但调用方知道还有没覆盖到的范围」—— 例如分包
  /// 安装包只审计了 base APK。**不能直接改 `limitations` 列表**：它是
  /// `const` 默认值，共享实例被就地修改会污染其他结果。
  SecurityAnalysisResult withLimitation(AnalysisNote limitation) {
    return SecurityAnalysisResult(
      engineVersion: engineVersion,
      rulesVersion: rulesVersion,
      findings: findings,
      limitations: [...limitations, limitation],
      includesRuntimeEvidence: includesRuntimeEvidence,
      coverage: coverage,
      network: network,
    );
  }

  /// 最严重的**风险档**发现；没有 P0–P3 发现时返回 `null`。
  ///
  /// 返回 `null` 时总体结论只能是「当前分析范围内未发现明确的高风险证据」
  /// 这类审慎表述，绝不允许推导成「安全」。
  SecurityFinding? get highestRiskFinding {
    SecurityFinding? worst;
    for (final finding in findings) {
      if (!finding.severity.isRisk) continue;
      if (worst == null || finding.severity.rank < worst.severity.rank) {
        worst = finding;
      }
    }
    return worst;
  }

  bool get hasRiskFindings => highestRiskFinding != null;

  /// 引擎是否**声明**了方法论层面的局限（离线静态分析、基于共现…）。
  ///
  /// 两个引擎都**无条件**追加至少两条，因此它在本项目的实际输出里恒为真。
  /// 这正是它不能当「有缺口」用的原因 —— 一个恒真的警告等于没有警告。
  /// 要判断「这份结论有多可信」请用 [hasActualGaps]。
  bool get hasDeclaredLimitations => limitations.isNotEmpty;

  /// 是否**真的**存在可判定的覆盖缺口。
  ///
  /// 两条来源，都必须有具体指向：
  /// 1. 结构化覆盖里某个维度是 `partial` / `notCovered`（[AnalysisCoverage.gaps]）；
  /// 2. 有 `UNKNOWN` 档发现 —— 引擎自己说「这条我判不了」。
  ///
  /// 与 [hasDeclaredLimitations] 分开是 2026-10-19 审计的直接结论：此前二者
  /// 被合成一个 `hasCoverageGaps`，于是 14/14 个样本都报「有缺口」，
  /// 而同一份结果的结构化覆盖明明全绿。界面的「覆盖不足」卡片因此永远亮着。
  bool get hasActualGaps =>
      coverage.gaps.isNotEmpty ||
      findings.any((f) => f.severity.isInconclusive);

  /// 有缺口的覆盖维度数。UI 用它决定要不要在总览卡上写「N 个维度未覆盖」。
  int get coverageGapCount => coverage.gaps.length;

  @override
  String toString() => 'SecurityAnalysisResult(engine: $engineVersion, '
      'rules: $rulesVersion, findings: ${findings.length}, '
      'limitations: ${limitations.length})';
}
