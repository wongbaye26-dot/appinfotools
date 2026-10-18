import 'dart:io';

import 'package:archive_safety/archive_safety.dart'
    show BoundedReadLedger, ZipBombException, ZipBudget, ZipBudgetLimits;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

/// 归档**路径**安全防护（应用层）。
///
/// 解压**预算**（ZIP 炸弹判定）已下沉到 `package:apk_parser` 的 [ZipBudget]，
/// 本类不再重复实现 —— 历史上 `ZipGuard` 与 `ApkReader` 各写了一份逻辑等价、
/// 常量重复的判定，任何一边调整阈值都不会同步到另一边。
///
/// 本类只保留依赖 `dart:io` / `path` 的路径级防护：
///
/// 1. **Zip Slip**：条目名形如 `../../.ssh/authorized_keys` 时写入目录之外。
/// 2. **绝对路径 / 盘符 / UNC 前缀**：Windows 下的逃逸形式。
class ZipGuard {
  /// 将归档条目名安全地拼接到目标根目录下。
  ///
  /// 拒绝绝对路径、盘符路径、UNC 路径以及任何解析后逃逸出 [root] 的条目。
  /// [root] 会被规范化为绝对路径后比较，因此传入相对根目录同样安全。
  static String safeJoin(String root, String entry) {
    // 统一分隔符：ZIP 规范要求使用 `/`
    final normalizedEntry = entry.replaceAll('\\', '/');

    if (normalizedEntry.isEmpty) {
      throw ArgumentError('zip entry name is empty');
    }
    // 绝对路径（POSIX 根、盘符 `C:`、UNC `//server/share`）一律拒绝。
    if (normalizedEntry.startsWith('/') ||
        normalizedEntry.startsWith('~') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalizedEntry)) {
      throw ArgumentError('zip entry uses an absolute path: $entry');
    }
    // 逐段检查，确保没有任何 `..` 试图上跳。
    for (final segment in normalizedEntry.split('/')) {
      if (segment == '..') {
        throw ArgumentError('zip entry escapes destination: $entry');
      }
    }

    final rootAbs = path.normalize(path.absolute(root));
    final resolved = path.normalize(path.join(rootAbs, normalizedEntry));

    if (resolved != rootAbs && !path.isWithin(rootAbs, resolved)) {
      throw ArgumentError('zip entry escapes destination: $entry');
    }
    return resolved;
  }

  /// 将归档安全地解包到 [destination]。
  ///
  /// - 逐条通过 [safeJoin] 校验，任何越界条目都会抛异常而非静默跳过。
  /// - [stripPrefix] 用于剥离归档内的顶层目录（例如 `platform-tools/`）。
  /// - 返回实际写入的条目数。
  ///
  /// 调用方应在解包**之前**先做 [ZipBudget.ensureWithin] 校验：一旦开始写入
  /// 磁盘再发现超预算就已经太晚了。
  ///
  /// 若归档中存在越界条目则抛出 [ArgumentError]，不做静默忽略，
  /// 以免调用方误以为拿到了完整内容。
  /// [maxSessionBytes] 可覆盖本次解包的真实产出预算（**测试注入用**）。
  /// 生产调用不传，走 `ZipBudgetLimits.maxSessionOutputBytes`。
  static Future<int> extractToDirectory(
    Archive archive,
    String destination, {
    String? stripPrefix,
    int? maxSessionBytes,
  }) async {
    final root = path.normalize(path.absolute(destination));
    await Directory(root).create(recursive: true);

    // 一次解包流程共用一个预算 —— 逐条目各自计会漏掉「加起来很大」。
    final ledger = BoundedReadLedger(
      maxTotalBytes: maxSessionBytes ?? ZipBudgetLimits.maxSessionOutputBytes,
    );

    var written = 0;
    for (final file in archive.files) {
      var name = file.name;
      if (stripPrefix != null && stripPrefix.isNotEmpty) {
        if (!name.startsWith(stripPrefix)) {
          continue;
        }
        name = name.substring(stripPrefix.length);
      }
      if (name.isEmpty) {
        continue;
      }

      final target = safeJoin(root, name);

      if (file.isFile) {
        // **有界读取**（V2.4.12）：`file.content` 无上限，而这里会把内容写到
        // 磁盘 —— 一个几 MB 的包足以写满磁盘。整个解包流程共用一个 ledger。
        final read = ZipBudget.readEntry(file, ledger: ledger);
        if (!read.isOk) {
          throw ZipBombException(
            'Refusing to extract: ${read.failure!.describe()}',
            source: destination,
          );
        }
        final outFile = File(target);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(read.bytes!, flush: true);
        written++;
      } else {
        await Directory(target).create(recursive: true);
      }
    }
    return written;
  }
}
