import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/utils/official_baseline_store.dart';
import 'package:flutter_test/flutter_test.dart';

final _json = '''
{
  "schemaVersion": 1,
  "dbVersion": "2026.11.0",
  "generatedAt": "2026-11-04T00:00:00Z",
  "reviewedBy": ["security"],
  "entries": [
    {
      "id": "android.example.wallet",
      "platform": "android",
      "packageId": "com.example.wallet",
      "displayName": "Example Wallet",
      "certSha256": ["ea5ff6c485d14b51f064479904231706dbcd243e9ef61d670cb59c24b92e919f"],
      "sources": [{"type": "other", "url": "https://example.com", "retrievedAt": "2026-11-04T00:00:00Z"}],
      "status": "active"
    }
  ]
}
''';

const _cert =
    'ea5ff6c485d14b51f064479904231706dbcd243e9ef61d670cb59c24b92e919f';
const _otherCert =
    '1111111111111111111111111111111111111111111111111111111111111111';

final _iosJson = '''
{
  "schemaVersion": 1,
  "dbVersion": "2026.11.0",
  "entries": [
    {
      "id": "ios.example.wallet",
      "platform": "ios",
      "packageId": "com.example.wallet",
      "displayName": "Example Wallet",
      "teamIds": ["ABCDE12345"],
      "sources": [{"type": "other", "url": "https://example.com", "retrievedAt": "2026-11-04T00:00:00Z"}],
      "status": "active"
    }
  ]
}
''';

void main() {
  test('基线 JSON 可解析，按包名匹配', () {
    final db = OfficialBaselineStore.parse(_json);
    expect(db, isNotNull);
    final match = OfficialBaselineStore.matchAndroid(
      db,
      packageId: 'com.example.wallet',
      actualCertSha256: const [_cert],
    );
    expect(match.status, BaselineStatus.match);
    expect(match.entryId, 'android.example.wallet');
  });

  test('同包名不同证书 → mismatch，保留指纹前缀', () {
    final db = OfficialBaselineStore.parse(_json);
    final match = OfficialBaselineStore.matchAndroid(
      db,
      packageId: 'com.example.wallet',
      actualCertSha256: const [_otherCert],
    );
    expect(match.status, BaselineStatus.mismatch);
    expect(match.expectedFingerprintPrefixes.single, _cert.substring(0, 16));
    expect(match.actualFingerprintPrefixes.single, _otherCert.substring(0, 16));
  });

  test('库里没有该包 → noBaseline，不是 mismatch', () {
    final db = OfficialBaselineStore.parse(_json);
    final match = OfficialBaselineStore.matchAndroid(
      db,
      packageId: 'com.example.other',
      actualCertSha256: const [_cert],
    );
    expect(match.status, BaselineStatus.noBaseline);
  });

  test('没有实际证书指纹 → unavailable，不判 mismatch', () {
    final db = OfficialBaselineStore.parse(_json);
    final match = OfficialBaselineStore.matchAndroid(
      db,
      packageId: 'com.example.wallet',
      actualCertSha256: const [],
    );
    expect(match.status, BaselineStatus.unavailable);
    expect(match.status, isNot(BaselineStatus.mismatch));
  });

  test('基线库不可用 → unavailable，不是 match', () {
    final match = OfficialBaselineStore.matchAndroid(
      null,
      packageId: 'com.example.wallet',
      actualCertSha256: const [_cert],
    );
    expect(match.status, BaselineStatus.unavailable);
  });

  test('基线 integritySha256 不匹配时拒绝加载', () {
    final raw =
        File('assets/baseline/official_baseline_v1.json').readAsStringSync();
    final bad = raw.replaceFirst(
      RegExp(r'"integritySha256": "[a-f0-9]+"'),
      '"integritySha256": "0000000000000000000000000000000000000000000000000000000000000000"',
    );
    expect(OfficialBaselineStore.parse(bad), isNull);
    expect(OfficialBaselineStore.parse(raw), isNotNull);
  });

  test('随包基线资产包含提供的 APK 条目', () {
    final json =
        File('assets/baseline/official_baseline_v1.json').readAsStringSync();
    final db = OfficialBaselineStore.parse(json);
    expect(db, isNotNull);
    final entry = db!.find(
      platform: SecurityPlatform.android,
      packageId: 'com.pwtma.tgewuir.ddmw',
    );
    expect(entry, isNotNull);
    expect(entry!.certSha256, contains(_cert));

    final fn = db.find(
      platform: SecurityPlatform.android,
      packageId: 'com.trim.music',
    );
    expect(fn, isNotNull);
    expect(
      fn!.certSha256,
      contains(
          '863ffbb78fec1d01f37f39f35f572fd99e2cb1d58bdaae70b7e85d90dad07257'),
    );
  });

  test('iOS：Bundle ID + Team ID 一致 → match，不一致 → mismatch', () {
    final db = OfficialBaselineStore.parse(_iosJson);
    final ok = OfficialBaselineStore.matchIos(
      db,
      bundleId: 'com.example.wallet',
      actualTeamIds: const ['ABCDE12345'],
    );
    expect(ok.status, BaselineStatus.match);
    final bad = OfficialBaselineStore.matchIos(
      db,
      bundleId: 'com.example.wallet',
      actualTeamIds: const ['ZZZZZ99999'],
    );
    expect(bad.status, BaselineStatus.mismatch);
  });

  test('iOS 拿不到 Team ID → unavailable，不判 mismatch', () {
    final db = OfficialBaselineStore.parse(_iosJson);
    final match = OfficialBaselineStore.matchIos(
      db,
      bundleId: 'com.example.wallet',
      actualTeamIds: const [],
    );
    expect(match.status, BaselineStatus.unavailable);
  });
}
