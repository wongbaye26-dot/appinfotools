// DEX 方法引用扫描（安全分析第二层）。
//
// 这一层的全部意义是**把「代码引用了」与「字符串里提到了」分开**。样本
// `real-netprobe.dex` 刻意做成两者分离：
// - `okhttp3` 只出现在一个字符串字面量里（`dexdump -s` 的 string[000024]）
// - `java.net.HttpURLConnection` 出现在 `method_ids` 里（`dexdump -d` 的
//   `invoke-virtual … getInputStream` 行）
//
// 期望值来自 `dexdump`，不是从本项目解析器取的。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const String _fixtureDir = 'test/fixtures/dex';

Uint8List _bytes(String name) => File('$_fixtureDir/$name').readAsBytesSync();

DexMethodScanResult _scan(String name) =>
    DexMethodScanner.scan([DexBytes(name, _bytes(name))]);

void main() {
  group('真实 DEX：代码引用命中', () {
    test('HttpURLConnection 在 method_ids 里被找到', () {
      final result = _scan('real-netprobe.dex');

      expect(result.scannedDexCount, 1);
      expect(result.notTraversable, isEmpty);

      final http = result.reference('httpurlconnection');
      expect(
        http,
        isNotNull,
        reason:
            'dexdump -d 显示 invoke-virtual … HttpURLConnection.getInputStream',
      );
      expect(http!.category, SecurityCategory.network);
      expect(
        http.samples.any((s) => s.contains('HttpURLConnection')),
        isTrue,
        reason: '证据要带上是哪条引用：${http.samples}',
      );
    });

    test('okhttp3 只在字符串里，方法引用里一条都没有', () {
      final bytes = _bytes('real-netprobe.dex');

      // 第一层（字符串）会命中。
      final clues = DexClueScanner.scan([DexBytes('classes.dex', bytes)]);
      expect(clues.clues.any((c) => c.markerId == 'okhttp'), isTrue);

      // 第二层（代码引用）不该命中 —— 这正是这一层存在的理由。
      final result = DexMethodScanner.scan([DexBytes('classes.dex', bytes)]);
      expect(
        result.hasReference('okhttp'),
        isFalse,
        reason: '实际命中：${result.references.map((r) => r.markerId).toList()}',
      );
    });

    test('multipart/form-data 只可能是字符串（它是请求头的取值）', () {
      final result = _scan('real-netprobe.dex');

      expect(
        result.hasReference('multipart'),
        isFalse,
        reason: 'multipart/form-data 是 HTTP 头的值，不会成为 method_ids 条目',
      );
    });
  });

  group('覆盖范围必须如实记录', () {
    test('非 DEX 字节不产生引用，并进入 notTraversable', () {
      final result = DexMethodScanner.scan([
        DexBytes('classes.dex', Uint8List.fromList(List.filled(64, 0x41))),
      ]);

      expect(result.references, isEmpty);
      expect(result.scannedDexCount, 0);
      expect(result.notTraversable, ['classes.dex']);
    });

    test('结构畸形的 DEX 同样进入 notTraversable', () {
      final result = _scan('bad-magic.dex');

      expect(result.references, isEmpty);
      expect(result.notTraversable, ['bad-magic.dex']);
    });

    test('一个文件坏了不影响另一个被分析', () {
      final result = DexMethodScanner.scan([
        DexBytes('classes.dex', _bytes('bad-magic.dex')),
        DexBytes('classes2.dex', _bytes('real-netprobe.dex')),
      ]);

      expect(result.scannedDexCount, 1);
      expect(result.notTraversable, ['classes.dex']);
      expect(result.hasReference('httpurlconnection'), isTrue);
      // 命中的那条应当只归到被成功分析的文件上。
      expect(
        result.reference('httpurlconnection')!.dexNames,
        ['classes2.dex'],
      );
    });

    test('解析不出来的条目单独计数，不静默跳过', () {
      // 真实样本上应当一个都没有。
      final result = _scan('real-netprobe.dex');
      expect(result.skippedEntries, 0);
    });
  });

  // 第三层：调用点。`method_ids` 只说「引用存在」，`code_item` 里的 invoke
  // 指令才说明「真的有一条调用指令，在哪个方法的哪个偏移上」。
  group('调用点（第三层）', () {
    test('HttpURLConnection 的两条调用指令都被找到，并带上调用者', () {
      final result = _scan('real-netprobe.dex');

      final http = result.reference('httpurlconnection');
      expect(http, isNotNull);
      expect(
        http!.hasCallSite,
        isTrue,
        reason:
            'dexdump -d 里 NetProbe.open 有 setRequestMethod 与 getInputStream '
            '两条 invoke-virtual',
      );
      expect(http.callSiteCount, 2);
      expect(
        http.callSiteSamples.any(
            (s) => s.contains('getInputStream') && s.contains('NetProbe;.open')),
        isTrue,
        reason: '证据要能回答「在哪个方法里」：${http.callSiteSamples}',
      );
      expect(
        http.callSiteSamples.any((s) => s.contains('+0x10')),
        isTrue,
        reason: '还要能回答「在什么偏移上」',
      );
    });

    test('总调用指令数与 dexdump -d 一致（7 条）', () {
      final result = _scan('real-netprobe.dex');

      expect(result.callSiteCount, 7);
      expect(result.invokeCustomCount, 0);
      expect(result.walkedDexCount, 1);
    });

    test('遍历全部同步，没有方法体错位', () {
      for (final name in const [
        'real-netprobe.dex',
        'real-opcodes.dex',
        'real-cooccurrence.dex',
      ]) {
        final result = _scan(name);
        expect(
          result.desyncedBodies,
          isEmpty,
          reason: '$name 的方法体应当都能正好走到末尾：${result.desyncedBodies}',
        );
      }
    });

    test('invoke-custom 单独计数，不算进调用点', () {
      // 三个真实夹具里都没有 invoke-custom。
      for (final name in const [
        'real-netprobe.dex',
        'real-opcodes.dex',
        'real-cooccurrence.dex',
      ]) {
        final result = _scan(name);
        expect(result.invokeCustomCount, 0, reason: name);
      }
    });
  });

  group('同方法内同现', () {
    test('Pipeline.run 里同时出现识别与上传的调用', () {
      final result = _scan('real-cooccurrence.dex');

      final occurrence = result.firstCoOccurrenceAcross(
        ['ocr-recognizetext'],
        ['uploadimage'],
      );
      expect(
        occurrence,
        isNotNull,
        reason: 'dexdump -d 显示 recognizeText 在 0x254、uploadImage 在 0x25a，'
            '相邻且同属 Pipeline.run。实际同现：${result.coOccurrences}',
      );
      expect(occurrence!.callerDisplayName, contains('Pipeline'));
      expect(occurrence.callerDisplayName, contains('run'));
      expect(occurrence.markerIds,
          containsAll(['ocr-recognizetext', 'uploadimage']));
    });

    test('只有识别、没有上传的方法不会被报成同现', () {
      final result = _scan('real-cooccurrence.dex');

      expect(
        result.coOccurrences
            .any((c) => c.callerDisplayName.contains('onlyOcr')),
        isFalse,
        reason: '只命中一个标记的方法不是同现：${result.coOccurrences}',
      );
    });

    test('同现记录只保留命中两个以上标记的方法', () {
      final result = _scan('real-cooccurrence.dex');

      for (final occurrence in result.coOccurrences) {
        expect(
          occurrence.markerIds.length,
          greaterThanOrEqualTo(2),
          reason: '单个标记不是同现',
        );
      }
    });

    test('没有同现时查询返回 null，而不是抛异常', () {
      final result = _scan('real-netprobe.dex');

      expect(
        result.firstCoOccurrenceAcross(['ocr-recognizetext'], ['uploadimage']),
        isNull,
      );
      expect(result.coOccurInSameMethod(['ocr-recognizetext']), isFalse);
    });
  });

  group('匹配规则', () {
    test('标记表与字符串扫描器共用同一份（不会两边漂移）', () {
      // 同一个标记 id 在两个扫描器里必须指向同一类别与同一说明。
      for (final marker in codeMarkers) {
        // 两侧都要能从同一段文本里命中。补足到最短字符串长度以上 ——
        // 字符串扫描器会丢掉 `OCR` 这种短于 6 字符的串，那是它的预算策略，
        // 不是标记表的问题。
        final text = 'prefix-${marker.literal}-suffix';
        final inStringScan = DexClueScanner.scan([
          DexBytes('classes.dex', Uint8List.fromList(text.codeUnits)),
        ]).clues;
        expect(
          inStringScan.any((c) => c.markerId == marker.id),
          isTrue,
          reason: '字面量 `${marker.literal}` 应当能命中标记 ${marker.id}',
        );
        // 方法引用侧用同样的匹配函数，因此同样应当命中。
        expect(
          matchCodeMarkers(text).any((m) => m.id == marker.id),
          isTrue,
        );
      }
    });

    test('样本条数有上限', () {
      final result = _scan('real-netprobe.dex');
      for (final reference in result.references) {
        expect(
          reference.samples.length,
          lessThanOrEqualTo(DexMethodScanner.maxSamplesPerMarker),
        );
      }
    });

    test('结果按类别与 id 稳定排序（报告输出可复现）', () {
      final result = _scan('real-netprobe.dex');
      final keys = [
        for (final r in result.references) '${r.category.name}/${r.markerId}',
      ];
      expect(keys, equals([...keys]..sort()));
    });
  });
}
