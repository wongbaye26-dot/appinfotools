import 'field_value.dart';

/// 诊断记录的严重程度。
enum DiagnosticSeverity { info, warning, error }

/// 一条诊断记录。
///
/// [code] 是稳定的机器可读标识（例如 `hardening.dex_header_not_standard`），
/// 便于后续做筛选、统计与本地化；[message] 是面向人的说明，直接进日志与
/// 详情页的「解析诊断」区。
///
/// 用 code 而不是只留一句人话，是因为诊断最终要能按类别呈现给用户
/// （规范第七步的「解析诊断」），也便于回归测试断言。
///
/// ## [messageArgs] 是本地化的必要条件
///
/// [message] 是**英文回退**（硬编码句子）。仅凭它没法翻译：句子里的数字与
/// 路径是**插值**出来的，还原不回模板。因此同一个 code 还要配一份
/// [messageArgs]（占位符名 → 实参），呈现层才能把本地化模板填上。
/// 没有 [messageArgs] 的条目**照旧显示英文原文** —— 不会出现半吊子状态。
class AnalysisDiagnostic {
  final DiagnosticSeverity severity;

  /// 稳定的机器可读标识，建议用 `领域.具体问题` 形式。
  final String code;

  /// 面向人的说明（**英文回退**）。
  final String message;

  /// 该诊断涉及的来源（可为空）。
  final FieldSource? source;

  /// [message] 的占位符实参，例如 `{'path': path, 'size': entry.size}`。
  final Map<String, Object> messageArgs;

  const AnalysisDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.source,
    this.messageArgs = const {},
  });

  const AnalysisDiagnostic.info(
    this.code,
    this.message, {
    this.source,
    this.messageArgs = const {},
  }) : severity = DiagnosticSeverity.info;

  const AnalysisDiagnostic.warning(
    this.code,
    this.message, {
    this.source,
    this.messageArgs = const {},
  }) : severity = DiagnosticSeverity.warning;

  const AnalysisDiagnostic.error(
    this.code,
    this.message, {
    this.source,
    this.messageArgs = const {},
  }) : severity = DiagnosticSeverity.error;

  @override
  String toString() => '[${severity.name}] $code: $message';
}
