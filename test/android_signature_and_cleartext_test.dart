// 签名材料的可读性 + 明文流量默认值（2026-10-19 审计 P2-8 / P2-10）。
//
// 这两条都属于「我们没看到 / 我们推错默认值」的诚实性问题：
//
// - 签名块读不出来时，`v1Only` 与 `hasV1Signature` 都推不出结论，两条签名
//   规则都不报，覆盖表若也没有签名这一维，「没读到」就变成了「没问题」。
// - `usesCleartextTraffic` 未声明时，平台默认值取决于 `targetSdk`：
//   API 28 起默认禁止，之前默认放行。一律当 false 会让老包漏报，
//   而且覆盖表还会把这一维标成「已覆盖」。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ApkMeta _meta({
  int? targetSdk,
  bool? usesCleartext,
  String? nscPath,
  ApkSigningSchemes? schemes,
  bool? hasV1,
}) =>
    ApkMeta()
      ..targetSdkVersion = targetSdk
      ..applicationUsesCleartextTraffic = usesCleartext
      ..networkSecurityConfig = nscPath
      ..signingSchemes = schemes
      ..hasV1Signature = hasV1;

SecurityAnalysisResult _audit(ApkMeta meta) =>
    AndroidSecurityAudit.audit(meta: meta, dexEntries: const []);

CoverageEntry? _entry(SecurityAnalysisResult r, String id) =>
    r.coverage.entry(id);

void main() {
  group('明文流量：未声明时按 targetSdk 取平台默认值', () {
    test('targetSdk 34 未声明 → 默认禁止（规则 D 不报，覆盖标 covered）', () {
      final result = _audit(_meta(targetSdk: 34));
      expect(
        result.findings.where((f) => f.ruleId.startsWith('ANDROID-RULE-D')),
        isEmpty,
      );
      final entry = _entry(result, 'android.cleartextPolicy')!;
      expect(entry.status, CoverageStatus.covered);
      expect(entry.noteCode, isNull);
    });

    test('targetSdk 26 未声明 → 默认**允许**明文，规则 D 必须报', () {
      // 这是修复前漏掉的那一半：`?? false` 会把它判成「不允许」。
      final result = _audit(_meta(targetSdk: 26));
      final ruleD =
          result.findings.where((f) => f.ruleId.startsWith('ANDROID-RULE-D'));
      expect(ruleD, hasLength(1), reason: 'API 28 之前不声明 = 允许明文');
    });

    test('连 targetSdk 都没有 → 判不了，覆盖标 partial 且说明原因', () {
      final result = _audit(_meta());
      final entry = _entry(result, 'android.cleartextPolicy')!;
      expect(entry.status, CoverageStatus.partial);
      expect(entry.noteCode, 'android.cleartext_policy_target_sdk_unknown');
    });

    test('显式声明优先于平台默认值', () {
      final off = _audit(_meta(targetSdk: 26, usesCleartext: false));
      expect(
        off.findings.where((f) => f.ruleId.startsWith('ANDROID-RULE-D')),
        isEmpty,
      );
      final on = _audit(_meta(targetSdk: 34, usesCleartext: true));
      expect(
        on.findings.where((f) => f.ruleId.startsWith('ANDROID-RULE-D')),
        hasLength(1),
      );
    });

    test('声明了 NSC 但没展开 → 仍然不判定（不猜）', () {
      final result = _audit(_meta(
        targetSdk: 34,
        usesCleartext: true,
        nscPath: '@res/0x7f010000',
      ));
      final entry = _entry(result, 'android.cleartextPolicy')!;
      expect(entry.status, CoverageStatus.partial);
      expect(entry.noteCode, 'android.cleartext_policy_unknown');
    });
  });

  group('签名材料：读不出来必须可见', () {
    test('签名块解析失败 → notCovered + 说明 + 限制说明，且两条签名规则都不报', () {
      final result = _audit(_meta(
        targetSdk: 34,
        schemes: const ApkSigningSchemes.unreadable('APK Signing Block 长度越界'),
        hasV1: false,
      ));

      final entry = _entry(result, 'android.signature')!;
      expect(entry.status, CoverageStatus.notCovered);
      expect(entry.covered, 0);
      expect(entry.noteCode, 'android.signature.unreadable');

      expect(
        result.limitations.map((l) => l.code),
        contains('android.signing_block.unreadable'),
      );
      // 读不出来时**不能**顺手说「没有签名」。
      expect(
        result.findings.where(
          (f) =>
              f.ruleId == 'ANDROID-V1-ONLY-SIGNING' ||
              f.ruleId == 'ANDROID-UNSIGNED',
        ),
        isEmpty,
      );
    });

    test('签名块可读 + v1 已判定 → covered', () {
      final result = _audit(_meta(
        targetSdk: 34,
        schemes: const ApkSigningSchemes(pairIds: [0x7109871a]),
        hasV1: true,
      ));
      final entry = _entry(result, 'android.signature')!;
      expect(entry.status, CoverageStatus.covered);
      expect(entry.ratioText, '1/1');
      expect(entry.noteCode, isNull);
    });

    test('签名块可读但 v1 未判定 → partial，不假装全绿', () {
      final result = _audit(_meta(
        targetSdk: 34,
        schemes: const ApkSigningSchemes(pairIds: [0x7109871a]),
      ));
      final entry = _entry(result, 'android.signature')!;
      expect(entry.status, CoverageStatus.partial);
      expect(entry.noteCode, 'android.signature.v1_undetermined');
    });

    test('完全没检查签名块 → notCovered 且说明是「没检查」而不是「没有」', () {
      final result = _audit(_meta(targetSdk: 34));
      final entry = _entry(result, 'android.signature')!;
      expect(entry.status, CoverageStatus.notCovered);
      expect(entry.noteCode, 'android.signature.not_read');
    });
  });
}
