// DEX 字符串线索扫描器测试（V1.1 规格 3.3 / 3.4 第一层取证）。
//
// 这里测的是**取证质量**而不是「能匹配到」：证据原文要能指回文件、
// 预算截断要如实记录、覆盖不足不许悄悄发生。样本是手工构造的字节串 ——
// 没有工具会产出「只含这些字符串的 DEX」，而这里要断言的正是提取与匹配
// 本身；真实 DEX 的结构由 manifest 夹具与真实样本测试另行覆盖。

import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把若干字符串用 NUL 分隔拼成「类 DEX」字节。
Uint8List _blob(List<String> strings) {
  final parts = <int>[];
  for (final s in strings) {
    parts.addAll(s.codeUnits);
    parts.add(0);
  }
  return Uint8List.fromList(parts);
}

void main() {
  group('DexClueScanner — 标记匹配', () {
    test('OCR / 上传 / 网络 / 后台标记分别命中并带证据', () {
      final result = DexClueScanner.scan([
        DexBytes(
            'classes.dex',
            _blob([
              'Lcom/google/mlkit/vision/text;',
              'okhttp3.RequestBody',
              'multipart/form-data',
              'androidx.work.WorkManager',
              'https://cdn.example.com/api/upload',
              'short',
              'ab',
            ])),
      ]);

      expect(result.hasClue('ocr-mlkit'), isTrue);
      expect(result.hasClue('multipart'), isTrue);
      expect(result.hasClue('okhttp'), isTrue);
      expect(result.hasClue('workmanager'), isTrue);
      expect(result.scannedDexCount, 1);

      final ocr = result.clues.firstWhere((c) => c.markerId == 'ocr-mlkit');
      expect(ocr.samples, contains('Lcom/google/mlkit/vision/text;'));
      expect(ocr.dexNames, ['classes.dex']);
      // 太短的串不提取（minStringLength=6）。
      expect(ocr.samples.any((s) => s == 'ab' || s == 'short'), isFalse);
    });

    test('域名与 IP 被提取，且不含二进制噪声', () {
      final result = DexClueScanner.scan([
        DexBytes(
            'classes.dex',
            _blob([
              'https://api.example.com/v1/upload',
              'http://10.0.0.7:8080/callback',
              'sub.domain.org.cn',
              'abcdefghij',
            ])),
      ]);

      expect(result.domains, contains('api.example.com'));
      expect(result.ips, contains('10.0.0.7'));
      expect(result.domains, contains('sub.domain.org.cn'));
      // 随机英文串不是域名。
      expect(result.domains, isNot(contains('abcdefghij')));
    });

    test('多条 DEX 分别记录来源文件', () {
      final result = DexClueScanner.scan([
        DexBytes('classes.dex', _blob(['Lcom/google/mlkit/vision/text;'])),
        DexBytes('classes2.dex', _blob(['okhttp3.OkHttpClient'])),
      ]);
      expect(result.scannedDexCount, 2);
      expect(
        result.clues.firstWhere((c) => c.markerId == 'okhttp').dexNames,
        ['classes2.dex'],
      );
    });
  });

  group('DexClueScanner — 预算与边界', () {
    test('空输入返回空结果而不是抛异常', () {
      final result = DexClueScanner.scan(const []);
      expect(result.clues, isEmpty);
      expect(result.domains, isEmpty);
      expect(result.scannedDexCount, 0);
    });

    test('超过单文件预算的 DEX 记为部分扫描，不静默少扫', () {
      // 8 MiB 预算：前面填一个超长的不可打印前缀，后面放真实标记。
      final head = Uint8List(DexClueScanner.maxBytesPerDex + 16);
      final tail = _blob(['Lcom/google/mlkit/vision/text;']);
      final bytes = Uint8List.fromList([...head, ...tail]);

      final result = DexClueScanner.scan([DexBytes('classes.dex', bytes)]);

      expect(result.skippedForBudget, isNotEmpty);
      // 结构化记录：名字、扫了多少、文件多大、覆盖百分比。
      // 界面按语言拼句子，所以这几个数必须分开给，不能只给一句英文。
      final skip = result.skippedForBudget.first;
      expect(skip.name, 'classes.dex');
      expect(skip.scannedBytes, DexClueScanner.maxBytesPerDex);
      expect(skip.totalBytes, bytes.length);
      expect(skip.percent, lessThan(100));
      // 截断之外的标记扫不到 —— 这正是不许悄悄少扫的原因。
      expect(result.hasClue('ocr-mlkit'), isFalse);
    });

    test('总预算达到后剩余 DEX 记为跳过', () {
      // 8 个 8 MiB 文件：每个都在单文件预算内（整扫），前 6 个填满
      // 48 MiB 总预算，后 2 个必须被记为跳过。
      final bytes = Uint8List(8 * 1024 * 1024);
      final entries = [
        for (var i = 0; i < 8; i++) DexBytes('classes$i.dex', bytes),
      ];
      final result = DexClueScanner.scan(entries);
      expect(result.scannedDexCount, 6);
      expect(result.skippedForBudget.length, 2);
      // 整份没扫时 `scannedBytes` 为 0（区别于「只扫了一部分」）。
      expect(result.skippedForBudget.first.scannedBytes, 0);
      expect(result.skippedForBudget.first.percent, 0);
    });

    test('纯二进制内容不产生虚假线索', () {
      final noise = Uint8List(4096);
      for (var i = 0; i < noise.length; i++) {
        noise[i] = i % 256;
      }
      final result = DexClueScanner.scan([DexBytes('classes.dex', noise)]);
      expect(result.clues, isEmpty);
    });
  });
}
