// Mach-O 解析测试（规范 5.4）。
//
// 正常样本是 clang 编出来的**真实** Mach-O（见 test/fixtures/macho/README.md），
// 期望值取自 `otool -hv` / `otool -l` —— 独立于本项目的参照物。
//
// 畸形样本只能手工构造，而它们断言的是「解析器必须拒绝并且不死循环」，
// 构造器与被测逻辑不共享假设。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

Uint8List _fixture(String name) {
  final file = File('test/fixtures/macho/$name');
  expect(file.existsSync(), isTrue,
      reason: '缺少测试样本 $name —— 见 test/fixtures/macho/README.md');
  return file.readAsBytesSync();
}

List<int> _le32(int value) => [
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF
    ];

List<int> _be32(int value) => [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF
    ];

/// 构造一个最小的 64 位小端 Mach-O（`MH_MAGIC_64`）。
Uint8List _thinHeader({
  int cpuType = 0x0100000C, // arm64
  int fileType = 0x6, // DYLIB
  int ncmds = 0,
  int sizeofcmds = 0,
  List<int> loadCommands = const [],
}) =>
    Uint8List.fromList([
      0xCF, 0xFA, 0xED, 0xFE, // MH_MAGIC_64（小端存储）
      ..._le32(cpuType),
      ..._le32(0), // cpusubtype
      ..._le32(fileType),
      ..._le32(ncmds),
      ..._le32(sizeofcmds),
      ..._le32(0), // flags
      ..._le32(0), // reserved
      ...loadCommands,
    ]);

/// 一条 `LC_UUID`。
List<int> _lcUuid(List<int> uuid16) => [
      0x1B, 0, 0, 0, // cmd
      ..._le32(24), // cmdsize
      ...uuid16,
    ];

bool _hasDiagnostic(MachOFile file, String code) =>
    file.diagnostics.any((d) => d.code == code);

