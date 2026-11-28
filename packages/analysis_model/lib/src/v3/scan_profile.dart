// V3 扫描 Profile 与规则包引用（F10 的前置模型）。
//
// 阶段 1 只做「模型 + 校验」：让 UI 与将来的 CLI 共用同一份合法性判断，
// 避免出现「UI 能选、CLI 不认」或「未知字段被静默忽略」的两套语义。
//
// 校验原则：
// - 未知扫描器 / 未知平台 / 超预算 → **整体拒绝**，不做部分生效；
// - 错误信息给到具体字段路径，便于 UI 标红。

/// 已知的扫描阶段。新增扫描器必须同时加进这里与文档。
enum ScanStage {
  manifest,
  permissions,
  components,
  artifacts,
  secrets,
  sdk,
  privacy,
  sbom,
  dexGraph,
  vulnerabilities;

  static ScanStage? fromName(String? value) {
    for (final stage in values) {
      if (stage.name == value) return stage;
    }
    return null;
  }
}

/// Profile 的资源预算。
///
/// 硬上限（不能通过 Profile 放宽）：
/// - `maxTotalBytes` ≤ 4 GiB：现有 `ZipBudgetLimits.maxTotalCompressed` 是 2 GiB，
///   Profile 允许略高以便将来支持解压后统计，但不允许无限；
/// - `maxEntries` ≤ 100 000：现有清单上限 2 000、条目总数通常远小于 10 万。
class ScanBudgets {
  static const int hardMaxTotalBytes = 4 * 1024 * 1024 * 1024;
  static const int hardMaxEntries = 100000;

  final int? maxTotalBytes;
  final int? maxEntries;

  const ScanBudgets({this.maxTotalBytes, this.maxEntries});

  bool get isEmpty => maxTotalBytes == null && maxEntries == null;

  Map<String, Object?> toJson() => {
        if (maxTotalBytes != null) 'maxTotalBytes': maxTotalBytes,
        if (maxEntries != null) 'maxEntries': maxEntries,
      };

  static ScanBudgets fromJson(Object? value, List<String> issues) {
    if (value == null) return const ScanBudgets();
    if (value is! Map) {
      issues.add('budgets: 必须是对象');
      return const ScanBudgets();
    }
    int? readInt(String key, int hardMax) {
      final raw = value[key];
      if (raw == null) return null;
      if (raw is! int) {
        issues.add('budgets.$key: 必须是整数');
        return null;
      }
      if (raw <= 0) {
        issues.add('budgets.$key: 必须大于 0');
        return null;
      }
      if (raw > hardMax) {
        issues.add('budgets.$key: 超过硬上限 $hardMax');
        return null;
      }
      return raw;
    }

    return ScanBudgets(
      maxTotalBytes: readInt('maxTotalBytes', hardMaxTotalBytes),
      maxEntries: readInt('maxEntries', hardMaxEntries),
    );
  }
}

/// 一个扫描 Profile。
class ScanProfile {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String id;
  final String name;
  final String version;
  final List<String> platforms;
  final List<ScanStage> scanners;
  final ScanBudgets budgets;
  final List<String> rulePacks;

  /// 阈值（如 `failOn: high`）。保持字符串映射，避免把业务枚举钉死在模型里。
  final Map<String, String> thresholds;

  const ScanProfile({
    this.schemaVersion = currentSchemaVersion,
    required this.id,
    required this.name,
    required this.version,
    required this.platforms,
    required this.scanners,
    this.budgets = const ScanBudgets(),
    this.rulePacks = const [],
    this.thresholds = const {},
  });

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'name': name,
        'version': version,
        'platforms': platforms,
        'scanners': [for (final stage in scanners) stage.name],
        if (!budgets.isEmpty) 'budgets': budgets.toJson(),
        'rulePacks': rulePacks,
        'thresholds': thresholds,
      };

  /// 解析并校验；有任何问题都抛 [ScanProfileException]，不做部分生效。
  static ScanProfile fromJson(Map<String, Object?> json) {
    final issues = <String>[];

    final rawSchema = json['schemaVersion'];
    final schemaVersion = rawSchema is int ? rawSchema : currentSchemaVersion;
    if (schemaVersion != currentSchemaVersion) {
      issues.add('schemaVersion: 只支持 $currentSchemaVersion，收到 $schemaVersion');
    }

    String requireText(String key) {
      final raw = json[key];
      if (raw is! String || raw.trim().isEmpty) {
        issues.add('$key: 必填字符串');
        return '';
      }
      return raw.trim();
    }

    final id = requireText('id');
    final name = requireText('name');
    final version = requireText('version');

    final platforms = <String>[];
    final rawPlatforms = json['platforms'];
    if (rawPlatforms is! List || rawPlatforms.isEmpty) {
      issues.add('platforms: 至少声明一个平台');
    } else {
      for (final raw in rawPlatforms) {
        final value = raw is String ? raw.trim() : '';
        if (value != 'android' && value != 'ios') {
          issues.add('platforms: 未知平台 "$value"（只支持 android / ios）');
          continue;
        }
        platforms.add(value);
      }
    }

    final scanners = <ScanStage>[];
    final rawScanners = json['scanners'];
    if (rawScanners is! List || rawScanners.isEmpty) {
      issues.add('scanners: 至少声明一个扫描阶段');
    } else {
      for (final raw in rawScanners) {
        final value = raw is String ? raw.trim() : '';
        final stage = ScanStage.fromName(value);
        if (stage == null) {
          issues.add('scanners: 未知扫描阶段 "$value"');
          continue;
        }
        if (!scanners.contains(stage)) scanners.add(stage);
      }
    }

    final budgets = ScanBudgets.fromJson(json['budgets'], issues);

    final rulePacks = <String>[];
    final rawRulePacks = json['rulePacks'];
    if (rawRulePacks != null) {
      if (rawRulePacks is! List) {
        issues.add('rulePacks: 必须是字符串数组');
      } else {
        for (final raw in rawRulePacks) {
          if (raw is! String || raw.trim().isEmpty) {
            issues.add('rulePacks: 每项必须是非空字符串');
            continue;
          }
          rulePacks.add(raw.trim());
        }
      }
    }

    final thresholds = <String, String>{};
    final rawThresholds = json['thresholds'];
    if (rawThresholds != null) {
      if (rawThresholds is! Map) {
        issues.add('thresholds: 必须是对象');
      } else {
        for (final entry in rawThresholds.entries) {
          final key = entry.key.toString().trim();
          final value = entry.value;
          if (key.isEmpty || value is! String || value.trim().isEmpty) {
            issues.add('thresholds: 键与值都必须是字符串');
            continue;
          }
          thresholds[key] = value.trim();
        }
      }
    }

    if (issues.isNotEmpty) throw ScanProfileException(issues);

    return ScanProfile(
      schemaVersion: schemaVersion,
      id: id,
      name: name,
      version: version,
      platforms: List.unmodifiable(platforms),
      scanners: List.unmodifiable(scanners),
      budgets: budgets,
      rulePacks: List.unmodifiable(rulePacks),
      thresholds: Map.unmodifiable(thresholds),
    );
  }
}

/// Profile 校验失败：一次返回全部问题，便于 UI 一次标完。
class ScanProfileException implements Exception {
  final List<String> issues;

  const ScanProfileException(this.issues);

  @override
  String toString() => 'ScanProfileException(${issues.join('; ')})';
}
