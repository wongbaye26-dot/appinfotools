// 解析流水线性能探针（**不是**质量门禁的一部分，默认 `flutter test` 不会跑到它）。
//
// 用法：
//   NO_PROXY=127.0.0.1,localhost,::1 \
//     ~/development/flutter/bin/flutter test tool/perf_probe_test.dart
//
// 它只做两件事：**测量**与**打印**。断言只钉住「跑得完、结果非空」这类
// 不会随机器波动的事实 —— 时间数字不参与断言，否则在慢机器上必然变红，
// 而一个会随机变红的守卫等于没有守卫。
//
// 存在的理由：优化解析速度必须有基线。「感觉快了」不是证据，这张表才是。

import 'dart:io';

import 'package:apk_info_tool/ipaparser/ios_codesign_step.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/ipa_bundle_extractor.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

/// 探针用的样本。缺了就跳过（样本不入库，体积 42 MB）。
const _ipaPath = 'sun_signed.ipa';

/// 跑 [body] 并返回毫秒耗时。
Future<(T, double)> _timed<T>(Future<T> Function() body) async {
  final sw = Stopwatch()..start();
  final value = await body();
  sw.stop();
  return (value, sw.elapsedMicroseconds / 1000);
}

void main() {
  test('IPA 解析各阶段耗时基线', () async {
    final file = File(_ipaPath);
    if (!file.existsSync()) {
      markTestSkipped('样本 $_ipaPath 不存在，跳过');
      return;
    }
    final sizeMB = (await file.length()) / (1024 * 1024);

    final rows = <(String, double)>[];

    final helper = ZipHelper();
    final (openResult, openMs) = await _timed(() => helper.open(_ipaPath));
    expect(openResult.isOk, isTrue, reason: '样本必须能打开');
    rows.add(('1. 打开归档（中央目录 + 预算判定）', openMs));
    rows.add(('   条目数', -helper.archive!.files.length.toDouble()));

    final archive = helper.archive!;
    final (container, containerMs) =
        await _timed(() async => IpaContainerReader.read(archive));
    rows.add(('2. 枚举 bundle', containerMs));

    final mainApp = container.mainApp!;

    final (info, plistMs) =
        await _timed(() async => IpaInfoPlistReader.read(archive, mainApp));
    rows.add(('3. Info.plist', plistMs));

    final (_, iconMs) =
        await _timed(() async => IpaIconResolver.resolve(archive, info));
    rows.add(('4. 图标定位', iconMs));

    final executablePath = '${mainApp.path}/${info.executable.value ?? ''}';
    final (machoBytes, machoReadMs) = await _timed(() async {
      final entry = archive.findFile(executablePath);
      return entry?.content;
    });
    rows.add(('5a. 主可执行文件读取', machoReadMs));

    final (_, machoParseMs) =
        await _timed(() async => MachOParser.parse(machoBytes!));
    rows.add(('5b. 主可执行文件 Mach-O 解析', machoParseMs));

    // 嵌套 bundle：逐个计时，找出真正的热点。
    const interesting = {
      IosBundleKind.framework,
      IosBundleKind.appExtension,
      IosBundleKind.watchApp,
      IosBundleKind.nestedApp,
    };
    final candidates = container.bundles
        .where((b) => b.path != mainApp.path && interesting.contains(b.kind))
        .toList();
    var nestedReadMs = 0.0;
    var nestedParseMs = 0.0;
    var nestedRetained = 0;
    for (final bundle in candidates) {
      final (nestedInfo, rMs) =
          await _timed(() async => IpaInfoPlistReader.read(archive, bundle));
      nestedReadMs += rMs;
      final name = nestedInfo.executable.value;
      if (name == null || name.isEmpty) continue;
      final (bytes, readMs) = await _timed(() async {
        final entry = archive.findFile('${bundle.path}/$name');
        return entry?.content;
      });
      nestedReadMs += readMs;
      if (bytes == null) continue;
      nestedRetained += bytes.length;
      final (_, pMs) = await _timed(() async => MachOParser.parse(bytes));
      nestedParseMs += pMs;
    }
    rows.add(('6a. 嵌套 bundle 读取（${candidates.length} 个）', nestedReadMs));
    rows.add(('6b. 嵌套 bundle Mach-O 解析', nestedParseMs));

    final (_, sigMs) = await _timed(
        () async => IpaSignatureMaterialReader.read(archive, mainApp));
    rows.add(('7. 签名材料', sigMs));

    helper.close();

    // 整条链再跑一次，作为「一次完整静态解析」的口径。
    final helper2 = ZipHelper();
    final (_, totalMs) = await _timed(() async {
      await helper2.open(_ipaPath);
      return IpaAnalysisReader.analyze(helper2.archive!);
    });
    rows.add(('★ 完整静态解析（open + analyze）', totalMs));
    helper2.close();

    // 三条并行线里另外两条。
    final (_, hashMs) = await _timed(() => computeFileHashes(_ipaPath));
    rows.add(('8. 三种哈希（独立 isolate）', hashMs));

    // 解包 + codesign：静态解析之后才跑，是用户等得最久的一段。
    final helper3 = ZipHelper();
    await helper3.open(_ipaPath);
    final mainApp2 = IpaContainerReader.read(helper3.archive!).mainApp!;
    final (_, extractMs) = await _timed(() async {
      final extraction = await IpaBundleExtractor.extract(
        helper3.archive!,
        mainApp2,
      );
      await IpaBundleExtractor.cleanUp(extraction.tempRoot);
      return extraction;
    });
    rows.add(('9a. 解包主 .app 到临时目录', extractMs));
    helper3.close();

    final (codesignResult, codesignMs) =
        await _timed(() async => IosCodeSignStep.run(_ipaPath, mainApp2));
    rows.add(('9b. 解包 + codesign（完整一步）', codesignMs));
    rows.add(('   codesign 结论', -1));
    // ignore: avoid_print
    print('   → ${codesignResult.status} toolExecuted='
        '${codesignResult.toolExecuted} exit=${codesignResult.exitCode}');
    // ignore: avoid_print
    print('   → codesign 路径：'
        '${IosCodeSignAnalyzer.findCodesignPath()}');

    final buffer = StringBuffer()
      ..writeln('')
      ..writeln('样本 $_ipaPath（${sizeMB.toStringAsFixed(1)} MB）')
      ..writeln('-' * 56);
    for (final (label, ms) in rows) {
      final value = ms < 0 ? '' : '${ms.toStringAsFixed(1)} ms';
      buffer.writeln('${label.padRight(42)} $value');
    }
    buffer.writeln('-' * 56);
    buffer.writeln(
        '嵌套字节合计 ${(nestedRetained / (1024 * 1024)).toStringAsFixed(1)} MB');
    // ignore: avoid_print
    print(buffer.toString());

    expect(machoBytes, isNotNull);
    expect(container.mainApp, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
