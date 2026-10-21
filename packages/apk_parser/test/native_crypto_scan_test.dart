// 原生库字符串里的「盗 U」信号。
//
// 这条路存在的理由：钱包的密码学实现常被静态链接进 `.so` 且不导出符号，
// 符号表看不到（release 还会 strip），但 `.rodata` 里的字符串还在。

import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

/// 造一段「像原生库」的字节：只有 ASCII 字符串，NUL 分隔。
Uint8List _blob(List<String> strings) {
  final bytes = <int>[];
  for (final s in strings) {
    bytes.addAll(s.codeUnits);
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

NativeCryptoScanResult _scan(List<String> strings, {String name = 'libx.so'}) =>
    NativeCryptoScan.scan([NativeLibraryBytes(name, _blob(strings))]);

void main() {
  test('捡到密码学常量名（secp256k1 / bip39）', () {
    final result = _scan([
      'secp256k1_ecdsa_sign_recoverable',
      'bip39_mnemonic_to_seed',
    ]);
    expect(result.markerIds, contains('wallet-secp256k1'));
    expect(result.markerIds, contains('wallet-bip39'));
    expect(result.sources['wallet-secp256k1'], contains('libx.so'));
  });

  test('捡到剪贴板与地址', () {
    final result = _scan([
      'getPrimaryClip',
      '0x52908400098527886E0F7030069857D2E4169EE7',
    ]);
    expect(result.markerIds, contains('clipboard-read'));
    expect(result.addresses, hasLength(1));
    expect(
      result.addressSources.values.first,
      contains('libx.so'),
      reason: '地址要能追溯到具体库',
    );
  });

  test('公开合约地址不算收款地址', () {
    final result = _scan(['TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t']);
    expect(result.addresses, isEmpty);
  });

  test('普通字符串不命中', () {
    final result = _scan(['libc.so', 'pthread_create', 'SSL_CTX_new']);
    expect(result.isEmpty, isTrue);
  });

  test('没有库时是空的，不编造结论', () {
    final result = NativeCryptoScan.scan(const []);
    expect(result.isEmpty, isTrue);
    expect(result.hasNoInput, isTrue);
  });

  test('超过单库预算时只扫前一段，并把库记进 skipped', () {
    // 标记放在 8 MiB 之后 —— 不该被扫到，但要如实报告「这个库只扫了一部分」。
    final filler = Uint8List(NativeCryptoScan.maxBytesPerLibrary + 1024)
      ..fillRange(0, NativeCryptoScan.maxBytesPerLibrary + 1024, 0x41);
    final tail = _blob(['secp256k1']);
    final bytes = Uint8List(filler.length + tail.length)
      ..setAll(0, filler)
      ..setAll(filler.length, tail);

    final result = NativeCryptoScan.scan(
      [NativeLibraryBytes('libbig.so', bytes)],
    );
    expect(result.markerIds, isEmpty, reason: '标记在预算之外，扫不到是预期的');
    expect(result.skippedLibraries, contains('libbig.so'));
    expect(result.scannedBytes, NativeCryptoScan.maxBytesPerLibrary);
  });

  test('多个库时按库分别记录来源', () {
    final result = NativeCryptoScan.scan([
      NativeLibraryBytes('liba.so', _blob(['secp256k1'])),
      // 注意长度：`AsciiStrings` 只保留 ≥ 6 字符的串，`bip39` 单独出现会被丢掉。
      NativeLibraryBytes('libb.so', _blob(['bip39_mnemonic_to_seed'])),
    ]);
    expect(result.sources['wallet-secp256k1'], {'liba.so'});
    expect(result.sources['wallet-bip39'], {'libb.so'});
  });
}
