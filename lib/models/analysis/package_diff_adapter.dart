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
      // --- Android 专属 ---
      if (android != null) ...[
        (id: 'android.minSdkVersion', value: android.minSdkVersion),
        (id: 'android.targetSdkVersion', value: android.targetSdkVersion),
        (id: 'android.maxSdkVersion', value: android.maxSdkVersion),
        (id: 'android.debuggable', value: android.debuggable),
        (id: 'android.archiveType', value: android.archiveType),
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
