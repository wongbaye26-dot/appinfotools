// 单次分析的 RSS 探针（**不进 CI**）。
// 与 perf_probe_test 的区别：只打开**一个**归档、只跑一次 analyze，
// 避免探针自身同时持有多个 Archive 把峰值算高。
import 'dart:io';

import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/content_digest.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:flutter_test/flutter_test.dart';

const _ipaPath = 'sun_signed.ipa';

String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

void main() {
  test('IPA 单次 analyze 的 RSS 基线', () async {
    final file = File(_ipaPath);
    if (!file.existsSync()) {
      markTestSkipped('样本 $_ipaPath 不存在');
      return;
    }
    final start = ProcessInfo.currentRss;
    final helper = ZipHelper();
    await helper.open(_ipaPath);
    final afterOpen = ProcessInfo.currentRss;
    final analysis = IpaAnalysisReader.analyze(
      helper.archive!,
      digest: contentDigest,
      retainRawBytes: false,
    );
    final afterAnalyze = ProcessInfo.currentRss;
    helper.close();
    // ignore: avoid_print
    print('IPA ${_mb(file.lengthSync())} MB  '
        'start=${_mb(start)} MB  open=${_mb(afterOpen)} MB  '
        'analyze=${_mb(afterAnalyze)} MB  peak=${_mb(ProcessInfo.maxRss)} MB  '
        'findings=${analysis.security?.findings.length}');
    expect(analysis.infoPlist, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
