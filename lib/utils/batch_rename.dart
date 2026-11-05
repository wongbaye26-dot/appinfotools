import 'dart:io';

import 'package:path/path.dart' as p;

/// 一条批量重命名计划。
class BatchRenamePlan {
  final String sourcePath;
  final String newName;
  const BatchRenamePlan({required this.sourcePath, required this.newName});
}

/// 批量重命名结果。
class BatchRenameResult {
  final BatchRenamePlan plan;
  final String? newPath;
  final Object? error;
  const BatchRenameResult.renamed(this.plan, this.newPath) : error = null;
  const BatchRenameResult.failed(this.plan, this.error) : newPath = null;
  bool get ok => newPath != null;
}

/// 把应用名/版本整理成安全文件名（不含扩展名）。
String sanitizeRenameBase(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  return cleaned.isEmpty ? 'unnamed' : cleaned;
}

/// 生成批量重命名计划。
List<BatchRenamePlan> buildBatchRenamePlans(
  List<({String path, String appName, String version})> items, {
  required bool includeVersion,
}) {
  final used = <String>{};
  final plans = <BatchRenamePlan>[];
  for (final item in items) {
    final ext = p.extension(item.path).toLowerCase();
    final base = sanitizeRenameBase(item.appName);
    final version = sanitizeRenameBase(item.version);
    final stem =
        includeVersion && version != 'unnamed' ? '$base-$version' : base;
    var name = '$stem$ext';
    if (!used.add(name)) {
      var i = 2;
      while (!used.add('$stem ($i)$ext')) {
        i++;
      }
      name = '$stem ($i)$ext';
    }
    plans.add(BatchRenamePlan(sourcePath: item.path, newName: name));
  }
  return plans;
}

/// 就地批量重命名；失败只记录，不中断其它文件。
Future<List<BatchRenameResult>> batchRenameFiles(
  List<BatchRenamePlan> plans,
) async {
  final results = <BatchRenameResult>[];
  for (final plan in plans) {
    final source = File(plan.sourcePath);
    final target = p.join(source.parent.path, plan.newName);
    if (source.path == target) {
      results.add(BatchRenameResult.renamed(plan, target));
      continue;
    }
    try {
      final renamed = await source.rename(target);
      results.add(BatchRenameResult.renamed(plan, renamed.path));
    } catch (_) {
      try {
        await source.copy(target);
        await source.delete();
        results.add(BatchRenameResult.renamed(plan, target));
      } catch (e) {
        results.add(BatchRenameResult.failed(plan, e));
      }
    }
  }
  return results;
}
