// ELF（Android `lib/**.so`）的结构与符号表解析。
//
// 正常样本是 Android NDK 25 的 clang **真实编译**出来的 `.so`
// （arm64-v8a / armeabi-v7a / 已 strip 三个），期望值来自 NDK 自带的
// `llvm-readelf` 与 `llvm-nm` —— **不是**从本项目解析器取的，那样等于自证。
//
// 畸形样本是手工改的：没有工具会产出「节表越界」的 ELF，而那正是要防的形态。
// 每个畸变都先用 `llvm-readelf` 核对过它的判断，期望值记在 README 里。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const String _fixtureDir = 'test/fixtures/elf';

Uint8List _bytes(String name) => File('$_fixtureDir/$name').readAsBytesSync();

ElfStructure _read(String name) => ElfStructure.read(name, _bytes(name));

List<String> _codes(ElfStructure s) => [for (final a in s.anomalies) a.code];

/// `llvm-nm -D --undefined-only arm64-v8a-libnative.so` 的输出（原样抄录）。
///
/// 注意 `llvm-nm` 会补上 `@LIBC` 版本后缀，而 ELF 的 `st_name` 指向的名字
/// 本来就不带后缀（版本来自 `.gnu.version`）—— 所以这里的期望值不带后缀。
const List<String> _llvmNmUndefined = [
  '__android_log_print',
  '__cxa_atexit',
  '__cxa_finalize',
  'connect',
  'dlopen',
  'dlsym',
  'execl',
  'fork',
  'getenv',
  'pclose',
  'popen',
  'ptrace',
  'socket',
  'system',
];

/// `llvm-nm -D --defined-only arm64-v8a-libnative.so` 的输出。
const List<String> _llvmNmDefined = [
  'do_ptrace',
  'exported_helper',
  'exported_name',
  'load_plugin',
  'make_socket',
  'probe_env',
  'run_command',
  'spawn',
];

