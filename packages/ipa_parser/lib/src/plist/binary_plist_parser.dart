import 'dart:convert';
import 'dart:typed_data';

import 'plist_value.dart';
import 'xml_plist_parser.dart' show PlistParseException;

/// 二进制 plist（`bplist00`）解析器。
///
/// 该格式没有公开规范，实现依据 Apple CFBinaryPlist 的实际布局：
///
/// ```
/// "bplist00"        8 字节魔数
/// <objects>         变长，每个对象以 1 字节 marker 开头
/// <offset table>    numObjects 项，每项 offsetIntSize 字节（大端）
/// <trailer>         末尾 32 字节
/// ```
///
/// trailer（32 字节）：
///
/// | 偏移 | 含义 |
/// |---|---|
/// | 0..5 | 未使用 |
/// | 6 | offsetIntSize |
/// | 7 | objectRefSize |
/// | 8..15 | numObjects（大端 u64） |
/// | 16..23 | topObject（大端 u64） |
/// | 24..31 | offsetTableOffset（大端 u64） |
///
/// 对象 marker 的高 4 位是类型，低 4 位是长度/尺寸；低 4 位为 `0xF` 时，
/// 真实长度由紧随其后的一个整数对象给出。
///
/// **所有长度与偏移都来自文件自身，因此一律先做边界检查再使用。** 恶意或
/// 损坏的 plist 可以声明任意 numObjects、偏移与长度；直接信任会导致越界读取
/// 或内存耗尽。
class BinaryPlistParser {
  /// `bplist00`
  static const List<int> _magic = [
    0x62,
    0x70,
    0x6C,
    0x69,
    0x73,
    0x74,
    0x30,
    0x30
  ];

  static const int _trailerSize = 32;

  /// Apple 纪元：2001-01-01T00:00:00Z。
  static final DateTime _appleEpoch = DateTime.utc(2001, 1, 1);

  /// 递归深度上限。
  ///
  /// 二进制 plist 的对象引用可以构成**环**，也可以构造极深的嵌套 —— 两者都会
  /// 让朴素递归爆栈。这里显式设上限，而不是让进程崩掉。
  static const int _maxDepth = 128;

  /// 会被"扩展长度"规则影响的类型：低 4 位表示元素个数。
  static const Set<int> _countedTypes = {0x04, 0x05, 0x06, 0x0A, 0x0C, 0x0D};

  final Uint8List _data;
  final int _objectRefSize;
  final int _numObjects;
  final List<int> _offsets;

  BinaryPlistParser._(
      this._data, this._objectRefSize, this._numObjects, this._offsets);

  static PlistValue parse(Uint8List data) {
    if (data.length < _magic.length + _trailerSize) {
      throw const PlistParseException('binary plist is too short');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (data[i] != _magic[i]) {
        throw const PlistParseException('missing bplist00 magic');
      }
    }

    final trailerStart = data.length - _trailerSize;
    final offsetIntSize = data[trailerStart + 6];
    final objectRefSize = data[trailerStart + 7];

    if (offsetIntSize < 1 || offsetIntSize > 8) {
      throw PlistParseException('invalid offsetIntSize: $offsetIntSize');
    }
    if (objectRefSize < 1 || objectRefSize > 8) {
      throw PlistParseException('invalid objectRefSize: $objectRefSize');
    }

    final numObjects = _readU64(data, trailerStart + 8);
    final topObject = _readU64(data, trailerStart + 16);
    final offsetTableOffset = _readU64(data, trailerStart + 24);

    // 每个对象至少占 1 字节，所以对象数不可能超过数据长度。
    if (numObjects < 0 || numObjects > data.length) {
      throw PlistParseException('implausible numObjects: $numObjects');
    }
    if (numObjects == 0) {
      throw const PlistParseException('plist declares zero objects');
    }
    if (offsetTableOffset < _magic.length ||
        offsetTableOffset + numObjects * offsetIntSize > trailerStart) {
      throw const PlistParseException('offset table out of bounds');
    }
    if (topObject < 0 || topObject >= numObjects) {
      throw PlistParseException('topObject out of range: $topObject');
    }

    final offsets = List<int>.filled(numObjects, 0);
    for (var i = 0; i < numObjects; i++) {
      final offset = _readUintFrom(
          data, offsetTableOffset + i * offsetIntSize, offsetIntSize);
      if (offset < _magic.length || offset >= offsetTableOffset) {
        throw PlistParseException('object $i offset out of bounds: $offset');
      }
      offsets[i] = offset;
    }

    return BinaryPlistParser._(data, objectRefSize, numObjects, offsets)
        ._parseObject(topObject, 0, <int>{});
  }

