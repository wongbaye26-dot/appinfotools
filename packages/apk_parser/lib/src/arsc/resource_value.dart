// ignore_for_file: constant_identifier_names
//
// 这些常量名刻意对齐 Android 平台 `Res_value` 的规范命名
// （AOSP: frameworks/base/libs/androidfw/include/androidfw/ResourceTypes.h），
// 以便与 AOSP 源码逐项对照。改成 lowerCamelCase 会破坏这种可核对性。

import 'dart:typed_data';
import '../byte_data_reader.dart';

/// Res_value structure
class ResourceValue {
  final int size;
  final int type;
  final int data;

  ResourceValue({required this.size, required this.type, required this.data});

  static const int TYPE_NULL = 0x00;
  static const int TYPE_REFERENCE = 0x01;
  static const int TYPE_ATTRIBUTE = 0x02;
  static const int TYPE_STRING = 0x03;
  static const int TYPE_FLOAT = 0x04;
  static const int TYPE_DIMENSION = 0x05;
  static const int TYPE_FRACTION = 0x06;
  static const int TYPE_INT_DEC = 0x10;
  static const int TYPE_INT_HEX = 0x11;
  static const int TYPE_INT_BOOLEAN = 0x12;
  static const int TYPE_INT_COLOR_ARGB8 = 0x1c;
  static const int TYPE_INT_COLOR_RGB8 = 0x1d;
  static const int TYPE_INT_COLOR_ARGB4 = 0x1e;
  static const int TYPE_INT_COLOR_RGB4 = 0x1f;

  bool get isString => type == TYPE_STRING;
  bool get isReference => type == TYPE_REFERENCE;
  bool get isColor =>
      type == TYPE_INT_COLOR_ARGB8 ||
      type == TYPE_INT_COLOR_RGB8 ||
      type == TYPE_INT_COLOR_ARGB4 ||
      type == TYPE_INT_COLOR_RGB4;

  /// 将颜色值转换为 #AARRGGBB 格式的十六进制字符串
  String? get colorHex {
    if (!isColor) return null;
    switch (type) {
      case TYPE_INT_COLOR_ARGB8:
        return '#${data.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';
      case TYPE_INT_COLOR_RGB8:
        return '#ff${(data & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
      case TYPE_INT_COLOR_ARGB4:
        final a = (data >> 12) & 0xF;
        final r = (data >> 8) & 0xF;
        final g = (data >> 4) & 0xF;
        final b = data & 0xF;
        return '#${(a * 17).toRadixString(16).padLeft(2, '0')}'
            '${(r * 17).toRadixString(16).padLeft(2, '0')}'
            '${(g * 17).toRadixString(16).padLeft(2, '0')}'
            '${(b * 17).toRadixString(16).padLeft(2, '0')}';
      case TYPE_INT_COLOR_RGB4:
        final r = (data >> 8) & 0xF;
        final g = (data >> 4) & 0xF;
        final b = data & 0xF;
        return '#ff'
            '${(r * 17).toRadixString(16).padLeft(2, '0')}'
            '${(g * 17).toRadixString(16).padLeft(2, '0')}'
            '${(b * 17).toRadixString(16).padLeft(2, '0')}';
      default:
        return null;
    }
  }

  static ResourceValue read(ByteDataReader reader) {
    final size = reader.readUint16();
    reader.readUint8(); // res0
    final type = reader.readUint8();
    final data = reader.readUint32();
    return ResourceValue(size: size, type: type, data: data);
  }
}

/// ResTable_entry
class ResourceEntry {
  final int flags;
  final int keyIndex;
  final ResourceValue? value;
  final Map<int, ResourceValue>? mapValues;

  ResourceEntry({
    required this.flags,
    required this.keyIndex,
    this.value,
    this.mapValues,
  });

  bool get isComplex => (flags & 0x0001) != 0;
}

/// ResTable_config
///
/// 字段偏移按 AOSP `ResTable_config` 的实际布局（不是猜的）：
/// 4 mcc、6 mnc、8 language、10 country、12 orientation、13 touchscreen、
/// 14 density、16 keyboard、17 navigation、18 inputFlags、19 inputPad0、
/// 20 screenWidth、22 screenHeight、24 sdkVersion、26 minorVersion、
/// 28 screenLayout、**29 uiMode**、30 smallestScreenWidthDp、
/// 32 screenWidthDp、34 screenHeightDp、36 localeScript、40 localeVariant。
///
/// `size` 决定哪些字段真的存在：解析器必须按 `size` 判断，不能直接读到越界。
class ResourceConfig {
  final int size;
  final int mcc;
  final int mnc;
  final String language;
  final String country;
  final String script;
  final String variant;
  final int density;

  /// `uiMode` 原始字节（偏移 29）。
  ///
  /// 高 2 位（掩码 [uiModeNightMask]）表示夜间模式，低 4 位
  /// （掩码 [uiModeTypeMask]）表示设备类型。配置里没有该字段时为 0。
  final int uiMode;

