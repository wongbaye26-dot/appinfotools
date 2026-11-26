// 端到端「打开一个包要等多久」探针（**不进质量门禁**）。
//
// 与 `perf_probe_apk_test.dart` 的分工：
// - 那个拆的是 **worker 内部**各段（纯解析引擎）；
// - 这个测的是**用户实际等待**：`getApkInfo` 全链路 + 三条并行线
//   （哈希 / 签名 / 图标）—— 平台差异（进程启动、文件 IO、Defender 扫描）
//   恰恰出现在这些地方，而不在纯 Dart 计算里。
//
// 用法：
//   NO_PROXY=127.0.0.1,localhost,::1 \
//     PERF_APK=/path/to/big.apk \
//     ~/development/flutter/bin/flutter test tool/perf_probe_getapk_test.dart

import 'dart:io';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

const _defaultSample = '/Users/wangbaye/Downloads/217_0919155004.apk';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `[PERF]` 是 `log.info` 打出来的，只在挂了监听器时可见 ——
  // 探针里不挂就等于白测（应用里靠 `enableDebug` 落盘）。
  setUpAll(() {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      if (record.message.startsWith('[PERF]')) {
        // ignore: avoid_print
        print('  ${record.message}');
      }
    });
  });

  test('getApkInfo 端到端耗时', () async {
    final path = Platform.environment['PERF_APK'] ?? _defaultSample;
    if (!File(path).existsSync()) {
      markTestSkipped('样本 $path 不存在，跳过');
      return;
    }
    final sizeMB = File(path).lengthSync() / (1024 * 1024);

    // 1) 工具路径解析：Windows 上这里是 PATH × PATHEXT 的同步 stat 风暴。
    final toolSw = Stopwatch()..start();
    final aapt2 = ToolPaths.findSystemTool('aapt2');
    final apksigner = ToolPaths.findSystemTool('apksigner');
    final toolMs = toolSw.elapsedMicroseconds / 1000;

    // 2) 哈希（与解析并行的那条线）。
    final hashSw = Stopwatch()..start();
    final hashes = await computeFileHashes(path);
    final hashMs = hashSw.elapsedMicroseconds / 1000;

    // 3) getApkInfo 全链路（worker + 封签 + 图标）。
    final totalSw = Stopwatch()..start();
    final info = await getApkInfo(path);
    totalSw.stop();

    expect(info, isNotNull);
    final rows = <(String, String)>[
      (
        '工具路径解析（aapt2 + apksigner）',
        '${toolMs.toStringAsFixed(1)} ms  aapt2=${aapt2 ?? '未找到'}'
      ),
      ('三种哈希（3 isolate 并行）', '${hashMs.toStringAsFixed(1)} ms'),
      ('getApkInfo（worker + 封签 + 图标）', '${totalSw.elapsedMilliseconds} ms'),
    ];

    final buffer = StringBuffer()
      ..writeln('')
      ..writeln('样本 ${path.split(Platform.pathSeparator).last}'
          '（${sizeMB.toStringAsFixed(1)} MB）')
      ..writeln('-' * 60);
    for (final (label, value) in rows) {
      buffer.writeln('${label.padRight(34)} $value');
    }
    buffer
      ..writeln('-' * 60)
      ..writeln('图标候选 ${info!.iconCandidates.length} 个'
          '，主图标${info.mainIconImage == null ? '未渲染' : '已渲染'}')
      ..writeln('sha256=${hashes.sha256.substring(0, 16)}… '
          'apksigner=${apksigner ?? '未找到'}');
    // ignore: avoid_print
    print(buffer.toString());

    info.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
