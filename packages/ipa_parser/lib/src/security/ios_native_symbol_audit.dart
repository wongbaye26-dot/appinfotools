import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

import '../macho.dart';

/// 一个命中的原生符号（iOS 侧）。
class IosNativeSymbol {
  /// C 符号名（**已去掉 Mach-O 的前导下划线**，如 `system`）。
  final String symbol;

  final SecurityCategory category;

  final String description;

  /// 原样符号名（带前导下划线），作为证据原文。
  final List<String> rawNames;

  const IosNativeSymbol({
    required this.symbol,
    required this.category,
    required this.description,
    required this.rawNames,
  });
}

/// iOS 原生符号审计的结果。
class IosNativeSymbolResult {
  final List<IosNativeSymbol> symbols;

  /// 读到了符号表的镜像数。
  final int scannedImages;

  /// 符号表**没读成**的镜像（结构越界等）。
  ///
  /// 必须进覆盖范围说明：这些镜像上的「没发现导入符号」是「没查到」。
  final List<String> unreadableImages;

  /// 是否有镜像根本没有 `LC_SYMTAB`。
  final bool hasImageWithoutSymtab;

  final int importedCount;
  final int exportedCount;

  const IosNativeSymbolResult({
    this.symbols = const [],
    this.scannedImages = 0,
    this.unreadableImages = const [],
    this.hasImageWithoutSymtab = false,
    this.importedCount = 0,
    this.exportedCount = 0,
  });

  bool hasSymbol(String symbol) => symbols.any((s) => s.symbol == symbol);

  IosNativeSymbol? symbol(String name) {
    for (final entry in symbols) {
      if (entry.symbol == name) return entry;
    }
    return null;
  }

  @override
  String toString() => 'IosNativeSymbolResult($scannedImages images, '
      '${symbols.length} symbols, unreadable=${unreadableImages.length})';
}

/// iOS 侧的原生符号审计（安全分析的**原生层**）。
///
/// 与 Android 侧读 ELF `.dynsym` 是同一件事、两个平台各自的实现：
/// 从 Mach-O 的 `LC_SYMTAB` 读**未定义**（导入）符号，回答「这个二进制
/// 从系统拿到了哪些能力」。
///
/// **标记表是共享的**（`analysis_model` 的 [nativeSymbolMarkers]）——
/// `system` / `dlopen` / `ptrace` 在两端是同一套 libc 名字，两边各写一份
/// 必然漂移。差异只在**符号名的写法**：Mach-O 的 C 符号带前导下划线
/// （`_system`），匹配前用 [MachOSymbol.cName] 去掉。
///
/// **只读符号表，不反汇编**。
class IosNativeSymbolAudit {
  IosNativeSymbolAudit._();

  static const String rulesVersion = 'ios-native-symbols-2026.10.15';

  /// 从可执行文件字节里扫原生符号。
  static IosNativeSymbolResult scan({
    required Uint8List? executableBytes,
    required String? executablePath,
  }) {
    final bytes = executableBytes;
    if (bytes == null || bytes.isEmpty) {
      return const IosNativeSymbolResult();
    }

    final file = MachOParser.parse(bytes);
    final hits = <String, Set<String>>{};
    final unreadable = <String>[];
    var scannedImages = 0;
    var hasImageWithoutSymtab = false;
    var importedCount = 0;
    var exportedCount = 0;

    for (final image in file.images) {
      if (image.symtab == null) {
        hasImageWithoutSymtab = true;
        continue;
      }
      if (!image.symbolsRead) {
        // 符号表越界：**没查**，不是「没有」。
        unreadable
            .add('$image.cpuTypeName @0x${image.offset.toRadixString(16)}');
        continue;
      }
      scannedImages++;
      importedCount += image.importedSymbols.length;
      exportedCount += image.exportedSymbols.length;

      for (final symbol in image.importedSymbols) {
        // Mach-O 的 C 符号带前导下划线；标记表用的是不带下划线的名字。
        final marker = nativeSymbolMarkerIndex[symbol.cName];
        if (marker == null) continue;
        (hits[marker.symbol] ??= <String>{}).add(symbol.name);
      }
    }

    final symbols = <IosNativeSymbol>[];
    for (final marker in nativeSymbolMarkers) {
      final rawNames = hits[marker.symbol];
      if (rawNames == null || rawNames.isEmpty) continue;
      symbols.add(IosNativeSymbol(
        symbol: marker.symbol,
        category: marker.category,
        description: marker.description,
        rawNames: rawNames.toList()..sort(),
      ));
    }
    // 稳定排序：先按类别、再按符号名，报告输出才可复现。
    symbols.sort((a, b) {
      final byCategory = a.category.name.compareTo(b.category.name);
      return byCategory != 0 ? byCategory : a.symbol.compareTo(b.symbol);
    });

    return IosNativeSymbolResult(
      symbols: symbols,
      scannedImages: scannedImages,
      unreadableImages: unreadable,
      hasImageWithoutSymtab: hasImageWithoutSymtab,
      importedCount: importedCount,
      exportedCount: exportedCount,
    );
  }

