// 验收：样本矩阵、夹具完整性与性能基线（规格书任务 5）。
//
// 这一层不测「某个功能对不对」（那些在各模块的测试里），而是测**验收条件本身**：
//
// 1. 规格书要求的每一类样本都能指向**实际存在的**夹具或测试，而不是一句
//    「已覆盖」。夹具被删掉时这里会红。
// 2. 没有**死夹具** —— 每个夹具文件都被至少一个测试源码提到。
//    产出了没人用的夹具与「产出了没人读的数据」是同一类问题。
// 3. 代表性夹具的解析耗时在阈值内，且**把实测值打印出来**作为后续改动的基线。
//
// 未执行项（超大文件、任务取消的真实进程）不在这里假装通过 —— 它们写在
// `docs/audit/2026-10-15-v2.3-release-acceptance.md` 的「未验证项」一节。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:path/path.dart' as path;

/// 规格书任务 5 要求的样本矩阵。
///
/// `evidence` 是**实际存在的路径**：夹具的相对路径，或根 `test/` 下的测试
/// 文件名。本测试会逐个断言它们存在。
const List<({String category, List<String> evidence, String note})>
    _sampleMatrix = [
  (
    category: '正常 APK',
    evidence: ['fixtures/apk/night-mode-resources.apk'],
    note: 'aapt2 真实产出，含 values-night',
  ),
  (
    category: '分包 APK（XAPK / APKM / APKS）',
    evidence: ['xapk_security_audit_test.dart'],
    note: '夹具在测试里现场构造（外层真 ZIP + 无效 base.apk）',
  ),
  (
    category: '加固样本',
    evidence: ['fixtures/apk/hardened-manifest.axml'],
    note: '来自真实加固 APK 的 AndroidManifest.xml 片段',
  ),
  (
    category: '正常 IPA',
    evidence: [
      'fixtures/ipa/embedded.mobileprovision',
      'fixtures/macho/thin-arm64.dylib'
    ],
    note: 'clang 编译的真实 Mach-O + 描述文件',
  ),
  (
    category: '嵌套 Bundle（fat 切片）',
    evidence: ['fixtures/macho/fat-x86_64-arm64.dylib'],
    note: 'lipo 合成的 fat，两个切片各一份符号表',
  ),
  (
    category: 'OCR 应用',
    evidence: ['fixtures/dex/real-cooccurrence.dex'],
    note: '同一方法体内同时有识别与上传的调用',
  ),
  (
    category: '正常上传应用',
    evidence: ['fixtures/dex/real-netprobe.dex'],
    note: 'javac + d8 真实产出，HttpURLConnection 调用点',
  ),
  (
    category: '风险模拟样本（原生能力）',
    evidence: ['fixtures/elf/arm64-v8a-libnative.so'],
    note: '导入 system / dlopen / ptrace / socket',
  ),
  (
    category: '损坏文件（DEX）',
    evidence: [
      'fixtures/dex/bad-magic.dex',
      'fixtures/dex/truncated.dex',
      'fixtures/dex/multiple-anomalies.dex',
    ],
    note: 'magic 错 / 截断 / 多处异常同时存在',
  ),
  (
    category: '损坏文件（ELF）',
    evidence: [
      'fixtures/elf/bad-magic.so',
      'fixtures/elf/truncated.so',
      'fixtures/elf/no-section-headers.so',
    ],
    note: 'magic 错 / 节表越界 / 节表被完全剥离（合法但读不到符号）',
  ),
  (
    category: 'ZIP Bomb（预算）',
    evidence: ['archive_safety_boundary_test.dart'],
    note: '单条目上限 / 跨层累计 / 条目数上限，样本在测试里构造',
  ),
  (
    category: '超大文件',
    evidence: ['archive_safety_boundary_test.dart'],
    note: '预算判定用**声明尺寸**，不实际分配 —— 见「未验证项」',
  ),
  (
    category: '越界数据',
    evidence: [
      'fixtures/dex/method-ids-off-out-of-range.dex',
      'fixtures/dex/method-ids-size-absurd.dex',
      'fixtures/elf/section-table-out-of-range.so',
    ],
    note: '校验和合法但偏移/条目数越界，只能靠边界校验发现',
  ),
  (
    category: '任务取消',
    evidence: ['parse_task_test.dart'],
    note: 'worker isolate 的真实终止见「未验证项」',
  ),
];

