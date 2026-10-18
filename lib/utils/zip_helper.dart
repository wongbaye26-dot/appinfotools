import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/zip_guard.dart';
import 'package:archive_safety/archive_safety.dart'
    show
        ArchiveOpenResult,
        ZipBudget,
        looksLikeZip,
        looksStructurallyBroken,
        readArchiveHeader;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

class ZipHelper {
  Archive? _archive;

  /// 已打开的归档；未打开或打开失败时为 `null`。
  ///
  /// 暴露出来是为了让 IPA 解析能在**已经过全部安全检查**的同一个归档上继续
  /// 工作 —— 否则调用方只能自己再开一次，等于把 [open] 里那串安全判定
  /// （魔数、结构完整性、解压预算）抄第二遍。
  Archive? get archive => _archive;

  /// 打开 ZIP 文件，使用 InputFileStream 流式读取避免将整个文件加载到内存。
  ///
  /// 返回具体的失败原因而非 `bool`，调用方据此区分「不是归档」「归档损坏」
  /// 「命中解压预算」「IO 失败」—— 这四种情况对用户的含义完全不同。
  Future<ArchiveOpenResult> open(String filePath) async {
    InputFileStream? inputStream;
    try {
      if (!looksLikeZip(await readArchiveHeader(filePath))) {
        return ArchiveOpenResult.notArchive;
      }
      final length = await File(filePath).length();
      inputStream = InputFileStream(filePath);
      final archive = ZipDecoder().decodeStream(inputStream);
      if (looksStructurallyBroken(archive, length)) {
        log.severe('Refusing to open $filePath: structurally broken archive');
        _archive = null;
        return ArchiveOpenResult.corrupt;
      }
      if (ZipBudget.isExceeded(archive)) {
        _archive = null;
        log.severe('Refusing to open $filePath: decompression bomb detected');
        return ArchiveOpenResult.resourceBudgetExceeded;
      }
      _archive = archive;
      return ArchiveOpenResult.ok;
    } on FileSystemException catch (e) {
      log.severe('Failed to open zip file (io): $e');
      return ArchiveOpenResult.ioError;
    } catch (e) {
      log.severe('Failed to open zip file: $e');
      return ArchiveOpenResult.corrupt;
    } finally {
      inputStream?.closeSync();
    }
  }

  Future<Uint8List?> readFileContent(String fileName) async {
    try {
      final file = _archive?.findFile(fileName);
      if (file == null) return null;
      final read = ZipBudget.readEntry(file);
      if (!read.isOk) {
        log.severe('Refusing to read $fileName: ${read.violation}');
        return null;
      }
      return read.bytes;
    } catch (e) {
      log.severe('Failed to read file content: $e');
      return null;
    }
  }

  List<String> listFiles({String? extension}) {
    final files = _archive?.files ?? [];
    final lowerExtension = extension?.toLowerCase();
    return files
        .where((file) => file.isFile)
        .map((file) => file.name)
        .where((name) =>
            lowerExtension == null ||
            name.toLowerCase().endsWith(lowerExtension))
        .toList();
  }

  /// 将归档中的单个条目解出到 [outputPath]。
  ///
  /// [entryName] 与 [outputPath] 均会被 [ZipGuard.safeJoin] 校验，
  /// 因此调用方传入的条目名（如 `Android/obb/...`）无法逃逸出目标目录。
  Future<bool> extractFile(String entryName, String outputPath) async {
    final archive = _archive;
    if (archive == null) {
      log.severe('extractFile called without an open archive');
      return false;
    }
    final file = archive.findFile(entryName);
    if (file == null) {
      log.severe('File not found in zip: $entryName');
      return false;
    }
    final root = path.dirname(path.absolute(outputPath));
    try {
      final out = ZipGuard.safeJoin(root, path.basename(outputPath));
      // **落盘前也要过闸**：中央目录撒谎时，`file.content` 会产出远超声明值的
      // 字节 —— 直接写盘等于让一个几 MB 的包写满磁盘。
      final read = ZipBudget.readEntry(file);
      if (!read.isOk) {
        log.severe('Refusing to extract $entryName: ${read.violation}');
        return false;
      }
      await Directory(path.dirname(out)).create(recursive: true);
      await File(out).writeAsBytes(read.bytes!, flush: true);
      return true;
    } on ArgumentError catch (e) {
      log.severe('Refusing unsafe zip entry $entryName: ${e.message}');
      return false;
    } catch (e) {
      log.severe('Failed to extract file: $e');
      return false;
    }
  }

  void close() {
    _archive?.clearSync();
    _archive = null;
  }
}
