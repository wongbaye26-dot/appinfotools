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

export 'src/ipa_container.dart';
export 'src/plist/binary_plist_parser.dart';
export 'src/plist/plist_parser.dart';
export 'src/plist/plist_value.dart';
export 'src/plist/xml_plist_parser.dart';
