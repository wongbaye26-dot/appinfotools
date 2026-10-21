// 「静态分析没看全」这句话必须出现在正文里。
//
// 否则读者会把「没报出来」读成「没有」—— 这是这类能力型规则最容易造成的
// 误解，比误报更难纠正。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

SecurityFinding _finding({List<String> blindSpots = const []}) =>
    SecurityFinding(
      ruleId: 'ANDROID-CRYPTO-THEFT-RISK',
      platform: SecurityPlatform.android,
      category: SecurityCategory.cryptoAsset,
      severity: SecuritySeverity.p3,
      confidence: SecurityConfidence.independentCapability,
      finding: 'raw english fallback',
      evidence: const [],
      recommendation: 'review by hand',
      limitation: 'static only',
      messageCode: 'crypto.theft_risk',
      messageArgs: {
        'signals': ['wallet-web3j'],
        'addressCount': 0,
        'blindSpots': blindSpots,
      },
    );

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  test('有盲区时正文补一句「没看全」', () {
    final text = AnalysisReport.findingText(
      _finding(blindSpots: ['dexPartial', 'nativePacked']),
      t,
    );
    expect(
      text,
      contains(t.security.finding_texts.crypto_theft_risk_blind_spots),
    );
  });

  test('没有盲区时不加那句', () {
    final text = AnalysisReport.findingText(_finding(), t);
    expect(
      text,
      isNot(contains(t.security.finding_texts.crypto_theft_risk_blind_spots)),
    );
  });
}
