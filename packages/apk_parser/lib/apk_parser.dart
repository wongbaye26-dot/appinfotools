export 'src/models.dart';
export 'src/byte_data_reader.dart';
export 'src/binary_xml.dart';
export 'src/manifest_parser.dart';
export 'src/arsc_parser.dart';
export 'src/icp_filing.dart';
export 'src/arsc/string_pool.dart';
export 'src/arsc/resource_value.dart';
export 'src/arsc/type_spec.dart';
export 'src/arsc/reference_graph.dart';

// DEX 结构级解析（安全分析的第二层）。与 `security/dex_clue_scanner.dart` 的
// 字符串扫描分开：那个回答「出现了哪些字面量」，这个回答「文件结构长什么样」。
export 'src/dex/dex_structure.dart';
export 'src/dex/dex_method_table.dart';
export 'src/dex/dex_instruction.dart';
export 'src/dex/dex_method_bodies.dart';

// 原生库（`lib/**.so`）的 ELF 解析。与 DEX 一样是**静态**分析：
// 只读结构、节表与符号表，不反汇编、不执行。
export 'src/native/elf.dart';
// 原生库的二进制加固属性（NX 栈 / RELRO / BIND_NOW / 栈保护 / strip）。
// 与符号表解析分开：那是「导入了哪些敏感函数」，这是「库本身编得硬不硬」。
export 'src/native/elf_hardening.dart';
export 'src/hardening.dart';
export 'src/container_structure.dart';
export 'src/apk_reader.dart';
// APK Signing Block：回答「有没有 v2/v3 签名块」，**不做**密码学验证。
export 'src/apk_signing_block.dart';

// 安全检测引擎（V1.1）：权限规则目录、DEX 字符串线索、Android 侧审计编排。
// 产出的是 `analysis_model` 里的平台中立发现项模型，与平台自身的解析结果
// 分开导出 ——「解析出了什么」和「据此判断有什么风险」是两个问题。
export 'src/security/android_security_audit.dart';
// 组合规则表：与 `permission_catalog.dart` 一样是**数据**，因此一并导出 ——
// 测试要能逐条驱动它，应用层也可能要按 ruleId 反查规则说明。
export 'src/security/android_security_rules.dart';
export 'src/security/dex_clue_scanner.dart';
export 'src/security/dex_method_scanner.dart';
export 'src/security/code_markers.dart';
export 'src/security/native_symbol_scanner.dart';
// 网络安全配置（`res/xml/network_security_config.xml`）：声明了它之后
// `android:usesCleartextTraffic` 就被平台忽略，明文策略完全由它决定。
export 'src/security/network_security_config.dart';
export 'src/security/permission_catalog.dart';

// ZIP 容器安全原语已下沉到 `archive_safety` —— 它们与「里面装的是 APK 还是
// IPA」无关，IPA 解析器也要用同一份实现（复制一份安全防护意味着两边的阈值
// 会各自漂移）。
//
// 这里**转出**它们，是为了让 `ApkReader.open` 的返回值 `ArchiveOpenResult`
// 在 `package:apk_parser/apk_parser.dart` 一个 import 下就可用 —— 否则每个
// 调用方都得同时 import 两个包。
export 'package:archive_safety/archive_safety.dart';
