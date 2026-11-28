import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';

/// 一次应用分析的正式记录状态。
///
/// 与页面状态（空/加载/失败）不是同一个概念：
/// - 页面状态描述 UI 当前有没有可渲染内容；
/// - run 状态描述一次分析任务从排队到结束的生命周期。
enum AnalysisRunStatus {
  queued,
  running,
  success,
  partial,
  failed,
  cancelled;

  bool get isTerminal =>
      this == success || this == partial || this == failed || this == cancelled;

  String get code => name;

  static AnalysisRunStatus fromCode(String? code) {
    for (final status in values) {
      if (status.code == code) return status;
    }
    throw FormatException('未知的分析状态: $code');
  }
}

/// 一次分析的不可变记录。
///
/// Stage 1 只负责“记录元数据 + 真实报告快照”。后续 Stage 2–5 再把
/// evidence / graph / network 等拆成独立、可查询的一等结构。
class AnalysisRun {
  /// 当前 run JSON 的结构版本。与报告 schema 版本无关。
  static const int schemaVersion = 1;

  final String id;
  final String toolVersion;
  final String? appName;
  final PackagePlatform platform;
  final String packagePath;
  final String? packageSha256;
  final DateTime startedAt;
  final DateTime? completedAt;
  final AnalysisRunStatus status;

  /// `AnalysisReport.renderJson` 的 JSON 快照。
  ///
  /// null 表示任务尚未完成/没有可保存结果；**不能**用空对象伪装“分析成功”。
  final Map<String, dynamic>? snapshot;

  /// V3 结构化模型（`Component` 列表、指纹、制品身份等）的可选载荷。
  ///
  /// 为什么与 [snapshot] 并存：snapshot 是导出契约的一部分（必须保持原样），
  /// 结构化模型供历史对比/误报处置按字段查询，不要求两边同时可用。
  /// 旧 run 没有这个键 → null，读取方必须按「只有快照」处理。
  final Map<String, dynamic>? model;

  /// 分析级限制（例如“归档条目超预算”“加密内容不可读”）。
  final List<String> limitations;

  const AnalysisRun({
    required this.id,
    required this.toolVersion,
    required this.platform,
    required this.packagePath,
    required this.startedAt,
    required this.status,
    this.appName,
    this.packageSha256,
    this.completedAt,
    this.snapshot,
    this.model,
    this.limitations = const [],
  });

  bool get isTerminal => status.isTerminal;

  /// 生成一个稳定、可读、无路径字符的 run id。
  ///
  /// 使用 UTC 微秒 + 文件哈希前缀，避免同一毫秒内两条 run 冲突；
  /// 不含文件路径，因此文件移动不会改变历史身份。
  static String createId({
    required DateTime startedAt,
    String? packageSha256,
  }) {
    final stamp = startedAt.toUtc().microsecondsSinceEpoch;
    final prefix = (packageSha256 == null || packageSha256.isEmpty)
        ? 'unknown'
        : packageSha256.substring(0, 8).toLowerCase();
    return 'analysis_${stamp}_$prefix';
  }

