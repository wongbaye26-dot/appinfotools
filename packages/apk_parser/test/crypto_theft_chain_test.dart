import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

void main() {
  test('audit 总能产出 cryptoTheft（没有信号时 level=none，不是 null）', () {
    final result = AndroidSecurityAudit.audit(
      meta: ApkMeta(),
      dexEntries: const [],
    );
    expect(result.cryptoTheft, isNotNull);
    expect(result.cryptoTheft!.id, 'android.crypto.theft');
    expect(result.cryptoTheft!.level, CryptoTheftLevel.none);
    expect(result.cryptoTheft!.chain, hasLength(5));
    expect(result.cryptoTheft!.missing, hasLength(5));
  });

  test('密封 mismatch → P1 finding + 评估 P1', () {
    final result = AndroidSecurityAudit.audit(
      meta: ApkMeta(),
      dexEntries: const [],
      seal: const SealCheck(
        scheme: 'apk.v2.content',
        state: SealState.mismatch,
        checks: [
          SealEntryCheck(
            path: 'classes.dex',
            state: SealState.mismatch,
            algorithm: 'sha256',
            expectedDigestPrefix: 'aaaaaaaaaaaaaaaa',
            actualDigestPrefix: 'bbbbbbbbbbbbbbbb',
          ),
        ],
      ),
    );
    final finding = result.findings
        .firstWhere((f) => f.ruleId == 'ANDROID-APK-SEAL-MISMATCH');
    expect(finding.severity, SecuritySeverity.p1);
    expect(finding.confidence, SecurityConfidence.confirmed);
    expect(result.cryptoTheft?.severity, SecuritySeverity.p1);
  });

  test('官方基线 mismatch → P1 finding + 评估 P1', () {
    final result = AndroidSecurityAudit.audit(
      meta: ApkMeta(),
      dexEntries: const [],
      baseline: const BaselineMatch(
        status: BaselineStatus.mismatch,
        entryId: 'android.example.wallet',
        packageId: 'com.example.wallet',
        expectedFingerprintPrefixes: ['aaaaaaaaaaaaaaaa'],
        actualFingerprintPrefixes: ['bbbbbbbbbbbbbbbb'],
      ),
    );
    final finding = result.findings
        .firstWhere((f) => f.ruleId == 'ANDROID-BASELINE-MISMATCH');
    expect(finding.severity, SecuritySeverity.p1);
    expect(result.cryptoTheft?.baselineEntryId, 'android.example.wallet');
  });

  test('cryptoTheft 与 findings 并列，不在 findings 里重复', () {
    final result = AndroidSecurityAudit.audit(
      meta: ApkMeta(),
      dexEntries: const [],
    );
    expect(
      result.findings.where((f) => f.ruleId == 'ANDROID-CRYPTO-THEFT-RISK'),
      isEmpty,
    );
    expect(result.cryptoTheft, isNotNull);
  });
}
