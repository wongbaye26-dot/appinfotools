import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

Uint8List _le(String text) => _utf16(text, bigEndian: false);

Uint8List _be(String text) => _utf16(text, bigEndian: true);

Uint8List _utf16(String text, {required bool bigEndian}) {
  final out = <int>[];
  for (final unit in text.codeUnits) {
    final low = unit & 0xff;
    final high = (unit >> 8) & 0xff;
    out.addAll(bigEndian ? [high, low] : [low, high]);
  }
  return Uint8List.fromList(out);
}

void main() {
  test('提取 UTF-16LE 的英文/中文串，忽略 UTF-8 垃圾', () {
    final bytes = Uint8List.fromList([
      ..._le('MetaMask'),
      0x00,
      0x00,
      ..._le('请把USDT转到这个地址'),
      0x00,
      0x00,
    ]);
    final strings = Utf16Strings.extract(bytes).toList();
    expect(strings, contains('MetaMask'));
    expect(strings, contains('请把USDT转到这个地址'));
  });

  test('少于 minLength 的串不输出', () {
    final bytes = _le('ab');
    expect(Utf16Strings.extract(bytes), isEmpty);
  });

  test('大端 UTF-16 也能取出中文串', () {
    final bytes = Uint8List.fromList([
      ..._be('客服解冻'),
      0x00,
      0x00,
    ]);
    expect(
      Utf16Strings.extract(bytes, bigEndian: true).toList(),
      contains('客服解冻'),
    );
    // 小端读同一段字节得不到原文 —— 端序不是可以猜的。
    expect(
      Utf16Strings.extract(bytes).toList(),
      isNot(contains('客服解冻')),
    );
  });

  test('奇对齐（前面多一个字节）靠 alignment 参数捞到', () {
    final padded = Uint8List.fromList([
      0x00,
      ..._le('收款地址'),
      0x00,
      0x00,
    ]);
    expect(Utf16Strings.extract(padded).toList(), isNot(contains('收款地址')));
    expect(
      Utf16Strings.extract(padded, alignment: 1).toList(),
      contains('收款地址'),
    );
  });

  test('extractAll 四种组合一次扫完并去重', () {
    final leEven = Uint8List.fromList([..._le('验证助记词'), 0, 0]);
    final leOdd = Uint8List.fromList([0, ..._le('资金归集'), 0, 0]);
    final beEven = Uint8List.fromList([..._be('解冻账户'), 0, 0]);
    final beOdd = Uint8List.fromList([0, ..._be('领取空投'), 0, 0]);

    final cases = <String, Uint8List>{
      '验证助记词': leEven,
      '资金归集': leOdd,
      '解冻账户': beEven,
      '领取空投': beOdd,
    };
    for (final entry in cases.entries) {
      final all = Utf16Strings.extractAll(entry.value).toList();
      expect(all, contains(entry.key), reason: '${entry.key} 应被四种组合之一捞到');
      expect(all.where((s) => s == entry.key).length, 1, reason: '同一条串不应重复产出');
    }
  });

  test('中文短语只有三个字时，调用方要能把 minLength 降到 3', () {
    final bytes = Uint8List.fromList([..._le('助记词'), 0, 0]);
    // 默认门槛 4 是给整文件降噪用的，但「助记词」这类三字话术会漏。
    expect(Utf16Strings.extract(bytes).toList(), isNot(contains('助记词')));
    expect(
      Utf16Strings.extractAll(bytes, minLength: 3).toList(),
      contains('助记词'),
    );
  });

  test('requireWide 只产出含 CJK 的串', () {
    final bytes = Uint8List.fromList([
      ..._le('MetaMask'),
      0,
      0,
      ..._le('资金冻结'),
      0,
      0,
    ]);
    final wide = Utf16Strings.extract(bytes, requireWide: true).toList();
    expect(wide, contains('资金冻结'));
    expect(wide, isNot(contains('MetaMask')));
  });
}
