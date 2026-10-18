// 覆盖率口径的**诚实性**测试（审计报告 P1-1 / P1-2 / P3-3）。
//
// ## 为什么这两条比新规则更重要
//
// 一份报告说「原生库已覆盖 24/24」，而实际包里 266 个唯一库只看了 24 个 ——
// 这不是「能力不足」，是**让读者高估了扫描量**。用户据此判断「原生层没问题」，
// 而 242 个库根本没被打开过。
//
// 同理，`android.dex.strings` 只有 `covered` 没有 `limit` 时，界面显示
// 「已扫描 50,648,616 字节」—— 没人能从这个数字看出那是 437 MiB 的 11%。
//
// 本文件钉住三件事：
// 1. `android.nativeSymbols` 的 `limit` 是**全包唯一库名数**，不是「选中数」；
// 2. 被 `selectLibraries` 跳过的库必须进 `limitations`（否则读者完全看不到）；
// 3. `android.dex.strings` 的 `limit` 是 DEX 总字节，能算出比例。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ApkMeta _meta() => ApkMeta()
  ..permissionRequests = const []
  ..permissions = const []
  ..components = const [];

/// 造一个「有内容的 DEX」：字符串线索扫描需要字节，审计本身不看内容。
DexBytes _dex(String name, int size) =>
    DexBytes(name, Uint8List(size)..fillRange(0, size, 0x41));

/// 真实的 ELF 夹具 —— **必须用真产物**：随便填 64 个零字节不是合法 ELF，
/// 符号扫描会把它记成「不可遍历」，`covered` 就是 0，测不到覆盖率口径。
final Uint8List _realSo =
    File('test/fixtures/elf/arm64-v8a-libnative.so').readAsBytesSync();

CoverageEntry _entry(SecurityAnalysisResult r, String id) =>
    r.coverage.entries.firstWhere((e) => e.id == id);

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('原生库覆盖：limit 必须是全包唯一库名数', () {
    test('传了 nativeLibraryTotal：limit 用它，不是选中数', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [_dex('classes.dex', 1024)],
        // 只扫了 2 个，但包里一共有 266 个唯一库。
        nativeEntries: [
          NativeLibraryBytes('lib/arm64-v8a/liba.so', _realSo),
          NativeLibraryBytes('lib/arm64-v8a/libb.so', _realSo),
        ],
        nativeLibraryTotal: 266,
        nativeSkipped: const ['lib/arm64-v8a/libc.so', 'lib/arm64-v8a/libd.so'],
      );

      final entry = _entry(result, 'android.nativeSymbols');
      expect(entry.covered, 2);
      expect(entry.limit, 266, reason: 'limit 是「包里有几个」，不是「传进来几个」');
      expect(
        entry.status,
        CoverageStatus.partial,
        reason: '264 个库没扫过，不能标 covered',
      );
    });

    test('被跳过的库必须进未覆盖说明，且带数量', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [_dex('classes.dex', 1024)],
        nativeEntries: [
          NativeLibraryBytes('lib/arm64-v8a/liba.so', _realSo),
        ],
        nativeLibraryTotal: 3,
        nativeSkipped: const ['lib/arm64-v8a/libb.so', 'lib/arm64-v8a/libc.so'],
      );

      final note = result.limitations
          .where((n) => n.code == 'android.native_symbols.not_scanned')
          .toList();
      expect(note, hasLength(1), reason: '跳过 2 个库却没有任何说明，等于隐瞒');
      expect(note.single.args['count'], 2);
    });

    test('没有跳过时不产生这条说明（不制造假缺口）', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [_dex('classes.dex', 1024)],
        nativeEntries: [
          NativeLibraryBytes('lib/arm64-v8a/liba.so', _realSo),
        ],
        nativeLibraryTotal: 1,
      );
      expect(
        result.limitations
            .where((n) => n.code == 'android.native_symbols.not_scanned'),
        isEmpty,
      );
      expect(_entry(result, 'android.nativeSymbols').status,
          CoverageStatus.covered);
    });

    test('不传 nativeLibraryTotal 时退回旧行为（不编造总数）', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [_dex('classes.dex', 1024)],
        nativeEntries: [
          NativeLibraryBytes('lib/arm64-v8a/liba.so', _realSo),
          NativeLibraryBytes('lib/arm64-v8a/libb.so', _realSo),
        ],
      );
      final entry = _entry(result, 'android.nativeSymbols');
      expect(entry.covered, 2);
      expect(entry.limit, 2);
    });
  });

  group('字符串扫描：limit 必须是 DEX 总字节', () {
    test('limit = 所有 DEX 的字节数之和，能算出比例', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [
          _dex('classes.dex', 100 * 1024),
          _dex('classes2.dex', 300 * 1024),
        ],
      );

      final entry = _entry(result, 'android.dex.strings');
      expect(entry.limit, 400 * 1024, reason: '总字节 = 100 KiB + 300 KiB');
      expect(
        entry.covered,
        lessThanOrEqualTo(entry.limit!),
        reason: '扫描量不可能超过总量',
      );
    });

    test('没有 DEX 时 limit 为 null（而不是 0）', () {
      final result = AndroidSecurityAudit.audit(meta: _meta(), dexEntries: []);
      expect(_entry(result, 'android.dex.strings').limit, isNull);
    });
  });

  group('这条说明必须本地化（不能静默回退英文）', () {
    test('中文界面下「未扫描」说明是中文，且带数量', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [_dex('classes.dex', 1024)],
        nativeEntries: [
          NativeLibraryBytes('lib/arm64-v8a/liba.so', _realSo),
        ],
        nativeLibraryTotal: 3,
        nativeSkipped: const ['lib/arm64-v8a/libb.so', 'lib/arm64-v8a/libc.so'],
      );

      final note = result.limitations
          .firstWhere((n) => n.code == 'android.native_symbols.not_scanned');
      final text = AnalysisReport.limitationNoteText(note, t);

      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue,
          reason: '中文界面下不能显示英文回退：$text');
      expect(text, contains('2'), reason: '数量要出现在句子里');
      expect(text, isNot(contains('{count}')), reason: '占位符必须被替换，不能原样渲染');
      expect(text, isNot(contains('**')), reason: '界面是纯 Text，不能有 Markdown');
    });
  });

  group('唯一库名计数', () {
    test('同一个库的不同 ABI 只算一个', () {
      final count = NativeSymbolScanner.uniqueLibraryCount(const [
        (name: 'lib/arm64-v8a/liba.so', size: 10),
        (name: 'lib/armeabi-v7a/liba.so', size: 10),
        (name: 'lib/arm64-v8a/libb.so', size: 10),
      ]);
      expect(count, 2);
    });

    test('空列表是 0', () {
      expect(NativeSymbolScanner.uniqueLibraryCount(const []), 0);
    });
  });
}
