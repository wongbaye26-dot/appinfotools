// APK 解析流水线性能探针（**不进质量门禁**，默认 `flutter test` 跑不到它）。
//
// 用法：
//   NO_PROXY=127.0.0.1,localhost,::1 \
//     ~/development/flutter/bin/flutter test tool/perf_probe_apk_test.dart
//
// 样本用环境变量指定，默认指向一个真实的大包：
//   PERF_APK=/path/to/big.apk
//
// 它逐段复刻 `lib/apkparser/parse_task.dart` 的 worker 入口，把每一步的耗时
// 打出来 —— 「解析慢」是个笼统的抱怨，只有拆到阶段才能知道该动哪里。

import 'dart:io';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaultSample = '/Users/wangbaye/Downloads/抖音-v40.7.0.apk';

Future<(T, double)> _timed<T>(Future<T> Function() body) async {
  final sw = Stopwatch()..start();
  final value = await body();
  sw.stop();
  return (value, sw.elapsedMicroseconds / 1000);
}

/// 同步版本 —— 解析里大部分是同步 CPU 计算。
(T, double) _timedSync<T>(T Function() body) {
  final sw = Stopwatch()..start();
  final value = body();
  sw.stop();
  return (value, sw.elapsedMicroseconds / 1000);
}

void main() {
  test('APK 解析各阶段耗时基线', () async {
    final path = Platform.environment['PERF_APK'] ?? _defaultSample;
    final file = File(path);
    if (!file.existsSync()) {
      markTestSkipped('样本 $path 不存在，跳过');
      return;
    }
    final sizeMB = file.lengthSync() / (1024 * 1024);

    final rows = <(String, double)>[];
    final reader = ApkReader();
    try {
      final (openResult, openMs) = await _timed(() => reader.open(path));
      expect(openResult.isOk, isTrue, reason: '样本必须能打开');
      rows.add(('1. 打开归档（中央目录 + 预算 + EOCD）', openMs));

      final (meta, parseMs) = await _timed(() => reader.parse());
      expect(meta, isNotNull);
      rows.add(('2. parse（manifest + arsc + 原生码）', parseMs));

      // 资源表全量遍历 —— 环检测与图标渲染器都用这一份。
      final (arsc, arscMs) =
          _timedSync(() => reader.arscParser?.getAllResources() ?? const {});
      rows.add(('3. 资源表全量遍历（${arsc.length} 项）', arscMs));

      // DEX：listFiles 之后逐个读进内存（安全审计的输入）。
      final (dexNames, dexListMs) =
          _timedSync(() => reader.listFiles(extension: '.dex'));
      rows.add(('4a. 列出 DEX 条目（${dexNames.length} 个）', dexListMs));
      final (dexEntries, dexReadMs) = _timedSync(() {
        final out = <DexBytes>[];
        for (final name in dexNames) {
          final bytes = reader.readFile(name);
          if (bytes != null) out.add(DexBytes(name, bytes));
        }
        return out;
      });
      rows.add(('4b. 读取全部 DEX 字节', dexReadMs));

      // 原生库：先按声明尺寸挑，再读。
      final (selection, soListMs) =
          _timedSync(() => NativeSymbolScanner.selectLibraries(
                reader.listFilesWithSize(extension: '.so'),
              ));
      rows.add(('5a. 挑选原生库（${selection.selected.length} 个）', soListMs));
      final (nativeEntries, soReadMs) = _timedSync(() {
        final out = <NativeLibraryBytes>[];
        for (final name in selection.selected) {
          final bytes = reader.readFile(name);
          if (bytes != null) out.add(NativeLibraryBytes(name, bytes));
        }
        return out;
      });
      rows.add(('5b. 读取选中的原生库字节', soReadMs));

      final (hardening, hardeningMs) =
          _timedSync(() => reader.scanHardeningSignals());
      rows.add(('6. 加固线索扫描', hardeningMs));

      final (_, structureMs) = _timedSync(() => reader.collectStructure());
      rows.add(('7. 容器结构统计', structureMs));

      // ---- 审计内部拆解（这一项在真实大包上占九成以上）----
      final (clueScan, clueMs) =
          _timedSync(() => DexClueScanner.scan(dexEntries));
      rows.add(('8a. 审计·DEX 字符串扫描', clueMs));
      final (structures, structMs) = _timedSync(() => [
            for (final e in dexEntries) DexStructure.read(e.name, e.bytes),
          ]);
      rows.add(('8b. 审计·DEX 结构（${structures.length} 个）', structMs));
      final (methodScan, methodMs) =
          _timedSync(() => DexMethodScanner.scan(dexEntries));
      rows.add(('8c. 审计·方法引用与调用点遍历（现状）', methodMs));

      // 拆开「走一遍字节码」与「每个调用点跑一遍标记匹配」这两件事：
      // 前者是结构遍历的固有成本，后者是可以优化的。
      var refCount = 0;
      final (_, refOnlyMs) = _timedSync(() {
        for (final e in dexEntries) {
          final st = DexStructure.read(e.name, e.bytes);
          if (!st.isTraversable) continue;
          DexMethodTable.forEachReference(e.bytes, st,
              onReference: (_) => refCount++);
        }
      });
      rows.add(('8c-1. 仅遍历 method_ids（$refCount 条）', refOnlyMs));

      var siteCount = 0;
      final (_, walkOnlyMs) = _timedSync(() {
        for (final e in dexEntries) {
          final st = DexStructure.read(e.name, e.bytes);
          if (!st.isTraversable) continue;
          DexMethodBodies.walk(e.bytes, st, onCallSite: (_) => siteCount++);
        }
      });
      rows.add(('8c-2. 仅遍历调用点（$siteCount 个）', walkOnlyMs));
      final (_, nativeMs) =
          _timedSync(() => NativeSymbolScanner.scan(nativeEntries));
      rows.add(('8d. 审计·原生符号扫描', nativeMs));

      final (_, auditMs) = _timedSync(() => AndroidSecurityAudit.audit(
            meta: meta!,
            dexEntries: dexEntries,
            containerAnomalies: [
              for (final obs in hardening) obs.evidence,
              if (reader.structureAnomaly case final anomaly?) anomaly,
            ],
            nativeEntries: nativeEntries,
          ));
      rows.add(('8. 安全审计（DEX + 原生符号）', auditMs));

      final (_, cyclesMs) =
          _timedSync(() => ResourceReferenceGraph.findCycles(arsc));
      rows.add(('9. 资源引用环检测', cyclesMs));

      expect(clueScan.scannedBytes, greaterThanOrEqualTo(0));
      // ---- 端到端：与 `_parseEntryPoint` 完全同序地跑一遍 ----
      //
      // 上面那张表是逐段计时（8a–8d 落在 8 里面，相加会重复计算），
      // **这一个数才是「打开一个包要等多久」**。
      reader.close();
      final e2eReader = ApkReader();
      final (_, e2eMs) = await _timed(() async {
        await e2eReader.open(path);
        final m = await e2eReader.parse();
        final dex = <DexBytes>[
          for (final n in e2eReader.listFiles(extension: '.dex'))
            if (e2eReader.readFile(n) case final b?) DexBytes(n, b),
        ];
        final arscRes = e2eReader.arscParser?.getAllResources() ??
            const <int, ResourceInfo>{};
        final sel = NativeSymbolScanner.selectLibraries(
          e2eReader.listFilesWithSize(extension: '.so'),
        );
        final native = <NativeLibraryBytes>[
          for (final n in sel.selected)
            if (e2eReader.readFile(n) case final b?) NativeLibraryBytes(n, b),
        ];
        final hardening = e2eReader.scanHardeningSignals();
        AndroidSecurityAudit.audit(
          meta: m!,
          dexEntries: dex,
          containerAnomalies: [
            for (final o in hardening) o.evidence,
            if (e2eReader.structureAnomaly case final a?) a,
          ],
          nativeEntries: native,
        );
        e2eReader.collectStructure();
        ResourceReferenceGraph.findCycles(arscRes);
      });
      e2eReader.close();
      rows.add(('★ 端到端（open → 审计 → 环检测）', e2eMs));

      final buffer = StringBuffer()
        ..writeln('')
        ..writeln('样本 ${path.split('/').last}（${sizeMB.toStringAsFixed(1)} MB）')
        ..writeln('-' * 56);
      for (final (label, ms) in rows) {
        final value =
            ms < 0 ? '${(-ms).toInt()} 个' : '${ms.toStringAsFixed(1)} ms';
        buffer.writeln('${label.padRight(42)} $value');
      }
      buffer.writeln('-' * 56);
      // ignore: avoid_print
      print(buffer.toString());
    } finally {
      reader.close();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
