import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('SecurityEvidence V3 扩展字段', () {
    test('旧构造不传新字段时默认 null，语义不变', () {
      const evidence = SecurityEvidence(
        source: SecurityEvidenceSource.manifest,
        location: 'AndroidManifest.xml',
        detail: 'uses-permission INTERNET',
      );
      expect(evidence.redactedValue, isNull);
      expect(evidence.extractorId, isNull);
      expect(evidence.evidenceId, isNotEmpty);
    });

    test('可携带脱敏值与扫描器 id，且不参与 evidenceId 派生', () {
      const withExtras = SecurityEvidence(
        source: SecurityEvidenceSource.dexString,
        location: 'classes.dex',
        detail: '疑似密钥',
        redactedValue: 'sk-…a1b2',
        extractorId: 'secret.regex.v1',
        id: 'ev-fixed',
      );
      expect(withExtras.redactedValue, 'sk-…a1b2');
      expect(withExtras.extractorId, 'secret.regex.v1');
      expect(withExtras.evidenceId, 'ev-fixed');
    });
  });
}
