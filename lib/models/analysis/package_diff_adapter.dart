import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_parser/apk_parser.dart' show AndroidComponent;

/// 把一份 [PackageAnalysisResult] 适配成平台中立的 [DiffSubject]。
///
/// **适配层为什么在应用层**：差异模型（`analysis_model` 的 `package_diff.dart`）
/// 刻意不认识 `PackageAnalysisResult` —— 那会让零依赖的模型包反过来依赖应用层。
/// 于是由这里负责「把两份解析结果摊平成差异模型认识的形状」。
///
/// **字段清单与顺序即报告的输出顺序**，因此这份清单是**契约**：
/// 加字段要同步 `test/package_diff_adapter_test.dart` 里的断言，
/// 否则新增的字段会静默地不进差异。
///
/// 只比**同一平台**的两份包才有意义 —— 跨平台（APK vs IPA）时各自的
/// 平台专属字段会全部落进 `added` / `removed`，那是噪音而不是差异。
/// 调用方负责拦住这种情况（见 [samePlatform]）。
DiffSubject diffSubjectOf(PackageAnalysisResult result) {
  final android = result.android;
  final ios = result.ios;
  final security = result.security;
  // 网络端点挂在安全分析结果上（它是那一步的产物）。
  final network = security?.network;

  return DiffSubject(
    fields: [
      // --- 文件身份 ---
      (id: 'file.fileName', value: result.fileName),
      (id: 'file.fileSize', value: result.fileSize),
      (id: 'file.sha256', value: result.sha256),
      // --- 应用身份（两平台通用字段）---
      (id: 'app.name', value: result.appName),
      (id: 'app.id', value: result.packageId),
      (id: 'app.version', value: result.version),
      (id: 'app.buildNumber', value: result.buildNumber),
      // 签名结论是**平台中立**的（Android 走 apksigner、iOS 走 codesign，
      // 但对用户只有「通过 / 不通过 / 无法确认 / 没查」四种结论），
      // 因此放在通用字段里而不是某一侧的专属字段里。
      (id: 'signature.verdict', value: _verdictValue(result.signatureVerdict)),
      // --- 安全检测结论（平台中立）---
      //
      // 与上面那些「文件里写了什么」是两个问题：这里比的是**审计给出的
      // 结论**。放通用字段是因为两侧都有安全结果，只是判据不同；逐条规则
      // 的去留是集合 `security.findings`，不在这里。
      ..._securityFields(security),
      // --- Android 专属 ---
      if (android != null) ...[
        (id: 'android.minSdkVersion', value: android.minSdkVersion),
        (id: 'android.targetSdkVersion', value: android.targetSdkVersion),
        (id: 'android.maxSdkVersion', value: android.maxSdkVersion),
        (id: 'android.debuggable', value: android.debuggable),
        (id: 'android.archiveType', value: android.archiveType),
        // DEX 数量是「安装包里真的有几个 dex」，与结构证据同源；
        // 结构缺失时写 null（渲染成「未读取」），不写 0。
        (id: 'android.dexCount', value: _dexCountOf(android)),
      ],
      // --- iOS 专属 ---
      if (ios != null) ...[
        (id: 'ios.bundleIdentifier', value: ios.bundleIdentifier),
        (id: 'ios.displayName', value: ios.displayName),
        (id: 'ios.shortVersion', value: ios.shortVersion),
        (id: 'ios.buildNumber', value: ios.buildNumber),
        (id: 'ios.minimumOSVersion', value: ios.minimumOSVersion),
        (id: 'ios.executableName', value: ios.executableName),
      ],
    ],
    sets: {
      // --- 安全检测（平台中立，排在平台集合之前：它是差异页上最该先看到的）---
      ..._securitySets(security),
      // --- Android 集合 ---
      if (android != null) ...{
        'android.permissions': android.permissions,
        'android.components': _componentIdentities(android.components),
        'android.nativeCodes': android.nativeCodes,
        'android.locales': android.locales,
        'android.densities': android.densities,
        // 原生符号不是一份独立模型，而是安全审计产出的一条发现的参数
        // （`messageCode` + `messageArgs['symbols']`）。没有安全结果时
        // **不产出**这个维度 —— 与「查了、一个都没有」结论相反。
        if (security != null)
          'android.nativeSymbols':
              _asFieldValue(_nativeSymbols(security, 'android.native_symbols')),
        // ---- 安全维度的版本差异（2026-10-19 审计 P3-7）----
        //
        // 这三条都**从安全发现推导**，而不是从解析字段取：`allowBackup` 与
        // 明文策略在 `AndroidPackageInfo` 里没有独立字段（它们是规则判据的
        // 输入，不是解析结果）。推导的语义要在标签上写清，不能让人以为
        // 那是「清单里写了什么」的原始值。
        if (security != null) ...{
          'android.allowBackup': _asFieldValue(
              _findingPresent(security, 'ANDROID-ALLOW-BACKUP')
                  ? const ['true']
                  : const []),
          'android.cleartextPolicy': _asFieldValue(
            _findingPresent(security, 'ANDROID-RULE-D') ||
                    _findingPresent(security, 'ANDROID-RULE-D-ESCALATED')
                ? const ['allows-cleartext']
                : const [],
          ),
          'android.thirdPartySdk': _asFieldValue(_sdkNames(security)),
        },
      },
      // --- iOS 集合 ---
      if (ios != null) ...{
        'ios.urlSchemes': ios.urlSchemes,
        'ios.queriesSchemes': ios.queriesSchemes,
        'ios.backgroundModes': ios.backgroundModes,
        'ios.requiredDeviceCapabilities': ios.requiredDeviceCapabilities,
        if (security != null)
          'ios.nativeSymbols':
              _asFieldValue(_nativeSymbols(security, 'ios.native_symbols')),
        // 授权项（entitlements）是「被授权什么」，与 Android 的权限语义不同，
        // 但版本之间「多了/少了一项」是同一类差异。
        if (ios.signatureMaterials?.profile.value case final profile?)
          'ios.entitlements': _asFieldValue([
            for (final e in profile.entitlements) e.key,
          ]),
      },
      // --- 网络端点：平台中立，单列成一级字段，因此这里也单列 ---
      // `NetworkFacts` 是复合结构而不是 `FieldValue`，这里按「读到了就是
      // extracted、空就是 absent」还原状态 —— 它是**静态提取**的结果，
      // 不存在「来源不报」这一态（提取器总会跑）。
      // 没做安全分析时**不产出**这两个维度 —— 那与「做了、没提取到」
      // 结论相反，不能压成同一个空列表。
      if (network != null) ...{
        'network.domains': _asFieldValue(network.domains),
        'network.ips': _asFieldValue(network.ips),
      },
    },
  );
}

