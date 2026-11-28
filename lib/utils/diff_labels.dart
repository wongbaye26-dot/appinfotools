import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/field_value_text.dart';
import 'package:apk_info_tool/utils/format.dart';

/// 差异的呈现文案 —— **UI 与 Markdown 报告共用的唯一一份实现**。
///
/// 与 `AnalysisReport.coverageDimensionLabel` 同一思路：**JSON 里保留机器 id**
/// （`android.minSdkVersion` 是给程序读的稳定标识），而 UI 与 Markdown 必须
/// 显示本地化名字。两处各写一遍必然漂移。
///
/// 字段 id 里带点（`.`），而 slang 用点做路径分隔，所以 i18n 的键名把点换成
/// 下划线（`android.minSdkVersion` → `diff.fields.android_minSdkVersion`）。
/// 这个映射**只有这一处**，认不出的 id 原样返回 —— 不显示空白，也不吞掉它。
class DiffLabels {
  const DiffLabels._();

  /// 字段 id → 本地化名字。
  static String field(String id, Translations t) => switch (id) {
        'file.fileName' => t.diff.fields.file_fileName,
        'file.fileSize' => t.diff.fields.file_fileSize,
        'file.sha256' => t.diff.fields.file_sha256,
        'app.name' => t.diff.fields.app_name,
        'app.id' => t.diff.fields.app_id,
        'app.version' => t.diff.fields.app_version,
        'app.buildNumber' => t.diff.fields.app_buildNumber,
        'signature.verdict' => t.diff.fields.signature_verdict,
        'security.highestSeverity' => t.diff.fields.security_highestSeverity,
        'security.findingCount' => t.diff.fields.security_findingCount,
        'security.cryptoTheftLevel' => t.diff.fields.security_cryptoTheftLevel,
        'android.minSdkVersion' => t.diff.fields.android_minSdkVersion,
        'android.targetSdkVersion' => t.diff.fields.android_targetSdkVersion,
        'android.maxSdkVersion' => t.diff.fields.android_maxSdkVersion,
        'android.debuggable' => t.diff.fields.android_debuggable,
        'android.archiveType' => t.diff.fields.android_archiveType,
        'android.dexCount' => t.diff.fields.android_dexCount,
        'ios.bundleIdentifier' => t.diff.fields.ios_bundleIdentifier,
        'ios.displayName' => t.diff.fields.ios_displayName,
        'ios.shortVersion' => t.diff.fields.ios_shortVersion,
        'ios.buildNumber' => t.diff.fields.ios_buildNumber,
        'ios.minimumOSVersion' => t.diff.fields.ios_minimumOSVersion,
        'ios.executableName' => t.diff.fields.ios_executableName,
        _ => id,
      };

  /// 集合 id → 本地化名字。
  static String set(String id, Translations t) => switch (id) {
        'security.findings' => t.diff.sets.security_findings,
        'security.coverageGaps' => t.diff.sets.security_coverageGaps,
        'android.permissions' => t.diff.sets.android_permissions,
        'android.components' => t.diff.sets.android_components,
        'android.nativeCodes' => t.diff.sets.android_nativeCodes,
        'android.locales' => t.diff.sets.android_locales,
        'android.densities' => t.diff.sets.android_densities,
        'android.nativeSymbols' => t.diff.sets.android_nativeSymbols,
        'android.allowBackup' => t.diff.sets.android_allowBackup,
        'android.cleartextPolicy' => t.diff.sets.android_cleartextPolicy,
        'android.thirdPartySdk' => t.diff.sets.android_thirdPartySdk,
        'ios.urlSchemes' => t.diff.sets.ios_urlSchemes,
        'ios.queriesSchemes' => t.diff.sets.ios_queriesSchemes,
        'ios.backgroundModes' => t.diff.sets.ios_backgroundModes,
        'ios.requiredDeviceCapabilities' =>
          t.diff.sets.ios_requiredDeviceCapabilities,
        'ios.nativeSymbols' => t.diff.sets.ios_nativeSymbols,
        'ios.entitlements' => t.diff.sets.ios_entitlements,
        'network.domains' => t.diff.sets.network_domains,
        'network.ips' => t.diff.sets.network_ips,
        _ => id,
      };

  /// 差异类型 → 本地化名字（新增 / 删除 / 变更 / 无法比较）。
  static String kind(DiffKind kind, Translations t) => switch (kind) {
        DiffKind.added => t.diff.kind_added,
        DiffKind.removed => t.diff.kind_removed,
        DiffKind.changed => t.diff.kind_changed,
        DiffKind.same => t.diff.summary_same,
        DiffKind.unknown => t.diff.kind_unknown,
      };

