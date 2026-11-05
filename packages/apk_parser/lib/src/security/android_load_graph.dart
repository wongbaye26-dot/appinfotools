import 'package:analysis_model/analysis_model.dart';

import '../dex/dex_method_bodies.dart';
import '../dex/dex_method_table.dart';
import '../dex/dex_structure.dart';
import '../dex/dex_tables.dart';
import 'dex_clue_scanner.dart' show DexBytes;
import 'dex_method_scanner.dart';

/// Android 加载链：DEX 里的加载点 × 包内制品清单。
///
/// 回答的是「**谁**会去加载**什么**，那个东西在不在包里」。节点与边都只
/// 记录事实，不判断恶意性 —— 悬空边（`presentInPackage == false`）由规则层
/// 结合钱包语境解释。
///
/// ## 关键局限：调用点与路径字面量是「同现」，不是参数关联
///
/// 精确回答「`System.loadLibrary("foo")` 的参数是 `foo`」需要寄存器级数据流
/// （`const-string` 的结果如何流到 `invoke-*` 的参数寄存器）。本层用
/// `DexMethodBodies.walk(onCallSite:)` 只拿到调用点本身，指令回调不携带
/// 操作数（`DexInstruction` 只有 offset/opcode/width），因此做不到参数级
/// 关联。这里的做法是：
///
/// 1. 在 `method_ids` 里找 loader API，确认该 DEX **至少有一条**加载调用；
/// 2. 在同一个 DEX 的 `string_ids` 里找路径类字面量；
/// 3. 按「loader 类型 × 字面量类别」配对成边，边位置写成
///    `<dex>: <调用者> @0x<偏移>; loader call + literal co-occurrence`。
///
/// 配对规则用类别收窄（`loadLibrary` 只配库名、DexClassLoader 只配
/// `.dex/.jar/.apk/assets/` 等），避免把「同一个包里的任意字符串」都连上；
/// 但**同一个 DEX 里两条无关的加载语句仍然可能交叉配对**。下游若要用这些边
/// 做判级，必须把 `location` 里的 `co-occurrence` 当成强度标记 —— 它比
/// 「字符串同现」强（至少证明有加载调用），但**不是**调用点级证据。
///
/// ## 本层不做的事
///
/// - **不解析原生 `dlopen`/`dlsym`**：那要遍历 ELF 的 `.dynsym` 与重定位，
///   属于 Phase C（且 `LoadEdgeKind.nativeDlopen` 已为此保留）。因此
///   `lib/**/*.so` 之间「谁 `dlopen` 了谁」在本层是空白；
/// - **不解析 `Runtime.exec` / `ProcessBuilder`**：它们启动进程而不是加载
///   制品，冻结的 [LoadEdgeKind] 里也没有对应值。要产出这类边必须先回契约
///   加枚举值，本层不擅自映射成 `unknown`；
/// - **`PathClassLoader` 构造器**：契约同样没有对应边类型，这里用
///   [LoadEdgeKind.unknown] 表示并保留在结果里（它在热修复/插件框架里是
///   真实存在的 DEX 加载路径），但调用方不能把它当 `dexClassLoader`。
class AndroidLoadGraphScanner {
  AndroidLoadGraphScanner._();

  /// 最多产出多少条边；超过时 [LoadGraph.complete] 为 `false`。
  static const int defaultMaxEdges = 5000;

  /// 单个 DEX 最多解多少个 `string_ids`。
  ///
  /// 8 MiB 的 DEX 大约几十万条字符串；上限只兜住畸形文件，截断时
  /// `complete=false`（漏掉的字面量可能就是载荷路径）。
  static const int maxStringsPerDex = 500000;

  /// 单个 DEX 最多保留多少条路径字面量。
  ///
  /// 收窄「同现」噪声：真实 DEX 里有成百上千条 `/data/data/...` 之类的字面
  /// 量，与一两条加载调用相乘会淹没结果。截断时 `complete=false`。
  static const int maxLiteralsPerDex = 64;