/// 两份包是不是同一个平台。
///
/// 跨平台比较没有意义：Android 与 iOS 的专属字段会全部落进 `added` /
/// `removed`，把噪音当差异。调用方在发起比较前应该先问这一句。
bool samePlatform(PackageAnalysisResult a, PackageAnalysisResult b) =>
    a.platform == b.platform && a.platform != PackagePlatform.unknown;

/// **三端同源的唯一入口**：差异页（UI）、Markdown 报告、JSON 报告都调这一个。
///
/// 三处各自「适配 + 比较」一遍迟早会漂移 —— 用户会看到界面上说「变更」、
/// 报告里说「新增」。这里把两步绑成一个函数，调用方拿到的就是同一份
/// [PackageDiff]。
PackageDiff diffOf(PackageAnalysisResult left, PackageAnalysisResult right) =>
    diffSubjects(diffSubjectOf(left), diffSubjectOf(right));

// ---------------------------------------------------------------------------
// 安全检测结论
// ---------------------------------------------------------------------------

/// 安全结论的**标量**对比：最严重等级、发现条数、五段链等级。
///
/// ## 为什么 `security == null` 也要产出
///
/// `null` 表示**本次没做安全审计**（设置里关掉了 `enableSecurityAudit`，
/// 或解析在安全阶段之前就失败了）。此时记 `notRequested` 而不是「不产出」：
/// 不产出的话，另一侧的成员会整片落进 `added` / `removed`，把「这次没查」
/// 读成「新版本多了这些漏洞」—— 那正是这个工具最不该犯的错。
///
/// 代价是两侧都没审计时会多出几条「无法比较」。这是**有意的噪音**：
/// 它们诚实地说明「安全这一块这次说不清」，而差异页本来就把「无法比较」
/// 与「没有差异」分开呈现。
List<({String id, FieldValue<Object?> value})> _securityFields(
  SecurityAnalysisResult? security,
) {
  if (security == null) {
    return [
      for (final id in _securityFieldIds)
        (id: id, value: _securityNotRequested),
    ];
  }

  final theft = security.cryptoTheft;
  return [
    (
      id: 'security.highestSeverity',
      // 机器值：`p0`…`info`，以及 `none`（查了、一条发现都没有）。
      // `none` 与 `notRequested` 是相反的两个结论，不能压成同一个空值。
      value: FieldValue<Object?>.extracted(
        _highestSeverity(security.findings),
        source: FieldSource.unknown,
      ),
    ),
    (
      id: 'security.findingCount',
      value: FieldValue<Object?>.extracted(
        security.findings.length,
        source: FieldSource.unknown,
      ),
    ),
    (
      id: 'security.cryptoTheftLevel',
      // `cryptoTheft == null` = 五段链没跑（不是「没有风险」）。
      value: theft == null
          ? const FieldValue<Object?>.notRequested(
              diagnostic: 'crypto theft chain was not assessed',
              diagnosticCode: 'security.crypto_theft_not_assessed',
            )
          : FieldValue<Object?>.extracted(
              theft.level.name,
              source: FieldSource.unknown,
            ),
    ),
  ];
}

