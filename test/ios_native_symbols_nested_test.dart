// iOS 原生符号：**嵌套可执行文件也要扫**（审计 P2-3），以及扫描预算 16 → 64 MiB
// （P2-1）。
//
// ## 为什么要扫嵌套
//
// App Extension / 框架里的 C/C++ 代码不在主二进制里。此前 `IosNativeSymbolAudit`
// 只收主可执行文件 —— 实测 `sun_signed.ipa` 有 25 个可执行文件，符号层只看了 1 个
// （覆盖表 `ios.nativeSymbols = covered 1`），而「扩展正是处理照片与 OCR 的地方」。
//
// ## 为什么预算要提到 64 MiB
//
// 同一份 IPA 的主可执行文件 34.3 MiB，原先单文件上限 16 MiB → 后 19.2 MiB
// （47%）完全没扫。B-6 那个「声明了相机但没实现」的误报就是这么来的。
//
// 本文件用**真实的 Mach-O 夹具**（`libnative-fixture-arm64.dylib` 的导入符号是
// connect / dlopen / dlsym / fork / ptrace / system 等），期望值来自 `nm -u`。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

/// 有导入符号的真实 dylib（`nm -u` 可核对）。
final Uint8List _withSymbols =
    File('test/fixtures/macho/libnative-fixture-arm64.dylib').readAsBytesSync();

/// 没有导入符号的真实 dylib（主可执行文件用）。
final Uint8List _withoutSymbols =
    File('test/fixtures/macho/thin-arm64.dylib').readAsBytesSync();

const _bundlePath = 'Payload/Example.app';

IosBundle _bundle() => const IosBundle(
      kind: IosBundleKind.mainApp,
      path: _bundlePath,
      name: 'Example.app',
      infoPlistPath: '$_bundlePath/Info.plist',
      infoPlistSize: 512,
      fileCount: 3,
      uncompressedBytes: 4096,
    );

IpaInfoPlist _plist() {
  const plist = '<?xml version="1.0" encoding="UTF-8"?>'
      '<plist version="1.0"><dict>'
      '<key>CFBundleIdentifier</key><string>com.example.app</string>'
      '</dict></plist>';
  final archive = Archive();
  final bytes = const Utf8Encoder().convert(plist);
  archive.addFile(ArchiveFile('$_bundlePath/Info.plist', bytes.length, bytes));
  return IpaInfoPlistReader.read(archive, _bundle());
}

SecurityAnalysisResult _audit({
  Uint8List? main,
  List<IosNestedExecutableInput> nested = const [],
  int? scanBudgetBytes,
}) =>
    IosPrivacyAudit.audit(
      infoPlist: _plist(),
      executableBytes: main,
      executablePath: '$_bundlePath/Example',
      nestedExecutables: nested,
      scanBudgetBytes: scanBudgetBytes,
    );

IosNestedExecutableInput _nested(String name, Uint8List bytes) =>
    IosNestedExecutableInput(
      path: '$_bundlePath/Frameworks/$name.framework/$name',
      bundlePath: '$_bundlePath/Frameworks/$name.framework',
      kind: IosBundleKind.framework,
      bytes: bytes,
    );

SecurityFinding? _nativeSymbols(SecurityAnalysisResult r) {
  for (final f in r.findings) {
    if (f.ruleId == 'IOS-NATIVE-SYMBOLS') return f;
  }
  return null;
}

CoverageEntry _entry(SecurityAnalysisResult r, String id) =>
    r.coverage.entries.firstWhere((e) => e.id == id);

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('嵌套可执行文件的符号也要进结果', () {
    test('主可执行文件没有符号、嵌套里有 → 仍然产出 IOS-NATIVE-SYMBOLS', () {
      final result = _audit(
        main: _withoutSymbols,
        nested: [_nested('Core', _withSymbols)],
      );
      final finding = _nativeSymbols(result);
      expect(finding, isNotNull, reason: '符号只出现在嵌套框架里，此前会被整条丢掉');
      // nm -u 显示这个夹具导入了 system / dlopen / ptrace 等。
      final text = finding!.evidence.map((e) => e.detail).join(' ');
      expect(text, contains('system'));
    });

    test('覆盖表：limit 是尝试解析的镜像数，不是 1', () {
      final result = _audit(
        main: _withoutSymbols,
        nested: [_nested('Core', _withSymbols)],
      );
      final entry = _entry(result, 'ios.nativeSymbols');
      expect(entry.limit, isNotNull, reason: '没有 limit 就看不出只看了 1 个');
      expect(entry.limit, greaterThanOrEqualTo(2),
          reason: '主可执行文件 + 嵌套各至少 1 个镜像');
      expect(entry.covered, lessThanOrEqualTo(entry.limit!));
    });

    test('只有嵌套、没有主可执行文件 → 仍然扫（不因主缺失而全丢）', () {
      final result = _audit(nested: [_nested('Core', _withSymbols)]);
      expect(_nativeSymbols(result), isNotNull);
    });

    test('嵌套条目没有字节（读失败）→ 不参与，也不崩', () {
      final result = _audit(
        main: _withoutSymbols,
        nested: [
          const IosNestedExecutableInput(
            path: '$_bundlePath/Frameworks/Broken.framework/Broken',
            bundlePath: '$_bundlePath/Frameworks/Broken.framework',
            kind: IosBundleKind.framework,
            failure: 'too large to read',
          ),
        ],
      );
      // 主可执行文件仍然被扫过；坏条目只是没贡献符号。
      expect(_entry(result, 'ios.nativeSymbols').limit, 1);
    });
  });

  group('扫描预算：默认 64 MiB，且截断时状态是 partial', () {
    test('小预算下 macho.strings 是 partial，不是 covered', () {
      final result = _audit(
        main: _withoutSymbols,
        scanBudgetBytes: 64, // 比夹具还小 → 必然截断
      );
      expect(
        _entry(result, 'ios.macho.strings').status,
        CoverageStatus.partial,
      );
      expect(
        result.limitations.any((n) => n.code == 'ios.executable.over_budget'),
        isTrue,
        reason: '截断了就必须说出来',
      );
    });

    test('预算足够时是 covered（不再因 16 MiB 上限被误判 partial）', () {
      final result = _audit(main: _withoutSymbols);
      expect(
        _entry(result, 'ios.macho.strings').status,
        CoverageStatus.covered,
        reason: '夹具只有几 KB，默认 64 MiB 预算下不该截断',
      );
    });

    test('预算说明里写的是实际生效的那个值，不是常量', () {
      final result = _audit(main: _withoutSymbols, scanBudgetBytes: 64);
      final note = result.limitations
          .firstWhere((n) => n.code == 'ios.executable.over_budget');
      final text = AnalysisReport.limitationNoteText(note, t);
      expect(text, contains('64'), reason: '要写出真正生效的预算：$text');
      expect(text, isNot(contains('67108864')), reason: '不能把默认常量写死进说明');
    });
  });
}