  /// 把一个 [FieldValue] 渲染成差异页 / 报告里的文本。
  ///
  /// 沿用详情页既有的四态口径（`info_page.dart` 的 `_androidField`）：
  /// - 有值 → 值本身；
  /// - `absent` → 「文件里没有」（**不是**空白、也不是 `-`：差异页上「左边没有」
  ///   正是「新增」的判据，写成一个不起眼的符号会让人读不出结论）；
  /// - 其余 → `[状态名] 原因`，明确说「我们没读到」。
  ///
  /// 状态名保留机器拼写（`unsupported` / `failed`…）：它是稳定标识，也是
  /// 详情页一直在用的写法，两处必须一致。
  static String value(String id, FieldValue<Object?> value, Translations t) {
    if (value.hasValue) return formatValue(id, value.value, t);
    if (value.status == FieldStatus.absent) return t.diff.value_absent;
    // 差异页对 `absent` 的措辞与详情页不同（「文件里没有」而不是 `-`），
    // 因为在这里它正是「新增」的判据，一个破折号读不出结论。其余走共用实现。
    final reason = FieldValueText.diagnostic(value, t);
    return reason == null
        ? '[${value.status.name}]'
        : '[${value.status.name}] $reason';
  }

  /// 值本身的文本。绝大多数就是 `toString`，两类例外单独处理：
  /// - 字节数：差异页上 `1048576 → 2097152` 远不如 `1.0 MB → 2.0 MB` 直观，
  ///   而文件大小恰恰是版本对比里最常被看的一项；
  /// - 签名结论：它是枚举，直接 `toString` 会渲染成 `SignatureVerdict.verified`。
  ///   走 [DetailRenderer.signatureVerdictLabel] —— 同一个结论在详情页与
  ///   差异页必须是同一句话，另写一份必然漂移。
  static String formatValue(String id, Object? value, Translations t) {
    if (id == 'file.fileSize' && value is int) {
      return '${formatFileSize(value)} ($value Bytes)';
    }
    if (value is SignatureVerdict) {
      return DetailRenderer.signatureVerdictLabel(value, t);
    }
    // 安全结论存的是**机器值**（`p0` / `strongEvidence`），直接 `toString`
    // 会把枚举名甩给用户。映射与详情页共用同一份实现，另写一份必然漂移。
    if (id == 'security.highestSeverity' && value is String) {
      return _severityText(value, t);
    }
    if (id == 'security.cryptoTheftLevel' && value is String) {
      final level = _levelByName(value);
      if (level != null) {
        return DetailRenderer.cryptoTheftLevelLabel(level, t);
      }
    }
    return '$value';
  }

  /// 集合成员的**显示文本**。
  ///
  /// 集合里存的是**稳定身份**（规则 id、覆盖维度 id），JSON 原样保留；
  /// 界面与 Markdown 要换成人话。两个安全集合之外原样返回。
  ///
  /// [ruleTitles] 由 [findingTitles] 生成 —— 规则 id 本身没有语言包
  /// （引擎不依赖 slang），只有本侧那条发现的结论句能翻。
  static String member(
    String setId,
    String member,
    Translations t, {
    Map<String, String> ruleTitles = const {},
  }) =>
      switch (setId) {
        'security.findings' => ruleTitles[member] ?? member,
        'security.coverageGaps' =>
          AnalysisReport.coverageDimensionLabel(member, t),
        _ => member,
      };

  /// 规则 id → 本侧发现的中文结论（`security.findings` 成员的显示用）。
  ///
  /// 两侧同名规则取**左侧**的措辞：同一句文案在同一份报告里出现两种写法
  /// 比缺一句更让人怀疑。
  static Map<String, String> findingTitles(
    PackageAnalysisResult? left,
    PackageAnalysisResult? right,
    Translations t,
  ) {
    final titles = <String, String>{};
    for (final result in [left, right]) {
      for (final finding
          in result?.security?.findings ?? const <SecurityFinding>[]) {
        titles.putIfAbsent(
          finding.ruleId,
          () => AnalysisReport.findingText(finding, t),
        );
      }
    }
    return titles;
  }

  /// `p0`…`info` / `none` → 界面文本。
  ///
  /// 等级名是**语言中立**的（`P0` / `INFO` 与详情页的严重度 chip 一致），
  /// 只有「一条都没有」需要翻译。
  static String _severityText(String name, Translations t) => switch (name) {
        'p0' => 'P0',
        'p1' => 'P1',
        'p2' => 'P2',
        'p3' => 'P3',
        'info' => 'INFO',
        'unknown' => '?',
        'none' => t.diff.severity_none,
        _ => name,
      };

  /// 枚举名 → 枚举值。认不出时返回 `null`（新引擎 + 旧界面），由调用方
  /// 退回原始机器值，而不是显示一个空白。
  static CryptoTheftLevel? _levelByName(String name) {
    for (final level in CryptoTheftLevel.values) {
      if (level.name == name) return level;
    }
    return null;
  }
}
