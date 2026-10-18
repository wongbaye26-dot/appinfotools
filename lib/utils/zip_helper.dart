import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/zip_guard.dart';
import 'package:archive_safety/archive_safety.dart'
    show
        ArchiveOpenResult,
        BoundedReadLedger,
        ZipBudget,
        ZipBudgetLimits,
        looksLikeZip,
        looksStructurallyBroken,
        readArchiveHeader;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

class ZipHelper {
  /// 本次流程的读取预算上限；`null` 表示用默认值。
  ///
  /// **可注入是为了集成测试**：真实上限是 1 GiB，而测试必须用小预算才能
  /// 在不制造大内存分配的前提下验证「超限即中止」。
  final int? maxSessionBytes;

  ZipHelper({this.maxSessionBytes});

  Archive? _archive;

  /// 最近一次 [open] 因解压预算被拒绝时的**具体原因**。
  ///
  /// 「归档超出安全解压上限」这句话对用户和排查都没有信息量 —— 真正要回答的
  /// 是**哪个条目**、声明了多少字节、上限是多少。这里是那份结构化说明，
  /// 由调用方原样呈现（英文，面向排查），不在这里拼中文。
  String? _lastBudgetViolation;

  /// 见 [_lastBudgetViolation]。`null` 表示没有命中预算。
  String? get lastBudgetViolation => _lastBudgetViolation;

  /// 本次打开期间的**共享**读取预算（V2.4.12）。每次 `open` 重置。
  late BoundedReadLedger _ledger = _newLedger();

  BoundedReadLedger _newLedger() => BoundedReadLedger(
        maxTotalBytes: maxSessionBytes ?? ZipBudgetLimits.maxSessionOutputBytes,
      );

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
    _lastBudgetViolation = null;
    try {
      if (!looksLikeZip(await readArchiveHeader(filePath))) {
        return ArchiveOpenResult.notArchive;
      }
      final length = await File(filePath).length();
      _ledger = _newLedger();
      inputStream = InputFileStream(filePath);
      final archive = ZipDecoder().decodeStream(inputStream);
      if (looksStructurallyBroken(archive, length)) {
        log.severe('Refusing to open $filePath: structurally broken archive');
        _archive = null;
        return ArchiveOpenResult.corrupt;
      }
      final violation = ZipBudget.check(archive);
      if (violation != null) {
        _archive = null;
        // 记下**是哪一条**超的，而不是只说「超了」。
        _lastBudgetViolation = violation.describe();
        log.severe('Refusing to open $filePath: $_lastBudgetViolation');
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
      final read = ZipBudget.readEntry(file, ledger: _ledger);
      if (!read.isOk) {
        log.severe('Refusing to read $fileName: ${read.failure?.describe()}');
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
      final read = ZipBudget.readEntry(file, ledger: _ledger);
      if (!read.isOk) {
        log.severe(
            'Refusing to extract $entryName: ${read.failure?.describe()}');
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
