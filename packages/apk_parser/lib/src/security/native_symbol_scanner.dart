import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

import '../native/elf.dart';

/// [NativeSymbolScanner.selectLibraries] 的挑选结果。
class NativeLibrarySelection {
  /// 要分析的名字（已按 ABI 优先级与库名排序）。
  final List<String> selected;

  /// 被跳过的（名字 + 原因）。**必须进报告的覆盖范围说明**。
  final List<String> skipped;

  const NativeLibrarySelection(
      {this.selected = const [], this.skipped = const []});

  bool get isEmpty => selected.isEmpty;

  @override
  String toString() => 'NativeLibrarySelection(${selected.length} selected, '
      '${skipped.length} skipped)';
}

/// 一个待扫描的原生库：归档内名字 + 字节。
///
/// 名字（如 `lib/arm64-v8a/libnative.so`）同时是证据位置 —— 报告里要能指出
/// 是**哪个 ABI 的哪个库**导入了这个符号。
class NativeLibraryBytes {
  final String name;
  final Uint8List bytes;

  const NativeLibraryBytes(this.name, this.bytes);
}

/// 一个命中的原生符号。
class NativeCodeSymbol {
  /// 精确符号名。
  final String symbol;

  final SecurityCategory category;

  final String description;

  /// 导入这个符号的库（归档内路径，已排序）。
  final List<String> libraryNames;

  const NativeCodeSymbol({
    required this.symbol,
    required this.category,
    required this.description,
    required this.libraryNames,
  });

  @override
  String toString() => 'NativeCodeSymbol($symbol, $libraryNames)';
}

/// 一个原生库的结构概况。
class NativeLibraryInfo {
  final String name;

  /// ABI（`arm64-v8a` 等），从路径里取；取不到时为 `null`。
  final String? abi;

  final ElfStructure structure;

  final int importedCount;
  final int exportedCount;

  /// 是否存在 `.symtab`（完整符号表）。
  ///
  /// `true` 说明这个库**没有剥离**，能读到内部函数名 —— 这是一条事实，
  /// 不是风险。发布版本通常会剥离。
  final bool hasStaticSymbols;

  const NativeLibraryInfo({
    required this.name,
    required this.abi,
    required this.structure,
    required this.importedCount,
    required this.exportedCount,
    required this.hasStaticSymbols,
  });
}

/// 原生库扫描结果。
class NativeSymbolScanResult {
  /// 命中的符号标记（按类别、符号名稳定排序）。
  final List<NativeCodeSymbol> symbols;

  /// 成功解析的库。
  final List<NativeLibraryInfo> libraries;

  /// 结构不可信、因此**没有**读符号表的库。
  final List<String> notTraversable;

  /// 因为体积 / 数量预算被跳过的库（名字 + 原因）。
  final List<String> skippedForBudget;

  /// 读不出来的符号条目总数。
  final int skippedSymbols;

  /// 是否有任何库的符号表读取被预算截断。
  final bool truncated;

  const NativeSymbolScanResult({
    this.symbols = const [],
    this.libraries = const [],
    this.notTraversable = const [],
    this.skippedForBudget = const [],
    this.skippedSymbols = 0,
    this.truncated = false,
  });

  /// 是否命中某个符号。
  bool hasSymbol(String symbol) => symbols.any((s) => s.symbol == symbol);

  /// 某个符号的命中；没有时返回 `null`。
  NativeCodeSymbol? symbol(String name) {
    for (final entry in symbols) {
      if (entry.symbol == name) return entry;
    }
    return null;
  }

  /// 未剥离符号表的库（能读到内部函数名）。
  List<NativeLibraryInfo> get unstrippedLibraries => [
        for (final lib in libraries)
          if (lib.hasStaticSymbols) lib
      ];

  @override
  String toString() => 'NativeSymbolScanResult(${libraries.length} libs, '
      '${symbols.length} symbols, skipped=${skippedForBudget.length})';
}

