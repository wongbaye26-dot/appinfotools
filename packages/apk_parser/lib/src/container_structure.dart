import 'package:archive/archive.dart';

/// 归档容器的结构概览。
///
/// 规范 4.1 要求提供「DEX 数量、SO 文件、ABI、资源目录」这类结构信息。
///
/// 全部数据只来自条目名与声明尺寸，**不解压任何内容**（`Archive` 解码阶段已把
/// 内容物化，这里只做遍历与统计），因此开销很低。
class ContainerStructure {
  /// 文件条目数（不含目录条目）。
  final int fileEntryCount;

  /// `classes*.dex` 条目。
  final List<DexEntry> dexFiles;

  /// `lib/<abi>/` 下的原生库条目。
  final List<NativeLibraryEntry> nativeLibraries;

  /// 出现过的 ABI，已排序。
  final List<String> abis;

  /// 顶层目录 → 统计。仅包含**有文件**的顶层目录。
  final Map<String, DirectoryStat> topLevelDirectories;

  /// 归档全部文件条目声明的解压后字节数之和。
  final int totalUncompressedBytes;

  const ContainerStructure({
    this.fileEntryCount = 0,
    this.dexFiles = const [],
    this.nativeLibraries = const [],
    this.abis = const [],
    this.topLevelDirectories = const {},
    this.totalUncompressedBytes = 0,
  });

  int get dexFileCount => dexFiles.length;
  int get nativeLibraryCount => nativeLibraries.length;

  /// 按解压后字节数降序排列的顶层目录，最多 [limit] 个。
  ///
  /// 限制条数是刻意的：顶层目录可能有几十个，全列出来在详情页里只会变成
  /// 噪声。按体积取前几名才是用户真正想看的。
  List<MapEntry<String, DirectoryStat>> topDirectoriesBySize({int limit = 8}) {
    final entries = topLevelDirectories.entries.toList()
      ..sort((a, b) =>
          b.value.uncompressedBytes.compareTo(a.value.uncompressedBytes));
    return entries.take(limit).toList();
  }
}

/// 一个 DEX 条目。
class DexEntry {
  final String name;
  final int size;

  const DexEntry({required this.name, required this.size});

  @override
  String toString() => 'DexEntry($name, $size)';
}

/// 一个原生库条目。
class NativeLibraryEntry {
  /// ABI 目录名，例如 `arm64-v8a`。
  final String abi;

  /// 文件名，例如 `libfoo.so`。
  final String name;

  /// 完整条目名，例如 `lib/arm64-v8a/libfoo.so`。
  final String path;

  final int size;

  const NativeLibraryEntry({
    required this.abi,
    required this.name,
    required this.path,
    required this.size,
  });

  @override
  String toString() => 'NativeLibraryEntry($path, $size)';
}

/// 一个顶层目录的统计。
class DirectoryStat {
  final int fileCount;
  final int uncompressedBytes;

  const DirectoryStat({
    required this.fileCount,
    required this.uncompressedBytes,
  });

  @override
  String toString() => 'DirectoryStat($fileCount files, $uncompressedBytes B)';
}

/// 从归档条目列表收集结构信息。
class ContainerStructureCollector {
  ContainerStructureCollector._();

  static final _dexNamePattern = RegExp(r'^classes(\d*)\.dex$');
  static final _nativeLibPattern = RegExp(r'^lib/([^/]+)/([^/]+)$');

  static ContainerStructure collect(Archive archive) {
    final fileEntries = archive.files.where((f) => f.isFile).toList();

    final dexFiles = <DexEntry>[];
    final nativeLibraries = <NativeLibraryEntry>[];
    final abis = <String>{};
    final directories = <String, DirectoryStat>{};
    var totalUncompressed = 0;

    for (final entry in fileEntries) {
      final size = entry.size;
      totalUncompressed += size;

      if (_dexNamePattern.hasMatch(entry.name)) {
        dexFiles.add(DexEntry(name: entry.name, size: size));
      }

      final libMatch = _nativeLibPattern.firstMatch(entry.name);
      if (libMatch != null) {
        final abi = libMatch.group(1)!;
        abis.add(abi);
        nativeLibraries.add(NativeLibraryEntry(
          abi: abi,
          name: libMatch.group(2)!,
          path: entry.name,
          size: size,
        ));
      }

      final topLevel = _topLevelDirectoryOf(entry.name);
      final previous = directories[topLevel];
      directories[topLevel] = DirectoryStat(
        fileCount: (previous?.fileCount ?? 0) + 1,
        uncompressedBytes: (previous?.uncompressedBytes ?? 0) + size,
      );
    }

    dexFiles.sort((a, b) => a.name.compareTo(b.name));
    nativeLibraries.sort((a, b) => a.path.compareTo(b.path));

    return ContainerStructure(
      fileEntryCount: fileEntries.length,
      dexFiles: dexFiles,
      nativeLibraries: nativeLibraries,
      abis: abis.toList()..sort(),
      topLevelDirectories: directories,
      totalUncompressedBytes: totalUncompressed,
    );
  }

  /// 取条目名所属的顶层目录；根目录下的条目归到 `(root)`。
  static String _topLevelDirectoryOf(String entryName) {
    final slash = entryName.indexOf('/');
    return slash <= 0 ? '(root)' : entryName.substring(0, slash);
  }
}
