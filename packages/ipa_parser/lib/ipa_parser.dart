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
// 主应用 bundle 的目录布局事实（重打包判据的输入）。
export 'src/ipa_layout.dart';
// `Assets.car` 的**索引**解析（不解码像素：数据是 LZFSE 压缩的）。
export 'src/assets_car.dart';
// LZFSE 解码：`Assets.car` 的像素数据是 LZFSE 压过的。
export 'src/lzfse.dart';
// 从 `Assets.car` 真正取出图像（LZFSE 解码 + PNG 编码）。
export 'src/assets_car_extract.dart';
export 'src/png_encoder.dart';
export 'src/ipa_info_plist.dart';
export 'src/ios_signature.dart';
export 'src/macho.dart';
export 'src/ios_reference_tables.dart';
// 安全检测引擎（V1.1）：iOS 侧隐私审计。
export 'src/security/ios_privacy_audit.dart';
export 'src/security/ios_crypto_audit.dart';
// 中文 / Unicode 话术线索（UTF-8 与 UTF-16 字符串，不单独判级）。
export 'src/security/ios_unicode_phrases.dart';
export 'src/security/ios_strings_unicode.dart';
export 'src/security/ios_jailbreak_audit.dart';
export 'src/security/ios_repackaging_audit.dart';
export 'src/security/ios_call_sites.dart';
export 'src/security/ios_native_symbol_audit.dart';
// 盗 U 检测 Phase B 事实层（契约 C4/C7/C9）：制品清单 / 载荷探测 / 加载链。
// 三者都只回答事实，不判恶意；判级在 Phase C 的规则层。
export 'src/security/ios_artifact_inventory.dart';
export 'src/security/ios_payload_probe.dart';
export 'src/security/ios_load_graph.dart';
export 'src/security/ios_crypto_theft_chain.dart';
export 'src/security/ios_code_resources_check.dart';
export 'src/plist/binary_plist_parser.dart';
export 'src/plist/plist_fields.dart';
export 'src/plist/plist_parser.dart';
export 'src/plist/plist_value.dart';
export 'src/plist/xml_plist_parser.dart';
