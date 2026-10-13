import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:crypto/crypto.dart';

/// 文件的三种哈希值。
///
/// 一起返回而不是各算各的：三种算法可以共用**一次**文件读取，在大 APK 上
/// 分别读三遍是明显的浪费。
class FileHashes {
  final String md5;
  final String sha1;

  /// 规范 4.1 要求提供 SHA-256；此前项目只有 MD5 / SHA-1。
  final String sha256;

  const FileHashes({
    required this.md5,
    required this.sha1,
    required this.sha256,
  });

  @override
  String toString() => 'FileHashes(md5: $md5, sha1: $sha1, sha256: $sha256)';
}

/// 简单的 Digest 收集器，用于 chunked conversion
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 在独立 isolate 中流式计算文件的 MD5 / SHA-1 / SHA-256。
///
/// 三种算法共用一次文件读取；内存占用恒定 O(chunkSize)，不随文件大小增长。
FileHashes _computeHashesInIsolate(String filePath) {
  final input = File(filePath).openSync();

  const chunkSize = 4 * 1024 * 1024; // 4MB
  final buffer = Uint8List(chunkSize);

  final md5Out = _DigestSink();
  final sha1Out = _DigestSink();
  final sha256Out = _DigestSink();

  final md5Chunked = md5.startChunkedConversion(md5Out);
  final sha1Chunked = sha1.startChunkedConversion(sha1Out);
  final sha256Chunked = sha256.startChunkedConversion(sha256Out);

  try {
    int bytesRead;
    while ((bytesRead = input.readIntoSync(buffer)) > 0) {
      final chunk = Uint8List.sublistView(buffer, 0, bytesRead);
      md5Chunked.add(chunk);
      sha1Chunked.add(chunk);
      sha256Chunked.add(chunk);
    }
  } finally {
    input.closeSync();
  }

  md5Chunked.close();
  sha1Chunked.close();
  sha256Chunked.close();

  return FileHashes(
    md5: md5Out.value.toString(),
    sha1: sha1Out.value.toString(),
    sha256: sha256Out.value.toString(),
  );
}

/// 计算文件的 MD5 / SHA-1 / SHA-256（在独立 isolate 中执行）。
///
/// 一次读取文件，三种算法同时计算。
Future<FileHashes> computeFileHashes(String filePath) async {
  try {
    return await Isolate.run(() => _computeHashesInIsolate(filePath));
  } catch (e) {
    log.warning('computeFileHashes: failed to compute hashes: $e');
    rethrow;
  }
}
