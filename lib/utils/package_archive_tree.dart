// 把已打开的包接成文件树，并支持读取**嵌套归档内**的条目。
//
// 为什么单独一层：`ArchiveTreeBuilder` 是平台中立的，它不知道 ZipBudget；
// `ApkReader` 知道预算但只认识外层 zip。这里把两者接起来，并保证：
// - 建树时的嵌套解压走同一条 BoundedReadLedger（和外层读取共享总预算）；
// - 预览/导出读取也走预算，不会因为「只是看一眼」绕过上限；
// - 嵌套路径用 `!` 分隔，与树的路径一致。

import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';

/// 建树结果。
class PackageTreeResult {
  final ArchiveTree? tree;

  /// 失败原因（稳定 code 之外的英文/诊断说明）；成功为 null。
  final String? failure;

  const PackageTreeResult({this.tree, this.failure});

  bool get isOk => tree != null;
}

/// 读取一个嵌套条目的结果。
class PackageEntryRead {
  final Uint8List? bytes;
  final String? skipCode;

  const PackageEntryRead({this.bytes, this.skipCode});

  bool get isOk => bytes != null;
}

/// 包文件树 + 条目读取。
class PackageArchiveTree {
  final ApkReader _reader;
  final BoundedReadLedger _ledger;

  PackageArchiveTree._(this._reader, this._ledger);

  /// 打开包并建树。调用方负责 [close]。
  static Future<(PackageArchiveTree?, PackageTreeResult)> open(
    String path, {
    ArchiveTreeLimits limits = const ArchiveTreeLimits(),
  }) async {
    final reader = ApkReader();
    final opened = await reader.open(path);
    if (!opened.isOk || reader.archive == null) {
      return (null, PackageTreeResult(failure: opened.description));
    }
    final ledger = BoundedReadLedger(
      maxTotalBytes: ZipBudgetLimits.maxSessionOutputBytes,
    );
    final tree = ArchiveTreeBuilder.build(
      reader.archive!,
      limits: limits,
      readForNesting: (file) {
        final read = ZipBudget.readEntry(file, ledger: ledger);
        return read.isOk ? read.bytes : null;
      },
    );
    return (
      PackageArchiveTree._(reader, ledger),
      PackageTreeResult(tree: tree)
    );
  }

  /// 读取条目（支持 `a.zip!b.txt` 形式）。
  ///
  /// 预览只用前 [maxBytes] 字节：整条读取留给导出，UI 不应该把 200 MB 的
  /// assets 全解进内存。
  PackageEntryRead readEntry(String path, {required int maxBytes}) {
    final bang = path.indexOf('!');
    if (bang < 0) {
      final bytes = _reader.readFilePrefix(path, maxBytes: maxBytes);
      return PackageEntryRead(
        bytes: bytes,
        skipCode: bytes == null ? 'entry.unreadable' : null,
      );
    }

    final containerPath = path.substring(0, bang);
    final innerPath = path.substring(bang + 1);
    final container = _reader.readFile(containerPath);
    if (container == null) {
      return const PackageEntryRead(skipCode: 'entry.containerUnreadable');
    }
    if (!_looksLikeZip(container)) {
      return const PackageEntryRead(skipCode: 'entry.containerNotZip');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(container, verify: false);
    } catch (_) {
      return const PackageEntryRead(skipCode: 'entry.containerUndecodable');
    }
    final file = archive.findFile(innerPath);
    if (file == null) {
      return const PackageEntryRead(skipCode: 'entry.missing');
    }
    final read = ZipBudget.readEntry(file, maxBytes: maxBytes, ledger: _ledger);
    return PackageEntryRead(
      bytes: read.isOk ? read.bytes : null,
      skipCode: read.isOk ? null : 'entry.budgetRefused',
    );
  }

  /// 整条读取（导出用）。
  Uint8List? readAll(String path) {
    final bang = path.indexOf('!');
    if (bang < 0) return _reader.readFile(path);
    final container = _reader.readFile(path.substring(0, bang));
    if (container == null || !_looksLikeZip(container)) return null;
    final archive = ZipDecoder().decodeBytes(container, verify: false);
    final file = archive.findFile(path.substring(bang + 1));
    if (file == null) return null;
    final read = ZipBudget.readEntry(file, ledger: _ledger);
    return read.isOk ? read.bytes : null;
  }

  static bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;

  void close() => _reader.close();
}
