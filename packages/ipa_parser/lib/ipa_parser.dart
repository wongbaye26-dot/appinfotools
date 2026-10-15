// 纯 Dart 的 iOS `.ipa` 解析库。
//
// 与 Android 解析器完全解耦：两者只共享 `archive_safety` 里的 ZIP 容器安全
// 原语（解压预算、打开结果分类、结构完整性兜底），不共享任何格式模型。
// Android 的权限与 iOS 的 Entitlements 语义不同，把它们塞进同一套类型只会让
// 两边都失真。
//
// 当前已实现：
// - plist 解析（XML 与二进制 `bplist00`）
// - IPA 容器结构解析（bundle 枚举、主应用定位、签名材料存在性）
// - `Info.plist` 字段提取（带状态与来源）
// - 图标资源定位（只按配置点名的文件，不扫描目录）
// - Mach-O 解析（thin / fat、架构、load commands、动态库，全部先验边界）
// - 签名材料的**静态**提取（`_CodeSignature/` 条目、描述文件 plist）
//
// 明确**不**包含：签名验证。规范 5.5 禁止自行实现签名算法并宣称权威结论，
// 因此本包只回答「文件里有什么」，验证由调用方交给 `codesign`。

export 'src/cgbi_png.dart';
export 'src/cms.dart';
export 'src/der.dart';
export 'src/x509.dart';
export 'src/ipa_container.dart';
export 'src/ipa_icon.dart';
export 'src/ipa_info_plist.dart';
export 'src/ios_signature.dart';
export 'src/macho.dart';
// 安全检测引擎（V1.1）：iOS 侧隐私审计。
export 'src/security/ios_privacy_audit.dart';
export 'src/security/ios_native_symbol_audit.dart';
export 'src/plist/binary_plist_parser.dart';
export 'src/plist/plist_fields.dart';
export 'src/plist/plist_parser.dart';
export 'src/plist/plist_value.dart';
export 'src/plist/xml_plist_parser.dart';
