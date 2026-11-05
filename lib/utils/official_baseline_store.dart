import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:analysis_model/analysis_model.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 官方基线库的加载与匹配。
///
/// 只读公开指纹；不读应用二进制。匹配逻辑是纯函数，便于测试。
class OfficialBaselineStore {
  OfficialBaselineStore._();

  static const String assetPath = 'assets/baseline/official_baseline_v1.json';
  static OfficialBaselineDb? _cached;

  /// 加载基线库；失败返回 `null`（调用方按 `unavailable` 处理，不冒充匹配）。
  static Future<OfficialBaselineDb?> load() async {
    if (_cached != null) return _cached;
    try {
      final text = await rootBundle.loadString(assetPath);
      _cached = parse(text);
      return _cached;
    } catch (_) {
      return null;
    }
  }

  /// 从 JSON 文本解析；schema/字段不合法时返回 `null`。
  static OfficialBaselineDb? parse(String text) {
    try {
      final raw = jsonDecode(text);
      if (raw is! Map<String, dynamic>) return null;
      if (raw['schemaVersion'] != 1) return null;
      final dbVersion = raw['dbVersion'];
      final entriesRaw = raw['entries'];
      if (dbVersion is! String || entriesRaw is! List) return null;
      final entries = <OfficialBaselineEntry>[];
      for (final item in entriesRaw) {
        final entry = _entry(item);
        if (entry != null) entries.add(entry);
      }
      if (entries.isEmpty) return null;
      // 完整性校验只覆盖 entries 的规范 JSON；没有该字段时跳过（旧库兼容）。
      final integrity = raw['integritySha256'];
      if (integrity is String) {
        final actual =
            sha256.convert(utf8.encode(jsonEncode(entriesRaw))).toString();
        if (actual != integrity) return null;
      }
      return OfficialBaselineDb(dbVersion: dbVersion, entries: entries);
    } catch (_) {
      return null;
    }
  }

  static OfficialBaselineEntry? _entry(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'];
    final platform = raw['platform'];
    final packageId = raw['packageId'];
    final displayName = raw['displayName'];
    if (id is! String || packageId is! String || displayName is! String) {
      return null;
    }
    if (platform != 'android' && platform != 'ios') return null;
    final certs = <String>[
      for (final value in (raw['certSha256'] as List? ?? const []))
        if (value is String) value.toLowerCase(),
    ];
    final teams = <String>[
      for (final value in (raw['teamIds'] as List? ?? const []))
        if (value is String) value.toUpperCase(),
    ];
    final sources = <BaselineSource>[
      for (final source in (raw['sources'] as List? ?? const []))
        if (source is Map<String, dynamic> &&
            source['type'] is String &&
            source['url'] is String &&
            source['retrievedAt'] is String)
          BaselineSource(
            type: source['type'] as String,
            url: source['url'] as String,
            retrievedAt: source['retrievedAt'] as String,
            method: source['method'] as String?,
          ),
    ];
    return OfficialBaselineEntry(
      id: id,
      platform: platform == 'android'
          ? SecurityPlatform.android
          : SecurityPlatform.ios,
      packageId: packageId,
      displayName: displayName,
      certSha256: certs,
      teamIds: teams,
      sources: sources,
      notes: raw['notes'] as String?,
    );
  }

  /// Android：packageId + 证书 SHA-256 交集。
  static BaselineMatch matchAndroid(
    OfficialBaselineDb? db, {
    required String? packageId,
    required List<String> actualCertSha256,
  }) {
    if (db == null) return const BaselineMatch.unavailable();
    if (packageId == null || packageId.isEmpty) {
      return const BaselineMatch.noBaseline();
    }
    final entry = db.find(
      platform: SecurityPlatform.android,
      packageId: packageId,
    );
    if (entry == null) {
      return BaselineMatch.noBaseline(
          packageId: packageId, dbVersion: db.dbVersion);
    }
    final expected = entry.certSha256.map((v) => v.toLowerCase()).toSet();
    final actual = actualCertSha256.map((v) => v.toLowerCase()).toSet();
    String prefix(String value) =>
        value.length <= 16 ? value : value.substring(0, 16);
    // 没有实际指纹时不能说“不匹配”：那是“没算”，不是“对不上”。
    if (expected.isEmpty || actual.isEmpty) {
      return BaselineMatch(
        status: BaselineStatus.unavailable,
        dbVersion: db.dbVersion,
        packageId: packageId,
        expectedFingerprintPrefixes: expected.map(prefix).toList()..sort(),
        actualFingerprintPrefixes: actual.map(prefix).toList()..sort(),
        noteCodes: const ['baseline.fingerprint_unavailable'],
      );
    }
    final match = expected.intersection(actual).isNotEmpty;
    return BaselineMatch(
      status: match ? BaselineStatus.match : BaselineStatus.mismatch,
      dbVersion: db.dbVersion,
      entryId: entry.id,
      packageId: packageId,
      expectedFingerprintPrefixes: expected.map(prefix).toList()..sort(),
      actualFingerprintPrefixes: actual.map(prefix).toList()..sort(),
      noteCodes: match ? const [] : const ['baseline.fingerprint_mismatch'],
    );
  }

  /// iOS：Bundle ID + Team ID 交集。
  static BaselineMatch matchIos(
    OfficialBaselineDb? db, {
    required String? bundleId,
    required List<String> actualTeamIds,
  }) {
    if (db == null) return const BaselineMatch.unavailable();
    if (bundleId == null || bundleId.isEmpty) {
      return const BaselineMatch.noBaseline();
    }
    final entry = db.find(
      platform: SecurityPlatform.ios,
      packageId: bundleId,
    );
    if (entry == null) {
      return BaselineMatch.noBaseline(
          packageId: bundleId, dbVersion: db.dbVersion);
    }
    final expected = entry.teamIds.map((v) => v.toUpperCase()).toSet();
    final actual = actualTeamIds.map((v) => v.toUpperCase()).toSet();
    String prefix(String value) =>
        value.length <= 16 ? value : value.substring(0, 16);
    if (expected.isEmpty || actual.isEmpty) {
      return BaselineMatch(
        status: BaselineStatus.unavailable,
        dbVersion: db.dbVersion,
        packageId: bundleId,
        expectedFingerprintPrefixes: expected.map(prefix).toList()..sort(),
        actualFingerprintPrefixes: actual.map(prefix).toList()..sort(),
        noteCodes: const ['baseline.fingerprint_unavailable'],
      );
    }
    final match = expected.intersection(actual).isNotEmpty;
    return BaselineMatch(
      status: match ? BaselineStatus.match : BaselineStatus.mismatch,
      dbVersion: db.dbVersion,
      entryId: entry.id,
      packageId: bundleId,
      expectedFingerprintPrefixes: expected.map(prefix).toList()..sort(),
      actualFingerprintPrefixes: actual.map(prefix).toList()..sort(),
      noteCodes: match ? const [] : const ['baseline.fingerprint_mismatch'],
    );
  }

  /// 测试/离线导入用：清缓存。
  static void resetForTest() => _cached = null;
}
