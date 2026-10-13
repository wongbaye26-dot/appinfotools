import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/zip_guard.dart';
import 'package:ipa_parser/ipa_parser.dart' show IosBundle;

/// 解包一个 bundle 到临时目录的结果。
class IpaExtractionResult {
  /// 解包后的 bundle 目录绝对路径；失败时为 `null`。
  final String? bundlePath;

  /// 需要由调用方清理的临时根目录；失败时为 `null`。
  ///
  /// **调用方必须负责删除它**（见 `cleanUp`）。放在这里而不是让调用方自己
  /// 记住路径，是为了避免「拿到了 bundlePath 却忘了 tempRoot」这种泄漏。
  final String? tempRoot;

  /// 实际写出的条目数。
  final int entryCount;

  /// 实际写出的字节数。
  final int totalBytes;

  /// 其中被当作普通文件写出的符号链接条目数。
  ///
  /// 符号链接**不会**在磁盘上被创建：归档里的链接目标可以指向目标目录之外，
  /// 一旦真的建出链接，后续任何按路径访问都可能被引到外面去。这里把链接
  /// 当作普通文件写（内容就是链接目标那串文本），因此不会逃逸。
  ///
  /// 代价是这类条目的字节与签名时的原始文件不同，`codesign` 校验可能因此
  /// 失败。调用方据此区分「签名被篡改」与「我们的解包方式导致的不一致」。
  final int symlinkCount;

  /// 是否被取消。
  final bool cancelled;

  /// 失败原因（人类可读）；成功时为 `null`。
  final String? failure;

  /// 失败原因的机器可读标识，便于测试与分类。
  final String? failureCode;

  const IpaExtractionResult._({
    this.bundlePath,
    this.tempRoot,
    this.entryCount = 0,
    this.totalBytes = 0,
    this.symlinkCount = 0,
    this.cancelled = false,
    this.failure,
    this.failureCode,
  });

  const IpaExtractionResult.success({
    required String bundlePath,
    required String tempRoot,
    required int entryCount,
    required int totalBytes,
    int symlinkCount = 0,
  }) : this._(
          bundlePath: bundlePath,
          tempRoot: tempRoot,
          entryCount: entryCount,
          totalBytes: totalBytes,
          symlinkCount: symlinkCount,
        );

  const IpaExtractionResult.failure(String code, String reason)
      : this._(failureCode: code, failure: reason);

  const IpaExtractionResult.cancelled()
      : this._(cancelled: true, failureCode: 'cancelled');

  bool get ok => bundlePath != null;

  @override
  String toString() => ok
      ? 'IpaExtractionResult($bundlePath, $entryCount entries, $totalBytes B)'
      : 'IpaExtractionResult(${cancelled ? 'cancelled' : failureCode})';
}

/// 把一个 bundle 从归档里解包到临时目录。
///
/// 规范 5.1 要求「禁止未校验解包」，5.5 又要求「限制文件大小、总解压量、
/// 条目数、比例与时间；支持取消；保证临时目录清理」。本类是那两条的落地：
///
/// 1. **先算后写**：第一遍只统计条目数与声明解压总量，超限直接拒绝 ——
///    开始写盘之后再发现超预算，磁盘上已经躺着一堆文件了。
/// 2. **逐条路径校验**：每条都过 [ZipGuard.safeJoin]，越界即抛异常，
///    不静默跳过（静默跳过会让调用方以为拿到了完整内容）。
/// 3. **可取消**：每写一条检查一次取消标志。
/// 4. **不越界读**：条目内容长度再校验一次，防止 ZIP 头部谎报尺寸。
///
/// 已知局限：ZIP 里的符号链接会被当作普通文件写出（`archive` 包不暴露
/// 外部属性）。对签名验证没有影响 —— `codesign` 校验的是文件内容哈希。
class IpaBundleExtractor {
  IpaBundleExtractor._();

  /// 单次解包的条目数上限。
  static const int maxEntryCount = 20000;

  /// 单次解包的解压总量上限（512 MiB）。
  ///
  /// 比容器层的 1 GiB 预算更紧：那一层只是「不要解压炸弹」，这一层是真的
  /// 往用户磁盘上写文件。
  static const int maxTotalBytes = 512 * 1024 * 1024;

