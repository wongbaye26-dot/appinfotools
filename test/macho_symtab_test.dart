// Mach-O 的 `LC_SYMTAB` 解析（iOS 侧原生符号）。
//
// 正常样本是 clang **真实编译**的 dylib（arm64 thin / fat / strip 过），
// 期望值来自 `otool -l`（LC_SYMTAB 的四个字段）与 `nm -u` / `nm -gU`
// （导入 / 导出符号）—— **不是**从本项目解析器取的。
//
// 这一层最容易写错的是 **fat 里的偏移基准**：`symoff` / `stroff` 是相对
// **切片起始**的，不是相对整个文件。实测 fat 里 arm64 切片的 `symoff` 与
// thin arm64 完全相同（33112），而它在文件里的起点是 16384 —— 下面有一条
// 测试专门钉住这件事。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const String _fixtureDir = 'test/fixtures/macho';

Uint8List _bytes(String name) => File('$_fixtureDir/$name').readAsBytesSync();

MachOFile _parse(String name) => MachOParser.parse(_bytes(name));

/// `nm -u libnative-fixture-arm64.dylib` 的输出（原样抄录，含前导下划线）。
const List<String> _nmUndefined = [
  '_connect',
  '_dlopen',
  '_dlsym',
  '_execl',
  '_fork',
  '_pclose',
  '_popen',
  '_ptrace',
  '_socket',
  '_system',
];

/// `nm -gU libnative-fixture-arm64.dylib` 的输出。
const List<String> _nmDefinedExternal = [
  '_do_ptrace',
  '_exported_helper',
  '_exported_name',
  '_load_plugin',
  '_make_socket',
  '_run_command',
  '_spawn',
];

