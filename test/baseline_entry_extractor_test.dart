import 'package:apk_info_tool/utils/baseline_entry_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('APK 提取出包名/证书 SHA-256/稳定 id', () async {
    final entry = await buildAndroidBaselineEntry(
      path: 'test/fixtures/apk/signed-v2-v3.apk',
      sourceType: 'other',
      sourceUrl: 'https://example.invalid/provided',
      retrievedAt: '2026-11-05T00:00:00Z',
    );
    expect(entry['platform'], 'android');
    expect((entry['packageId'] as String).isNotEmpty, isTrue);
    expect(entry['id'], startsWith('android.'));
    final certs = entry['certSha256'] as List;
    expect(certs, hasLength(1));
    expect((certs.single as String).length, 64);
    expect(entry['status'], 'active');
    expect((entry['notes'] as String), contains('not independently verified'));
  });

  test('不存在的 APK 抛 BaselineEntryExtractionException', () async {
    await expectLater(
      buildAndroidBaselineEntry(
        path: 'test/fixtures/apk/does-not-exist.apk',
        sourceType: 'other',
        sourceUrl: 'https://example.invalid',
        retrievedAt: '2026-11-05T00:00:00Z',
      ),
      throwsA(isA<BaselineEntryExtractionException>()),
    );
  });
}
