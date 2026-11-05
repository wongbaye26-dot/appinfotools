import 'dart:convert';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/apks_toc.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _varint(int value) {
  final out = <int>[];
  while (value >= 0x80) {
    out.add((value & 0x7f) | 0x80);
    value >>= 7;
  }
  out.add(value);
  return out;
}

List<int> _entry(String path) {
  final bytes = utf8.encode(path);
  return [0x0a, ..._varint(bytes.length), ...bytes];
}

void main() {
  test('解析 TableOfContents 的 entry.path', () {
    final paths = ['base.apk', 'split_config.arm64_v8a.apk'];
    final bytes = <int>[];
    for (final p in paths) {
      final entry = _entry(p);
      bytes
        ..add(0x0a)
        ..addAll(_varint(entry.length))
        ..addAll(entry);
    }
    expect(parseApksToc(Uint8List.fromList(bytes)), paths);
  });

  test('未知字段/空输入不崩溃', () {
    expect(parseApksToc(Uint8List(0)), isEmpty);
    expect(parseApksToc(Uint8List.fromList([0xff, 0xff, 0xff])), isEmpty);
  });
}