  /// 把扫描结果转成发现项与覆盖说明。
  ///
  /// 分成两个返回值而不是直接拼 `SecurityAnalysisResult`：调用方
  /// （`IosPrivacyAudit`）要把它并进自己的结果里，而不是替换掉。
  static ({List<SecurityFinding> findings, List<String> limitations}) report({
    required IosNativeSymbolResult result,
    required String? executablePath,
  }) {
    final findings = <SecurityFinding>[];
    final limitations = <String>[];

    if (result.unreadableImages.isNotEmpty) {
      limitations.add('${result.unreadableImages.length} 个 Mach-O 镜像的'
          '`LC_SYMTAB` 越界，未读出符号（${result.unreadableImages.join('、')}）：'
          '这些镜像上的「没发现导入符号」是「没查到」，不是「没有」。');
    }
    if (result.hasImageWithoutSymtab) {
      limitations.add('部分 Mach-O 镜像没有 `LC_SYMTAB`（符号表被剥离）：'
          '这些镜像的导入符号无法检查。App Store 处理的二进制通常会剥离符号表。');
    }
    if (result.scannedImages > 0) {
      limitations.add('原生符号来自 Mach-O 的 `LC_SYMTAB`：它说明二进制**导入**'
          '了哪些系统能力，**不说明**这些能力被调用过、更不说明调用的参数。'
          '本次未反汇编原生代码。');
    }

    if (result.symbols.isEmpty) {
      return (findings: findings, limitations: limitations);
    }

    // 与 Android 侧同一套分组：命令执行 / 动态加载 / 反调试值得多看一眼，
    // 但**都不构成恶意判定**。
    const elevated = {
      'system',
      'popen',
      'execl',
      'execlp',
      'execle',
      'execv',
      'execvp',
      'execvpe',
      'fork',
      'vfork',
      'posix_spawn',
      'dlopen',
      'android_dlopen_ext',
      'dlsym',
      'dladdr',
      'ptrace',
    };
    final elevatedHits =
        result.symbols.where((s) => elevated.contains(s.symbol)).toList();

    findings.add(SecurityFinding(
      ruleId: 'IOS-NATIVE-SYMBOLS',
      platform: SecurityPlatform.ios,
      category: elevatedHits.isNotEmpty
          ? SecurityCategory.backgroundTask
          : SecurityCategory.network,
      severity:
          elevatedHits.isNotEmpty ? SecuritySeverity.p3 : SecuritySeverity.info,
      confidence: SecurityConfidence.independentCapability,
      finding: '可执行文件导入了 ${result.symbols.length} 项有具体含义的系统能力：'
          '${result.symbols.map((s) => s.description).join('、')}。'
          '只证明二进制**有能力**使用它们，不证明被调用过，'
          '也不说明调用的参数。',
      evidence: [
        for (final hit in result.symbols)
          SecurityEvidence(
            source: SecurityEvidenceSource.nativeSymbol,
            location: executablePath ?? 'main Mach-O executable',
            detail: '${hit.symbol}（导入）: ${hit.description}'
                '${hit.rawNames.isEmpty ? '' : ' ｜ 符号：${hit.rawNames.join(', ')}'}',
          ),
      ],
      relationship: '符号来自 Mach-O `LC_SYMTAB` 里 `N_UNDF | N_EXT`（未定义的外部）'
          '条目 —— 它们由 dyld 在加载时从系统库解析。'
          '二进制自己定义一个同名函数不会被算进来。',
      limitation: '导入不等于调用：未反汇编原生代码，'
          '因此不知道这些函数在哪些代码路径上被调用。'
          '经 `syscall()` 直接发起系统调用、或经 libc 内部间接调用的实现'
          '不会出现在符号表里。',
      recommendation: '如需确认实际行为，请在隔离环境中动态分析'
          '（`dtrace` / Frida 等）；仅凭导入 `system` / `dlopen` '
          '不构成风险判定 —— 崩溃上报、热修复、插件化框架都会用到它们。',
    ));

    return (findings: findings, limitations: limitations);
  }
}
