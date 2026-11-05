import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

Uint8List _bytes(String text) =>
    Uint8List.fromList(const Utf8Encoder().convert(text));

Uint8List _cString(String text) => Uint8List.fromList([
      ...const Utf8Encoder().convert(text),
      0,
    ]);

void main() {
  test('能取出 UTF-8 中文串，纯 ASCII 串不重复产出', () {
    final bytes = Uint8List.fromList([
      ..._cString('请输入助记词'),
      ..._cString('MetaMask'),
    ]);
    final strings = Utf8Strings.extract(bytes).toList();
    expect(strings, contains('请输入助记词'));
    expect(strings, isNot(contains('MetaMask')));
  });

  test('中英混排是同一条串，中文不会被 ASCII 扫描切断', () {
    final strings =
        Utf8Strings.extract(_cString('请输入助记词 to continue')).toList();
    expect(strings, contains('请输入助记词 to continue'));
  });

  test('坏的 UTF-8 序列断开当前串，但后面那条仍能捞到', () {
    final bytes = Uint8List.fromList([
      ..._bytes('前缀乱码'),
      0xFF, // 非法前导
      0xC0, 0x80, // 超长编码
      0xED, 0xA0, 0x80, // 代理区
      0x00,
      ..._cString('资金归集'),
    ]);
    final strings = Utf8Strings.extract(bytes).toList();
    expect(strings, contains('资金归集'));
    expect(strings.any((s) => s.contains('乱码') && s.contains('资金')), isFalse,
        reason: '坏字节两侧的串不能被粘成一条');
  });

  test('少于 minLength 的串不产出', () {
    expect(Utf8Strings.extract(_cString('私')).toList(), isEmpty);
    expect(
      Utf8Strings.extract(_cString('私钥'), minLength: 2).toList(),
      contains('私钥'),
    );
  });

  test('超长串只留头尾，带省略号', () {
    final strings = Utf8Strings.extract(
      _cString('助记词' * 100),
      maxKeep: 20,
    ).toList();
    expect(strings, hasLength(1));
    expect(strings.single, contains('…'));
    expect(strings.single.length, lessThanOrEqualTo(21));
  });

  test('limit 之外的字节不读', () {
    final bytes = Uint8List.fromList([
      ..._cString('占位'),
      ..._cString('解冻账户'),
    ]);
    final prefix = bytes.length - _cString('解冻账户').length;
    expect(Utf8Strings.extract(bytes, limit: prefix).toList(),
        isNot(contains('解冻账户')));
    expect(Utf8Strings.extract(bytes).toList(), contains('解冻账户'));
  });

  test('minCjkChars 把「ASCII + 一个拉丁字母」这类噪声挡掉', () {
    final bytes = Uint8List.fromList([
      ..._bytes('Aé'),
      0x00,
      ..._cString('资金冻结'),
    ]);
    expect(Utf8Strings.extract(bytes).toList(), contains('Aé'));
    final filtered = Utf8Strings.extract(bytes, minCjkChars: 2).toList();
    expect(filtered, isNot(contains('Aé')));
    expect(filtered, contains('资金冻结'));
  });

  test('UTF-16LE 的中文不会被误当成 UTF-8 中文产出', () {
    // '助记词' 的 UTF-16LE 字节里没有合法的 UTF-8 中文序列；这里只钉住
    // 「不会凭空造出原文」这一条，避免两种提取器互相污染。
    final le = Uint8List.fromList([
      for (final unit in '助记词'.codeUnits) ...[unit & 0xff, (unit >> 8) & 0xff],
      0,
      0,
    ]);
    expect(Utf8Strings.extract(le).toList(), isNot(contains('助记词')));
  });
}
