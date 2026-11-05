import 'security_finding.dart' show SecurityPlatform;

/// 官方基线匹配结果的状态。
enum BaselineStatus {
  /// 命中了官方基线条目，且指纹一致。
  match,

  /// 命中了同 platform + packageId 的条目，但指纹不一致。
  mismatch,

  /// 库里没有这个 packageId 的条目。
  noBaseline,

  /// 基线库不可用（未加载/加载失败/完整性校验失败）。
  unavailable,
}

/// 一条官方基线来源。
class BaselineSource {
  final String type;
  final String url;
  final String retrievedAt;
  final String? method;

  const BaselineSource({
    required this.type,
    required this.url,
    required this.retrievedAt,
    this.method,
  });
}

/// 官方基线条目（只存公开指纹，不存应用二进制）。
class OfficialBaselineEntry {
  final String id;
  final SecurityPlatform platform;
  final String packageId;
  final String displayName;
  final List<String> certSha256;
  final List<String> teamIds;
  final List<BaselineSource> sources;
  final String? notes;

  const OfficialBaselineEntry({
    required this.id,
    required this.platform,
    required this.packageId,
    required this.displayName,
    this.certSha256 = const [],
    this.teamIds = const [],
    this.sources = const [],
    this.notes,
  });
}

/// 官方基线库。
class OfficialBaselineDb {
  final String dbVersion;
  final List<OfficialBaselineEntry> entries;

  const OfficialBaselineDb({
    required this.dbVersion,
    required this.entries,
  });

  OfficialBaselineEntry? find({
    required SecurityPlatform platform,
    required String packageId,
  }) {
    for (final entry in entries) {
      if (entry.platform == platform && entry.packageId == packageId) {
        return entry;
      }
    }
    return null;
  }
}

/// 一次基线匹配结果。
class BaselineMatch {
  final BaselineStatus status;
  final String? dbVersion;
  final String? entryId;
  final String? packageId;
  final List<String> expectedFingerprintPrefixes;
  final List<String> actualFingerprintPrefixes;
  final List<String> noteCodes;

  const BaselineMatch({
    required this.status,
    this.dbVersion,
    this.entryId,
    this.packageId,
    this.expectedFingerprintPrefixes = const [],
    this.actualFingerprintPrefixes = const [],
    this.noteCodes = const [],
  });

  const BaselineMatch.unavailable()
      : status = BaselineStatus.unavailable,
        dbVersion = null,
        entryId = null,
        packageId = null,
        expectedFingerprintPrefixes = const [],
        actualFingerprintPrefixes = const [],
        noteCodes = const ['baseline.unavailable'];

  const BaselineMatch.noBaseline({this.packageId, this.dbVersion})
      : status = BaselineStatus.noBaseline,
        entryId = null,
        expectedFingerprintPrefixes = const [],
        actualFingerprintPrefixes = const [],
        noteCodes = const ['baseline.no_entry'];

  bool get isMatch => status == BaselineStatus.match;
  bool get isMismatch => status == BaselineStatus.mismatch;
}
