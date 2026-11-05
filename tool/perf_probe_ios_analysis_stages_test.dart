// analyze 内部阶段 RSS 探针（**不进 CI**）。
import 'dart:io';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/content_digest.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:flutter_test/flutter_test.dart';

const _ipaPath = 'sun_signed.ipa';
String _mb(int b) => (b / 1048576).toStringAsFixed(1);

void main() {
  test('iOS analyze 阶段 RSS', () async {
    final file = File(_ipaPath);
    if (!file.existsSync()) {
      markTestSkipped('样本不存在');
      return;
    }
    final helper = ZipHelper();
    await helper.open(_ipaPath);
    IpaAnalysisReader.analyze(
      helper.archive!,
      digest: contentDigest,
      retainRawBytes: false,
      onProfileStage: (stage) {
        // ignore: avoid_print
        print('$stage rss=${_mb(ProcessInfo.currentRss)} '
            'peak=${_mb(ProcessInfo.maxRss)}');
      },
    );
    helper.close();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