  /// 单条字面量的最大长度；异常长的字符串不像路径。
  static const int maxLiteralLength = 512;

  /// 只由字母数字/下划线/连字符组成、且不以点开头的名字，才可能是
  /// `System.loadLibrary("foo")` 的参数。
  static final RegExp _bareLibraryName = RegExp(r'^[A-Za-z0-9_\-]{1,64}$');

  /// 扫描 DEX 与制品清单，建立加载图。
  ///
  /// [dexEntries] 的 `name` 必须与 [inventory] 里的路径一致（通常就是
  /// `classes.dex` / `classes2.dex`），否则从节点无法对齐清单条目。
  static LoadGraph scan({
    required List<DexBytes> dexEntries,
    required ArtifactInventory inventory,
    int maxEdges = defaultMaxEdges,

    /// 已由 `AndroidSecurityAudit` 算过的调用点扫描结果。
    ///
    /// 传入时不再自己遍历 `method_ids`/字节码：加载链复用同一次
    /// `DexMethodScanner` 结果（code_markers 里已收录 loadLibrary/load）。
    /// `null` 时走兼容路径（自带 method_ids + invoke 遍历）。
    DexMethodScanResult? methodScan,
  }) {
    final edgeLimit = maxEdges < 0 ? 0 : maxEdges;
    final nodes = <String, LoadNode>{};
    final edges = <String, LoadEdge>{};
    final danglingEdgeIds = <String>{};
    var complete = true;

    // 清单索引只建一次：每个 DEX 都要用它解析字面量。
    final byPath = <String, ArtifactEntry>{
      for (final entry in inventory.entries) entry.path: entry,
    };
    // basename → 路径。多 ABI 时取**字典序最小**的那条：归档顺序会因为
    // 重打包而变化，取「第一个」会让同一份内容给出不同的边。
    final byBasename = <String, String>{};
    for (final entry in inventory.entries) {
      final name = _basename(entry.path);
      final current = byBasename[name];
      if (current == null || entry.path.compareTo(current) < 0) {
        byBasename[name] = entry.path;
      }
    }

    for (final dex in dexEntries) {
      if (edges.length >= edgeLimit) {
        complete = false;
        break;
      }
      final structure = DexStructure.read(dex.name, dex.bytes);
      if (!structure.isTraversable) {
        // 结构不可信时「没发现加载点」不成立，必须记为不完整。
        complete = false;
        continue;
      }

      final tables = DexTables(dex.bytes, structure);
      final Map<LoadEdgeKind, _LoaderCallSite> callSites;

      if (methodScan != null) {
        // 复用 `DexMethodScanner` 已经走过的调用点：不再自己遍历
        // `method_ids` 或字节码。加载链仍需 string_ids 找路径字面量。
        callSites = _callSitesFromMethodScan(methodScan, dex.name);
        if (methodScan.truncatedForBudget.contains(dex.name)) complete = false;
        if (callSites.isEmpty) continue;
      } else {
        // 兼容路径：`method_ids` 里是否有 loader API。
        //
        // 先查这张表是为了**避免白跑字节码**：绝大多数 DEX 根本没有加载调用，
        // 而 `DexMethodBodies.walk` 要解全部 `class_data`，是这里最贵的一步。
        final loaderKinds = <int, LoadEdgeKind>{};
        final tableResult = DexMethodTable.forEachReference(
          dex.bytes,
          structure,
          onReference: (reference) {
            final kind = _loaderKind(reference.classDescriptor, reference.name);
            final index = reference.index;
            if (kind != null && index != null) loaderKinds[index] = kind;
          },
        );
        if (tableResult.truncated) complete = false;
        if (loaderKinds.isEmpty) continue;

        // 真实调用点（`invoke-*` 指令）。
        final scanned = <LoadEdgeKind, _LoaderCallSite>{};
        final bodyResult = DexMethodBodies.walk(
          dex.bytes,
          structure,
          onCallSite: (site) {
            final kind = loaderKinds[site.target.index];
            if (kind == null) return;
            scanned.putIfAbsent(
              kind,
              () => _LoaderCallSite(
                  site.callerDisplayName, site.instructionOffset),
            );
          },
        );
        if (bodyResult.truncated) complete = false;
        if (bodyResult.desyncedBodies.isNotEmpty) {
          // 指令边界不可信 ⇒ 调用点也不可信；与其它扫描器的口径一致。
          complete = false;
        }
        callSites = scanned;
        if (callSites.isEmpty) continue;
      }

      // 第 3 步：路径类字面量。
      final literals = <_PathLiteral>[];
      final stringSection = structure.section('string_ids');
      if (stringSection != null) {
        final limit = stringSection.size < maxStringsPerDex
            ? stringSection.size
            : maxStringsPerDex;
        if (limit < stringSection.size) complete = false;
        for (var i = 0; i < limit; i++) {
          final text = tables.string(i);
          if (text == null || text.isEmpty || text.length > maxLiteralLength) {
            continue;
          }
          final literal = _classifyLiteral(
            text,
            byBasename,
            // 裸库名只对 `System.loadLibrary` 有意义，没这种调用时不必收。
            bareNames: callSites.containsKey(LoadEdgeKind.systemLoadLibrary),
          );
          if (literal == null) continue;
          if (literals.length >= maxLiteralsPerDex) {
            complete = false;
            break;
          }
          literals.add(literal);
        }
      }
      _dropAbsoluteDirectoryPrefixes(literals);
      if (literals.isEmpty) continue;

      // 第 4 步：配对成边。
      final fromId = 'artifact:${dex.name}';
      nodes.putIfAbsent(
        fromId,
        () => LoadNode(
          id: fromId,
          kind: LoadNodeKind.dex,
          // DEX 字节是调用方从这个包里读出来的，因此「在包内」是已知事实，
          // 不依赖清单是否完整（清单缺条目是清单的覆盖问题，不是加载图的事）。
          resolvedPath: dex.name,
          presentInPackage: true,
        ),
      );

      for (final callSite in callSites.entries) {
        for (final literal in literals) {
          if (!literal.matches(callSite.key)) continue;
          if (edges.length >= edgeLimit) {
            complete = false;
            break;
          }
          _addEdge(
            nodes: nodes,
            edges: edges,
            danglingEdgeIds: danglingEdgeIds,
            fromId: fromId,
            literal: literal,
            kind: callSite.key,
            callSite: callSite.value,
            dexName: dex.name,
            byPath: byPath,
            byBasename: byBasename,
          );
        }
        if (edges.length >= edgeLimit) {
          // 撞到上限就**一律**记不完整：宁可说「可能还有」，也不要在
          // 恰好等于上限时声称「已经全了」。
          complete = false;
          break;
        }
      }
    }

    final sortedNodes = nodes.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final sortedEdges = edges.values.toList()
      ..sort((a, b) {
        final byFrom = a.fromId.compareTo(b.fromId);
        if (byFrom != 0) return byFrom;
        final byTo = a.toId.compareTo(b.toId);
        if (byTo != 0) return byTo;
        return a.kind.index.compareTo(b.kind.index);
      });
    return LoadGraph(
      nodes: sortedNodes,
      edges: sortedEdges,
      danglingEdgeIds: danglingEdgeIds.toList()..sort(),
      complete: complete,
    );
  }

