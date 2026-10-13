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
class AnalysisDiagnostic {
  final DiagnosticSeverity severity;

  /// 稳定的机器可读标识，建议用 `领域.具体问题` 形式。
  final String code;

  /// 面向人的说明。
  final String message;

  /// 该诊断涉及的来源（可为空）。
  final FieldSource? source;

  const AnalysisDiagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.source,
  });

  const AnalysisDiagnostic.info(this.code, this.message, {this.source})
      : severity = DiagnosticSeverity.info;

  const AnalysisDiagnostic.warning(this.code, this.message, {this.source})
      : severity = DiagnosticSeverity.warning;

  const AnalysisDiagnostic.error(this.code, this.message, {this.source})
      : severity = DiagnosticSeverity.error;

  @override
  String toString() => '[${severity.name}] $code: $message';
}