void main() {
  group('LC_SYMTAB 的四个字段（对照 otool -l）', () {
    test('thin arm64 的 symoff / nsyms / stroff / strsize 与工具一致', () {
      final file = _parse('libnative-fixture-arm64.dylib');

      expect(file.images, hasLength(1));
      final symtab = file.images.single.symtab;

      // otool -l 对这个文件输出：
      //   cmd LC_SYMTAB / cmdsize 24
      //   symoff 33112 / nsyms 17 / stroff 33464 / strsize 168
      expect(symtab, isNotNull);
      expect(symtab!.symbolOffset, 33112);
      expect(symtab.symbolCount, 17);
      expect(symtab.stringOffset, 33464);
      expect(symtab.stringSize, 168);
    });

    test('读到的符号条数与 nsyms 一致', () {
      final image = _parse('libnative-fixture-arm64.dylib').images.single;

      expect(image.symbolsRead, isTrue);
      expect(image.symbols, hasLength(17));
    });
  });

  group('导入 / 导出符号（对照 nm）', () {
    test('导入符号与 nm -u 完全一致', () {
      final image = _parse('libnative-fixture-arm64.dylib').images.single;

      final imported = image.importedSymbols.map((s) => s.name).toList()
        ..sort();
      expect(imported, _nmUndefined);
    });

    test('导出符号与 nm -gU 完全一致', () {
      final image = _parse('libnative-fixture-arm64.dylib').images.single;

      final exported = image.exportedSymbols.map((s) => s.name).toList()
        ..sort();
      expect(exported, _nmDefinedExternal);
    });

    test('N_UNDF|N_EXT 与 N_SECT|N_EXT 的判定正确', () {
      final image = _parse('libnative-fixture-arm64.dylib').images.single;

      final system = image.symbols.firstWhere((s) => s.name == '_system');
      expect(system.isUndefined, isTrue);
      expect(system.isExternal, isTrue);
      expect(system.isDefinedExternal, isFalse);
      expect(system.typeField, 0x0, reason: 'N_UNDF');

      final helper =
          image.symbols.firstWhere((s) => s.name == '_exported_helper');
      expect(helper.isUndefined, isFalse);
      expect(helper.isDefinedExternal, isTrue);
      expect(helper.typeField, 0xe, reason: 'N_SECT');
      expect(helper.value, greaterThan(0), reason: '有实际地址');
    });

    test('cName 只去掉一个前导下划线', () {
      // `_system` → `system`（C 符号前缀）
      expect(
        _parse('libnative-fixture-arm64.dylib')
            .images
            .single
            .symbols
            .firstWhere((s) => s.name == '_system')
            .cName,
        'system',
      );

      // 手工构造：`___cxa_atexit` 是 C++ 运行时的 `__cxa_atexit`，
      // 去掉两个下划线就认不出来了。
      const symbol = MachOSymbol(
          name: '___cxa_atexit', type: 0x1, sectionIndex: 0, value: 0);
      expect(symbol.cName, '__cxa_atexit');

      const noUnderscore =
          MachOSymbol(name: 'plain', type: 0x1, sectionIndex: 0, value: 0);
      expect(noUnderscore.cName, 'plain', reason: '没有下划线就原样返回');
    });
  });

  group('fat 二进制的切片偏移基准', () {
    test('两个切片都读到符号，且 arm64 切片的 symoff 是**切片内**偏移', () {
      final file = _parse('libnative-fixture-fat.dylib');

      expect(file.images, hasLength(2));
      final byCpu = {for (final img in file.images) img.cpuTypeName: img};
      expect(byCpu.keys, containsAll(['arm64', 'x86_64']));

      final arm64 = byCpu['arm64']!;
      final x86 = byCpu['x86_64']!;

      // lipo -detailed_info：x86_64 在 4096，arm64 在 16384。
      expect(x86.offset, 4096);
      expect(arm64.offset, 16384);

      // 关键：arm64 切片的 symoff 与 **thin arm64** 完全相同（33112），
      // 而它在文件里的起点是 16384 —— 说明 symoff 是切片内偏移。
      // 若误当成文件偏移，符号表会读到 16384 字节之后的位置，全是垃圾。
      expect(arm64.symtab!.symbolOffset, 33112);
      expect(
        arm64.symtab!.symbolOffset,
        _parse('libnative-fixture-arm64.dylib')
            .images
            .single
            .symtab!
            .symbolOffset,
      );
      // 真正的证据是下一条测试：按「切片内偏移」解释时解出的名字与 nm
      // 逐个一致；按「文件绝对偏移」解释会落到切片内的别处，名字不可能对上。
      // 这里只补一条算术上的自洽检查。
      final bytes = _bytes('libnative-fixture-fat.dylib');
      final symbolTableEnd = arm64.offset +
          arm64.symtab!.symbolOffset +
          arm64.symtab!.symbolCount * 16;
      expect(
        symbolTableEnd,
        lessThanOrEqualTo(bytes.length),
        reason: '按切片内偏移解释时，符号表要落在文件里',
      );
    });

    test('两个切片解出同一批符号', () {
      final file = _parse('libnative-fixture-fat.dylib');

      for (final image in file.images) {
        expect(
          image.importedSymbols.map((s) => s.name).toList()..sort(),
          _nmUndefined,
          reason: '${image.cpuTypeName} 切片',
        );
        expect(
          image.exportedSymbols.map((s) => s.name).toList()..sort(),
          _nmDefinedExternal,
          reason: '${image.cpuTypeName} 切片',
        );
      }
    });
  });

  group('既有夹具与 strip', () {
    test('旧的 thin-arm64.dylib 只有一个导出符号', () {
      // nm 对这个文件输出：00000000000002d0 T _probe_value
      final image = _parse('thin-arm64.dylib').images.single;

      expect(image.symbolsRead, isTrue);
      expect(image.symbols, hasLength(1));
      expect(image.importedSymbols, isEmpty);
      expect(image.exportedSymbols.single.name, '_probe_value');
    });

    test('strip 过的 dylib 仍然保留外部符号（共享库的导出无法剥离）', () {
      final stripped = _parse('libnative-fixture-stripped.dylib').images.single;

      expect(stripped.symtab, isNotNull);
      expect(
        stripped.importedSymbols.map((s) => s.name).toList()..sort(),
        _nmUndefined,
        reason: '导入符号是链接期必需的，strip 不会去掉',
      );
      expect(
        stripped.exportedSymbols.map((s) => s.name).toList()..sort(),
        _nmDefinedExternal,
        reason: '导出符号是共享库的对外接口，strip 也不会去掉',
      );
    });
  });

  group('边界：畸形输入不炸', () {
    test('空字节与随机字节不抛异常', () {
      expect(() => MachOParser.parse(Uint8List(0)), returnsNormally);
      expect(
        () => MachOParser.parse(Uint8List.fromList(List.filled(200, 0x41))),
        returnsNormally,
      );
    });

    test('符号表越界时记诊断，且 symbolsRead 为 false', () {
      // 手工构造：把 LC_SYMTAB 的 symoff 改到文件之外。
      // 需要先找到 symtab_command 在文件里的位置 —— 用解析结果反推不方便，
      // 改为直接构造一个「有 LC_SYMTAB 但 symoff 荒谬」的最小镜像。
      final bytes = Uint8List.fromList(_bytes('libnative-fixture-arm64.dylib'));
      // LC_SYMTAB 的 cmd 是 0x2、cmdsize 24。在文件里搜它。
      final offset = _findSymtabCommand(bytes);
      expect(offset, isNotNull, reason: '夹具里应当有 LC_SYMTAB');

      // symoff 是 cmd 之后的第一个 u32（小端）。
      final view = ByteData.sublistView(bytes);
      view.setUint32(offset! + 8, 0x00FFFFFF, Endian.little);

      final file = MachOParser.parse(bytes);
      final image = file.images.single;
      expect(image.symbolsRead, isFalse, reason: '越界 = 没查，不是「没有」');
      expect(image.symbols, isEmpty);
      expect(
        file.diagnostics.map((d) => d.code),
        contains('ios.macho.symtab_out_of_bounds'),
      );
    });
  });

  group('iOS 原生符号审计', () {
    test('命中真实夹具里导入的系统能力', () {
      final result = IosNativeSymbolAudit.scan(
        executableBytes: _bytes('libnative-fixture-arm64.dylib'),
        executablePath: 'Payload/App.app/App',
      );

      final found = result.symbols.map((s) => s.symbol).toList();
      expect(found, containsAll(['system', 'popen', 'execl', 'fork']));
      expect(found, containsAll(['dlopen', 'dlsym', 'ptrace']));
      expect(found, containsAll(['socket', 'connect']));
      expect(
        found,
        isNot(contains('getaddrinfo')),
        reason: '夹具没导入 getaddrinfo —— 报出来就是误报',
      );
      expect(result.scannedImages, 1);
      expect(result.importedCount, 10);
    });

    test('标记匹配用的是去掉前导下划线的名字', () {
      final result = IosNativeSymbolAudit.scan(
        executableBytes: _bytes('libnative-fixture-arm64.dylib'),
        executablePath: 'App',
      );

      final system = result.symbol('system');
      expect(system, isNotNull, reason: 'Mach-O 里叫 _system，标记表里叫 system');
      expect(
        system!.rawNames,
        ['_system'],
        reason: '证据要保留原样符号名，用户才能拿去核对',
      );
    });

    test('fat 的两个切片都参与扫描，符号不会重复计数', () {
      final result = IosNativeSymbolAudit.scan(
        executableBytes: _bytes('libnative-fixture-fat.dylib'),
        executablePath: 'App',
      );

      expect(result.scannedImages, 2);
      expect(result.importedCount, 20, reason: '两个切片各 10 条');
      // 命中的标记按符号去重 —— 两个切片导入同一个符号只算一条。
      expect(result.symbol('system'), isNotNull);
      expect(result.symbol('system')!.rawNames, ['_system']);
    });

    test('没有可执行文件字节时返回空结果，不报错', () {
      final result = IosNativeSymbolAudit.scan(
        executableBytes: null,
        executablePath: null,
      );
      expect(result.symbols, isEmpty);
      expect(result.scannedImages, 0);
    });

    test('发现项用 nativeSymbol 作证据来源，且不抬高置信度', () {
      final result = IosNativeSymbolAudit.scan(
        executableBytes: _bytes('libnative-fixture-arm64.dylib'),
        executablePath: 'Payload/App.app/App',
      );
      final report = IosNativeSymbolAudit.report(
        result: result,
        executablePath: 'Payload/App.app/App',
      );

      expect(report.findings, hasLength(1));
      final finding = report.findings.single;
      expect(finding.ruleId, 'IOS-NATIVE-SYMBOLS');
      expect(finding.platform, SecurityPlatform.ios);
      expect(finding.severity, SecuritySeverity.p3);
      expect(finding.confidence, SecurityConfidence.independentCapability);
      expect(
        finding.evidence
            .every((e) => e.source == SecurityEvidenceSource.nativeSymbol),
        isTrue,
      );
      expect(
        AnalysisReport.limitationText(finding, t),
        contains('Import does not mean call'),
      );
      expect(
        AnalysisReport.recommendationText(finding, t),
        contains('is not a risk verdict'),
      );
      expect(
        report.limitations.any((l) => l.contains('未反汇编原生代码')),
        isTrue,
      );
    });

    test('没有命中时不产出发现项，但仍说明覆盖范围', () {
      // thin-arm64.dylib 只有 _probe_value，一个标记都不命中。
      final result = IosNativeSymbolAudit.scan(
        executableBytes: _bytes('thin-arm64.dylib'),
        executablePath: 'App',
      );
      final report = IosNativeSymbolAudit.report(
        result: result,
        executablePath: 'App',
      );

      expect(result.symbols, isEmpty);
      expect(report.findings, isEmpty);
      expect(
        report.limitations.any((l) => l.contains('未反汇编原生代码')),
        isTrue,
        reason: '「没发现」也必须说清是查过了没发现',
      );
    });
  });
}

/// 在字节里找 `LC_SYMTAB`（cmd=0x2、cmdsize=24）命令的位置。
///
/// 返回 cmd 字段的偏移。找不到返回 `null`。
int? _findSymtabCommand(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  for (var i = 32; i + 8 <= bytes.length; i += 4) {
    if (view.getUint32(i, Endian.little) == 0x2 &&
        view.getUint32(i + 4, Endian.little) == 24) {
      return i;
    }
  }
  return null;
}
