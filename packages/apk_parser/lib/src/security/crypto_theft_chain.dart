import 'package:analysis_model/analysis_model.dart';

import 'android_security_rules.dart';
import 'dex_unicode_phrases.dart';

/// Android 侧的证据链装配（Phase C）。
///
/// 输入是已经算好的 [AndroidRuleFacts]，输出是平台中立的
/// [CryptoTheftAssessment]。判级逻辑只存在于
/// `analysis_model` 的 `CryptoTheftAssessor`，这里不复制第二套阈值。
class AndroidCryptoTheftChain {
  AndroidCryptoTheftChain._();

  static CryptoTheftAssessment assess(
    AndroidRuleFacts facts, {
    BaselineMatch? baseline,
    SealCheck? seal,
    DexUnicodePhraseSignals? phrases,
  }) {
    return CryptoTheftAssessor.assess(
      buildAndroidCryptoTheftFacts(
        facts,
        baseline: baseline,
        seal: seal,
        phrases: phrases,
      ),
    );
  }
}
