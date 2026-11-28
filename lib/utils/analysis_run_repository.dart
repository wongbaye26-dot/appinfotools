import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/models/analysis/analysis_run.dart';

/// 本地 AnalysisRun 仓库。
///
/// 目录结构：
/// ```
/// <root>/runs/<id>.json
/// <root>/runs/index.json
/// ```
///
/// 设计约束：
/// - 不依赖 UI / provider；测试可直接注入临时目录。
/// - 单 run 独立文件，避免一次写到巨大的索引里。
/// - 写入先写临时文件再 rename，避免半截 JSON。
/// - 索引可重建；索引损坏不能导致历史全部丢失。
class AnalysisRunRepository {
  static const String runsDirectoryName = 'analysis_runs';
  static const String indexFileName = 'index.json';

  /// 索引结构版本。
  ///
  /// v2：摘要增加 `hasSnapshot`。旧索引没有这个字段会让历史页的「存档报告」
  /// 一直不可用，因此版本号 +1，让旧索引整体重建一次（重建本身会读 run 文件，
  /// 不在列表渲染时读）。
  static const int indexSchemaVersion = 2;

  final Directory root;
  final int maxRuns;

  AnalysisRunRepository(this.root, {this.maxRuns = 100});

  Directory get _runsDir =>
      Directory('${root.path}${Platform.pathSeparator}$runsDirectoryName');

  File get _indexFile =>
      File('${_runsDir.path}${Platform.pathSeparator}$indexFileName');

  File _runFile(String id) =>
      File('${_runsDir.path}${Platform.pathSeparator}$id.json');

  /// id 同时作为文件名；必须禁止路径分隔符和 `..`。
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  static bool isValidId(String id) => _idPattern.hasMatch(id);

  Future<void> ensureInitialized() async {
    if (!_runsDir.existsSync()) {
      await _runsDir.create(recursive: true);
    }
  }

  /// 保存一条 run（新增或更新状态/快照）。
  ///
  /// 同一 id 重写是允许的：running → success 是正常状态迁移；
  /// **不同分析必须使用不同 id**，由调用方负责。
  Future<void> save(AnalysisRun run) async {
    if (!isValidId(run.id)) {
      throw FormatException('非法 AnalysisRun id: ${run.id}');
    }
    await ensureInitialized();

    final payload = const JsonEncoder.withIndent('  ').convert(run.toJson());
    final target = _runFile(run.id);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    if (target.existsSync()) {
      await target.delete();
    }
    await temp.rename(target.path);

    final summaries = await _readIndexOrRebuild();
    final next = <AnalysisRunSummary>[
      for (final summary in summaries)
        if (summary.id != run.id) summary,
      AnalysisRunSummary.fromRun(run),
    ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final kept = await _prune(next);
    await _writeIndex(kept);
  }

  Future<AnalysisRun?> read(String id) async {
    if (!isValidId(id)) {
      throw FormatException('非法 AnalysisRun id: $id');
    }
    final file = _runFile(id);
    if (!file.existsSync()) return null;
    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('AnalysisRun 文件不是 JSON 对象: ${file.path}');
    }
    return AnalysisRun.fromJson(decoded);
  }

  /// 历史列表，按开始时间倒序。
  Future<List<AnalysisRunSummary>> list({int limit = 50}) async {
    if (limit <= 0) return const [];
    final summaries = await _readIndexOrRebuild();
    summaries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return summaries.take(limit).toList(growable: false);
  }

  Future<void> delete(String id) async {
    if (!isValidId(id)) {
      throw FormatException('非法 AnalysisRun id: $id');
    }
    final file = _runFile(id);
    if (file.existsSync()) {
      await file.delete();
    }
    final summaries = await _readIndexOrRebuild();
    await _writeIndex([
      for (final summary in summaries)
        if (summary.id != id) summary,
    ]);
  }

  /// 从 run 文件重建索引。损坏文件被跳过，不阻塞其余历史。
  Future<List<AnalysisRunSummary>> rebuildIndex() async {
    await ensureInitialized();
    final files = _runsDir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .where((file) => !file.path.endsWith(indexFileName))
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));

    final summaries = <AnalysisRunSummary>[];
    for (final file in files) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          final run = AnalysisRun.fromJson(decoded);
          summaries.add(AnalysisRunSummary.fromRun(run));
        }
      } catch (_) {
        // 单个损坏 run 不能拖垮历史列表；文件保留供人工排查。
        continue;
      }
    }
    summaries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    await _writeIndex(summaries);
    return summaries;
  }

  Future<List<AnalysisRunSummary>> _readIndexOrRebuild() async {
    await ensureInitialized();
    if (!_indexFile.existsSync()) {
      return await rebuildIndex();
    }
    try {
      final decoded = jsonDecode(await _indexFile.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return await rebuildIndex();
      }
      if (decoded['schemaVersion'] != indexSchemaVersion) {
        return await rebuildIndex();
      }
      final rawRuns = decoded['runs'];
      if (rawRuns is! List) {
        return await rebuildIndex();
      }
      return [
        for (final item in rawRuns)
          if (item is Map<String, dynamic>) AnalysisRunSummary.fromJson(item),
      ];
    } catch (_) {
      return await rebuildIndex();
    }
  }

  Future<void> _writeIndex(List<AnalysisRunSummary> summaries) async {
    await ensureInitialized();
    final payload = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': indexSchemaVersion,
      'runs': [for (final summary in summaries) summary.toJson()],
    });
    final temp = File('${_indexFile.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    if (_indexFile.existsSync()) {
      await _indexFile.delete();
    }
    await temp.rename(_indexFile.path);
  }

  Future<List<AnalysisRunSummary>> _prune(
    List<AnalysisRunSummary> summaries,
  ) async {
    if (maxRuns <= 0 || summaries.length <= maxRuns) return summaries;
    final overflow = summaries.length - maxRuns;
    final kept = List<AnalysisRunSummary>.of(summaries);
    var removed = 0;
    // 从最旧开始删。遇到 running 就停止：删比它更新的记录会破坏时间顺序，
    // 宁可暂时超过 maxRuns，也不删除当前分析。
    while (removed < overflow && kept.isNotEmpty) {
      final summary = kept.last;
      if (summary.status == AnalysisRunStatus.running) break;
      final file = _runFile(summary.id);
      if (file.existsSync()) {
        await file.delete();
      }
      kept.removeLast();
      removed++;
    }
    return kept;
  }
}
