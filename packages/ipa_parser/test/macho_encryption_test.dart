// FairPlay 加密命令（LC_ENCRYPTION_INFO / _64）的解析测试。
//
// 这里用**手工拼的最小 Mach-O**，不依赖真实样本：加密样本在 CI 上没有，
// 而解析层的正确性（偏移、cryptid、缺失命令的 null 语义）可以完全合成。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const _mhMagic64 = 0xFEEDFACF;
const _mhExecute = 0x2;
const _lcEncryptionInfo = 0x21;
const _lcEncryptionInfo64 = 0x2C;

void _u32(ByteData data, int offset, int value) {
  data.setUint32(offset, value, Endian.little);
}

Uint8List _macho({
  int command = _lcEncryptionInfo64,
  int cryptOff = 0x4000,
  int cryptSize = 0x8000,
  int cryptId = 1,
  int commandSize = 20,
}) {
  final buffer = Uint8List(32 + 20);
  final data = ByteData.sublistView(buffer);
  _u32(data, 0, _mhMagic64);
  _u32(data, 4, 0x0100000C); // arm64
  _u32(data, 8, 0); // cpusubtype
  _u32(data, 12, _mhExecute);
  _u32(data, 16, 1); // ncmds
  _u32(data, 20, 20); // sizeofcmds
  _u32(data, 24, 0); // flags
  _u32(data, 28, 0); // reserved
  _u32(data, 32, command);
  _u32(data, 36, commandSize);
  _u32(data, 40, cryptOff);
  _u32(data, 44, cryptSize);
  _u32(data, 48, cryptId);
  return buffer;
}

void main() {
  test('解析 LC_ENCRYPTION_INFO_64：保留 cryptid 与加密范围', () {
    final file = MachOParser.parse(_macho());
    expect(file.images, hasLength(1));
    final encryption = file.primary!.encryption;
    expect(encryption, isNotNull);
    expect(encryption!.cryptId, 1);
    expect(encryption.isEncrypted, isTrue);
    expect(encryption.isDecrypted, isFalse);
    expect(encryption.cryptOffset, 0x4000);
    expect(encryption.cryptSize, 0x8000);
    expect(encryption.is64Bit, isTrue);
    expect(file.primary!.isEncrypted, isTrue);
    expect(
        file.diagnostics.where((d) => d.severity == DiagnosticSeverity.error),
        isEmpty);
  });

  test('解析 LC_ENCRYPTION_INFO（32 位命令号）', () {
    final file = MachOParser.parse(_macho(command: _lcEncryptionInfo));
    final encryption = file.primary!.encryption!;
    expect(encryption.cryptId, 1);
    expect(encryption.is64Bit, isFalse);
  });

  test('cryptid=0 表示已解密，不是“未知”', () {
    final file = MachOParser.parse(_macho(cryptId: 0));
    final encryption = file.primary!.encryption;
    expect(encryption, isNotNull);
    expect(encryption!.isEncrypted, isFalse);
    expect(encryption.isDecrypted, isTrue);
    expect(file.primary!.isEncrypted, isFalse);
  });

  test('没有加密命令时是 null，不是 false', () {
    // 只保留 32 字节头、ncmds=0；动态库常见形态。
    final buffer = Uint8List(32);
    final data = ByteData.sublistView(buffer);
    _u32(data, 0, _mhMagic64);
    _u32(data, 4, 0x0100000C);
    _u32(data, 12, 0x6); // MH_DYLIB
    _u32(data, 16, 0); // ncmds
    _u32(data, 20, 0); // sizeofcmds

    final file = MachOParser.parse(buffer);
    expect(file.images, hasLength(1));
    expect(file.primary!.encryption, isNull);
    expect(file.primary!.isEncrypted, isFalse,
        reason: 'isEncrypted 只是便捷判断；null 才是“没有加密信息”');
  });

  test('命令长度不足 20 时不读取，保持 null', () {
    final file = MachOParser.parse(_macho(commandSize: 16));
    expect(file.primary!.encryption, isNull);
  });
}