const List<String> _securityFieldIds = [
  'security.highestSeverity',
  'security.findingCount',
  'security.cryptoTheftLevel',
];

/// 安全结论的**集合**对比：命中了哪些规则、哪些覆盖维度有缺口。
Map<String, FieldValue<List<String>>> _securitySets(
  SecurityAnalysisResult? security,
) {
  if (security == null) {
    return {
      for (final id in _securitySetIds)
        id: const FieldValue<List<String>>.notRequested(
          diagnostic: 'security audit is disabled in settings',
          diagnosticCode: 'security.disabled',
        ),
    };
  }
  return {
    'security.findings': _asFieldValue(_ruleIds(security.findings)),
    'security.coverageGaps': _coverageGaps(security),
  };
}

const List<String> _securitySetIds = [
  'security.findings',
  'security.coverageGaps',
];

/// 集合成员用**规则级身份**：同一规则命中多条只算一条。
///
/// 口径：这个集合回答「哪些规则命中了」，不回答「命中了几次」——
/// 次数变化由 `security.findingCount` 承担。把次数拼进身份会让「同一条
/// 规则多命中两次」表现成一删一增，读起来像换了一条规则（与组件身份串
/// 同一条原则，见 [_componentIdentities]）。
List<String> _ruleIds(List<SecurityFinding> findings) {
  final ids = <String>{for (final f in findings) f.ruleId};
  return ids.toList()..sort();
}

/// 有缺口的覆盖维度（部分覆盖 + 完全没覆盖）。
///
/// **空 `entries` 不是「没有缺口」**：那是「本引擎没有产出结构化覆盖」，
/// 与「全覆盖」结论相反，因此记 `unsupported` 而不是 `absent`。
FieldValue<List<String>> _coverageGaps(SecurityAnalysisResult security) {
  final entries = security.coverage.entries;
  if (entries.isEmpty) {
    return const FieldValue<List<String>>.unsupported(
      diagnostic: 'this engine did not produce structured coverage',
      diagnosticCode: 'security.coverage_not_structured',
    );
  }
  return _asFieldValue([
    for (final entry in entries)
      if (entry.isGap) entry.id
  ]);
}

/// 最严重的那条发现；没有发现时为 `none`。
///
/// 用 `rank` 而不是 `index`：枚举顺序是声明顺序，语义上不可靠。
String _highestSeverity(List<SecurityFinding> findings) {
  SecuritySeverity? highest;
  for (final f in findings) {
    if (highest == null || f.severity.rank < highest.rank) {
      highest = f.severity;
    }
  }
  return highest?.name ?? 'none';
}

/// 「本次没做安全审计」的统一状态 —— 三个标量字段共用同一个诊断 code，
/// 呈现层只翻一处。
const FieldValue<Object?> _securityNotRequested =
    FieldValue<Object?>.notRequested(
  diagnostic: 'security audit is disabled in settings',
  diagnosticCode: 'security.disabled',
);

/// 签名结论 → 带状态的字段值。
///
/// `notChecked` 记 [FieldStatus.notRequested]（「本次没去查」），**不是**
/// [FieldStatus.absent]（「文件里没有」）。压成 absent 会让差异页说
/// 「新版本加上了签名」—— 而事实只是这次没开签名检查。
///
/// 来源记 `unknown`：这个结论是**派生**出来的（Android 优先 apksigner、
/// 工具不可用时退回静态材料；iOS 优先 codesign、否则静态材料），
/// 没有单一来源可标注。
FieldValue<Object?> _verdictValue(SignatureVerdict verdict) =>
    verdict == SignatureVerdict.notChecked
        // 带上原因：差异页会把它渲染成 `[notRequested] 原因`。只给状态名
        // 会让人以为「没查」是个异常，而它其实是设置里关掉了。
        ? const FieldValue<Object?>.notRequested(
            diagnostic: 'signature check is disabled in settings',
            diagnosticCode: 'signature.disabled',
          )
        : FieldValue<Object?>.extracted(verdict, source: FieldSource.unknown);

