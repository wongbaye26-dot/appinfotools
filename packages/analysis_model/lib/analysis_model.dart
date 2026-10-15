// 「带来源与状态的字段值」这套通用机制。
//
// 单独成包是因为 Android 与 iOS 两侧都要用它，而它本身**不含任何平台概念**：
// 没有 Android 组件、没有 Mach-O、没有签名细节。把它放在某一侧的包里，会让
// 另一侧被迫依赖对方 —— 这正是规范要求「与 Android 解析器解耦」要避免的。
//
// 包内只有这几样东西：
// - `FieldValue<T>` / `FieldStatus` / `FieldSource`：字段值及其解析状态与来源
// - `AnalysisDiagnostic`：解析过程中的诊断记录
// - `SignatureStatus`：受信任工具给出的签名验证结论（Android 与 iOS 共用）
// - `SecurityFinding` 等：安全检测引擎的平台中立发现项模型
// - `AsciiStrings`：二进制 ASCII 字符串提取（Android 与 iOS 的安全扫描共用）

export 'src/ascii_strings.dart';
export 'src/diagnostic.dart';
export 'src/field_value.dart';
export 'src/security_finding.dart';
export 'src/signature_status.dart';
export 'src/native_symbol_markers.dart';
export 'src/analysis_coverage.dart';
export 'src/network_facts.dart';
export 'src/split_consistency.dart';
export 'src/package_diff.dart';
