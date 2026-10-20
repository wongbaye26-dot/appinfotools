// `LC_ENCRYPTION_INFO(_64).cryptid` 的读取。
//
// 这个值决定报告能不能从「可能是砸壳」升级成「这个二进制已解密，签名失效是
// 必然」。判错的代价是**给用户一个错误的结论**，所以每一档都要有用例：
// 32/64 位、两种字节序、没有这条命令、非 Mach-O、截断、畸形 cmdsize。

import 'dart:typed_data';

import 'package:apk_info_tool/utils/macho_crypt_id.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个最小的 Mach-O：头部 + 至多一条 `LC_ENCRYPTION_INFO(_64)`。
///
/// [order] 是**文件本身的字节序**：写成 big 之后，读取方按 little-endian
/// 看到的就是 `0xCFFAEDFE`，从而走 big-endian 分支。
Uint8List _macho({
  bool is64 = true,
  int? cryptId,
  Endian order = Endian.little,
}) {
  final headerSize = is64 ? 32 : 28;
  final cmdSize = is64 ? 24 : 20;
  final hasCommand = cryptId != null;
  final bytes = Uint8List(headerSize + (hasCommand ? cmdSize : 0));
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, is64 ? 0xFEEDFACF : 0xFEEDFACE, order);
  data.setUint32(16, hasCommand ? 1 : 0, order); // ncmds
  data.setUint32(20, hasCommand ? cmdSize : 0, order); // sizeofcmds
  if (hasCommand) {
    data.setUint32(headerSize, is64 ? 0x2C : 0x21, order);
    data.setUint32(headerSize + 4, cmdSize, order);
    data.setUint32(headerSize + 16, cryptId, order);
  }
  return bytes;
}

void main() {
  test('64 位小端：cryptid 0 = 已解密', () {
    expect(readMachOCryptId(_macho(cryptId: 0)), 0);
  });

  test('64 位小端：cryptid 1 = 仍是加密态', () {
    expect(readMachOCryptId(_macho(cryptId: 1)), 1);
  });

  test('32 位小端也认（LC_ENCRYPTION_INFO）', () {
    expect(readMachOCryptId(_macho(is64: false, cryptId: 0)), 0);
  });

  test('大端字节序也认', () {
    expect(
      readMachOCryptId(_macho(cryptId: 0, order: Endian.big)),
      0,
    );
  });

  test('没有加密命令 → null（不是 0）', () {
    // 「读不出 cryptid」绝不能当成「已解密」—— 那会给用户一个假结论。
    expect(readMachOCryptId(_macho()), isNull);
  });

  test('非 Mach-O（全零）→ null', () {
    expect(readMachOCryptId(Uint8List(64)), isNull);
  });

  test('fat 二进制 → null（本函数只处理单个切片）', () {
    final bytes = Uint8List(64);
    ByteData.sublistView(bytes).setUint32(0, 0xCAFEBABE, Endian.big);
    expect(readMachOCryptId(bytes), isNull);
  });

  test('截断在头部中间 → null，不越界', () {
    final full = _macho(cryptId: 0);
    expect(readMachOCryptId(Uint8List.sublistView(full, 0, 20)), isNull);
  });

  test('截断在命令中间 → null，不越界', () {
    final full = _macho(cryptId: 0);
    // 头部完整、命令只给前 12 字节（cmdsize 声称 24）。
    expect(
      readMachOCryptId(Uint8List.sublistView(full, 0, 32 + 12)),
      isNull,
    );
  });

  test('cmdsize 为 0 的畸形命令 → null，不无限循环', () {
    final bytes = _macho(cryptId: 0);
    final data = ByteData.sublistView(bytes);
    data.setUint32(32 + 4, 0, Endian.little); // cmdsize = 0
    expect(readMachOCryptId(bytes), isNull);
  });

  test('ncmds 声称有命令但缓冲区没有 → null', () {
    final bytes = _macho();
    ByteData.sublistView(bytes).setUint32(16, 3, Endian.little);
    expect(readMachOCryptId(bytes), isNull);
  });
}