  /// 解包 [bundle] 到新建的临时目录，返回其中的 bundle 目录路径。
  ///
  /// [isCancelled] 在每条写入前被调用，返回 true 即中止并清理临时目录。
  static Future<IpaExtractionResult> extract(
    Archive archive,
    IosBundle bundle, {
    bool Function()? isCancelled,
    String? destinationRoot,
  }) async {
    final prefix = '${bundle.path}/';

    // 第一遍：只统计，不写盘。
    final entries = <ArchiveFile>[];
    var plannedBytes = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      if (!name.startsWith(prefix)) continue;
      if (name.length == prefix.length) continue;

      entries.add(file);
      plannedBytes += file.size;
      if (entries.length > maxEntryCount) {
        return const IpaExtractionResult.failure(
          'too_many_entries',
          'the bundle has more than $maxEntryCount file entries',
        );
      }
      if (plannedBytes > maxTotalBytes) {
        return const IpaExtractionResult.failure(
          'too_large',
          'the bundle declares more than $maxTotalBytes bytes of files',
        );
      }
    }

    if (entries.isEmpty) {
      return const IpaExtractionResult.failure(
        'empty_bundle',
        'the bundle contains no file entries',
      );
    }

    Directory? tempRoot;
    try {
      tempRoot = destinationRoot != null
          ? await Directory(destinationRoot).create(recursive: true)
          : await Directory.systemTemp.createTemp('appinfo_ipa_');
      final root = tempRoot.path;

      // bundle 目录名保持原样，`codesign` 依赖 `.app` 后缀识别 bundle。
      final bundleTarget = ZipGuard.safeJoin(root, bundle.name);

      var written = 0;
      var writtenBytes = 0;
      var symlinks = 0;

      for (final file in entries) {
        if (isCancelled != null && isCancelled()) {
          await _deleteQuietly(tempRoot);
          return const IpaExtractionResult.cancelled();
        }

        final name = file.name.replaceAll('\\', '/');
        final relative = name.substring(prefix.length);
        final target = ZipGuard.safeJoin(bundleTarget, relative);

        final content = file.content;
        // ZIP 头声明的尺寸与实际解出的长度不一致时拒绝 —— 继续写下去就是
        // 在替攻击者把谎报的尺寸坐实。中心目录里的尺寸是权威值，对正常
        // 归档而言两者必然相等，因此这里不会误伤。
        if (content.length != file.size) {
          await _deleteQuietly(tempRoot);
          return IpaExtractionResult.failure(
            'size_mismatch',
            '$name declared ${file.size} bytes but decompressed to '
                '${content.length}',
          );
        }

        // 按**实际**字节再兜一道：即使每个条目的声明尺寸都很小，累计量也不
        // 允许突破上限。声明值那一道只是为了让拒绝发生在写盘之前。
        writtenBytes += content.length;
        if (writtenBytes > maxTotalBytes) {
          await _deleteQuietly(tempRoot);
          return const IpaExtractionResult.failure(
            'too_large',
            'the extracted files exceed $maxTotalBytes bytes',
          );
        }

        // 符号链接一律当普通文件写。真的建链接等于把归档里的相对路径交给
        // 文件系统去解释，而它可以是 `../../../..`。
        if (file.isSymbolicLink) symlinks++;

        final out = File(target);
        await out.parent.create(recursive: true);
        await out.writeAsBytes(content, flush: false);
        written++;
      }

      return IpaExtractionResult.success(
        bundlePath: bundleTarget,
        tempRoot: root,
        entryCount: written,
        totalBytes: writtenBytes,
        symlinkCount: symlinks,
      );
    } on ArgumentError catch (e) {
      // safeJoin 拒绝越界条目。
      await _deleteQuietly(tempRoot);
      return IpaExtractionResult.failure('unsafe_entry', '${e.message}');
    } on FileSystemException catch (e) {
      await _deleteQuietly(tempRoot);
      return IpaExtractionResult.failure('io_error', '$e');
    } catch (e) {
      await _deleteQuietly(tempRoot);
      return IpaExtractionResult.failure('unexpected', '$e');
    }
  }

  /// 删除临时目录。失败只记日志 —— 清理失败不该让整个分析流程失败。
  static Future<void> cleanUp(String? tempRoot) async {
    if (tempRoot == null) return;
    await _deleteQuietly(Directory(tempRoot));
  }

  static Future<void> _deleteQuietly(Directory? dir) async {
    if (dir == null) return;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      log.warning('IpaBundleExtractor: 临时目录清理失败 ${dir.path}: $e');
    }
  }

  /// 供 UI 展示的路径基名。
  static String basename(String filePath) => path.basename(filePath);
}
