/// 归档条目的**平台无关**事实。
///
/// Android APK 与 iOS IPA 都是 ZIP，但两边的安全扫描需要同一套「条目 →
/// 是否代码 → 是否被扫描」的输入。把这件事放在 `analysis_model` 里，
/// 两个解析器包就不必互相依赖，也不会各写一份路径归一化。
///
/// 约定：
/// - [path] 已归一化为 `/` 分隔、去掉前导 `./`；空串表示无法归一化；
/// - [sizeBytes] 是 ZIP 中央目录声明的**未压缩**大小（可能撒谎，读取时必须
///   另设预算）；
/// - [compressedBytes] / [compressionMethod] 不可得时为 `null`，不填空值。
class ContainerEntryFact {
  /// 归一化后的归档内路径。
  final String path;

  /// 声明的未压缩大小（字节）。
  final int sizeBytes;

  /// 声明的压缩大小（字节）；存储型条目等于 [sizeBytes]。
  final int? compressedBytes;

  /// ZIP 压缩方法编号（0 = stored，8 = deflate）；非 ZIP 容器为 `null`。
  final int? compressionMethod;

  /// 是否为目录条目。
  final bool isDirectory;

  const ContainerEntryFact({
    required this.path,
    required this.sizeBytes,
    this.compressedBytes,
    this.compressionMethod,
    this.isDirectory = false,
  });

  bool get isFile => !isDirectory;

  ContainerEntryFact copyWith({
    String? path,
    int? sizeBytes,
    int? compressedBytes,
    int? compressionMethod,
    bool? isDirectory,
  }) {
    return ContainerEntryFact(
      path: path ?? this.path,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      compressedBytes: compressedBytes ?? this.compressedBytes,
      compressionMethod: compressionMethod ?? this.compressionMethod,
      isDirectory: isDirectory ?? this.isDirectory,
    );
  }

  @override
  String toString() => 'ContainerEntryFact($path, $sizeBytes bytes'
      '${isDirectory ? ', dir' : ''})';
}

/// 归档路径归一化：统一 `/`、去掉前导 `./` 与结尾 `/`。
///
/// 不做路径穿越检查 —— 那是 `archive_safety` 的职责；这里只保证比较键稳定。
String normalizeArchivePath(String value) {
  var out = value.replaceAll('\\', '/');
  while (out.startsWith('./')) {
    out = out.substring(2);
  }
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}