void main() {
  group('ELF 头部与节表（对照 llvm-readelf）', () {
    test('arm64-v8a 的头部字段与工具一致', () {
      final s = _read('arm64-v8a-libnative.so');

      // llvm-readelf -h:
      //   Class ELF64 / Machine AArch64 / Type DYN
      //   Start of section headers 6256 / Size 64 / Number 23 / shstrndx 21
      expect(s.elfClass, ElfClass.elf64);
      expect(s.endianness, ElfEndianness.little);
      expect(s.type, 3, reason: 'ET_DYN');
      expect(s.machine, 183, reason: 'EM_AARCH64');
      expect(s.machineName, 'aarch64');
      expect(s.typeName, 'DYN');
      expect(s.sectionHeaderOffset, 6256);
      expect(s.sectionHeaderEntrySize, 64);
      expect(s.sectionHeaderCount, 23);
      expect(s.sectionNameIndex, 21);
      expect(s.sections, hasLength(23));
    });

    test('armeabi-v7a 是 32 位 ELF，节头尺寸也不同', () {
      final s = _read('armeabi-v7a-libnative.so');

      expect(s.elfClass, ElfClass.elf32);
      expect(s.machine, 40, reason: 'EM_ARM');
      expect(s.sectionHeaderEntrySize, 40, reason: 'Elf32_Shdr 是 40 字节');
      expect(s.sections, hasLength(23));
      expect(s.isTraversable, isTrue);
    });

    test('节名、偏移、大小与工具一致', () {
      final s = _read('arm64-v8a-libnative.so');

      // llvm-readelf -S:
      //   [ 2] .dynsym  DYNSYM  0002d0 0002d0 000228 18  A  7  1  8
      //   [ 7] .dynstr  STRTAB  0003cc 000670 0000ec 00  A  0  0  1
      final dynsym = s.section('.dynsym');
      expect(dynsym, isNotNull);
      expect(dynsym!.type, 11, reason: 'SHT_DYNSYM');
      expect(dynsym.offset, 0x2d0);
      expect(dynsym.size, 0x228);
      expect(dynsym.entrySize, 24);
      expect(dynsym.entryCount, 23, reason: '0x228 / 24 = 23');
      expect(dynsym.link, 7, reason: 'sh_link 指向 .dynstr');

      final dynstr = s.section('.dynstr');
      expect(dynstr, isNotNull);
      expect(dynstr!.type, 3, reason: 'SHT_STRTAB');
      expect(dynstr.offset, 0x670);
      expect(dynstr.size, 0xec);

      expect(s.section('.text'), isNotNull);
      expect(s.section('.不存在的节'), isNull);
    });
  });

  group('动态符号表（对照 llvm-nm -D）', () {
    test('导入的符号与 llvm-nm --undefined-only 完全一致', () {
      final bytes = _bytes('arm64-v8a-libnative.so');
      final s = ElfStructure.read('arm64-v8a-libnative.so', bytes);
      final dyn = ElfSymbolTable.readDynamic(bytes, s);

      final imported = dyn.imported.map((x) => x.name).toList()..sort();
      expect(imported, _llvmNmUndefined);
    });

    test('导出的符号与 llvm-nm --defined-only 完全一致', () {
      final bytes = _bytes('arm64-v8a-libnative.so');
      final s = ElfStructure.read('arm64-v8a-libnative.so', bytes);
      final dyn = ElfSymbolTable.readDynamic(bytes, s);

      final exported = dyn.exported.map((x) => x.name).toList()..sort();
      expect(exported, _llvmNmDefined);
    });

    test('符号总数与工具一致，且占位符号不算导入', () {
      final bytes = _bytes('arm64-v8a-libnative.so');
      final s = ElfStructure.read('arm64-v8a-libnative.so', bytes);
      final dyn = ElfSymbolTable.readDynamic(bytes, s);

      // llvm-readelf --dyn-syms 显示 23 项（含第 0 项占位符号）。
      expect(dyn.symbols, hasLength(23));
      expect(dyn.skipped, 0);
      expect(dyn.truncated, isFalse);

      // 第 0 项是空名占位符号：它是 UND，但**不是**一个真实导入。
      final nullSymbol = dyn.symbols.first;
      expect(nullSymbol.name, isEmpty);
      expect(nullSymbol.isUndefined, isTrue);
      expect(nullSymbol.isNullSymbol, isTrue);
      expect(
        dyn.imported.any((x) => x.name.isEmpty),
        isFalse,
        reason: '占位符号混进「导入了什么」会凭空多出一条空名字',
      );
      expect(dyn.imported, hasLength(14));
      expect(dyn.exported, hasLength(8));
    });

    test('符号类型与绑定属性解析正确', () {
      final bytes = _bytes('arm64-v8a-libnative.so');
      final s = ElfStructure.read('arm64-v8a-libnative.so', bytes);
      final dyn = ElfSymbolTable.readDynamic(bytes, s);

      final system = dyn.symbols.firstWhere((x) => x.name == 'system');
      expect(system.isUndefined, isTrue, reason: 'system 是导入的');
      expect(system.isFunction, isTrue, reason: 'llvm-readelf 标为 FUNC');
      expect(system.bind, 1, reason: 'GLOBAL');

      final helper = dyn.symbols.firstWhere((x) => x.name == 'exported_helper');
      expect(helper.isUndefined, isFalse, reason: '定义在本库里');
      expect(helper.isFunction, isTrue);
      expect(helper.value, greaterThan(0), reason: '有实际地址');
    });

    test('ELF32 与 ELF64 解出同一批符号', () {
      // 同一份源码编到两个 ABI，符号名应当一致（地址不同）。
      final results = <String, List<String>>{};
      for (final name in const [
        'arm64-v8a-libnative.so',
        'armeabi-v7a-libnative.so',
      ]) {
        final bytes = _bytes(name);
        final s = ElfStructure.read(name, bytes);
        results[name] = ElfSymbolTable.readDynamic(bytes, s)
            .imported
            .map((x) => x.name)
            .toList()
          ..sort();
      }

      expect(results['arm64-v8a-libnative.so'], _llvmNmUndefined);
      expect(
        results['armeabi-v7a-libnative.so'],
        _llvmNmUndefined,
        reason: '32 位下的符号表条目是 16 字节，偏移算法不同 —— '
            '结果一致才说明两套布局都读对了',
      );
    });
  });

  group('strip 与未 strip', () {
    test('未 strip 的库有 .symtab，能读到更多符号', () {
      final bytes = _bytes('arm64-v8a-libnative.so');
      final s = ElfStructure.read('arm64-v8a-libnative.so', bytes);

      expect(s.section('.symtab'), isNotNull);
      expect(s.section('.strtab'), isNotNull);
      final stat = ElfSymbolTable.readStatic(bytes, s);
      expect(stat.symbols.length, greaterThan(8), reason: '含内部符号');
      expect(stat.anomalies, isEmpty);
    });

    test('strip 过的库没有 .symtab，如实记「符号表被剥离」而不是报错', () {
      final bytes = _bytes('arm64-v8a-libnative-stripped.so');
      final s = ElfStructure.read('arm64-v8a-libnative-stripped.so', bytes);

      expect(s.section('.symtab'), isNull);
      final stat = ElfSymbolTable.readStatic(bytes, s);
      expect(stat.symbols, isEmpty);
      expect(
        stat.anomalies.map((a) => a.code),
        ['elf.symbol_table_absent'],
      );
      expect(
        stat.anomalies.single.blocking,
        isFalse,
        reason: '发布版本被 strip 是**正常**情况，不是异常',
      );

      // 但动态符号表仍然在 —— 运行时需要它。
      final dyn = ElfSymbolTable.readDynamic(bytes, s);
      expect(
          dyn.imported.map((x) => x.name).toList()..sort(), _llvmNmUndefined);
    });
  });

  group('畸形 ELF 必须被如实记下（期望值来自 llvm-readelf）', () {
    const cases = <String, String>{
      // llvm-readelf: The file was not recognized as a valid object file
      'bad-magic.so': 'elf.bad_magic',
      // llvm-readelf: section header table goes past the end of the file
      'truncated.so': 'elf.section_table_out_of_range',
      // llvm-readelf: section header table goes past the end of the file: e_shoff = 0xffffff
      'section-table-out-of-range.so': 'elf.section_table_out_of_range',
    };

    cases.forEach((file, code) {
      test('$file → $code', () {
        final s = _read(file);

        expect(_codes(s), contains(code), reason: '实际记下的是 ${s.anomalies}');
        expect(s.anomalies.firstWhere((a) => a.code == code).blocking, isTrue);
        expect(s.isTraversable, isFalse);
      });
    });

    test('节表被剥离（e_shnum=0）是**合法**文件，记非阻断异常', () {
      // llvm-readelf: There are 0 section headers
      final s = _read('no-section-headers.so');

      expect(_codes(s), ['elf.no_section_headers']);
      expect(
        s.anomalies.single.blocking,
        isFalse,
        reason: '完全剥离节表是合法的 —— 运行只需要程序头',
      );
      expect(s.isTraversable, isFalse, reason: '没有节表就无法读符号表');
    });

    test('节名表索引无效时节名读不出来，但节的类型与偏移仍然有效', () {
      // llvm-readelf: warning: section header string table index 255 does not exist
      //               节名显示为 <no-strings>
      final s = _read('bad-section-name-index.so');

      expect(_codes(s), ['elf.section_name_table_unavailable']);
      expect(s.isTraversable, isTrue, reason: '类型与偏移仍然可用');

      // 节名全空，但按**类型**仍然能找到符号表 —— 这正是按类型找而不是按名字
      // 找的理由。
      final bytes = _bytes('bad-section-name-index.so');
      final dyn = ElfSymbolTable.readDynamic(bytes, s);
      expect(
          dyn.imported.map((x) => x.name).toList()..sort(), _llvmNmUndefined);
    });

    test('短于标识的字节不越界读取', () {
      for (final length in [0, 1, 15]) {
        final s = ElfStructure.read('tiny.so', Uint8List(length));
        expect(_codes(s), ['elf.too_short'], reason: 'length=$length');
        expect(s.isTraversable, isFalse);
      }
    });

    test('头部被截断时明确说清需要多少字节', () {
      // 有完整 magic 但不足 64 字节
      final s = ElfStructure.read(
        'short.so',
        Uint8List.fromList(
            [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      );

      expect(_codes(s), ['elf.header_truncated']);
      expect(s.anomalies.single.message, contains('64'));
      expect(s.anomalies.single.message, contains('16'));
    });
  });

  group('符号扫描器', () {
    test('命中真实夹具里导入的系统能力', () {
      final bytes = _bytes('arm64-v8a-libnative.so');
      final result = NativeSymbolScanner.scan([
        NativeLibraryBytes('lib/arm64-v8a/libnative.so', bytes),
      ]);

      final found = result.symbols.map((s) => s.symbol).toList();
      // 夹具刻意导入了这些（见 test/fixtures/elf/README.md）。
      expect(found, containsAll(['system', 'popen', 'execl', 'fork']));
      expect(found, containsAll(['dlopen', 'dlsym', 'ptrace']));
      expect(found, containsAll(['socket', 'connect']));
      expect(
        found,
        isNot(contains('getaddrinfo')),
        reason: '夹具没导入 getaddrinfo —— 报出来就是误报',
      );
      expect(
        found,
        isNot(contains('pclose')),
        reason: 'pclose 在导入表里但不在标记表里（太常见，收进来只会是噪音）',
      );
    });

    test('证据里带上具体是哪个库', () {
      final result = NativeSymbolScanner.scan([
        NativeLibraryBytes(
            'lib/arm64-v8a/libnative.so', _bytes('arm64-v8a-libnative.so')),
        NativeLibraryBytes(
            'lib/armeabi-v7a/libnative.so', _bytes('armeabi-v7a-libnative.so')),
      ]);

      final system = result.symbol('system');
      expect(system, isNotNull);
      expect(system!.libraryNames, hasLength(2));
      expect(
        system.libraryNames.first,
        'lib/arm64-v8a/libnative.so',
      );
    });

    test('只匹配导入的符号：库自己定义的同名函数不算', () {
      // 夹具里 `exported_helper` 是定义的，不在标记表里；这里验证的是机制 ——
      // 标记表里的符号若只被**定义**（不在 UND 段）就不该命中。
      // 用一个只含导出符号的构造来验证：把导入表清空不现实，
      // 改为断言「命中的符号在导入集合里」。
      final bytes = _bytes('arm64-v8a-libnative.so');
      final s = ElfStructure.read('libnative.so', bytes);
      final imported = ElfSymbolTable.readDynamic(bytes, s)
          .imported
          .map((x) => x.name)
          .toSet();

      final result = NativeSymbolScanner.scan([
        NativeLibraryBytes('lib/arm64-v8a/libnative.so', bytes),
      ]);
      for (final hit in result.symbols) {
        expect(
          imported.contains(hit.symbol),
          isTrue,
          reason: '${hit.symbol} 不在导入集合里，说明匹配没限制在 UND 段',
        );
      }
    });

    test('记录库的 ABI 与「未剥离」事实', () {
      final result = NativeSymbolScanner.scan([
        NativeLibraryBytes(
            'lib/arm64-v8a/libnative.so', _bytes('arm64-v8a-libnative.so')),
        NativeLibraryBytes(
            'lib/armeabi-v7a/libnative.so', _bytes('armeabi-v7a-libnative.so')),
        NativeLibraryBytes('lib/arm64-v8a/libnative-stripped.so',
            _bytes('arm64-v8a-libnative-stripped.so')),
      ]);

      final byName = {for (final l in result.libraries) l.name: l};
      expect(byName['lib/arm64-v8a/libnative.so']!.abi, 'arm64-v8a');
      expect(byName['lib/armeabi-v7a/libnative.so']!.abi, 'armeabi-v7a');
      expect(
        byName['lib/arm64-v8a/libnative.so']!.hasStaticSymbols,
        isTrue,
      );
      expect(
        byName['lib/arm64-v8a/libnative-stripped.so']!.hasStaticSymbols,
        isFalse,
      );
      expect(result.unstrippedLibraries, hasLength(2));
    });

    test('结构不可信的库进 notTraversable，不产出符号', () {
      final result = NativeSymbolScanner.scan([
        NativeLibraryBytes(
            'lib/arm64-v8a/libbroken.so', _bytes('bad-magic.so')),
      ]);

      expect(result.symbols, isEmpty);
      expect(result.libraries, isEmpty);
      expect(result.notTraversable, ['lib/arm64-v8a/libbroken.so']);
    });

    test('没有原生库时结果为空，不报错', () {
      final result = NativeSymbolScanner.scan(const []);
      expect(result.symbols, isEmpty);
      expect(result.libraries, isEmpty);
      expect(result.skippedForBudget, isEmpty);
    });
  });

  group('库挑选：把预算花在不重复的内容上', () {
    test('同一个库的多个 ABI 只取一个，优先 arm64-v8a', () {
      final selection = NativeSymbolScanner.selectLibraries(const [
        (name: 'lib/x86/liba.so', size: 100),
        (name: 'lib/armeabi-v7a/liba.so', size: 100),
        (name: 'lib/arm64-v8a/liba.so', size: 100),
        (name: 'lib/x86_64/liba.so', size: 100),
      ]);

      expect(selection.selected, ['lib/arm64-v8a/liba.so']);
      expect(
        selection.skipped,
        isEmpty,
        reason: '其它 ABI 不是「跳过」，只是不重复分析',
      );
    });

    test('不同库都保留', () {
      final selection = NativeSymbolScanner.selectLibraries(const [
        (name: 'lib/arm64-v8a/liba.so', size: 100),
        (name: 'lib/arm64-v8a/libb.so', size: 100),
        (name: 'lib/arm64-v8a/libc.so', size: 100),
      ]);

      expect(selection.selected, hasLength(3));
    });

    test('超过单库上限的记入 skipped 并说明原因', () {
      final selection = NativeSymbolScanner.selectLibraries([
        (
          name: 'lib/arm64-v8a/libhuge.so',
          size: NativeSymbolScanner.maxBytesPerLibrary + 1
        ),
        (name: 'lib/arm64-v8a/libok.so', size: 100),
      ]);

      expect(selection.selected, ['lib/arm64-v8a/libok.so']);
      expect(selection.skipped, hasLength(1));
      expect(selection.skipped.single, contains('libhuge.so'));
      expect(selection.skipped.single, contains('单库上限'));
    });

    test('超过数量上限的记入 skipped', () {
      final candidates = [
        for (var i = 0; i < NativeSymbolScanner.maxLibraries + 3; i++)
          (name: 'lib/arm64-v8a/lib$i.so', size: 100),
      ];
      final selection = NativeSymbolScanner.selectLibraries(candidates);

      expect(selection.selected, hasLength(NativeSymbolScanner.maxLibraries));
      expect(selection.skipped, hasLength(3));
    });

    test('超过总体积上限的记入 skipped', () {
      // 每个都合法，但加起来超总预算。
      const each = NativeSymbolScanner.maxTotalBytes ~/ 3;
      final selection = NativeSymbolScanner.selectLibraries(const [
        (name: 'lib/arm64-v8a/liba.so', size: each),
        (name: 'lib/arm64-v8a/libb.so', size: each),
        (name: 'lib/arm64-v8a/libc.so', size: each),
        (name: 'lib/arm64-v8a/libd.so', size: each),
      ]);

      expect(selection.selected, hasLength(3));
      expect(selection.skipped.single, contains('总体积上限'));
    });

    test('ABI 未知的库排在已知 ABI 之后', () {
      final selection = NativeSymbolScanner.selectLibraries(const [
        (name: 'lib/weird/liba.so', size: 100),
        (name: 'lib/arm64-v8a/liba.so', size: 100),
      ]);

      expect(selection.selected, ['lib/arm64-v8a/liba.so']);
    });
  });

  group('审计接入', () {
    test('原生符号进发现项，证据来源是 nativeSymbol', () {
      final result = AndroidSecurityAudit.audit(
        meta: ApkMeta(),
        dexEntries: const [],
        nativeEntries: [
          NativeLibraryBytes(
              'lib/arm64-v8a/libnative.so', _bytes('arm64-v8a-libnative.so')),
        ],
      );

      final finding = result.findings
          .where((f) => f.ruleId == 'ANDROID-NATIVE-SYMBOLS')
          .firstOrNull;
      expect(finding, isNotNull,
          reason: '实际发现项：${result.findings.map((f) => f.ruleId).toList()}');
      expect(
        finding!.evidence
            .any((e) => e.source == SecurityEvidenceSource.nativeSymbol),
        isTrue,
      );
      expect(finding.finding, contains('不证明被调用过'));
    });

    test('命令执行类符号给出 p3，并写明不是恶意判定', () {
      final result = AndroidSecurityAudit.audit(
        meta: ApkMeta(),
        dexEntries: const [],
        nativeEntries: [
          NativeLibraryBytes(
              'lib/arm64-v8a/libnative.so', _bytes('arm64-v8a-libnative.so')),
        ],
      );

      final finding = result.findings
          .firstWhere((f) => f.ruleId == 'ANDROID-NATIVE-SYMBOLS');
      expect(finding.severity, SecuritySeverity.p3);
      expect(finding.confidence, SecurityConfidence.independentCapability);
      expect(finding.recommendation, contains('不构成风险判定'));
      expect(finding.limitation, contains('导入不等于调用'));
    });

    test('写明「未反汇编原生代码」这条局限', () {
      final result = AndroidSecurityAudit.audit(
        meta: ApkMeta(),
        dexEntries: const [],
        nativeEntries: [
          NativeLibraryBytes(
              'lib/arm64-v8a/libnative.so', _bytes('arm64-v8a-libnative.so')),
        ],
      );

      expect(
        result.limitations.any((l) => l.contains('未反汇编原生代码')),
        isTrue,
        reason: '实际局限：${result.limitations}',
      );
    });

    test('没有原生库时不产出该发现项', () {
      final result = AndroidSecurityAudit.audit(
        meta: ApkMeta(),
        dexEntries: const [],
      );

      expect(
        result.findings.any((f) => f.ruleId == 'ANDROID-NATIVE-SYMBOLS'),
        isFalse,
      );
    });
  });
}
