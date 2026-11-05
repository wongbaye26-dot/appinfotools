// 从 APK / IPA 提取官方基线条目。纯 Dart，不依赖 Flutter，便于工具与测试复用。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:ipa_parser/ipa_parser.dart';

import 'baseline_entry_id.dart';
import 'content_digest.dart';

class BaselineEntryExtractionException implements Exception {
  final String message;
  const BaselineEntryExtractionException(this.message);
  @override
  String toString() => message;
}

/// 从 APK 提取 packageId / label / 签名证书 SHA-256。
Future<Map<String, Object?>> buildAndroidBaselineEntry({
  required String path,
  required String sourceType,
  required String sourceUrl,
  required String retrievedAt,
  bool official = false,
}) async {
  final reader = ApkReader();
  try {
    final open = await reader.open(path);
    if (!open.isOk) {
      throw BaselineEntryExtractionException('APK open failed: ${open.name}');
    }
    final meta = await reader.parse();
    final packageId = meta?.packageName;
    if (packageId == null || packageId.isEmpty) {
      throw const BaselineEntryExtractionException('APK has no package name');
    }
    final cert = meta?.signingSchemes?.signingCertificate;
    if (cert == null) {
      throw const BaselineEntryExtractionException(
        'APK has no signing certificate',
      );
    }
    final certSha = contentDigest('sha256', cert);
    if (certSha == null) {
      throw const BaselineEntryExtractionException(
        'could not hash signing certificate',
      );
    }
    return {
      'id': buildBaselineEntryId(platform: 'android', packageId: packageId),
      'platform': 'android',
      'packageId': packageId,
      'displayName': meta?.label ?? packageId,
      'certSha256': [certSha],
      'sources': [
        {
          'type': sourceType,
          'url': sourceUrl,
          'retrievedAt': retrievedAt,
          'method': 'ApkReader signing block extraction; cert SHA-256',
        }
      ],
      'status': 'active',
      'notes': official
          ? 'Extracted from a caller-provided official APK.'
          : 'Candidate baseline extracted from a caller-provided APK; not '
              'independently verified as official.',
    };
  } finally {
    reader.close();
  }
}

/// 从 IPA 提取 Bundle ID / display name / Team ID。
Map<String, Object?> buildIosBaselineEntrySync({
  required String path,
  required String sourceType,
  required String sourceUrl,
  required String retrievedAt,
  bool official = false,
}) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final container = IpaContainerReader.read(archive);
  final mainApp = container.mainApp;
  if (mainApp == null) {
    throw const BaselineEntryExtractionException('IPA has no Payload/*.app');
  }
  final info = IpaInfoPlistReader.read(archive, mainApp);
  final bundleId = info.bundleIdentifier.value;
  if (bundleId == null || bundleId.isEmpty) {
    throw const BaselineEntryExtractionException(
      'IPA has no CFBundleIdentifier',
    );
  }
  final signature = IpaSignatureMaterialReader.read(archive, mainApp);
  final teams =
      signature.profile.value?.teamIdentifiers.value ?? const <String>[];
  if (teams.isEmpty) {
    throw const BaselineEntryExtractionException(
      'IPA has no TeamIdentifier (no embedded profile?)',
    );
  }
  return {
    'id': buildBaselineEntryId(platform: 'ios', packageId: bundleId),
    'platform': 'ios',
    'packageId': bundleId,
    'displayName': info.displayName.value ?? bundleId,
    'teamIds': teams,
    'sources': [
      {
        'type': sourceType,
        'url': sourceUrl,
        'retrievedAt': retrievedAt,
        'method': 'codesign/info.plist extraction; TeamIdentifier from '
            'embedded profile',
      }
    ],
    'status': 'active',
    'notes': official
        ? 'Extracted from a caller-provided official IPA.'
        : 'Candidate baseline extracted from a caller-provided IPA; not '
            'independently verified as official.',
  };
}