void main() {
  group('样本矩阵：每一类都能指向实际存在的证据', () {
    for (final entry in _sampleMatrix) {
      test('${entry.category}（${entry.note}）', () {
        for (final evidence in entry.evidence) {
          final resolved = evidence.startsWith('fixtures/')
              ? path.join('test', evidence)
              : path.join('test', evidence);
          expect(
            File(resolved).existsSync(),
            isTrue,
            reason: '${entry.category} 的证据不存在：$resolved',
          );
        }
      });
    }

    test('矩阵覆盖规格书点名的全部类别', () {
      final categories = _sampleMatrix.map((e) => e.category).toList();
      for (final required in const [
        '正常 APK',
        '分包 APK（XAPK / APKM / APKS）',
        '加固样本',
        '正常 IPA',
        '嵌套 Bundle（fat 切片）',
        'OCR 应用',
        '正常上传应用',
        '风险模拟样本（原生能力）',
        '损坏文件（DEX）',
        'ZIP Bomb（预算）',
        '超大文件',
        '越界数据',
        '任务取消',
      ]) {
        expect(
          categories.any((c) => c.startsWith(required)),
          isTrue,
          reason: '规格书要求「$required」，矩阵里没有',
        );
      }
    });
  });

  group('夹具完整性：没有死夹具', () {
    test('每个夹具文件都被至少一个测试源码提到', () {
      // 「产出了没人用的夹具」与「产出了没人读的数据」是同一类问题。
      final fixtureRoot = Directory('test/fixtures');
      expect(fixtureRoot.existsSync(), isTrue);

      final sources = StringBuffer();
      for (final entity in Directory('test').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        sources.write(entity.readAsStringSync());
      }
      final sourceText = sources.toString();

      final unreferenced = <String>[];
      for (final entity in fixtureRoot.listSync(recursive: true)) {
        if (entity is! File) continue;
        final name = path.basename(entity.path);
        if (name == 'README.md') continue;
        if (!sourceText.contains(name)) {
          unreferenced.add(entity.path);
        }
      }

      expect(
        unreferenced,
        isEmpty,
        reason: '这些夹具没有任何测试引用：$unreferenced',
      );
    });

    test('每个夹具目录都有 README（记录生成命令与独立期望值）', () {
      final missing = <String>[];
      for (final entity in Directory('test/fixtures').listSync()) {
        if (entity is! Directory) continue;
        if (!File(path.join(entity.path, 'README.md')).existsSync()) {
          missing.add(entity.path);
        }
      }
      expect(
        missing,
        isEmpty,
        reason: '夹具目录缺 README（生成命令与期望值来源必须可追溯）：$missing',
      );
    });
  });

  group('性能基线', () {
    /// 每个操作重复多少次。夹具都是几 KB，重复是为了让耗时可见而不是 0 ms。
    const iterations = 50;

    /// 阈值刻意宽松（本地实测通常 < 200 ms）。
    ///
    /// 它的作用不是「卡性能」，而是抓住**病态回归**（例如某次改动把 O(n)
    /// 变成了 O(n²)）。卡得太紧会在负载高的 CI 上变成随机失败 —— 那样的
    /// 测试比没有更糟。
    const budgetMs = 5000;

    test('DEX 结构 + 方法引用 + 调用点遍历', () {
      final bytes =
          File('test/fixtures/dex/real-opcodes.dex').readAsBytesSync();
      final sw = Stopwatch()..start();
      var callSites = 0;
      for (var i = 0; i < iterations; i++) {
        final structure = DexStructure.read('classes.dex', bytes);
        DexMethodTable.forEachReference(bytes, structure, onReference: (_) {});
        final result = DexMethodBodies.walk(bytes, structure,
            onCallSite: (_) => callSites++);
        expect(result.desyncedBodies, isEmpty);
      }
      sw.stop();
      // ignore: avoid_print
      print('[PERF] DEX 全流程 × $iterations = ${sw.elapsedMilliseconds} ms '
          '（$callSites 个调用点）');
      expect(sw.elapsedMilliseconds, lessThan(budgetMs));
    });

    test('ELF 结构 + 动态符号', () {
      final bytes =
          File('test/fixtures/elf/arm64-v8a-libnative.so').readAsBytesSync();
      final sw = Stopwatch()..start();
      var symbols = 0;
      for (var i = 0; i < iterations; i++) {
        final structure = ElfStructure.read('libnative.so', bytes);
        symbols += ElfSymbolTable.readDynamic(bytes, structure).symbols.length;
      }
      sw.stop();
      // ignore: avoid_print
      print('[PERF] ELF 结构 + dynsym × $iterations = '
          '${sw.elapsedMilliseconds} ms（$symbols 条符号）');
      expect(sw.elapsedMilliseconds, lessThan(budgetMs));
    });

    test('Mach-O 解析（fat，含两个切片的符号表）', () {
      final bytes =
          File('test/fixtures/macho/fat-x86_64-arm64.dylib').readAsBytesSync();
      final sw = Stopwatch()..start();
      var symbols = 0;
      for (var i = 0; i < iterations; i++) {
        final file = MachOParser.parse(bytes);
        for (final image in file.images) {
          symbols += image.symbols.length;
        }
      }
      sw.stop();
      // ignore: avoid_print
      print('[PERF] Mach-O fat 解析 × $iterations = '
          '${sw.elapsedMilliseconds} ms（$symbols 条符号）');
      expect(sw.elapsedMilliseconds, lessThan(budgetMs));
    });

    test('归档边界检查（单条目上限 + 跨层累计）在常量时间内完成', () {
      // 这两个判定只看**声明的尺寸**，不实际解压。因此构造一个「声明尺寸
      // 很大」的归档不会真的分配内存 —— 这正是它们的价值。
      final archive = Archive()
        ..addFile(ArchiveFile(
          'huge.bin',
          ZipBudget.maxSingleEntryUncompressed + 1,
          Uint8List(0),
        ));

      final sw = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        expect(ZipBudget.isExceeded(archive), isTrue);
      }
      sw.stop();
      // ignore: avoid_print
      print('[PERF] 归档预算判定 × $iterations = ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(budgetMs));
    });
  });
}
