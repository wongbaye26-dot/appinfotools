export 'src/models.dart';
export 'src/byte_data_reader.dart';
export 'src/binary_xml.dart';
export 'src/manifest_parser.dart';
export 'src/arsc_parser.dart';
export 'src/arsc/string_pool.dart';
export 'src/arsc/resource_value.dart';
export 'src/arsc/type_spec.dart';
export 'src/arsc/reference_graph.dart';

// DEX 结构级解析（安全分析的第二层）。与 `security/dex_clue_scanner.dart` 的
// 字符串扫描分开：那个回答「出现了哪些字面量」，这个回答「文件结构长什么样」。
export 'src/dex/dex_structure.dart';
export 'src/hardening.dart';
export 'src/container_structure.dart';
export 'src/apk_reader.dart';

// 安全检测引擎（V1.1）：权限规则目录、DEX 字符串线索、Android 侧审计编排。
// 产出的是 `analysis_model` 里的平台中立发现项模型，与平台自身的解析结果
// 分开导出 ——「解析出了什么」和「据此判断有什么风险」是两个问题。
export 'src/security/android_security_audit.dart';
export 'src/security/dex_clue_scanner.dart';
export 'src/security/permission_catalog.dart';

// ZIP 容器安全原语已下沉到 `archive_safety` —— 它们与「里面装的是 APK 还是
// IPA」无关，IPA 解析器也要用同一份实现（复制一份安全防护意味着两边的阈值
// 会各自漂移）。
//
// 这里**转出**它们，是为了让 `ApkReader.open` 的返回值 `ArchiveOpenResult`
// 在 `package:apk_parser/apk_parser.dart` 一个 import 下就可用 —— 否则每个
// 调用方都得同时 import 两个包。
export 'package:archive_safety/archive_safety.dart';