  PlistValue _parseObject(int index, int depth, Set<int> visiting) {
    if (depth > _maxDepth) {
      throw PlistParseException('plist nesting exceeds $_maxDepth levels');
    }
    if (index < 0 || index >= _numObjects) {
      throw PlistParseException('object reference out of range: $index');
    }
    if (!visiting.add(index)) {
      throw PlistParseException('cyclic object reference at object $index');
    }

    try {
      final marker = _data[_offsets[index]];
      final type = marker >> 4;
      final sizeInfo = marker & 0x0F;
      var cursor = _offsets[index] + 1;

      // 简单类型：marker 之后没有数据。
      switch (type) {
        case 0x00:
          switch (sizeInfo) {
            case 0x00:
              throw const PlistParseException(
                  'null plist value is unsupported');
            case 0x08:
              return const PlistBoolean(false);
            case 0x09:
              return const PlistBoolean(true);
            case 0x0F:
              throw const PlistParseException('fill byte is not a value');
            default:
              throw PlistParseException('unknown simple type: 0x$sizeInfo');
          }
        case 0x01:
          return PlistInteger(_readInteger(cursor, 1 << sizeInfo));
        case 0x02:
          final byteCount = 1 << sizeInfo;
          if (byteCount != 4 && byteCount != 8) {
            throw PlistParseException(
                'unsupported real size: $byteCount bytes');
          }
          return PlistReal(_readReal(cursor, byteCount));
        case 0x03:
          // date 固定 8 字节 float64（Apple 纪元起的秒数），不走扩展长度。
          return PlistDate(_appleEpoch.add(Duration(
              microseconds: (_readReal(cursor, 8) * 1000000).round())));
      }

      // 其余类型的低 4 位是元素个数，可能是扩展形式。
      var count = sizeInfo;
      if (sizeInfo == 0x0F && _countedTypes.contains(type)) {
        final intMarker = _readUint(cursor, 1);
        final intSize = 1 << (intMarker & 0x0F);
        count = _readUint(cursor + 1, intSize);
        cursor += 1 + intSize;
      }
      if (count < 0 || count > _data.length) {
        throw PlistParseException('implausible element count: $count');
      }

      switch (type) {
        case 0x04:
          return PlistData(_slice(cursor, count));
        case 0x05:
          return PlistString(latin1.decode(_slice(cursor, count)));
        case 0x06:
          return PlistString(_decodeUtf16Be(_slice(cursor, count * 2)));
        case 0x08:
          // UID：低 4 位是字节数 - 1。Info.plist 不用，但 keyed archive 会用。
          return PlistInteger(_readUint(cursor, sizeInfo + 1));
        case 0x0A:
        case 0x0C:
          return PlistArray([
            for (var i = 0; i < count; i++)
              _parseObject(
                _readUint(cursor + i * _objectRefSize, _objectRefSize),
                depth + 1,
                visiting,
              ),
          ]);
        case 0x0D:
          final result = <String, PlistValue>{};
          for (var i = 0; i < count; i++) {
            final keyIndex =
                _readUint(cursor + i * _objectRefSize, _objectRefSize);
            final valueIndex = _readUint(
                cursor + (count + i) * _objectRefSize, _objectRefSize);
            final key = _parseObject(keyIndex, depth + 1, visiting);
            if (key is! PlistString) {
              throw PlistParseException(
                  'dict key $i is ${key.typeName}, expected string');
            }
            result[key.value] = _parseObject(valueIndex, depth + 1, visiting);
          }
          return PlistDict(result);
        default:
          throw PlistParseException(
              'unsupported object type: 0x${type.toRadixString(16)}');
      }
    } finally {
      visiting.remove(index);
    }
  }

  /// 读整数。1/2/4 字节按无符号处理，8 字节按有符号 —— plist 里 8 字节整数
  /// 常见于负值（例如某些时间戳偏移）。
  int _readInteger(int offset, int byteCount) {
    if (byteCount > 8) {
      throw PlistParseException('unsupported integer width: $byteCount bytes');
    }
    final raw = _readUint(offset, byteCount);
    if (byteCount == 8) {
      return raw.toSigned(64);
    }
    return raw;
  }

  double _readReal(int offset, int byteCount) {
    _ensureRange(offset, byteCount);
    final view = ByteData.sublistView(_data, offset, offset + byteCount);
    return byteCount == 4
        ? view.getFloat32(0, Endian.big)
        : view.getFloat64(0, Endian.big);
  }

  Uint8List _slice(int offset, int length) {
    _ensureRange(offset, length);
    return Uint8List.sublistView(_data, offset, offset + length);
  }

  void _ensureRange(int offset, int length) {
    if (length < 0 || offset < 0 || offset + length > _data.length) {
      throw PlistParseException(
          'read of $length bytes at $offset is out of bounds');
    }
  }

  /// 从本 plist 的数据中读取大端无符号整数。
  int _readUint(int offset, int size) => _readUintFrom(_data, offset, size);

  static int _readU64(Uint8List data, int offset) =>
      _readUintFrom(data, offset, 8);

  static int _readUintFrom(Uint8List data, int offset, int size) {
    if (size < 1 || size > 8) {
      throw PlistParseException('invalid integer width: $size');
    }
    if (offset < 0 || offset + size > data.length) {
      throw PlistParseException(
          'read of $size bytes at $offset is out of bounds');
    }
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | data[offset + i];
    }
    return value;
  }

  /// UTF-16BE（大端，无 BOM）。
  static String _decodeUtf16Be(Uint8List bytes) {
    if (bytes.length.isOdd) {
      throw const PlistParseException('UTF-16 string has an odd byte length');
    }
    final units = Uint16List(bytes.length ~/ 2);
    for (var i = 0; i < units.length; i++) {
      units[i] = (bytes[i * 2] << 8) | bytes[i * 2 + 1];
    }
    return String.fromCharCodes(units);
  }
}
