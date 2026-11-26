// 工具路径解析的缓存。
//
// 为什么要专门测它：`findInPath` 在 Windows 上对每个 `PATH` 目录 × 每个
// `PATHEXT` 扩展各做一次同步 stat，而图标渲染是**每个候选调一次**
// `findAapt2Path()`。缓存失效在这里不是「慢一点」，是「重复扫十几遍全盘」。

import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Config.gPrefs = await SharedPreferences.getInstance();
  });

  setUp(() async {
    CommandTools.invalidateCache();
    await Config.aapt2Path.updateValue('');
    await Config.aapt2Source.updateValue(Config.kToolSourceBuiltin);
  });

  test('同一份设置只解析一次，重复调用命中缓存', () async {
    final tmp = await Directory.systemTemp.createTemp('cmd_cache');
    addTearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });
    final buildTools = Directory('${tmp.path}/build-tools/34.0.0')
      ..createSync(recursive: true);
    final aapt2 = File('${buildTools.path}/aapt2')..writeAsStringSync('');
    await Config.downloadDir.updateValue(tmp.path);

    final before = CommandTools.debugCacheSize;
    expect(CommandTools.findAapt2Path(), aapt2.path);
    expect(CommandTools.debugCacheSize, before + 1);

    // `getAapt2Path` 与 `findAapt2Path` 共用同一个键：内置路径存在时
    // 两者结论相同，不该各自再扫一遍。
    expect(CommandTools.getAapt2Path(), aapt2.path);
    expect(CommandTools.debugCacheSize, before + 1,
        reason: '同一次解析的两个入口应命中同一条缓存');
  });

  test('文件被删掉后仍返回缓存值，说明没有重新扫盘', () async {
    final tmp = await Directory.systemTemp.createTemp('cmd_cache_stale');
    addTearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });
    final buildTools = Directory('${tmp.path}/build-tools/34.0.0')
      ..createSync(recursive: true);
    final aapt2 = File('${buildTools.path}/aapt2')..writeAsStringSync('');
    await Config.downloadDir.updateValue(tmp.path);

    expect(CommandTools.findAapt2Path(), aapt2.path);

    aapt2.deleteSync();
    expect(CommandTools.findAapt2Path(), aapt2.path,
        reason: '缓存命中时不该再 stat 一次文件系统');

    // 显式失效后才重新探测 —— 下载工具之后必须走这一步。
    CommandTools.invalidateCache();
    expect(CommandTools.findAapt2Path(), isNot(aapt2.path));
  });

  test('改设置会让缓存自然失效', () async {
    final tmp = await Directory.systemTemp.createTemp('cmd_cache_cfg');
    addTearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });
    final buildTools = Directory('${tmp.path}/build-tools/34.0.0')
      ..createSync(recursive: true);
    final aapt2 = File('${buildTools.path}/aapt2')..writeAsStringSync('');
    await Config.downloadDir.updateValue(tmp.path);

    expect(CommandTools.findAapt2Path(), aapt2.path);

    // 换成「自定义路径」：键里的 source 变了，必须重新解析。
    await Config.aapt2Source.updateValue(Config.kToolSourceCustom);
    await Config.aapt2Path.updateValue(aapt2.path);
    expect(CommandTools.findAapt2Path(), aapt2.path);

    final entriesAfterCustom = CommandTools.debugCacheSize;
    CommandTools.invalidateCache();
    expect(CommandTools.debugCacheSize, 0);
    expect(entriesAfterCustom, greaterThan(0));
  });
}