/// 原生库（`lib/**.so`）的符号扫描（安全分析的**原生层**）。
///
/// 回答的是 DEX 层回答不了的问题：这个应用自带的**原生代码**导入了哪些
/// 系统能力。C/C++ 代码不经过 Java 层，`method_ids` 里看不到它。
///
/// **只读符号表，不反汇编**：符号名是精确的标识符，比字符串命中强；但
/// 「导入了 `system`」只说明这个库**有能力**执行命令，不说明它执行了、
/// 更不说明执行了什么。
class NativeSymbolScanner {
  NativeSymbolScanner._();

  static const String scannerVersion = 'native-symbols-2026.10.15';

  /// 单个库的体积上限（32 MiB）。
  ///
  /// 读整个文件才能拿到节表与符号表（节表在文件末尾），因此必须有上限。
  /// 32 MiB 已覆盖绝大多数真实 `.so`（Android 上通常是 1–20 MiB）；
  /// 超过的多是游戏引擎等巨型库，那里的符号分析价值也最低。
  static const int maxBytesPerLibrary = 32 * 1024 * 1024;

  /// 一次分析覆盖的库总体积上限（96 MiB）。
  ///
  /// 多 ABI 的应用里同一个库会有 4 份（arm64 / armv7 / x86 / x86_64）。
  static const int maxTotalBytes = 96 * 1024 * 1024;

  /// 最多解析多少个库。
  static const int maxLibraries = 24;

  /// ABI 的优先级：同一个库只分析一个 ABI 时优先取哪个。
  ///
  /// `arm64-v8a` 是当前 Android 的主力 ABI，它的符号表最完整。
  static const List<String> abiPreference = [
    'arm64-v8a',
    'armeabi-v7a',
    'arm64',
    'x86_64',
    'x86',
  ];

  /// 从候选库里挑出**要分析的那批名字**（不读内容）。
  ///
  /// 三条策略，都是为了让有限的预算花在**不重复**的内容上：
  ///
  /// 1. **按库名去重，同一个库只取一个 ABI**。同一个库在 4 个 ABI 下导出的
  ///    符号几乎一样，全部分析等于把预算花在重复内容上。ABI 优先级见
  ///    [abiPreference]。
  /// 2. 跳过超过 [maxBytesPerLibrary] 的库 —— 读整个文件才能拿到节表，
  ///    必须有上限。
  /// 3. 数量与总体积上限（[maxLibraries] / [maxTotalBytes]）。
  ///
  /// 返回的是**名字**，读取由调用方按自己的 IO 方式完成（本方法不碰内容，
  /// 因此可测、也不受 IO 方式影响）。
  static NativeLibrarySelection selectLibraries(
    List<({String name, int size})> candidates,
  ) {
    // 先按 ABI 优先级、再按库名排序，使「同一个库取哪个 ABI」是确定的。
    final sorted = [...candidates]..sort((a, b) {
        final byAbi = _abiRank(a.name).compareTo(_abiRank(b.name));
        return byAbi != 0 ? byAbi : a.name.compareTo(b.name);
      });

    final selected = <String>[];
    final skipped = <String>[];
    final seenBaseNames = <String>{};
    var totalBytes = 0;

    for (final candidate in sorted) {
      final baseName = _baseNameOf(candidate.name);
      if (!seenBaseNames.add(baseName)) {
        // 同一个库的其它 ABI：不是「跳过」，只是不重复分析。
        continue;
      }
      if (candidate.size > maxBytesPerLibrary) {
        skipped.add('${candidate.name}（${candidate.size ~/ (1024 * 1024)} MiB，'
            '超过单库上限 ${maxBytesPerLibrary ~/ (1024 * 1024)} MiB）');
        continue;
      }
      if (selected.length >= maxLibraries) {
        skipped.add('${candidate.name}（已达库数量上限 $maxLibraries）');
        continue;
      }
      if (totalBytes + candidate.size > maxTotalBytes) {
        skipped.add('${candidate.name}（已达总体积上限 '
            '${maxTotalBytes ~/ (1024 * 1024)} MiB）');
        continue;
      }
      totalBytes += candidate.size;
      selected.add(candidate.name);
    }

    return NativeLibrarySelection(selected: selected, skipped: skipped);
  }

  /// ABI 优先级序号；未知 ABI 排最后。
  static int _abiRank(String path) {
    final abi = _abiOf(path);
    if (abi == null) return abiPreference.length + 1;
    final index = abiPreference.indexOf(abi);
    return index < 0 ? abiPreference.length : index;
  }

