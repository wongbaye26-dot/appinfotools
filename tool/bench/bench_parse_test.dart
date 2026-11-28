// 解析性能基准：同一批夹具、同一段代码，量「耗时」与「进程峰值 RSS」。
//
// 为什么是 test 而不是纯 dart 脚本：`getApkInfo` 依赖 `dart:ui`（图标解码），
// 只能在 flutter_tester 里跑。用 `flutter test` 直接指定本文件即可：
//
//   BENCH_FILES=a.apk:b.xapk flutter test tool/bench/bench_parse_test.dart
//
// 输出每行一个 JSON，便于两个版本各跑一次后做对比。
//
// 口径：
// - 每文件先热身 2 次（让 JIT、OS 页缓存、资源表解码稳定），再计时 7 次取中位数；
// - 峰值内存取 `ProcessInfo.maxRss`（KB，进程级、单调），所以同一进程内
//   多个文件的后一个数字包含前一个的峰值 —— 对比两个版本时应在各自进程里
//   用同一顺序跑，或只比较最后一个文件的数字；
// - 不安装 aapt2 / apksigner，走内置解析器，避免外部进程把噪声带进来。

import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:flutter_test/flutter_test.dart';

const _warmupRuns = 2;
const _timedRuns = 7;

String _median(List<int> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2].toString();
}

void main() {
  final raw = Platform.environment['BENCH_FILES'] ?? '';
  final files = raw.isEmpty
      ? const [
          'test/fixtures/apk/signed-v2-v3.apk',
          'test/fixtures/xapk/xapk-fixture.xapk',
        ]
      : raw.split(':');

  test('解析耗时与峰值 RSS', () async {
    final out = StringBuffer();
    for (final file in files) {
      final parsed = await getApkInfo(file);
      expect(parsed, isNotNull, reason: '$file 应当能被内置解析器解析');

      for (var i = 0; i < _warmupRuns; i++) {
        await getApkInfo(file);
      }

      final rssBefore = ProcessInfo.currentRss;
      final samples = <int>[];
      for (var i = 0; i < _timedRuns; i++) {
        final sw = Stopwatch()..start();
        await getApkInfo(file);
        sw.stop();
        samples.add(sw.elapsedMilliseconds);
      }

      final line = jsonEncode({
        'file': file,
        'median_ms': int.parse(_median(samples)),
        'min_ms': samples.reduce((a, b) => a < b ? a : b),
        'max_ms': samples.reduce((a, b) => a > b ? a : b),
        'max_rss': ProcessInfo.maxRss,
        'rss_before': rssBefore,
        'rss_after': ProcessInfo.currentRss,
      });
      out.writeln(line);
      stdout.writeln(line);
    }

    final target = Platform.environment['BENCH_OUT'];
    if (target != null && target.isNotEmpty) {
      File(target).writeAsStringSync(out.toString());
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