  /// 把一条「loader 类型 × 字面量」配对落成边（重复的 from+to+kind 只留一条）。
  static void _addEdge({
    required Map<String, LoadNode> nodes,
    required Map<String, LoadEdge> edges,
    required Set<String> danglingEdgeIds,
    required String fromId,
    required _PathLiteral literal,
    required LoadEdgeKind kind,
    required _LoaderCallSite callSite,
    required String dexName,
    required Map<String, ArtifactEntry> byPath,
    required Map<String, String> byBasename,
  }) {
    final target = _resolve(literal, byPath, byBasename);
    final edgeKey = '$fromId->${target.nodeId}|${kind.name}';
    if (edges.containsKey(edgeKey)) return;

    nodes.putIfAbsent(
      target.nodeId,
      () => LoadNode(
        id: target.nodeId,
        kind: target.nodeKind,
        resolvedPath: target.path,
        presentInPackage: target.present,
      ),
    );

    edges[edgeKey] = LoadEdge(
      fromId: fromId,
      toId: target.nodeId,
      kind: kind,
      source: SecurityEvidenceSource.loadGraph,
      // 位置必须能指回可复现的地址；同时把强度局限写进同一行字面量，
      // 免得报告层只截取前面一段时把 co-occurrence 读成调用点级证据。
      location: '$dexName: ${callSite.display}; '
          'loader call + literal co-occurrence',
    );
    if (!target.present) danglingEdgeIds.add('$fromId->${target.nodeId}');
  }