  /// 库名（不含 ABI 目录与扩展名），用于跨 ABI 去重。
  static String _baseNameOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final lastSlash = normalized.lastIndexOf('/');
    final fileName =
        lastSlash < 0 ? normalized : normalized.substring(lastSlash + 1);
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  static NativeSymbolScanResult scan(List<NativeLibraryBytes> entries) {
    final symbols = <String, Set<String>>{};
    final libraries = <NativeLibraryInfo>[];
    final notTraversable = <String>[];
    final skipped = <String>[];
    var skippedSymbols = 0;
    var truncated = false;
    var totalBytes = 0;

    for (final entry in entries) {
      if (libraries.length >= maxLibraries) {
        skipped.add('${entry.name}（已达库数量上限 $maxLibraries）');
        continue;
      }
      if (entry.bytes.length > maxBytesPerLibrary) {
        skipped.add('${entry.name}（${entry.bytes.length ~/ (1024 * 1024)} MiB，'
            '超过单库上限 ${maxBytesPerLibrary ~/ (1024 * 1024)} MiB）');
        continue;
      }
      if (totalBytes + entry.bytes.length > maxTotalBytes) {
        skipped.add('${entry.name}（已达总体积上限 '
            '${maxTotalBytes ~/ (1024 * 1024)} MiB）');
        continue;
      }
      totalBytes += entry.bytes.length;

      final structure = ElfStructure.read(entry.name, entry.bytes);
      if (!structure.isTraversable) {
        // 结构读不出来就不读符号表 —— 节表不合法时读到的符号没有意义。
        notTraversable.add(entry.name);
        continue;
      }

      final dynamicSymbols = ElfSymbolTable.readDynamic(entry.bytes, structure);
      final staticSymbols = ElfSymbolTable.readStatic(entry.bytes, structure);
      skippedSymbols += dynamicSymbols.skipped + staticSymbols.skipped;
      if (dynamicSymbols.truncated || staticSymbols.truncated) {
        truncated = true;
      }

      libraries.add(NativeLibraryInfo(
        name: entry.name,
        abi: _abiOf(entry.name),
        structure: structure,
        importedCount: dynamicSymbols.imported.length,
        exportedCount: dynamicSymbols.exported.length,
        hasStaticSymbols: staticSymbols.symbols.isNotEmpty,
      ));

      // **只匹配导入的符号**：导入意味着这个库从 libc / 别的库拿到了这项
      // 能力。库自己定义一个叫 `connect` 的函数不算（那多半是同名封装）。
      for (final symbol in dynamicSymbols.imported) {
        final marker = nativeSymbolMarkerIndex[symbol.name];
        if (marker == null) continue;
        (symbols[marker.symbol] ??= <String>{}).add(entry.name);
      }
    }

    final hits = <NativeCodeSymbol>[];
    for (final marker in nativeSymbolMarkers) {
      final libraryNames = symbols[marker.symbol];
      if (libraryNames == null || libraryNames.isEmpty) continue;
      hits.add(NativeCodeSymbol(
        symbol: marker.symbol,
        category: marker.category,
        description: marker.description,
        libraryNames: libraryNames.toList()..sort(),
      ));
    }
    // 稳定排序：先按类别、再按符号名，报告输出才可复现。
    hits.sort((a, b) {
      final byCategory = a.category.name.compareTo(b.category.name);
      return byCategory != 0 ? byCategory : a.symbol.compareTo(b.symbol);
    });

    libraries.sort((a, b) => a.name.compareTo(b.name));

    return NativeSymbolScanResult(
      symbols: hits,
      libraries: libraries,
      notTraversable: notTraversable,
      skippedForBudget: skipped,
      skippedSymbols: skippedSymbols,
      truncated: truncated,
    );
  }

  /// 从归档路径里取 ABI：`lib/<abi>/xxx.so` 的 `<abi>` 段。
  static String? _abiOf(String path) {
    final parts = path.replaceAll('\\', '/').split('/');
    final index = parts.indexOf('lib');
    if (index < 0 || index + 1 >= parts.length) return null;
    final abi = parts[index + 1];
    return abi.isEmpty ? null : abi;
  }
}
