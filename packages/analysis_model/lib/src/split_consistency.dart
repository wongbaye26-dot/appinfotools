/// 分包（XAPK / APKM / APKS）之间的一致性核对结果。
///
/// 放在 `analysis_model` 而不是应用层：报告与界面都要读它，而报告只认识
/// 平台中立的模型。应用层（`apk_info.dart`）的 `SplitConsistencyReport`
/// 是**产出方**，这里的是**呈现载体**，字段一一对应。
///
/// 三件事必须分得开：
/// - **没查**（整个对象为 `null`）：单 APK 没有分包，或本次没做这项检查；
/// - **查了没问题**（`issues` 为空且 `checkedCount == totalCount`）；
/// - **查了但没查全**（`checkedCount < totalCount`）：抽检有上限，超出部分
///   未比对 —— 这不是「没问题」，是「没查完」。
class SplitConsistency {
  /// 实际发现的问题：包名 / versionCode 与 base 不符，或分包读不出来。
  final List<String> issues;

  /// 本次实际比对过的分包数（不含 base）。
  final int checkedCount;

  /// 分包总数（不含 base）。
  final int totalCount;

  const SplitConsistency({
    this.issues = const [],
    this.checkedCount = 0,
    this.totalCount = 0,
  });

  bool get hasIssues => issues.isNotEmpty;

  /// 是否所有分包都参与过比对。为 `false` 时结论**不覆盖全部范围**。
  bool get isFullyChecked => totalCount > 0 && checkedCount >= totalCount;

  /// 未参与比对的分包数。
  int get uncheckedCount =>
      totalCount > checkedCount ? totalCount - checkedCount : 0;

  @override
  String toString() => 'SplitConsistency($checkedCount/$totalCount checked, '
      '${issues.length} issues)';
}