void main() {
  group('MachOParser — thin arm64（clang 真实产物）', () {
    late MachOFile parsed;

    setUpAll(() => parsed = MachOParser.parse(_fixture('thin-arm64.dylib')));

    test('识别为 thin，且解析出一个镜像', () {
      expect(parsed.container, MachOContainer.thin);
      expect(parsed.isFat, isFalse);
      expect(parsed.isMachO, isTrue);
      expect(parsed.images, hasLength(1));
    });

    test('头部字段与 otool -hv 一致', () {
      final image = parsed.primary!;

      expect(image.is64Bit, isTrue);
      expect(image.cpuTypeName, 'arm64');
      expect(image.architectureName, 'arm64 (64-bit)');
      expect(image.fileType, MachOFileType.dylib);
      expect(image.loadCommandCount, 14);
      expect(image.loadCommandsSize, 656);
      expect(image.byteOrder, MachOByteOrder.little);
    });

    test('段信息与 otool -l 一致', () {
      final segments = parsed.primary!.segments;
      final byName = {for (final s in segments) s.name: s};

      expect(byName.keys, containsAll(['__TEXT', '__LINKEDIT']));
      expect(byName['__TEXT']!.fileOffset, 0);
      expect(byName['__TEXT']!.fileSize, 16384);
      expect(byName['__TEXT']!.vmSize, 0x4000);
      expect(byName['__TEXT']!.sectionCount, 2);
      expect(byName['__LINKEDIT']!.fileOffset, 16384);
      expect(byName['__LINKEDIT']!.fileSize, 416);
      expect(byName['__LINKEDIT']!.sectionCount, 0);
    });

    test('UUID / 安装名 / 动态库 / 版本与 otool -l 一致', () {
      final image = parsed.primary!;

      expect(image.uuid, '6D25269B-7E69-3D92-9EDA-A5C0DE4FECE6');
      expect(image.installName, 'libthin.dylib');
      expect(image.linkedLibraries, ['/usr/lib/libSystem.B.dylib']);
      expect(image.platform, 1);
      expect(image.platformName, 'macOS');
      expect(image.minimumOsVersionText, '27.0');
      expect(image.sdkVersionText, '27.0');
    });

    test('保留了一条 info 级诊断', () {
      expect(_hasDiagnostic(parsed, 'ios.macho.parsed'), isTrue);
    });
  });

  group('MachOParser — fat（clang 真实产物）', () {
    late MachOFile parsed;

    setUpAll(
        () => parsed = MachOParser.parse(_fixture('fat-x86_64-arm64.dylib')));

    test('识别为 fat，两个架构', () {
      expect(parsed.isFat, isTrue);
      expect(parsed.containerByteOrder, MachOByteOrder.big);
      expect(parsed.images, hasLength(2));
      expect(parsed.architectureNames, ['x86_64 (64-bit)', 'arm64 (64-bit)']);
    });

    test('切片偏移与大小与 otool -f 一致', () {
      final x86 = parsed.images[0];
      final arm = parsed.images[1];

      expect(x86.offset, 4096);
      expect(x86.size, 4216);
      expect(x86.loadCommandCount, 13);
      expect(x86.loadCommandsSize, 640);

      expect(arm.offset, 16384);
      expect(arm.size, 16800);
      expect(arm.loadCommandCount, 14);
      expect(arm.loadCommandsSize, 656);
    });

    test('每个切片独立解析出自己的头部（不沿用 fat 表的字节序）', () {
      for (final image in parsed.images) {
        expect(image.is64Bit, isTrue);
        expect(image.fileType, MachOFileType.dylib);
        expect(image.byteOrder, MachOByteOrder.little);
      }
    });

    test('allLinkedLibraries 汇总去重', () {
      expect(parsed.allLinkedLibraries, ['/usr/lib/libSystem.B.dylib']);
    });
  });

  group('MachOParser — 边界检查（规范 5.4 硬约束）', () {
    test('文件太短', () {
      final result = MachOParser.parse(Uint8List(2));

      expect(result.isMachO, isFalse);
      expect(_hasDiagnostic(result, 'ios.macho.unrecognised'), isTrue);
    });

    test('魔数不认识时返回诊断而不是抛异常', () {
      final result = MachOParser.parse(
          Uint8List.fromList('not a mach-o at all'.codeUnits));

      expect(result.isMachO, isFalse);
      expect(result.images, isEmpty);
      expect(_hasDiagnostic(result, 'ios.macho.unrecognised'), isTrue);
    });

    test('头部被截断', () {
      final full = _thinHeader();
      final result = MachOParser.parse(Uint8List.sublistView(full, 0, 16));

      expect(result.isMachO, isFalse);
      expect(_hasDiagnostic(result, 'ios.macho.image_truncated'), isTrue);
    });

    test('sizeofcmds 超出文件长度 → 拒绝，不读越界', () {
      final result = MachOParser.parse(_thinHeader(ncmds: 1, sizeofcmds: 4096));

      expect(result.isMachO, isFalse);
      expect(_hasDiagnostic(result, 'ios.macho.load_commands_out_of_bounds'),
          isTrue);
    });

    test('ncmds 与 sizeofcmds 不自洽 → 拒绝', () {
      // 100 条命令至少要 800 字节，却只声明 64
      final result = MachOParser.parse(_thinHeader(
          ncmds: 100, sizeofcmds: 64, loadCommands: List.filled(64, 0)));

      expect(result.isMachO, isFalse);
      expect(_hasDiagnostic(result, 'ios.macho.implausible_command_count'),
          isTrue);
    });

    test('cmdsize 为 0 不会死循环，而是停下来并记诊断', () {
      // 一条 cmdsize = 0 的命令
      final result = MachOParser.parse(_thinHeader(
        ncmds: 1,
        sizeofcmds: 8,
        loadCommands: [..._le32(0x1B), ..._le32(0)],
      ));

      expect(_hasDiagnostic(result, 'ios.macho.command_size_invalid'), isTrue);
    });

    test('cmdsize 超出 load command 区域 → 停下来并记诊断', () {
      final result = MachOParser.parse(_thinHeader(
        ncmds: 1,
        sizeofcmds: 8,
        loadCommands: [..._le32(0x1B), ..._le32(9999)],
      ));

      expect(_hasDiagnostic(result, 'ios.macho.command_size_invalid'), isTrue);
    });

    test('畸形命令不会丢掉前面已读到的信息', () {
      // 第 1 条是合法 UUID，第 2 条 cmdsize 非法
      final uuid = List.generate(16, (i) => i);
      final result = MachOParser.parse(_thinHeader(
        ncmds: 2,
        sizeofcmds: 32,
        loadCommands: [
          ..._lcUuid(uuid),
          ..._le32(0x1B),
          ..._le32(0), // 非法
        ],
      ));

      expect(result.isMachO, isTrue, reason: '部分成功也要保留');
      expect(result.primary!.uuid, '00010203-0405-0607-0809-0A0B0C0D0E0F');
      expect(_hasDiagnostic(result, 'ios.macho.command_size_invalid'), isTrue);
    });

    test('fat 架构数离谱时拒绝（不会尝试分配）', () {
      final result = MachOParser.parse(Uint8List.fromList([
        ..._be32(0xCAFEBABE),
        ..._be32(0xFFFFFF), // nfat_arch
      ]));

      expect(result.isMachO, isFalse);
      expect(_hasDiagnostic(result, 'ios.macho.unrecognised'), isTrue);
    });

    test('fat 架构表被截断', () {
      final result = MachOParser.parse(Uint8List.fromList([
        ..._be32(0xCAFEBABE),
        ..._be32(2), // 声称 2 个架构，但表只有 20 字节
        ...List.filled(20, 0),
      ]));

      expect(result.isMachO, isFalse);
      expect(_hasDiagnostic(result, 'ios.macho.unrecognised'), isTrue);
    });

    test('fat 切片越界时跳过该切片并记诊断，其余照常', () {
      final thin = _fixture('thin-arm64.dylib');
      final out = <int>[
        ..._be32(0xCAFEBABE),
        ..._be32(2),
        // 切片 0：越界
        ..._be32(0x01000007), ..._be32(3), ..._be32(999999), ..._be32(100),
        ..._be32(0),
        // 切片 1：指向文件末尾的 thin 镜像
        ..._be32(0x0100000C), ..._be32(0), ..._be32(4096),
        ..._be32(thin.length), ..._be32(0),
      ];
      out.addAll(List.filled(4096 - out.length, 0));
      out.addAll(thin);

      final result = MachOParser.parse(Uint8List.fromList(out));

      expect(result.isFat, isTrue);
      expect(result.images, hasLength(1), reason: '越界的切片被跳过');
      expect(result.images.single.cpuTypeName, 'arm64');
      expect(
          _hasDiagnostic(result, 'ios.macho.fat_entry_out_of_bounds'), isTrue);
    });
  });

  group('辅助函数', () {
    test('版本号格式化与 otool 一致', () {
      expect(formatMachOVersion(0x001B0000), '27.0');
      expect(formatMachOVersion(0x000B0000), '11.0');
      expect(formatMachOVersion(0x000B0302), '11.3.2');
      expect(formatMachOVersion(0), '0.0');
      expect(formatMachOVersion(null), isNull);
    });

    test('CPU 类型名', () {
      expect(machOCpuTypeName(0x0100000C), 'arm64');
      expect(machOCpuTypeName(0x01000007), 'x86_64');
      expect(machOCpuTypeName(0x00000007), 'i386');
      expect(machOCpuTypeName(0x0000000C), 'arm');
      // 认不出的类型带上原始值，而不是编个名字
      expect(machOCpuTypeName(0x1234), contains('0x1234'));
    });

    test('文件类型映射', () {
      expect(MachOFileType.fromRaw(0x2), MachOFileType.execute);
      expect(MachOFileType.fromRaw(0x6), MachOFileType.dylib);
      expect(MachOFileType.fromRaw(0x8), MachOFileType.bundle);
      expect(MachOFileType.fromRaw(0xFFFF), MachOFileType.unknown);
    });
  });
}