/// 把组件列表压成**身份串**：`activity com.example.Main`。
///
/// ## 刻意不含属性（口径，不是遗漏）
///
/// 只取「类型 + 类名」。`exported` / `permission` / `intent-filter` 这些**属性**
/// 不拼进来，因为集合维度回答的是「有哪些组件」；把属性拼进身份会让
/// 「同一个组件改了 `exported`」表现成**一删一增**，读起来像换了组件。
/// 属性级的差异需要「按组件 id 做逐字段比较」，那是另一层设计，本层不做。
/// 详情页照常展示全部属性。
///
/// 类名取不到时（混淆过的 manifest）用 `(unnamed)` 这个**稳定标记**而不是
/// 本地化文案：成员串是集合的成员标识，随语言变化会让同一个包的两次比较
/// 得到不同结果。
FieldValue<List<String>> _componentIdentities(
  FieldValue<List<AndroidComponent>> components,
) =>
    _mapMembers(
      components,
      (c) => '${c.type.elementName} ${c.name ?? '(unnamed)'}',
    );

/// 从安全审计结果里取某条发现的原生符号清单。
///
/// 找不到那条发现时返回空列表 —— 调用方已经把「没做安全分析」单独处理
/// （不产出该维度），因此这里的空只表示「查了，没有命中」。
List<String> _nativeSymbols(SecurityAnalysisResult security, String code) {
  for (final finding in security.findings) {
    if (finding.messageCode != code) continue;
    final symbols = finding.messageArgs['symbols'];
    if (symbols is List) return [for (final s in symbols) '$s'];
  }
  return const [];
}

/// 某条发现是否出现。
bool _findingPresent(SecurityAnalysisResult security, String ruleId) =>
    security.findings.any((f) => f.ruleId == ruleId);

/// 第三方服务类 SDK 的显示名清单。
List<String> _sdkNames(SecurityAnalysisResult security) {
  for (final finding in security.findings) {
    if (finding.ruleId != 'ANDROID-THIRD-PARTY-SDK') continue;
    final names = finding.messageArgs['names'];
    if (names is List) return [for (final n in names) '$n']..sort();
  }
  return const [];
}

/// 把一串**静态提取**得到的成员包成 [FieldValue]。
///
/// 空列表记 `absent`（「提取器跑了，包里没有」），不记 `unsupported` ——
/// 提取器不存在「这个来源不报」的情形。
FieldValue<List<String>> _asFieldValue(List<String> members) => members.isEmpty
    ? const FieldValue<List<String>>.absent(source: FieldSource.builtinParser)
    : FieldValue<List<String>>.extracted(
        members,
        source: FieldSource.builtinParser,
      );

/// 保留状态与来源，只把成员换成另一种写法。
///
/// `FieldValue` 没有 `map`，而这里需要「值换了、状态不变」—— 逐状态重建是
/// 唯一不丢信息的做法。**不能**只处理 `extracted` 就退回 `absent`：
/// 那会把「我们没读到组件」变成「文件里没有组件」。
FieldValue<List<String>> _mapMembers<T>(
  FieldValue<List<T>> source,
  String Function(T) render,
) {
  final diagnostic = source.diagnostic;
  final fieldSource = source.source;
  return switch (source.status) {
    FieldStatus.extracted => FieldValue<List<String>>.extracted(
        [for (final v in source.value!) render(v)],
        source: fieldSource,
        diagnostic: diagnostic,
      ),
    FieldStatus.absent => FieldValue<List<String>>.absent(
        source: fieldSource, diagnostic: diagnostic),
    FieldStatus.wrongType => FieldValue<List<String>>.wrongType(
        diagnostic: diagnostic ?? 'wrong type',
        source: fieldSource,
      ),
    FieldStatus.unsupported =>
      FieldValue<List<String>>.unsupported(diagnostic: diagnostic),
    FieldStatus.failed => FieldValue<List<String>>.failed(
        diagnostic: diagnostic ?? 'failed',
        source: fieldSource,
      ),
    FieldStatus.hardenedUnknown => FieldValue<List<String>>.hardenedUnknown(
        diagnostic: diagnostic,
        source: fieldSource,
      ),
    FieldStatus.notRequested => FieldValue<List<String>>.notRequested(
        diagnostic: diagnostic,
        source: fieldSource,
      ),
  };
}

/// DEX 数量字段。
///
/// 结构证据没读到时标 `unsupported`（界面显示「未读取」），**不写 0**：
/// 这个页面上「没读到」和「真的没有 DEX」必须区分 —— 后者在合法 APK 里不存在。
FieldValue<int> _dexCountOf(AndroidPackageInfo android) {
  final count = android.structure?.dexFileCount;
  if (count == null) {
    return const FieldValue<int>.unsupported(
      diagnostic: 'container structure was not read',
    );
  }
  return FieldValue<int>.extracted(count, source: FieldSource.builtinParser);
}
