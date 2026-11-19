import 'dart:io';

import 'package:path/path.dart' as p;

/// 一条批量重命名计划。
class BatchRenamePlan {
  final String sourcePath;
  final String newName;
  const BatchRenamePlan({required this.sourcePath, required this.newName});

  /// 目标绝对路径（与源文件同目录）。
  String get targetPath => p.join(p.dirname(sourcePath), newName);

  /// 目标是否与源完全相同（大小写敏感比较，用于「无需改名」判断）。
  bool get isNoop => sourcePath == targetPath;

  @override
  String toString() => 'BatchRenamePlan($sourcePath -> $newName)';
}

/// 失败原因分类。
///
/// 分开的理由很实际：这三类对用户意味着完全不同的事 ——
/// 「源文件不见了」要重新选文件，「目标已存在」要改个名，
/// 「写入失败」多半是权限或磁盘问题。只报一句「失败」等于什么都没说。
enum BatchRenameFailureReason {
  /// 源文件在计划生成之后消失了。
  sourceMissing,

  /// 目标位置已经有一个**不属于本批次**的文件。
  ///
  /// 这一条是**防数据丢失**的：POSIX 的 `rename(2)` 会静默覆盖目标，
  /// 所以必须自己先判一次，绝不能交给系统。
  targetExists,

  /// 改名 / 复制本身报错（权限、跨卷、文件被占用…）。
  ioError,
}

/// 批量重命名结果。
class BatchRenameResult {
  final BatchRenamePlan plan;
  final String? newPath;
  final Object? error;
  final BatchRenameFailureReason? reason;

  const BatchRenameResult.renamed(this.plan, this.newPath)
      : error = null,
        reason = null;

  const BatchRenameResult.failed(
    this.plan,
    this.error, {
    this.reason = BatchRenameFailureReason.ioError,
  }) : newPath = null;

  bool get ok => newPath != null;

