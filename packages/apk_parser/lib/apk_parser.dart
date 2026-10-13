export 'src/models.dart';
export 'src/byte_data_reader.dart';
export 'src/binary_xml.dart';
export 'src/manifest_parser.dart';
export 'src/arsc_parser.dart';
export 'src/arsc/string_pool.dart';
export 'src/arsc/resource_value.dart';
export 'src/arsc/type_spec.dart';
export 'src/hardening.dart';
export 'src/container_structure.dart';
export 'src/apk_reader.dart';

// ZIP 容器安全原语已下沉到 `archive_safety` —— 它们与「里面装的是 APK 还是
// IPA」无关，IPA 解析器也要用同一份实现（复制一份安全防护意味着两边的阈值
// 会各自漂移）。
//
// 这里**转出**它们，是为了让 `ApkReader.open` 的返回值 `ArchiveOpenResult`
// 在 `package:apk_parser/apk_parser.dart` 一个 import 下就可用 —— 否则每个
// 调用方都得同时 import 两个包。
export 'package:archive_safety/archive_safety.dart';