  /// 字面量 → 清单条目（或悬空目标）。
  static _ResolvedTarget _resolve(
    _PathLiteral literal,
    Map<String, ArtifactEntry> byPath,
    Map<String, String> byBasename,
  ) {
    // 绝对路径**永远**解析不到包内条目：ZIP 里的路径都是相对路径。
    // 因此 `System.load("/data/local/tmp/x.so")` 一定是悬空边 —— 这正是在
    // 「运行时才知道的路径」与「包内自带」之间划线的依据。
    if (literal.isAbsolute) return _ResolvedTarget.missing(literal.raw);

    final exact = byPath[normalizeArchivePath(literal.raw)];
    if (exact != null) return _ResolvedTarget.present(exact, literal);

    // 退到 basename：`libfoo.so` → 任意 ABI 的 `lib/<abi>/libfoo.so`。
    final path = byBasename[literal.basename];
    if (path != null) {
      final entry = byPath[path];
      if (entry != null) return _ResolvedTarget.present(entry, literal);
    }
    return _ResolvedTarget.missing(literal.raw);
  }

  /// 节点类型：优先用清单里的代码类型，其次用字面量后缀。
  ///
  /// 为什么需要后者：`assets/payload.dex` 在清单里是 `assetBinary`
  /// （「它在包里的角色」），但**加载边**要回答的是「会被当什么加载」。
  static LoadNodeKind _nodeKind(ArtifactEntry entry, _PathLiteral literal) {
    final fromInventory = switch (entry.kind) {
      ArtifactKind.dex => LoadNodeKind.dex,
      ArtifactKind.elf => LoadNodeKind.elf,
      ArtifactKind.machO => LoadNodeKind.machO,
      ArtifactKind.dylib => LoadNodeKind.dylib,
      ArtifactKind.framework => LoadNodeKind.framework,
      ArtifactKind.script => LoadNodeKind.script,
      _ => null,
    };
    if (fromInventory != null) return fromInventory;
    if (literal.isSo) return LoadNodeKind.elf;
    // `.jar` / `.apk` 被 DexClassLoader 加载时，里面装的就是 DEX。
    if (literal.isDexLike) return LoadNodeKind.dex;
    return LoadNodeKind.unknown;
  }

  /// 从 `DexMethodScanResult` 提取某个 DEX 的 loader 调用点。
  ///
  /// `code_markers` 已收录 `System.loadLibrary` / `System.load`；调用点样本由
  /// `DexMethodScanner` 生成（`callee @ caller +0x..`），这里只做映射，
  /// 不再遍历字节码。
  static Map<LoadEdgeKind, _LoaderCallSite> _callSitesFromMethodScan(
    DexMethodScanResult scan,
    String dexName,
  ) {
    final result = <LoadEdgeKind, _LoaderCallSite>{};
    for (final ref in scan.references) {
      if (!ref.dexNames.contains(dexName)) continue;
      final kind = _loaderMarkerKind(ref.markerId);
      if (kind == null) continue;
      // `System;.load` 是 `System;.loadLibrary` 的前缀；`DexMethodScanner`
      // 的标记是子串匹配，所以 loadLibrary 调用会同时命中两条。逐条样本
      // 跳过 loadLibrary，取真正的 System.load 调用点。
      String? raw;
      for (final sample in ref.callSiteSamples) {
        if (kind == LoadEdgeKind.systemLoad && sample.contains('loadLibrary')) {
          continue;
        }
        raw = sample;
        break;
      }
      // 只收**真实调用点**：`references` 里也可能只有方法声明/签名引用，
      // 没有 `invoke-*` 样本时不能编造一条边。
      final sample = raw;
      if (sample == null) continue;
      result.putIfAbsent(kind, () => _LoaderCallSite.fromRaw(sample));
    }
    return result;
  }

