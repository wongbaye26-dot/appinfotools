import 'dart:convert';
import 'dart:typed_data';

/// protobuf 线格式（wire type）编号。
///
/// 只列本包实际取值的三种：0 = varint、2 = length-delimited、5 = fixed32。
/// 1（fixed64）不取值，但**必须能跳过**：AAB 由 aapt2 / bundletool 产出，
/// 未来版本可能在消息里加入新字段；遇到不认识的字段就整条消息作废，会把
/// 「多了一个我们不关心的字段」误报成「文件损坏」。
const int _wireVarint = 0;
const int _wireFixed64 = 1;
const int _wireLengthDelimited = 2;
const int _wireFixed32 = 5;

/// 一个已解出的 protobuf 字段。
///
/// 保留 `wireType` 是为了让读取方（[PbMessage]）区分同号字段的不同编码 ——
/// 例如 `Primitive.float` 是 fixed32 而 `Primitive.int_decimal` 是 varint，
/// 只看字段号无法判断该按哪种方式取值。
class PbField {
  const PbField({
    required this.number,
    required this.wireType,
    this.intValue = 0,
    this.bytes,
    this.fixed32 = 0,
  });

  /// 字段号（tag >> 3）。
  final int number;

  /// 线格式编号（tag & 0x7）。
  final int wireType;

  /// wire type 0 的值。
  final int intValue;

  /// wire type 2 的原始字节（子消息、字符串、bytes 共用）。
  final Uint8List? bytes;

  /// wire type 5 的 4 字节小端值。
  final int fixed32;

  @override
  String toString() => 'PbField(#$number, wire=$wireType)';
}

/// 一条已解出的 protobuf 消息。
///
/// 设计原则：**越界、截断、非法 tag 一律返回 `null`，绝不抛异常**。
///
/// AAB 是不可信输入（用户可以选任意文件），解析器的职责是把「读不出来」
/// 变成可展示的事实，而不是让一个 `RangeError` 冒到界面线程。因此这里
/// 不做「防御性 assert」，每个读取点都用长度判断收口。
class PbMessage {
  PbMessage._(this._fields, this._depth);

  final List<PbField> _fields;

  /// 当前嵌套深度。子消息沿用同一个上限，避免畸形输入用深层嵌套耗尽栈。
  final int _depth;

  /// 允许的最大消息嵌套深度。
  ///
  /// `Resources.proto` 实际嵌套约 7 层（table → package → type → entry →
  /// config_value → value → item）；64 层已经远超真实文件，同时远低于会
  /// 让递归爆栈的量级。
  static const int maxDepth = 64;

  /// 解析一条消息；字节不合法时返回 `null`。
  static PbMessage? parse(Uint8List bytes) => _parse(bytes, 0);

  static PbMessage? _parse(Uint8List bytes, int depth) {
    if (depth > maxDepth) return null;

    final fields = <PbField>[];
    var pos = 0;

    while (pos < bytes.length) {
      final tag = _readVarint(bytes, pos);
      if (tag == null) return null;
      pos = tag.next;

      final number = tag.value >> 3;
      // 字段号 0 是非法值；不拒绝的话，一串 0 字节会被当成无数个字段 0。
      if (number <= 0) return null;

      final wireType = tag.value & 0x7;
      switch (wireType) {
        case _wireVarint:
          final value = _readVarint(bytes, pos);
          if (value == null) return null;
          fields.add(PbField(
            number: number,
            wireType: wireType,
            intValue: value.value,
          ));
          pos = value.next;

        case _wireFixed64:
          // 不取值，只跳过。8 字节放不下就是截断。
          if (pos + 8 > bytes.length) return null;
          pos += 8;

        case _wireLengthDelimited:
          final length = _readVarint(bytes, pos);
          if (length == null) return null;
          pos = length.next;
          final end = pos + length.value;
          // 长度超过剩余字节、或 varint 溢出成负数，都按截断处理。
          if (length.value < 0 || end > bytes.length) return null;
          fields.add(PbField(
            number: number,
            wireType: wireType,
            bytes: Uint8List.sublistView(bytes, pos, end),
          ));
          pos = end;

        case _wireFixed32:
          if (pos + 4 > bytes.length) return null;
          final value = ByteData.sublistView(bytes, pos, pos + 4)
              .getUint32(0, Endian.little);
          fields.add(PbField(
            number: number,
            wireType: wireType,
            fixed32: value,
          ));
          pos += 4;

        default:
          // wire type 3 / 4（group）已在 proto3 废弃；6 / 7 根本不存在。
          // 这里无法判断该跳多少字节，只能整条消息拒绝。
          return null;
      }
    }

    return PbMessage._(fields, depth);
  }

