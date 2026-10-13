import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/zip_guard.dart';
import 'package:path/path.dart' as path;

class ZipHelper {
  Archive? _archive;
  String? _filePath;

  /// 打开 ZIP 文件，使用 InputFileStream 流式读取避免将整个文件加载到内存
  Future<bool> open(String filePath) async {
    InputFileStream? inputStream;
    try {
      _filePath = filePath;
      inputStream = InputFileStream(filePath);
      _archive = ZipDecoder().decodeStream(inputStream);
      if (_isZipBomb(_archive!)) {
        _archive = null;
        throw Exception('ZIP bomb detected');
      }
      return true;
    } catch (e) {
      log.severe('Failed to open zip file: $e');
      return false;
    } finally {
      inputStream?.closeSync();
    }
  }

  Future<Uint8List?> readFileContent(String fileName) async {
    try {
      final file = _archive?.findFile(fileName);
      return file?.content as Uint8List?;
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

  String _safeJoin(String root, String entry) =>
      ZipGuard.safeJoin(root, entry);

  // ZIP bomb protection
  bool _isZipBomb(Archive archive) => ZipGuard.isBomb(archive);

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
      await Directory(path.dirname(out)).create(recursive: true);
      await File(out).writeAsBytes(file.content as List<int>, flush: true);
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
    _filePath = null;
  }
}