  static LoadEdgeKind? _loaderMarkerKind(String markerId) => switch (markerId) {
        'dynamic-loading' => LoadEdgeKind.dexClassLoader,
        'dynamic-loading-path' => LoadEdgeKind.unknown,
        'in-memory-dex' => LoadEdgeKind.inMemoryDexLoader,
        'loader-system-load-library' => LoadEdgeKind.systemLoadLibrary,
        'loader-system-load' => LoadEdgeKind.systemLoad,
        _ => null,
      };

  /// loader API 分类；不是加载点时为 `null`。
  static LoadEdgeKind? _loaderKind(String classDescriptor, String name) {
    return switch (classDescriptor) {
      'Ljava/lang/System;' => switch (name) {
          'loadLibrary' => LoadEdgeKind.systemLoadLibrary,
          'load' => LoadEdgeKind.systemLoad,
          _ => null,
        },
      'Ldalvik/system/DexClassLoader;' when name == '<init>' =>
        LoadEdgeKind.dexClassLoader,
      'Ldalvik/system/InMemoryDexClassLoader;' when name == '<init>' =>
        LoadEdgeKind.inMemoryDexLoader,
      // 契约没有 PathClassLoader 的边类型：用 unknown 保留事实，别冒充
      // dexClassLoader。见文件头「本层不做的事」。
      'Ldalvik/system/PathClassLoader;' when name == '<init>' =>
        LoadEdgeKind.unknown,
      _ => null,
    };
  }

  /// 字面量分类；不构成路径/库名时为 `null`。
  static _PathLiteral? _classifyLiteral(
    String text,
    Map<String, String> byBasename, {
    required bool bareNames,
  }) {
    final lower = text.toLowerCase();
    final isAbsolute = text.startsWith('/');
    final isSo = lower.endsWith('.so');
    final isDexLike = lower.endsWith('.dex') ||
        lower.endsWith('.jar') ||
        lower.endsWith('.apk');
    final isAsset = lower.startsWith('assets/');
    final bareName = !text.contains('/') &&
        !text.contains('.') &&
        _bareLibraryName.hasMatch(text);
    // 裸名字只有**包内确实存在** `lib<name>.so` 时才留下：一个 DEX 里有
    // 成千上万个普通标识符字符串（`value`、`load`、`main`…），全收下来会
    // 让「同现」放大成噪声。包内命中是这里唯一可靠的收窄依据。
    final isBareLibrary =
        bareNames && bareName && byBasename.containsKey('lib$text.so');

    if (!isAbsolute && !isSo && !isDexLike && !isAsset && !isBareLibrary) {
      return null;
    }
    return _PathLiteral(
      raw: text,
      basename: isBareLibrary ? 'lib$text.so' : _basename(text),
      isAbsolute: isAbsolute,
      isSo: isSo,
      isDexLike: isDexLike,
      isAsset: isAsset,
      isBareLibrary: isBareLibrary,
    );
  }

