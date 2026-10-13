// plist 解析测试（XML 与二进制 bplist00）。
//
// 二进制样本由 macOS 的 `plutil -convert binary1` 从等价的 XML 转换而来，
// 并内嵌为 base64 —— **不是**手工拼的字节。手工拼样本会带着与解析器相同的
// 错误假设，测出来只是自证。
//
// 唯一的例外是「自引用」「超深嵌套」这类畸形样本：没有工具能生成它们，只能
// 手工构造。但那种用例断言的是**解析器必须拒绝**，构造器与被测逻辑不共享假设。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

/// 与下面 XML 样本内容等价的二进制 plist，由 `plutil -convert binary1` 生成。
const String _binaryPlistBase64 =
    'YnBsaXN0MDDdAQIDBAUGBwgJCgsMDQ4PEBYXGBkbHB0eISNYU29tZURhdGFfEBJDRkJ1bmRsZUlkZW50aWZpZXJdQ0ZCdW5k'
    'bGVJY29uc18QFFVJRmlsZVNoYXJpbmdFbmFibGVkXxAPQ0ZCdW5kbGVWZXJzaW9uXxASQ0ZCdW5kbGVFeGVjdXRhYmxlXxAg'
    'VUlTdXBwb3J0ZWRJbnRlcmZhY2VPcmllbnRhdGlvbnNfEBBNaW5pbXVtT1NWZXJzaW9uWFNvbWVSZWFsWFNvbWVEYXRlXlVJ'
    'RGV2aWNlRmFtaWx5XxAbTFNBcHBsaWNhdGlvblF1ZXJpZXNTY2hlbWVzXxAaQ0ZCdW5kbGVTaG9ydFZlcnNpb25TdHJpbmdF'
    'aGVsbG9fEA9jb20uZXhhbXBsZS5hcHDRERJfEBNDRkJ1bmRsZVByaW1hcnlJY29u0RMUXxARQ0ZCdW5kbGVJY29uRmlsZXOh'
    'FVxBcHBJY29uNjB4NjAJECpXRXhhbXBsZaEaXxAeVUlJbnRlcmZhY2VPcmllbnRhdGlvblBvcnRyYWl0VDE1LjAjQAQAAAAA'
    'AAAzQcXI/WAAAACiHyAQARACoSJWd2VpeGluVTEuMi4zAAgAIwAsAEEATwBmAHgAjQCwAMMAzADVAOQBAgEfASUBNwE6AVAB'
    'UwFnAWkBdgF3AXkBgQGDAaQBqQGyAbsBvgHAAcIBxAHLAAAAAAAAAgEAAAAAAAAAJAAAAAAAAAAAAAAAAAAAAdE=';

/// 与二进制样本内容等价的 XML plist。
const String _xmlPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.example.app</string>
	<key>CFBundleShortVersionString</key>
	<string>1.2.3</string>
	<key>CFBundleVersion</key>
	<integer>42</integer>
	<key>CFBundleExecutable</key>
	<string>Example</string>
	<key>MinimumOSVersion</key>
	<string>15.0</string>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
	<key>LSApplicationQueriesSchemes</key>
	<array>
		<string>weixin</string>
	</array>
	<key>UIFileSharingEnabled</key>
	<true/>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
	</array>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon60x60</string>
			</array>
		</dict>
	</dict>
	<key>SomeDate</key>
	<date>2024-03-01T12:00:00Z</date>
	<key>SomeData</key>
	<data>aGVsbG8=</data>
	<key>SomeReal</key>
	<real>2.5</real>
