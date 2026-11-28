import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

import 'support/aab_builder.dart';

void main() {
  group('PbMessage', () {
    test('读出 varint、length-delimited 与 fixed32', () {
      final bytes = (PbOut()
            ..intField(1, 300)
            ..stringField(2, 'hello')
            ..floatField(3, 2.0))
          .toBytes();

      final message = PbMessage.parse(bytes);
      expect(message, isNotNull);
      expect(message!.getInt(1), 300);
      expect(message.getString(2), 'hello');
      // 2.0f 的位模式是 0x40000000。
      expect(message.getFixed32(3), 0x40000000);
    });

    test('同号标量取最后一个（protobuf 合并语义）', () {
      final bytes = (PbOut()
            ..intField(1, 1)
            ..intField(1, 2)
            ..stringField(2, 'first')
            ..stringField(2, 'second'))
          .toBytes();

      final message = PbMessage.parse(bytes)!;
      expect(message.getInt(1), 2);
      expect(message.getString(2), 'second');
    });

    test('fixed64 字段被跳过，不影响后续字段', () {
      final bytes = (PbOut()
            ..fixed64Field(1, List<int>.filled(8, 0xAA))
            ..intField(2, 7))
          .toBytes();

      final message = PbMessage.parse(bytes)!;
      expect(message.getInt(2), 7);
      // 跳过不等于取值：读取器不认识的位宽不应伪装成 0。
      expect(message.getInt(1), isNull);
      expect(message.has(1), isFalse);
    });

    test('长度超出剩余字节时整条消息返回 null', () {
      // field 1, wire 2, 长度 5，但只跟了 1 个字节。
      expect(PbMessage.parse(Uint8List.fromList([0x0a, 0x05, 0x01])), isNull);
    });

    test('fixed32 被截断时返回 null', () {
      expect(PbMessage.parse(Uint8List.fromList([0x0d, 0x01])), isNull);
    });

    test('varint 超过 10 字节时返回 null', () {
      final bytes = Uint8List.fromList([
        0x08,
        ...List<int>.filled(10, 0x80),
        0x01,
      ]);
      expect(PbMessage.parse(bytes), isNull);
    });

    test('第 10 个 varint 字节大于 1 时返回 null', () {
      final bytes = Uint8List.fromList([
        0x08,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0x7f,
      ]);
      expect(PbMessage.parse(bytes), isNull);
    });

    test('wire type 3（已废弃的 group）返回 null', () {
      expect(PbMessage.parse(Uint8List.fromList([0x0b])), isNull);
    });

    test('字段号 0 返回 null', () {
      expect(PbMessage.parse(Uint8List.fromList([0x00])), isNull);
    });

    test('非法 UTF-8 字符串返回 null，而不是替换字符', () {
      final bytes = (PbOut()..bytesField(1, const [0xc3, 0x28])).toBytes();
      final message = PbMessage.parse(bytes)!;
      expect(message.getString(1), isNull);
    });

    test('getMessages 跳过单条畸形子消息', () {
      final valid = (PbOut()..intField(1, 9)).toBytes();
      final bytes = (PbOut()
            // 这条子消息以 field 1 varint 开头，却没有 varint 值。
            ..bytesField(1, const [0x08])
            ..bytesField(1, valid))
          .toBytes();

      final messages = PbMessage.parse(bytes)!.getMessages(1);
      expect(messages, hasLength(1));
      expect(messages.single.getInt(1), 9);
    });

    test('嵌套超过上限后 getMessage 返回 null', () {
      // 造 70 层「field 1 包着下一层」，超过 maxDepth=64。
      Uint8List bytes = Uint8List(0);
      for (var i = 0; i < 70; i++) {
        bytes = (PbOut()..bytesField(1, bytes)).toBytes();
      }

      PbMessage? current = PbMessage.parse(bytes);
      var levels = 0;
      while (current != null) {
        levels++;
        current = current.getMessage(1);
      }

      // 根（depth 0）加上最多 64 层子消息。
      expect(levels, 65);
    });

    test('空字节是合法的空消息', () {
      final message = PbMessage.parse(Uint8List(0));
      expect(message, isNotNull);
      expect(message!.fields, isEmpty);
    });
  });
}
