import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

/// ZIP 解包安全防护。
///
/// 归档内容完全由不可信输入控制（用户打开的 APK/XAPK，或远程下载的
/// platform-tools / build-tools 压缩包），因此必须防御：
///
/// 1. **Zip Slip**：条目名形如 `../../.ssh/authorized_keys` 时写入目录之外。
/// 2. **Zip Bomb**：声明的解压体积或压缩比异常，导致磁盘/内存被耗尽。
/// 3. **绝对路径 / 盘符 / UNC 前缀**：Windows 下的逃逸形式。
class ZipGuard {
  /// 单个归档允许的解压后总字节数上限（1 GiB）。
  static const int maxTotalUncompressed = 1024 * 1024 * 1024;

  /// 单个归档允许的最大条目数。
  static const int maxEntryCount = 100000;

  /// 触发压缩比检查的最小解压体积（16 MiB）。
  ///
  /// 小体积文件即使压缩比很高也通常是合法资源（例如大面积为零的
  /// `resources.arsc`），不加以区分会产生误报。
  static const int ratioCheckMinSize = 16 * 1024 * 1024;

  /// 允许的最大压缩比（100:1）。
  static const int maxCompressionRatio = 100;

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

  /// 校验归档是否存在 zip bomb 特征。
  ///
  /// 只读取归档头部声明的尺寸，不实际解压，因此开销可忽略。
  static bool isBomb(Archive archive) {
    var totalUncompressed = 0;
    var count = 0;
    for (final file in archive.files) {
      count++;
      if (count > maxEntryCount) {
        return true;
      }
      if (!file.isFile) {
        continue;
      }
      // ArchiveFile.size 为解压后的尺寸（解码时取自 ZipFile.uncompressedSize）。
      final uncompressed = file.size;
      if (uncompressed < 0) {
        return true;
      }
      totalUncompressed += uncompressed;
      if (totalUncompressed > maxTotalUncompressed) {
        return true;
      }
      final raw = file.rawContent;
      if (raw is ZipFile) {
        final compressed = raw.compressedSize;
        if (uncompressed > ratioCheckMinSize &&
            compressed > 0 &&
            uncompressed > compressed * maxCompressionRatio) {
          return true;
        }
      }
    }
    return false;
  }

  /// 打开归档前的统一校验：命中 bomb 特征则抛异常。
  static void ensureNotBomb(Archive archive, {String? source}) {
    if (isBomb(archive)) {
      throw ArchiveException(
        'Refusing to open archive: decompression bomb detected'
        '${source == null ? '' : ' ($source)'}',
      );
    }
  }

  /// 将归档安全地解包到 [destination]。
  ///
  /// - 逐条通过 [safeJoin] 校验，任何越界条目都会跳过并记录日志语义为异常抛出。
  /// - [stripPrefix] 用于剥离归档内的顶层目录（例如 `platform-tools/`）。
  /// - 返回实际写入的条目数。
  ///
  /// 若归档中存在越界条目则抛出 [ArgumentError]，不做静默忽略，
  /// 以免调用方误以为拿到了完整内容。
  static Future<int> extractToDirectory(
    Archive archive,
    String destination, {
    String? stripPrefix,
  }) async {
    final root = path.normalize(path.absolute(destination));
    await Directory(root).create(recursive: true);

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
        final outFile = File(target);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>, flush: true);
        written++;
      } else {
        await Directory(target).create(recursive: true);
      }
    }
    return written;
  }
}
