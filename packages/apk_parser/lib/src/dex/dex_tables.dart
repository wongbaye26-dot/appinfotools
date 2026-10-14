import 'dart:convert';
import 'dart:typed_data';

import 'dex_structure.dart';

/// DEX 段读取的边界安全包装与字符串/类型缓存。
///
/// 抽成独立文件是因为**三个扫描器都要用**：`method_ids` 遍历、`code_item`
/// 指令遍历、以及上层的标记匹配。各自实现一份必然漂移，而漂移的后果是
/// 「同一个字符串在两边解出不同的值」。
///
/// 不是公开 API（`apk_parser.dart` 不导出本文件）。
class DexTables {
  final Uint8List bytes;
  final DexStructure structure;
  final ByteData _data;

  late final List<String?> _stringCache;
  late final List<String?> _typeCache;
  final Map<int, String?> _protoCache = {};

  DexTables(this.bytes, this.structure) : _data = ByteData.sublistView(bytes) {
    final stringIds = structure.section('string_ids');
    final typeIds = structure.section('type_ids');
    _stringCache = List<String?>.filled(stringIds?.size ?? 0, null);
    _typeCache = List<String?>.filled(typeIds?.size ?? 0, null);
  }

  /// 读 u16；越界返回 0（由调用方的索引校验兜住，不会因此产出错误引用）。
  int uint16(int offset) {
    if (offset < 0 || offset + 2 > bytes.length) return 0;
    return _data.getUint16(offset, Endian.little);
  }

  /// 读 u32；越界返回 0。
  int uint32(int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return _data.getUint32(offset, Endian.little);
  }

  /// 读一个 ULEB128，返回 `(值, 下一个偏移)`。
  ///
  /// 超过 5 字节视为畸形：DEX 规范里 uleb128 最多 5 字节（32 位）。
  /// 不设这个上限，一段全 `0xFF` 的字节会让循环一直读下去。
  (int, int)? uleb128(int offset) {
    var result = 0;
    var shift = 0;
    var i = offset;
    while (i < bytes.length) {
      final byte = bytes[i++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return (result, i);
      shift += 7;
      if (shift > 28) return null;
    }
    return null;
  }

  /// `string_ids[index]` 指向的字符串。
  String? string(int index) {
    if (index < 0 || index >= _stringCache.length) return null;
    final cached = _stringCache[index];
    if (cached != null) return cached;
    final section = structure.section('string_ids')!;
    final dataOff = uint32(section.offset + index * section.itemSize);
    final value = _stringAt(dataOff);
    // 只有解析成功才写缓存 —— 缓存 null 会让「暂时读不出来」变成永久。
    if (value != null) _stringCache[index] = value;
    return value;
  }

  /// `type_ids[index]` 对应的类型描述符。
  String? typeDescriptor(int index) {
    if (index < 0 || index >= _typeCache.length) return null;
    final cached = _typeCache[index];
    if (cached != null) return cached;
    final section = structure.section('type_ids')!;
    final descriptorIdx = uint32(section.offset + index * section.itemSize);
    final value = string(descriptorIdx);
    if (value != null) _typeCache[index] = value;
    return value;
  }

  /// `proto_ids[index]` 对应的原型描述符，例如 `(Ljava/lang/String;I)V`。
  String? protoDescriptor(int index) {
    if (_protoCache.containsKey(index)) return _protoCache[index];
    final value = _buildProtoDescriptor(index);
    _protoCache[index] = value;
    return value;
  }

  /// `method_ids[index]` 对应的 `(类描述符, 方法名, 原型描述符)`。
  ///
  /// 类描述符或方法名取不出来时返回 `null` —— 不猜。
  (String, String, String?)? methodReference(int index) {
    final section = structure.section('method_ids');
    if (section == null) return null;
    if (index < 0 || index >= section.size) return null;

    final base = section.offset + index * section.itemSize;
    // method_id_item: class_idx(u16) + proto_idx(u16) + name_idx(u32)
    final classDescriptor = typeDescriptor(uint16(base));
    final name = string(uint32(base + 4));
    if (classDescriptor == null || name == null) return null;
    return (classDescriptor, name, protoDescriptor(uint16(base + 2)));
  }

  String? _buildProtoDescriptor(int index) {
    final section = structure.section('proto_ids');
    if (section == null) return null;
    if (index < 0 || index >= section.size) return null;

    final base = section.offset + index * section.itemSize;
    // proto_id_item: shorty_idx(u32) + return_type_idx(u32) + parameters_off(u32)
    final returnTypeIdx = uint32(base + 4);
    final parametersOff = uint32(base + 8);

    final returnType = typeDescriptor(returnTypeIdx);
    if (returnType == null) return null;

    final parameters = <String>[];
    if (parametersOff != 0) {
      // type_list: size(u32) + size × type_idx(u16)
      final count = uint32(parametersOff);
      // 先验边界：size 是文件里声明的任意值，乘 2 之前必须确认读得到。
      if (parametersOff + 4 + count * 2 > bytes.length) return null;
      for (var i = 0; i < count; i++) {
        final typeIdx = uint16(parametersOff + 4 + i * 2);
        final parameter = typeDescriptor(typeIdx);
        if (parameter == null) return null;
        parameters.add(parameter);
      }
    }
    return '(${parameters.join()})$returnType';
  }

  /// 读 `string_data_item`：uleb128 的 utf16 长度 + MUTF-8 字节 + NUL。
  String? _stringAt(int offset) {
    if (offset <= 0 || offset >= bytes.length) return null;
    final read = uleb128(offset);
    if (read == null) return null;
    final start = read.$2;
    var end = start;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    // 没有终止符说明这个字符串跨到了文件之外 —— 不猜，如实返回 null。
    if (end >= bytes.length) return null;
    return _decodeModifiedUtf8(start, end);
  }

  /// 解码 MUTF-8。
  ///
  /// DEX 用的是「修改过的 UTF-8」：`U+0000` 编成 `0xC0 0x80`，而终止符是
  /// 裸的 `0x00`。因此按 `0x00` 截断是安全的（串内不会出现裸 0）。
  ///
  /// 用 `allowMalformed` 而不是严格解码：描述符与方法名基本是 ASCII，
  /// 真出现畸形字节时，**留着能读的部分**比整条丢掉有用。
  String _decodeModifiedUtf8(int start, int end) {
    final view = Uint8List.sublistView(bytes, start, end);
    return utf8.decode(view, allowMalformed: true);
  }
}
