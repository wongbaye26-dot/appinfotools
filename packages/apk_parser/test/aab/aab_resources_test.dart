import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

import 'support/aab_builder.dart';

void main() {
  group('AabResourceTable', () {
    late AabResourceTable table;

    setUp(() {
      final parsed = AabResourceTable.parse(standardResourceTable().toBytes());
      expect(parsed, isNotNull);
      table = parsed!;
    });

    test('默认配置的字符串资源', () {
      final value = table.values[0x7f010000];
      expect(value, isNotNull);
      expect(value!.kind, AabResourceKind.string);
      expect(value.value, 'Demo App');
    });

    test('locale 维度单独保存，可直接查某语言的 label', () {
      expect(table.localized[0x7f010000], {
        'zh-CN': '演示应用',
        'en': 'Demo EN',
      });
      expect(table.resolveString(0x7f010000, locale: 'zh-CN'), '演示应用');
      expect(table.resolveString(0x7f010000, locale: 'en'), 'Demo EN');
      // 没有该语言的翻译时退回默认值，而不是留空。
      expect(table.resolveString(0x7f010000, locale: 'ja'), 'Demo App');
      expect(table.locales, ['en', 'zh-CN']);
    });

    test('配置变体以可读键保存', () {
      expect(
        table.variants[0x7f010000]!.keys.toSet(),
        {'default', 'zh-CN', 'en'},
      );
    });

    test('引用跟随到被引用的字符串', () {
      expect(table.values[0x7f010001]!.kind, AabResourceKind.reference);
      expect(table.values[0x7f010001]!.referenceId, 0x7f010000);
      expect(table.resolveString(0x7f010001), 'Demo App');
      expect(table.resolveString(0x7f010001, locale: 'zh-CN'), '演示应用');
    });

    test('file 值按 density 保存，路径带上模块前缀', () {
      final files = table.resolveFiles(0x7f020000);
      expect(files.keys.toSet(), {'mdpi', 'xxxhdpi', 'anydpi'});
      expect(files['mdpi'], 'base/res/mipmap-mdpi-v4/ic_launcher.png');
      expect(table.densities, [160, 640]);
    });

    test('bestFile 优先位图并取最高密度', () {
      expect(
        table.bestFile(0x7f020000),
        'base/res/mipmap-xxxhdpi-v4/ic_launcher.png',
      );
    });

    test('颜色值的格式是 #aarrggbb', () {
      final value = table.values[0x7f030000];
      expect(value, isNotNull);
      expect(value!.kind, AabResourceKind.color);
      expect(value.value, '#ff112233');
    });

    test('没有默认配置时退回第一个变体', () {
      final bytes = resourceTable(types: [
        type(1, 'string', [
          entry(0, 'only_zh', [
            configValue(locale: 'zh-CN', item: itemString('仅中文')),
          ]),
        ]),
      ]).toBytes();

      final parsed = AabResourceTable.parse(bytes)!;
      expect(parsed.values[0x7f010000]!.value, '仅中文');
      expect(parsed.localized[0x7f010000], {'zh-CN': '仅中文'});
    });

    test('空 protobuf 消息是空表，而不是解析失败', () {
      final parsed = AabResourceTable.parse(Uint8List(0));
      expect(parsed, isNotNull);
      expect(parsed!.isEmpty, isTrue);
    });

    test('截断的字节返回 null', () {
      final bytes = standardResourceTable().toBytes();
      final truncated = Uint8List.sublistView(bytes, 0, bytes.length - 3);
      expect(AabResourceTable.parse(truncated), isNull);
    });

    test('单条坏记录被跳过，其余条目照常解析', () {
      // Item 里塞一个只有 tag、没有 varint 值的字段：这一条读不出来。
      final brokenValue = PbOut()
        ..messageField(1, config())
        ..messageField(2, PbOut()..bytesField(4, const [0x08]));
      final bytes = resourceTable(types: [
        type(1, 'string', [
          entry(0, 'ok', [configValue(item: itemString('OK'))]),
          entry(1, 'broken', [brokenValue]),
        ]),
      ]).toBytes();

      final parsed = AabResourceTable.parse(bytes)!;
      expect(parsed.values[0x7f010000]!.value, 'OK');
      expect(parsed.values.containsKey(0x7f010001), isFalse);
      expect(parsed.isEmpty, isFalse);
    });
  });

  group('aabItemValue', () {
    test('文件路径拼上模块名，已带前缀时不重复拼', () {
      expect(
        aabItemValue(messageOf(itemFile('res/a.png')))!.value,
        'base/res/a.png',
      );
      expect(
        aabItemValue(
          messageOf(itemFile('feature1/res/a.png')),
          module: 'feature1',
        )!
            .value,
        'feature1/res/a.png',
      );
      expect(aabModulePath('base', 'base/res/a.png'), 'base/res/a.png');
    });

    test('属性引用与资源引用分开标记', () {
      final attribute = aabItemValue(
        messageOf(itemReference(0x1010435, type: 1)),
      )!;
      expect(attribute.kind, AabResourceKind.attribute);
      expect(attribute.value, '@attr/0x1010435');
      expect(attribute.referenceId, 0x1010435);

      final resource = aabItemValue(messageOf(itemReference(0x7f010000)))!;
      expect(resource.kind, AabResourceKind.reference);
      expect(resource.value, '@res/0x7f010000');
    });

    test('primitive 值转成可读文本', () {
      expect(aabItemValue(messageOf(itemFloat(2.0)))!.value, '2.0');
      expect(aabItemValue(messageOf(itemInt(7)))!.value, '7');
      expect(aabItemValue(messageOf(itemBool(true)))!.value, 'true');
      expect(aabItemValue(messageOf(itemBool(false)))!.value, 'false');
      expect(
        aabItemValue(messageOf(itemColor(0x80112233)))!.value,
        '#80112233',
      );
    });

    test('既没有值也没有引用的 Item 返回 null', () {
      expect(aabItemValue(messageOf(PbOut())), isNull);
      // 引用 id 为 0 视为「没有引用」，不能显示成 @res/0x0。
      expect(aabItemValue(messageOf(itemReference(0))), isNull);
    });
  });
}