</dict>
</plist>
''';

/// 断言两种编码解析出**同样**的内容。
void _expectSampleContent(PlistValue value, String label) {
  final dict = value.asDict;
  expect(dict, isNotNull, reason: '$label: 顶层应当是 dict');
  final map = dict!.value;

  expect(
      map.keys.toSet(),
      {
        'CFBundleIdentifier',
        'CFBundleShortVersionString',
        'CFBundleVersion',
        'CFBundleExecutable',
        'MinimumOSVersion',
        'UIDeviceFamily',
        'LSApplicationQueriesSchemes',
        'UIFileSharingEnabled',
        'UISupportedInterfaceOrientations',
        'CFBundleIcons',
        'SomeDate',
        'SomeData',
        'SomeReal',
      },
      reason: '$label: 键集合不一致');

  expect(map['CFBundleIdentifier']!.asString, 'com.example.app');
  expect(map['CFBundleShortVersionString']!.asString, '1.2.3');
  expect(map['CFBundleVersion']!.asInt, 42);
  expect(map['CFBundleExecutable']!.asString, 'Example');
  expect(map['MinimumOSVersion']!.asString, '15.0');

  expect(map['UIDeviceFamily']!.asIntList, [1, 2]);
  expect(map['LSApplicationQueriesSchemes']!.asStringList, ['weixin']);
  expect(map['UISupportedInterfaceOrientations']!.asStringList,
      ['UIInterfaceOrientationPortrait']);
  expect(map['UIFileSharingEnabled']!.asBool, isTrue);

  // 嵌套 dict
  final icons = map['CFBundleIcons']!.asDict!;
  final primary = icons.value['CFBundlePrimaryIcon']!.asDict!;
  expect(primary.value['CFBundleIconFiles']!.asStringList, ['AppIcon60x60']);

  // date / data / real
  expect(map['SomeDate']!.asDate, DateTime.utc(2024, 3, 1, 12));
  expect(map['SomeData']!.asDict, isNull);
  final data = map['SomeData']!;
  expect(data, isA<PlistData>());
  expect(utf8.decode((data as PlistData).value), 'hello');
  expect(map['SomeReal']!.asInt, 2); // 2.5 -> 取整
  expect((map['SomeReal']! as PlistReal).value, 2.5);
}

/// 极简 bplist00 构造器，**仅用于生成畸形/对抗性样本**。
///
/// 正常样本一律用 plutil 生成。这里构造的是「自引用」「超深嵌套」这类工具
/// 造不出来的东西，而用例断言的是解析器会拒绝它们 —— 构造器与被测逻辑不共享
/// 假设，所以不会自证。
Uint8List _buildBplist(
  List<List<int>> objects, {
  int top = 0,
  int offsetIntSize = 1,
  int objectRefSize = 1,
}) {
  final out = <int>[...'bplist00'.codeUnits];
  final offsets = <int>[];
  for (final object in objects) {
    offsets.add(out.length);
    out.addAll(object);
  }
  final offsetTableOffset = out.length;
  for (final offset in offsets) {
    out.addAll(_be(offset, offsetIntSize));
  }

  out.addAll(List.filled(6, 0)); // 未使用
  out.add(offsetIntSize);
  out.add(objectRefSize);
  out.addAll(_be(objects.length, 8)); // numObjects
  out.addAll(_be(top, 8)); // topObject
  out.addAll(_be(offsetTableOffset, 8));

  return Uint8List.fromList(out);
}

List<int> _be(int value, int size) =>
    [for (var i = size - 1; i >= 0; i--) (value >> (i * 8)) & 0xFF];

void main() {
  group('XML plist', () {
    test('解析完整的 Info.plist 结构', () {
      _expectSampleContent(XmlPlistParser.parseString(_xmlPlist), 'XML');
    });

    test('UTF-8 BOM 与前导空白不影响解析', () {
      final withBom = '\uFEFF\n  $_xmlPlist';
      expect(XmlPlistParser.parseString(withBom).asDict, isNotNull);
    });

    test('base64 数据按 76 字符换行也能解出', () {
      const wrapped = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>d</key>
  <data>aGVsbG8gd29ybGQgdGhpcyBpcyBhIGxvbmc
       gZXIgYmFzZTY0IHBheWxvYWQ=</data>
</dict>
</plist>
''';
      final value = XmlPlistParser.parseString(wrapped).asDict!.value['d']!;
      expect(value, isA<PlistData>());
    });

    test('整数写成字符串时仍能取到值（真实应用常见）', () {
      const odd = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleVersion</key>
  <string>42</string>
</dict>
</plist>
''';
      expect(
          XmlPlistParser.parseString(odd)
              .asDict!
              .value['CFBundleVersion']!
              .asInt,
          42);
    });
  });

  group('XML plist 的错误', () {
    test('不是 XML', () {
      expect(() => XmlPlistParser.parseString('not xml at all'),
          throwsA(isA<PlistParseException>()));
    });

    test('根元素不是 plist', () {
      expect(
          () => XmlPlistParser.parseString('<root><string>x</string></root>'),
          throwsA(isA<PlistParseException>()));
    });

    test('<plist> 内没有值元素', () {
      expect(() => XmlPlistParser.parseString('<plist version="1.0"></plist>'),
          throwsA(isA<PlistParseException>()));
    });

    test('不认识的元素', () {
      expect(
          () => XmlPlistParser.parseString(
              '<plist version="1.0"><bogus/></plist>'),
          throwsA(isA<PlistParseException>()));
    });

    test('<integer> 内容非法', () {
      expect(
          () => XmlPlistParser.parseString(
              '<plist version="1.0"><integer>abc</integer></plist>'),
          throwsA(isA<PlistParseException>()));
    });

    test('dict 里出现没有 key 的值', () {
      expect(
          () => XmlPlistParser.parseString(
              '<plist version="1.0"><dict><string>x</string></dict></plist>'),
          throwsA(isA<PlistParseException>()));
    });

    test('key 后面没有值', () {
      expect(
          () => XmlPlistParser.parseString(
              '<plist version="1.0"><dict><key>a</key></dict></plist>'),
          throwsA(isA<PlistParseException>()));
    });
  });

  group('二进制 plist（plutil 生成的真实样本）', () {
    test('与等价 XML 解析出同样内容', () {
      final bytes = base64.decode(_binaryPlistBase64);
      expect(bytes.sublist(0, 8), 'bplist00'.codeUnits,
          reason: '样本应当是二进制 plist');

      _expectSampleContent(BinaryPlistParser.parse(bytes), 'binary');
    });

    test('date 精确到秒（Apple 纪元换算正确）', () {
      final value = BinaryPlistParser.parse(base64.decode(_binaryPlistBase64));
      expect(value.asDict!.value['SomeDate']!.asDate,
          DateTime.utc(2024, 3, 1, 12));
    });
  });

  group('格式识别', () {
    test('识别二进制', () {
      expect(PlistParser.detectFormat(base64.decode(_binaryPlistBase64)),
          PlistFormat.binary);
    });

    test('识别 XML（含 BOM 与前导空白）', () {
      expect(
          PlistParser.detectFormat(Uint8List.fromList(utf8.encode(_xmlPlist))),
          PlistFormat.xml);
      expect(
          PlistParser.detectFormat(
              Uint8List.fromList(utf8.encode('\uFEFF\n  $_xmlPlist'))),
          PlistFormat.xml);
    });

    test('两者都不是时返回 null，而不是猜一个', () {
      expect(PlistParser.detectFormat(Uint8List.fromList(utf8.encode('hello'))),
          isNull);
      expect(PlistParser.detectFormat(Uint8List(0)), isNull);
      // 有 bplist 前缀但不完整
      expect(PlistParser.detectFormat(Uint8List.fromList('bplist0'.codeUnits)),
          isNull);
    });

    test('parse 对非 plist 输入抛异常，而不是返回 null', () {
      expect(() => PlistParser.parse(Uint8List.fromList(utf8.encode('nope'))),
          throwsA(isA<PlistParseException>()));
    });

    test('parse 自动分派两种编码', () {
      expect(PlistParser.parse(base64.decode(_binaryPlistBase64)).asDict,
          isNotNull);
      expect(
          PlistParser.parse(Uint8List.fromList(utf8.encode(_xmlPlist))).asDict,
          isNotNull);
    });
  });

  group('二进制 plist 的安全防护', () {
    test('太短', () {
      expect(() => BinaryPlistParser.parse(Uint8List(16)),
          throwsA(isA<PlistParseException>()));
    });

    test('魔数不对', () {
      final bytes = base64.decode(_binaryPlistBase64);
      bytes[0] = 0x41; // 'A'
      expect(() => BinaryPlistParser.parse(bytes),
          throwsA(isA<PlistParseException>()));
    });

    test('截断（去掉尾部的 trailer）', () {
      final bytes = base64.decode(_binaryPlistBase64);
      expect(
          () => BinaryPlistParser.parse(
              Uint8List.sublistView(bytes, 0, bytes.length - 40)),
          throwsA(isA<PlistParseException>()));
    });

    test('offsetIntSize 非法', () {
      final bytes = base64.decode(_binaryPlistBase64);
      bytes[bytes.length - 32 + 6] = 0; // offsetIntSize = 0
      expect(() => BinaryPlistParser.parse(bytes),
          throwsA(isA<PlistParseException>()));
    });

    test('numObjects 声明得离谱时被拒绝（不会尝试分配）', () {
      final bytes = base64.decode(_binaryPlistBase64);
      final trailerStart = bytes.length - 32;
      for (var i = 0; i < 8; i++) {
        bytes[trailerStart + 8 + i] = 0xFF; // numObjects = 2^64-1
      }
      expect(() => BinaryPlistParser.parse(bytes),
          throwsA(isA<PlistParseException>()));
    });

    test('对象偏移越界时被拒绝', () {
      final bytes = _buildBplist([
        [0x51, 0x61], // string "a"
      ]);
      // 把 offset table 的第一项改成 0（指向魔数区域，不是对象）
      final offsetTableOffset = bytes.length - 32 - 1;
      bytes[offsetTableOffset] = 0;
      expect(() => BinaryPlistParser.parse(bytes),
          throwsA(isA<PlistParseException>()));
    });

    test('自引用不会无限递归，而是被拒绝', () {
      // obj0 = dict(1)，key -> obj1，value -> obj0（指向自己）
      final bytes = _buildBplist([
        [0xD1, 0x01, 0x00],
        [0x51, 0x61], // string "a"
      ]);
      expect(() => BinaryPlistParser.parse(bytes),
          throwsA(isA<PlistParseException>()));
    });

    test('嵌套过深时被拒绝，而不是爆栈', () {
      // 130 层：obj0..128 是 array(1) -> 下一个，obj129 是 string
      const depth = 130;
      final objects = <List<int>>[];
      for (var i = 0; i < depth - 1; i++) {
        objects.add([0xA1, i + 1]); // array(1), ref = i+1
      }
      objects.add([0x51, 0x78]); // string "x"

      final bytes = _buildBplist(objects, offsetIntSize: 2);
      expect(() => BinaryPlistParser.parse(bytes),
          throwsA(isA<PlistParseException>()));
    });

    test('合法的浅层嵌套仍然能解析（上限没有误伤正常样本）', () {
      // obj0 = array(1) -> obj1 = string "x"
      final bytes = _buildBplist([
        [0xA1, 0x01],
        [0x51, 0x78],
      ]);
      final value = BinaryPlistParser.parse(bytes);
      expect(value.asArray!.value.single.asString, 'x');
    });
  });
}
