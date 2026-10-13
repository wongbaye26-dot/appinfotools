import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'plist_value.dart';

/// plist 解析失败。
///
/// 单独成类型是为了让调用方能把它与「文件不存在」「容器损坏」区分开：
/// 对用户而言「Info.plist 格式不对」和「IPA 打不开」是两回事。
class PlistParseException implements Exception {
  final String message;

  const PlistParseException(this.message);

  @override
  String toString() => 'PlistParseException: $message';
}

/// 解析 XML 形式的 plist。
///
/// 大多数 `Info.plist` 是 XML plist；少数（尤其 App Store 下发的包）是二进制
/// plist，见 [BinaryPlistParser]。
class XmlPlistParser {
  XmlPlistParser._();

  static PlistValue parse(Uint8List bytes) =>
      parseString(utf8.decode(bytes, allowMalformed: true));

  static PlistValue parseString(String text) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(text);
    } on XmlException catch (e) {
      throw PlistParseException('not well-formed XML: ${e.message}');
    }

    final plist = document.rootElement;
    if (plist.name.local != 'plist') {
      throw PlistParseException(
          'root element is <${plist.name.local}>, expected <plist>');
    }

    final children = plist.childElements;
    if (children.isEmpty) {
      throw const PlistParseException('<plist> contains no value element');
    }
    return convertElement(children.first);
  }

  /// 把一个 plist 值元素转成 [PlistValue]。
  static PlistValue convertElement(XmlElement element) {
    switch (element.name.local) {
      case 'dict':
        return PlistDict(_convertDict(element));
      case 'array':
        return PlistArray(element.childElements.map(convertElement).toList());
      case 'string':
        return PlistString(element.innerText);
      case 'integer':
        final value = int.tryParse(element.innerText.trim());
        if (value == null) {
          throw PlistParseException('invalid <integer>: ${element.innerText}');
        }
        return PlistInteger(value);
      case 'real':
        final value = double.tryParse(element.innerText.trim());
        if (value == null) {
          throw PlistParseException('invalid <real>: ${element.innerText}');
        }
        return PlistReal(value);
      case 'true':
        return const PlistBoolean(true);
      case 'false':
        return const PlistBoolean(false);
      case 'date':
        final parsed = DateTime.tryParse(element.innerText.trim());
        if (parsed == null) {
          throw PlistParseException('invalid <date>: ${element.innerText}');
        }
        return PlistDate(parsed.toUtc());
      case 'data':
        return PlistData(_decodeBase64(element.innerText));
      default:
        throw PlistParseException(
            'unsupported plist element <${element.name.local}>');
    }
  }

  static Map<String, PlistValue> _convertDict(XmlElement dict) {
    final result = <String, PlistValue>{};
    String? pendingKey;

    for (final child in dict.childElements) {
      if (child.name.local == 'key') {
        if (pendingKey != null) {
          throw PlistParseException(
              '<key>$pendingKey</key> has no value before the next <key>');
        }
        pendingKey = child.innerText;
        continue;
      }

      final key = pendingKey;
      if (key == null) {
        throw PlistParseException(
            '<${child.name.local}> in <dict> without a preceding <key>');
      }
      result[key] = convertElement(child);
      pendingKey = null;
    }

    if (pendingKey != null) {
      throw PlistParseException('<key>$pendingKey</key> has no value');
    }
    return result;
  }

  /// `<data>` 的内容是 base64，且常按 76 字符换行 —— 先去掉所有空白。
  static Uint8List _decodeBase64(String text) {
    final compact = text.replaceAll(RegExp(r'\s'), '');
    try {
      return base64.decode(compact);
    } on FormatException catch (e) {
      throw PlistParseException('invalid <data> base64: ${e.message}');
    }
  }
}
