// iOS 安全审计内部 RSS 探针（**不进 CI**）。
//
// 用法：
//   NO_PROXY=127.0.0.1,localhost,::1 \
//     flutter test tool/perf_probe_ios_audit_stages_test.dart
//
// 它先做一次 securityAudit:false 的解析，再调用 `IosPrivacyAudit.audit`
// 并打印每个阶段的 currentRss/maxRss，用来判断峰值到底在解析、facts、
// 还是审计内部。
import 'dart:io';

import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const _ipaPath = 'sun_signed.ipa';

String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

void main() {
  test('iOS 审计阶段 RSS', () async {
    final file = File(_ipaPath);
    if (!file.existsSync()) {
      markTestSkipped('样本 $_ipaPath 不存在');
      return;
    }
    final helper = ZipHelper();
    await helper.open(_ipaPath);
    final analysis =
        IpaAnalysisReader.analyze(helper.archive!, securityAudit: false);
    // ignore: avoid_print
    print('parse rss=${_mb(ProcessInfo.currentRss)} '
        'peak=${_mb(ProcessInfo.maxRss)}');
    IosPrivacyAudit.audit(
      infoPlist: analysis.infoPlist!,
      executableBytes: analysis.executableBytes,
      executablePath: analysis.executablePath,
      nestedExecutables: [
        for (final n in analysis.nestedBinaries)
          IosNestedExecutableInput(
            path: n.path,
            bundlePath: n.bundlePath,
            kind: n.kind,
            bytes: n.bytes,
            failure: n.failure ?? n.bytesFailure,
            usageDescriptions: n.usageDescriptions,
          ),
      ],
      nestedBundleTotal: analysis.nestedBundleTotal,
      layout: analysis.layout,
      onStage: (stage) {
        // ignore: avoid_print
        print('$stage rss=${_mb(ProcessInfo.currentRss)} '
            'peak=${_mb(ProcessInfo.maxRss)}');
      },
    );
    helper.close();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