  /// 读取一个 varint；越界或超过 64 位时返回 `null`。
  ///
  /// 返回记录里带 `next`（读完后的位置），调用方不必再碰游标对象。
  static ({int value, int next})? _readVarint(Uint8List bytes, int pos) {
    var result = 0;
    var shift = 0;
    for (var i = 0; i < 10; i++) {
      if (pos >= bytes.length) return null;
      final byte = bytes[pos++];
      // uint64 最多 10 字节，第 10 字节只能是 0 或 1；再大就是溢出。
      if (i == 9 && (byte & 0x7f) > 1) return null;
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return (value: result, next: pos);
      shift += 7;
    }
    return null;
  }

  /// 全部字段，按出现顺序。
  List<PbField> get fields => List.unmodifiable(_fields);

  /// 是否存在该字段号的字段。
  bool has(int number) => _fields.any((f) => f.number == number);

  /// 取该字段号**最后一个** wire type 0 的值。
  ///
  /// protobuf 对非 repeated 标量允许重复出现，规范规定后者覆盖前者；
  /// 「取第一个」在拼接/合并过的消息上会读到过期值。
  int? getInt(int number) {
    for (var i = _fields.length - 1; i >= 0; i--) {
      final field = _fields[i];
      if (field.number == number && field.wireType == _wireVarint) {
        return field.intValue;
      }
    }
    return null;
  }

  /// 取该字段号最后一个 wire type 5 的值。
  int? getFixed32(int number) {
    for (var i = _fields.length - 1; i >= 0; i--) {
      final field = _fields[i];
      if (field.number == number && field.wireType == _wireFixed32) {
        return field.fixed32;
      }
    }
    return null;
  }

  /// 取该字段号最后一个 wire type 2 的原始字节。
  Uint8List? getBytes(int number) {
    for (var i = _fields.length - 1; i >= 0; i--) {
      final field = _fields[i];
      if (field.number == number && field.wireType == _wireLengthDelimited) {
        return field.bytes;
      }
    }
    return null;
  }

  /// 取该字段号最后一个字符串；UTF-8 非法时返回 `null`。
  ///
  /// 不返回替换字符（`U+FFFD`）是刻意的：那会把「这段字节不是 UTF-8」
  /// 显示成一个看起来正常的字符串，调用方再也分不清「标签就叫这个」与
  /// 「标签没读出来」。
  String? getString(int number) {
    final bytes = getBytes(number);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// 取该字段号最后一个子消息；子消息本身畸形时返回 `null`。
  PbMessage? getMessage(int number) {
    final bytes = getBytes(number);
    if (bytes == null) return null;
    return _parse(bytes, _depth + 1);
  }

  /// 取该字段号的全部子消息（repeated）。
  ///
  /// 单条畸形只跳过那一条：资源表里一条坏记录不应该让整张表作废 ——
  /// 其余条目仍然是可以如实展示的事实。
  List<PbMessage> getMessages(int number) {
    final result = <PbMessage>[];
    for (final field in _fields) {
      if (field.number != number || field.wireType != _wireLengthDelimited) {
        continue;
      }
      final parsed = _parse(field.bytes!, _depth + 1);
      if (parsed != null) result.add(parsed);
    }
    return result;
  }
}