  ResourceConfig({
    this.size = 0,
    this.mcc = 0,
    this.mnc = 0,
    this.language = '',
    this.country = '',
    this.script = '',
    this.variant = '',
    this.density = 0,
    this.uiMode = 0,
  });

  /// `uiMode` 里设备类型部分的掩码。
  static const int uiModeTypeMask = 0x0f;

  /// `uiMode` 里夜间模式部分的掩码。
  static const int uiModeNightMask = 0x30;

  /// `uiMode & [uiModeNightMask]` 取到该值表示**夜间模式**。
  static const int uiModeNightYes = 0x20;

  /// 该配置是否是夜间模式（`values-night` / `drawable-night` 等）。
  ///
  /// `uiMode & 0x30 == 0x20` 才是夜间；`0x10` 是显式的「非夜间」，
  /// `0x00` 是未指定 —— 后两者都不算夜间变体。
  bool get isNightMode => (uiMode & uiModeNightMask) == uiModeNightYes;

  /// `uiMode` 里的设备类型（低 4 位）。
  int get uiModeType => uiMode & uiModeTypeMask;

  /// `uiMode` 设备类型（低 4 位）对应的稳定标识符。
  ///
  /// 刻意返回**标识符**而不是自然语言：与加固线索的枚举名同理，它们要能与
  /// 代码、日志、aapt2 的输出对照，翻成「车载模式」反而更难排查。
  static const Map<int, String> uiModeTypeNames = {
    1: 'normal',
    2: 'desk',
    3: 'car',
    4: 'television',
    5: 'appliance',
    6: 'watch',
    7: 'vrheadset',
  };

  /// 设备类型的可读标识；未知取值返回 `type<N>`，不猜也不丢。
  static String uiModeTypeName(int type) =>
      uiModeTypeNames[type] ?? 'type$type';

  String get locale {
    if (language.isEmpty) return '';
    final parts = <String>[language];
    if (script.isNotEmpty) parts.add(script);
    if (country.isNotEmpty) parts.add(country);
    return parts.join('-');
  }

  static ResourceConfig read(ByteDataReader reader) {
    final startPos = reader.position;
    final size = reader.readUint32();

    if (size < 8) {
      if (size > 4) reader.position = startPos + size;
      return ResourceConfig(size: size);
    }

    final mcc = reader.readUint16();
    final mnc = reader.readUint16();

    // 混淆 APK 可能使用截短的 config（如 size=16），
    // 但 language/country 字段仍在标准位置（offset 8-11）
    String language = '';
    String country = '';
    int density = 0;
    String script = '';
    String variant = '';
    int uiMode = 0;

    if (size >= 12) {
      final langBytes = reader.readUint8List(2);
      final countryBytes = reader.readUint8List(2);
      language = _decodeChars(langBytes);
      country = _decodeChars(countryBytes, base: 0x41);
    }

    if (size >= 16) {
      reader.readUint8(); // orientation
      reader.readUint8(); // touchscreen
      density = reader.readUint16();
    }

    // uiMode: 1 byte at offset 29（需要 size >= 30 才存在）
    if (size >= 30) {
      reader.position = startPos + 29;
      uiMode = reader.readUint8();
    }

    // localeScript: 4 bytes at offset 36 (when size >= 40)
    if (size >= 40) {
      reader.position = startPos + 36;
      final scriptBytes = reader.readUint8List(4);
      script = String.fromCharCodes(scriptBytes.where((b) => b != 0));
    }

    // localeVariant: 8 bytes at offset 40 (when size >= 48)
    if (size >= 48) {
      reader.position = startPos + 40;
      final variantBytes = reader.readUint8List(8);
      variant = String.fromCharCodes(variantBytes.where((b) => b != 0));
    }

    // Skip remaining config fields
    reader.position = startPos + size;

    return ResourceConfig(
      size: size,
      mcc: mcc,
      mnc: mnc,
      language: language,
      country: country,
      script: script,
      variant: variant,
      density: density,
      uiMode: uiMode,
    );
  }

  /// 解码 2 字节语言/地区码，支持 BCP-47 packed 3 字母码
  ///
  /// packed 格式: byte[0] 高位 (0x80) 置位时，15 位编码 3 个字符
  /// (每字符 5 bits, base-26)。[base] 为语言码时用 0x61 ('a')，
  /// 地区码时用 0x41 ('A')。
  static String _decodeChars(Uint8List bytes, {int base = 0x61}) {
    if (bytes[0] == 0 && bytes[1] == 0) return '';
    // BCP-47 packed 3-letter code: high bit set on byte[0]
    if ((bytes[0] & 0x80) != 0) {
      final first = (bytes[0] >> 2) & 0x1F;
      final second = ((bytes[0] & 0x03) << 3) | ((bytes[1] >> 5) & 0x07);
      final third = bytes[1] & 0x1F;
      return String.fromCharCodes([base + first, base + second, base + third]);
    }
    return String.fromCharCodes(bytes.where((b) => b != 0));
  }
}
