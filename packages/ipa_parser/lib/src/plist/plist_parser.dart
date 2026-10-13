import 'dart:typed_data';

import 'binary_plist_parser.dart';
import 'plist_value.dart';
import 'xml_plist_parser.dart';

/// plist 的两种编码。
enum PlistFormat {
  /// XML plist（`<?xml ...?><plist version="1.0">`）。
  xml,

  /// 二进制 plist（`bplist00`）。
  binary,
}

/// 按**内容**识别格式并解析。
class PlistParser {
  PlistParser._();

  /// `bplist00`
  static const List<int> _binaryMagic = [
    0x62,
    0x70,
    0x6C,
    0x69,
    0x73,
    0x74,
    0x30,
    0x30,
  ];

  /// 判定编码。
  ///
  /// 只看开头几个字节 —— **不看扩展名、也不看调用方声明**。plist 经常被改名，
  /// 内容才是唯一可靠的依据。识别不出时返回 `null`，由调用方决定如何记录
  /// 「这不是 plist」，而不是抛一个笼统的解析错误。
  static PlistFormat? detectFormat(Uint8List bytes) {
    if (bytes.length >= _binaryMagic.length) {
      var isBinary = true;
      for (var i = 0; i < _binaryMagic.length; i++) {
        if (bytes[i] != _binaryMagic[i]) {
          isBinary = false;
          break;
        }
      }
      if (isBinary) return PlistFormat.binary;
    }

    var start = 0;
    // UTF-8 BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }

    // XML 声明前可能有空白；第一个非空白字节应当是 '<'。
    final limit = start + 256;
    for (var i = start; i < bytes.length && i < limit; i++) {
      final byte = bytes[i];
      if (byte == 0x3C) return PlistFormat.xml; // '<'
      if (byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) break;
    }
    return null;
  }

  /// 自动识别并解析。
  ///
  /// 识别不出格式时抛 [PlistParseException]（而不是返回 null）：调用方需要
  /// 区分「不是 plist」与「是 plist 但字段缺失」，这两者对用户的含义不同。
  static PlistValue parse(Uint8List bytes) {
    return switch (detectFormat(bytes)) {
      PlistFormat.binary => BinaryPlistParser.parse(bytes),
      PlistFormat.xml => XmlPlistParser.parse(bytes),
      null => throw const PlistParseException(
          'not a plist: neither bplist00 nor XML'),
    };
  }
}
