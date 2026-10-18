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

/// 一个参与符号扫描的可执行文件（主可执行文件或嵌套 bundle 里的）。
///
/// 单独定义而不是复用 `IosNestedExecutableInput`：那个类型带着「为什么没读到」
/// 之类的审计语义，符号层只需要「路径 + 字节」。
typedef IosNativeImage = ({String path, Uint8List bytes});

/// iOS 原生符号审计的结果。
class IosNativeSymbolResult {
  final List<IosNativeSymbol> symbols;

  /// 读到了符号表的镜像数。
  final int scannedImages;

  /// 尝试解析的镜像数（主可执行文件 + 参与扫描的嵌套可执行文件里的 slice 数）。
  ///
  /// 与 [scannedImages] 一起构成覆盖率的分子/分母 —— 只报「读到了几个」而不报
  /// 「一共有几个」，读者没法判断原生符号层查得全不全。
  final int imagesAttempted;

  /// 真正参与扫描的可执行文件路径（主 + 嵌套）。
  final List<String> scannedPaths;

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
    this.imagesAttempted = 0,
    this.scannedPaths = const [],
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
  ///
  /// [nested] 是**嵌套可执行文件**（App Extension / 框架）。此前只看主可执行
  /// 文件 —— 而扩展常常正是处理照片与 OCR 的地方，它的 C/C++ 代码完全不进
  /// 符号层。实测 `sun_signed.ipa`：25 个可执行文件只看了 1 个。
  static IosNativeSymbolResult scan({
    required Uint8List? executableBytes,
    required String? executablePath,
    List<IosNativeImage> nested = const [],
  }) {
    final hits = <String, Set<String>>{};
    final unreadable = <String>[];
    final scannedPaths = <String>[];
    var scannedImages = 0;
    var imagesAttempted = 0;
    var hasImageWithoutSymtab = false;
    var importedCount = 0;
    var exportedCount = 0;

    // 主可执行文件与嵌套可执行文件走**同一段**解析逻辑，只是路径前缀不同 ——
    // 两边各写一份必然漂移。
    for (final target in [
      if (executableBytes != null && executableBytes.isNotEmpty)
        (path: executablePath ?? '<main>', bytes: executableBytes),
      ...nested,
    ]) {
      final file = MachOParser.parse(target.bytes);
      if (file.images.isEmpty) continue;
      scannedPaths.add(target.path);
      for (final image in file.images) {
        imagesAttempted++;
        if (image.symtab == null) {
          hasImageWithoutSymtab = true;
          continue;
        }
        if (!image.symbolsRead) {
          // 符号表越界：**没查**，不是「没有」。
          unreadable.add(
            '${target.path}: $image.cpuTypeName '
            '@0x${image.offset.toRadixString(16)}',
          );
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
      imagesAttempted: imagesAttempted,
      scannedPaths: scannedPaths,
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
  static ({List<SecurityFinding> findings, List<AnalysisNote> limitations})
      report({
    required IosNativeSymbolResult result,
    required String? executablePath,
  }) {
    final findings = <SecurityFinding>[];
    final limitations = <AnalysisNote>[];

    if (result.unreadableImages.isNotEmpty) {
      limitations.add(AnalysisNote(
        'ios.native_symbols.unreadable',
        'The `LC_SYMTAB` of ${result.unreadableImages.length} Mach-O '
            'image(s) is out of bounds, so no symbols were read '
            '(${result.unreadableImages.join(', ')}): "no imported symbols '
            'found" on these images means "not looked at", not "none".',
        {
          'count': result.unreadableImages.length,
          'names': result.unreadableImages,
        },
      ));
    }
    if (result.hasImageWithoutSymtab) {
      limitations.add(AnalysisNote(
        'ios.native_symbols.stripped',
        'Some Mach-O images have no `LC_SYMTAB` (the symbol table was '
            'stripped): their imported symbols cannot be checked. Binaries '
            'processed by the App Store are usually stripped.',
      ));
    }
    if (result.scannedImages > 0) {
      limitations.add(AnalysisNote(
        'ios.native_symbols.semantics',
        'The native symbols come from the Mach-O `LC_SYMTAB`: they show '
            'which system capabilities the binary **imports**, and **do not '
            'show** that those capabilities were called, let alone with what '
            'arguments. The native code was not disassembled.',
      ));
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
      finding: 'The executable imports ${result.symbols.length} system '
          'capabilities with a specific meaning: '
          '${result.symbols.map((s) => s.description).join(', ')}. This only '
          'proves the binary **has the ability** to use them; it does not '
          'prove they are called, nor does it say anything about the '
          'arguments used.',
      // 只传**符号名**：说明由呈现层查 `nativeSymbolMarkers` 拼（表里存的是
      // 类别 id + 英文回退），因此 26 条记录只对应 14 类文案。
      messageCode: 'ios.native_symbols',
      messageArgs: {
        'count': result.symbols.length,
        'symbols': result.symbols.map((s) => s.symbol).toList(),
      },
      evidence: [
        for (final hit in result.symbols)
          SecurityEvidence(
            source: SecurityEvidenceSource.nativeSymbol,
            location: executablePath ?? 'main Mach-O executable',
            detail: '${hit.symbol} (imported): ${hit.description}'
                '${hit.rawNames.isEmpty ? '' : ' | raw symbol: ${hit.rawNames.join(', ')}'}',
            detailCode: hit.rawNames.isEmpty
                ? 'native_symbol.imported'
                : 'native_symbol.imported_raw',
            detailArgs: {
              'symbol': hit.symbol,
              if (hit.rawNames.isNotEmpty) 'rawNames': hit.rawNames.join(', '),
            },
          ),
      ],
      relationship: 'The symbols come from `N_UNDF | N_EXT` (undefined '
          'external) entries in the Mach-O `LC_SYMTAB` — dyld resolves them '
          'from system libraries at load time. A function the binary defines '
          'itself under the same name is not counted.',
      relationshipCode: 'ios.native_symbols.relationship',
      limitation: 'Import does not mean call: the native code was not '
          'disassembled, so it is unknown which code paths call these '
          'functions. Implementations that issue system calls directly via '
          '`syscall()` or call indirectly inside libc do not appear in the '
          'symbol table.',
      limitationCode: 'ios.native_symbols.limitation',
      recommendation: 'To confirm the actual behaviour, analyse dynamically '
          'in an isolated environment (`dtrace` / Frida and similar). '
          'Importing `system` / `dlopen` alone is not a risk verdict — crash '
          'reporting, hot-fix and plugin frameworks all use them.',
      recommendationCode: 'ios.native_symbols.manual_review',
    ));

    return (findings: findings, limitations: limitations);
  }
}