  @override
  String toString() =>
      'BatchRenameResult(${plan.sourcePath}, ok: $ok, reason: $reason, '
      'error: $error)';
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

/// 下载渠道给重名文件加的复合后缀：`xxx.apk.1`、`xxx.apk.1.1`。
///
/// 这类文件的 `p.extension` 只有 `.1`，直接用它会把 `.apk` 从名字里丢掉。
final RegExp _multiPartSuffix =
    RegExp(r'\.(apk|xapk|apkm|apks|ipa)(\.\d+)+$', caseSensitive: false);

/// 取「应当保留的扩展名」，含 `xxx.apk.1` 这种复合后缀。
///
/// **保留原始大小写**：用户看到的文件名不该因为批量重命名被悄悄改成小写。
String _preservedSuffix(String path) {
  final match = _multiPartSuffix.firstMatch(path);
  if (match != null) return path.substring(match.start);
  return p.extension(path);
}

/// 用于比较路径是否指向同一个名字的键。
///
/// macOS / Windows 的默认文件系统大小写不敏感：`App.apk` 与 `app.apk`
/// 是同一个文件。按原样比较会让「同一批里两个只差大小写的名字」互相覆盖。
String _pathKey(String path) => Platform.isLinux ? path : path.toLowerCase();

/// 生成批量重命名计划。
///
/// 三条与「失败」直接相关的规则：
///
/// 1. **不覆盖磁盘上已有的文件**。同名时追加 ` (2)`、` (3)`…，
///    判定基准是**同一个目录**，不是整批（不同目录下同名完全正常）。
/// 2. **批次内部去重按目录 + 名字（大小写不敏感）**。此前用一个全局
///    `Set<String>` 只装文件名，跨目录同名会被迫改名。
/// 3. **本批次自己的源文件名不算「已存在」** —— 它们马上就会被改走，
///    否则「已经改成目标名的文件再跑一次」会全部变成 ` (2)`。
///
/// [exists] 可注入，便于测试；默认查真实文件系统。
List<BatchRenamePlan> buildBatchRenamePlans(
  List<({String path, String appName, String version})> items, {
  required bool includeVersion,
  bool Function(String path)? exists,
}) {
  final isTaken = exists ?? (String path) => File(path).existsSync();
  final sourceKeys = {for (final item in items) _pathKey(item.path)};
  final used = <String>{};
  final plans = <BatchRenamePlan>[];

  for (final item in items) {
    final directory = p.dirname(item.path);
    final suffix = _preservedSuffix(item.path);
    final base = sanitizeRenameBase(item.appName);
    final version = sanitizeRenameBase(item.version);
    final stem =
        includeVersion && version != 'unnamed' ? '$base-$version' : base;

    var index = 1;
    while (true) {
      final name = index == 1 ? '$stem$suffix' : '$stem ($index)$suffix';
      final target = p.join(directory, name);
      final key = _pathKey(target);
      final freeOnDisk = !isTaken(target) || sourceKeys.contains(key);
      if (!used.contains(key) && freeOnDisk) {
        used.add(key);
        plans.add(BatchRenamePlan(sourcePath: item.path, newName: name));
        break;
      }
      index++;
      // 一万个同名文件已经不是重命名问题了；给个上限避免死循环。
      if (index > 9999) {
        used.add(key);
        plans.add(BatchRenamePlan(sourcePath: item.path, newName: name));
        break;
      }
    }
  }
  return plans;
}

/// 就地批量重命名；失败只记录，不中断其它文件。
///
/// **两阶段改名**：当某个目标名正好是**同一批里另一个文件的源名**时
/// （例如两个包互换名字，或 A→B 而 B→C），逐个直接改名会把还没搬走的
/// 那个文件覆盖掉 —— 而且 `rename(2)` 是静默覆盖，用户根本不会收到提示。
/// 这种情况先把所有文件改成同目录下的临时名，再改成最终名。
///
/// 没有这种交叉时走单阶段（多一次 rename 系统调用没有必要）。
Future<List<BatchRenameResult>> batchRenameFiles(
  List<BatchRenamePlan> plans,
) async {
  final sourceKeys = {for (final plan in plans) _pathKey(plan.sourcePath)};

  final hasCrossing = plans.any((plan) {
    if (plan.isNoop) return false;
    final key = _pathKey(plan.targetPath);
    return key != _pathKey(plan.sourcePath) && sourceKeys.contains(key);
  });

  if (!hasCrossing) {
    return [for (final plan in plans) await _renameDirect(plan, sourceKeys)];
  }
  return _renameTwoPhase(plans, sourceKeys);
}

Future<BatchRenameResult> _renameDirect(
  BatchRenamePlan plan,
  Set<String> sourceKeys,
) async {
  if (plan.isNoop) {
    return BatchRenameResult.renamed(plan, plan.sourcePath);
  }
  final source = File(plan.sourcePath);
  final target = plan.targetPath;

  if (!source.existsSync()) {
    return BatchRenameResult.failed(
      plan,
      'source file does not exist',
      reason: BatchRenameFailureReason.sourceMissing,
    );
  }
  // 绝不覆盖不属于本批次的文件（`rename` 会静默覆盖）。
  if (File(target).existsSync() && !sourceKeys.contains(_pathKey(target))) {
    return BatchRenameResult.failed(
      plan,
      'target already exists',
      reason: BatchRenameFailureReason.targetExists,
    );
  }

  try {
    final renamed = await source.rename(target);
    return BatchRenameResult.renamed(plan, renamed.path);
  } catch (e) {
    // 第 2 级：复制 + 删除。跨卷或文件被占用时用这条。
    try {
      await source.copy(target);
      await source.delete();
      return BatchRenameResult.renamed(plan, target);
    } catch (_) {
      return BatchRenameResult.failed(plan, e);
    }
  }
}

/// 先把所有文件搬成临时名，再搬成最终名。
///
/// 中途失败时**尽量把临时名改回原名** —— 留下一个 `.appinfotool-rename-*`
/// 文件比留下原名更糟。
Future<List<BatchRenameResult>> _renameTwoPhase(
  List<BatchRenamePlan> plans,
  Set<String> sourceKeys,
) async {
  final results = List<BatchRenameResult?>.filled(plans.length, null);
  final staged = <({int index, String temp})>[];

  for (var i = 0; i < plans.length; i++) {
    final plan = plans[i];
    if (plan.isNoop) {
      results[i] = BatchRenameResult.renamed(plan, plan.sourcePath);
      continue;
    }
    final source = File(plan.sourcePath);
    if (!source.existsSync()) {
      results[i] = BatchRenameResult.failed(
        plan,
        'source file does not exist',
        reason: BatchRenameFailureReason.sourceMissing,
      );
      continue;
    }
    final temp = p.join(
      p.dirname(plan.sourcePath),
      '.appinfotool-rename-$i-${p.basename(plan.sourcePath)}',
    );
    try {
      await source.rename(temp);
      staged.add((index: i, temp: temp));
    } catch (e) {
      results[i] = BatchRenameResult.failed(plan, e);
    }
  }

  for (final entry in staged) {
    final plan = plans[entry.index];
    final target = plan.targetPath;
    // 到这里，本批次的源文件都已经搬走了；目标若仍存在，就是外部文件。
    if (File(target).existsSync() && !sourceKeys.contains(_pathKey(target))) {
      try {
        await File(entry.temp).rename(plan.sourcePath);
      } catch (_) {
        // 回滚失败就保留临时名，结果里已记失败。
      }
      results[entry.index] = BatchRenameResult.failed(
        plan,
        'target already exists',
        reason: BatchRenameFailureReason.targetExists,
      );
      continue;
    }
    try {
      await File(entry.temp).rename(target);
      results[entry.index] = BatchRenameResult.renamed(plan, target);
    } catch (e) {
      try {
        await File(entry.temp).rename(plan.sourcePath);
      } catch (_) {
        // 同上。
      }
      results[entry.index] = BatchRenameResult.failed(plan, e);
    }
  }

  return [for (final result in results) result!];
}
