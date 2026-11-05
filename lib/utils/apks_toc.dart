import 'dart:convert';
import 'dart:typed_data';

/// 解析 APKS 里的 `toc.pb`（bundletool `TableOfContents`）。
///
/// APKS 的 `toc.pb` 是 protobuf：
///
/// ```proto
/// message TableOfContents { repeated SplitApkEntry entry = 1; }
/// message SplitApkEntry { string path = 1; }
/// ```
///
/// 这里只做**最小 wire-format 解码**，不引入 protobuf 依赖：只需要
/// `entry.path`，其余字段跳过即可。
///
/// 返回空列表表示没有可识别条目；调用方应退回 manifest / 目录枚举，
/// 不能把「解析不出来」当成「没有分包」。
List<String> parseApksToc(Uint8List bytes) {
  final paths = <String>[];
  for (final entry in _iterMessages(bytes, fieldNumber: 1)) {
    final path = _firstStringField(entry, fieldNumber: 1);
    if (path != null &&
        path.isNotEmpty &&
        path.toLowerCase().endsWith('.apk')) {
      if (!paths.contains(path)) paths.add(path);
    }
  }
  return paths;
}

Iterable<Uint8List> _iterMessages(
  Uint8List bytes, {
  required int fieldNumber,
}) sync* {
  var i = 0;
  while (i < bytes.length) {
    final key = _readVarint(bytes, i);
    if (key == null) return;
    i = key.next;
    final field = key.value >> 3;
    final wire = key.value & 7;
    if (wire == 2) {
      final len = _readVarint(bytes, i);
      if (len == null) return;
      i = len.next;
      final end = i + len.value;
      if (end < i || end > bytes.length) return;
      if (field == fieldNumber) yield Uint8List.sublistView(bytes, i, end);
      i = end;
    } else if (wire == 0) {
      final v = _readVarint(bytes, i);
      if (v == null) return;
      i = v.next;
    } else if (wire == 1) {
      i += 8;
    } else if (wire == 5) {
      i += 4;
    } else {
      return;
    }
  }
}

String? _firstStringField(Uint8List bytes, {required int fieldNumber}) {
  var i = 0;
  while (i < bytes.length) {
    final key = _readVarint(bytes, i);
    if (key == null) return null;
    i = key.next;
    final field = key.value >> 3;
    final wire = key.value & 7;
    if (wire == 2) {
      final len = _readVarint(bytes, i);
      if (len == null) return null;
      i = len.next;
      final end = i + len.value;
      if (end < i || end > bytes.length) return null;
      if (field == fieldNumber) {
        return utf8.decode(
          Uint8List.sublistView(bytes, i, end),
          allowMalformed: true,
        );
      }
      i = end;
    } else if (wire == 0) {
      final v = _readVarint(bytes, i);
      if (v == null) return null;
      i = v.next;
    } else if (wire == 1) {
      i += 8;
    } else if (wire == 5) {
      i += 4;
    } else {
      return null;
    }
  }
  return null;
}

({int value, int next})? _readVarint(Uint8List bytes, int offset) {
  var result = 0;
  var shift = 0;
  var i = offset;
  while (i < bytes.length && shift < 64) {
    final byte = bytes[i++];
    result |= (byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) return (value: result, next: i);
    shift += 7;
  }
  return null;
}