  AnalysisRun copyWith({
    AnalysisRunStatus? status,
    DateTime? completedAt,
    Map<String, dynamic>? snapshot,
    Map<String, dynamic>? model,
    List<String>? limitations,
    String? appName,
    String? packageSha256,
    PackagePlatform? platform,
  }) {
    return AnalysisRun(
      id: id,
      toolVersion: toolVersion,
      appName: appName ?? this.appName,
      platform: platform ?? this.platform,
      packagePath: packagePath,
      packageSha256: packageSha256 ?? this.packageSha256,
      startedAt: startedAt,
      completedAt: completedAt ?? this.completedAt,
      status: status ?? this.status,
      snapshot: snapshot ?? this.snapshot,
      model: model ?? this.model,
      limitations: limitations ?? this.limitations,
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'toolVersion': toolVersion,
        'appName': appName,
        'platform': platform.name,
        'packagePath': packagePath,
        'packageSha256': packageSha256,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'completedAt': completedAt?.toUtc().toIso8601String(),
        'status': status.code,
        'snapshot': snapshot,
        if (model != null) 'model': model,
        'limitations': limitations,
      };

  factory AnalysisRun.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is! int || version < 1 || version > schemaVersion) {
      throw FormatException('不支持的 AnalysisRun schemaVersion: $version');
    }

    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('AnalysisRun.id 缺失');
    }

    final toolVersion = json['toolVersion'];
    if (toolVersion is! String || toolVersion.isEmpty) {
      throw const FormatException('AnalysisRun.toolVersion 缺失');
    }

    final packagePath = json['packagePath'];
    if (packagePath is! String || packagePath.isEmpty) {
      throw const FormatException('AnalysisRun.packagePath 缺失');
    }

    final platformName = json['platform'];
    final platform = PackagePlatform.values.firstWhere(
      (value) => value.name == platformName,
      orElse: () => PackagePlatform.unknown,
    );

    final startedAtRaw = json['startedAt'];
    if (startedAtRaw is! String) {
      throw const FormatException('AnalysisRun.startedAt 缺失');
    }
    final startedAt = DateTime.tryParse(startedAtRaw);
    if (startedAt == null) {
      throw FormatException('AnalysisRun.startedAt 非法: $startedAtRaw');
    }

    final completedAtRaw = json['completedAt'];
    DateTime? completedAt;
    if (completedAtRaw != null) {
      if (completedAtRaw is! String) {
        throw const FormatException('AnalysisRun.completedAt 非法');
      }
      completedAt = DateTime.tryParse(completedAtRaw);
      if (completedAt == null) {
        throw FormatException('AnalysisRun.completedAt 非法: $completedAtRaw');
      }
    }

    final snapshotRaw = json['snapshot'];
    if (snapshotRaw != null && snapshotRaw is! Map<String, dynamic>) {
      throw const FormatException('AnalysisRun.snapshot 必须是对象');
    }

    final modelRaw = json['model'];
    if (modelRaw != null && modelRaw is! Map<String, dynamic>) {
      throw const FormatException('AnalysisRun.model 必须是对象');
    }

    final limitationsRaw = json['limitations'];
    final limitations = <String>[];
    if (limitationsRaw != null) {
      if (limitationsRaw is! List) {
        throw const FormatException('AnalysisRun.limitations 必须是数组');
      }
      for (final item in limitationsRaw) {
        if (item is! String) {
          throw const FormatException('AnalysisRun.limitations 只能包含字符串');
        }
        limitations.add(item);
      }
    }

    return AnalysisRun(
      id: id,
      toolVersion: toolVersion,
      appName: json['appName'] as String?,
      platform: platform,
      packagePath: packagePath,
      packageSha256: json['packageSha256'] as String?,
      startedAt: startedAt.toUtc(),
      completedAt: completedAt?.toUtc(),
      status: AnalysisRunStatus.fromCode(json['status'] as String?),
      snapshot: snapshotRaw == null
          ? null
          : Map<String, dynamic>.from(snapshotRaw as Map),
      model:
          modelRaw == null ? null : Map<String, dynamic>.from(modelRaw as Map),
      limitations: List.unmodifiable(limitations),
    );
  }
}

/// 历史列表使用的轻量摘要，避免每次列出都读取完整 snapshot。
class AnalysisRunSummary {
  final String id;
  final String? appName;
  final PackagePlatform platform;
  final String packagePath;
  final String? packageSha256;
  final DateTime startedAt;
  final DateTime? completedAt;
  final AnalysisRunStatus status;

  /// 是否存在可读的报告快照。
  ///
  /// 历史列表按摘要渲染，不读完整 snapshot（几百 KB）；这里只记一个布尔，
  /// 需要看内容时再按 id 读 run 文件。
  final bool hasSnapshot;

  const AnalysisRunSummary({
    required this.id,
    required this.platform,
    required this.packagePath,
    required this.startedAt,
    required this.status,
    this.appName,
    this.packageSha256,
    this.completedAt,
    this.hasSnapshot = false,
  });

  factory AnalysisRunSummary.fromRun(AnalysisRun run) => AnalysisRunSummary(
        id: run.id,
        appName: run.appName,
        platform: run.platform,
        packagePath: run.packagePath,
        packageSha256: run.packageSha256,
        startedAt: run.startedAt,
        completedAt: run.completedAt,
        status: run.status,
        hasSnapshot: run.snapshot != null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'appName': appName,
        'platform': platform.name,
        'packagePath': packagePath,
        'packageSha256': packageSha256,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'completedAt': completedAt?.toUtc().toIso8601String(),
        'status': status.code,
        'hasSnapshot': hasSnapshot,
      };

  factory AnalysisRunSummary.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final packagePath = json['packagePath'];
    final startedAtRaw = json['startedAt'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('AnalysisRunSummary.id 缺失');
    }
    if (packagePath is! String || packagePath.isEmpty) {
      throw const FormatException('AnalysisRunSummary.packagePath 缺失');
    }
    if (startedAtRaw is! String) {
      throw const FormatException('AnalysisRunSummary.startedAt 缺失');
    }
    final startedAt = DateTime.tryParse(startedAtRaw);
    if (startedAt == null) {
      throw FormatException('AnalysisRunSummary.startedAt 非法: $startedAtRaw');
    }
    final completedAtRaw = json['completedAt'];
    final completedAt =
        completedAtRaw is String ? DateTime.tryParse(completedAtRaw) : null;
    if (completedAtRaw != null && completedAt == null) {
      throw FormatException(
          'AnalysisRunSummary.completedAt 非法: $completedAtRaw');
    }
    final platformName = json['platform'];
    return AnalysisRunSummary(
      id: id,
      appName: json['appName'] as String?,
      platform: PackagePlatform.values.firstWhere(
        (value) => value.name == platformName,
        orElse: () => PackagePlatform.unknown,
      ),
      packagePath: packagePath,
      packageSha256: json['packageSha256'] as String?,
      startedAt: startedAt.toUtc(),
      completedAt: completedAt?.toUtc(),
      status: AnalysisRunStatus.fromCode(json['status'] as String?),
      hasSnapshot: json['hasSnapshot'] == true,
    );
  }
}