  /// 去掉「目录形态」的绝对路径字面量。
  ///
  /// 同一个 DEX 里常有 `"/data/local/tmp"` 与 `"/data/local/tmp/libbar.so"`
  /// 这样的目录 + 文件对；前者不是加载目标，留着会让每条加载调用多长一条
  /// 无意义的悬空边。判据只用「另一条绝对字面量以它 + `/` 开头」。
  static void _dropAbsoluteDirectoryPrefixes(List<_PathLiteral> literals) {
    if (literals.length < 2) return;
    final absolute = [
      for (final literal in literals)
        if (literal.isAbsolute) literal.raw,
    ];
    if (absolute.length < 2) return;
    literals.removeWhere((literal) {
      if (!literal.isAbsolute) return false;
      return absolute.any((other) => other.startsWith('${literal.raw}/'));
    });
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

/// 一条具体的加载调用点。
class _LoaderCallSite {
  /// 调用者完整描述（类 + 方法 + 原型）。
  final String caller;

  /// `invoke-*` 在 `insns` 里的代码单元偏移。
  final int instructionOffset;

  /// 预格式化的位置（复用 `DexMethodScanner` 的样本时使用）。
  final String? rawLocation;

  const _LoaderCallSite(this.caller, this.instructionOffset,
      {this.rawLocation});

  factory _LoaderCallSite.fromRaw(String raw) =>
      _LoaderCallSite('', 0, rawLocation: raw);

  String get display =>
      rawLocation ?? '$caller @0x${instructionOffset.toRadixString(16)}';
}

/// 一条候选路径字面量及其形态。
class _PathLiteral {
  /// 字符串原样（证据原文）。
  final String raw;

  /// 解析时先按路径、再按 basename 用的名字。
  final String basename;

  final bool isAbsolute;
  final bool isSo;
  final bool isDexLike;
  final bool isAsset;

  /// 是否是「裸库名」（`foo` → `libfoo.so`）。
  final bool isBareLibrary;

  const _PathLiteral({
    required this.raw,
    required this.basename,
    required this.isAbsolute,
    required this.isSo,
    required this.isDexLike,
    required this.isAsset,
    required this.isBareLibrary,
  });

  /// 该字面量是否可能是这种加载调用的目标。
  ///
  /// 只做**类别**匹配，不做参数级匹配 —— 见文件头的同现局限说明。
  bool matches(LoadEdgeKind kind) {
    return switch (kind) {
      // `System.loadLibrary` 只接受库名（不含路径分隔符），运行时在
      // `lib/<abi>/` 里按名字找；绝对路径不可能是它的参数。
      LoadEdgeKind.systemLoadLibrary =>
        isBareLibrary || (isSo && !isAbsolute && !raw.contains('/')),
      // `System.load` 要求绝对路径，也接受带路径的相对串（兼容写法）。
      LoadEdgeKind.systemLoad => isAbsolute || isSo,
      // `DexClassLoader(path, ...)` / `InMemoryDexClassLoader(ByteBuffer)` /
      // `PathClassLoader(path, ...)`（契约里记作 unknown）：目标都是 DEX 类
      // 容器或其所在路径。`.so` 不可能是它们的目标；绝对路径则可能是
      // （`DexClassLoader` 的第一个参数允许绝对路径）。
      LoadEdgeKind.dexClassLoader ||
      LoadEdgeKind.inMemoryDexLoader ||
      LoadEdgeKind.unknown =>
        isDexLike || isAsset || (isAbsolute && !isSo),
      _ => false,
    };
  }
}

/// 字面量的解析结果。
class _ResolvedTarget {
  final String nodeId;
  final LoadNodeKind nodeKind;
  final String? path;
  final bool present;

  const _ResolvedTarget._({
    required this.nodeId,
    required this.nodeKind,
    required this.path,
    required this.present,
  });

  factory _ResolvedTarget.present(ArtifactEntry entry, _PathLiteral literal) {
    return _ResolvedTarget._(
      nodeId: 'artifact:${entry.path}',
      nodeKind: AndroidLoadGraphScanner._nodeKind(entry, literal),
      path: entry.path,
      present: true,
    );
  }

  factory _ResolvedTarget.missing(String raw) {
    return _ResolvedTarget._(
      nodeId: 'missing:$raw',
      nodeKind: LoadNodeKind.missing,
      path: null,
      present: false,
    );
  }
}
