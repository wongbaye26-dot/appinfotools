import 'package:analysis_model/analysis_model.dart';

import '../macho.dart';

/// 一个已解析的 Mach-O 文件 + 它在归档里的路径。
///
/// 路径必须是**归档内路径**（`Payload/Foo.app/Foo`），不是宿主文件系统路径：
/// 加载链的所有解析结果都要和 `ArtifactInventory` 的条目比较，两边必须是
/// 同一个命名空间。
class IosMachOInput {
  final String path;
  final MachOFile macho;

  const IosMachOInput({required this.path, required this.macho});

  @override
  String toString() => 'IosMachOInput($path, ${macho.images.length} images)';
}

/// iOS 加载链：`LC_LOAD_DYLIB` / `LC_RPATH` × 包内条目对账。
///
/// ## iOS 没有字节码
///
/// Android 侧可以靠 DEX 的 `invoke` 给出**调用点**；iOS 没有等价物。
/// 本阶段只读 Mach-O 的 **load commands**：
///
/// * `LC_LOAD_DYLIB`（含 weak / reexport / upward 变体，见下）→
///   「这个二进制声明要加载谁」；
/// * `LC_RPATH` → 「`@rpath` 按哪些目录展开」；
/// * `LC_ID_DYLIB`（`MachOImage.installName`）**不参与**对账 —— 它是
///   「我自己叫什么」，而 [LoadNode] 没有对应字段。
///
/// `dlopen` / `dlsym` / `NSClassFromString` **不在这里**：它们只是符号表里的
/// 字符串/导入符号线索，没有调用点，属于 Phase C 的 `machoSymbol` 证据。
/// 把「引用了 dlopen 这个符号」写成加载边，等于凭空造出一条 Android 式调用链。
///
/// ## 解析语义（不执行 dyld）
///
/// * `@executable_path/X` → 相对**主可执行文件所在目录**（主 bundle 根）。
///   注意：这个展开与「哪个镜像写了这条命令」无关 —— 框架里的
///   `@executable_path` 同样指向主可执行文件目录，这是 dyld 的语义。
/// * `@loader_path/X` → 相对**写出这条命令的二进制所在目录**。
/// * `@rpath/X` → 先用本镜像的 `LC_RPATH` 逐条展开，命中包内条目即采用，
///   并把命中的 rpath 写进边的 `location`（「解析依据」）；没有 rpath 命中
///   时退化为**包内路径后缀匹配**（`Frameworks/X` 优先），并在 location
///   里注明 `suffix match`。这是启发式，不是 dyld 的求解器。
/// * 包外**绝对** `LC_RPATH`（如 `/Library/MobileSubstrate/DynamicLibraries`）
///   另建 `machoRPath` 边：搜索路径在包内不存在，因此也计入
///   [LoadGraph.danglingEdgeIds]；包内 rpath（`@executable_path/Frameworks`）
///   是正常布局，不建边，只作为 `@rpath` 的解析依据。
/// * `/usr/lib/*`、`/System/Library/*` → 系统库：**不建包内边**，也不建
///   节点。系统库不在包里，为它建边只会把图撑大并让「包内加载」看起来更多。
/// * `/Library/MobileSubstrate/*`、`/usr/lib/frida/*`、`/var/jb/*` 等
///   越狱/注入位置 → `missing` + dangling（它们**不在**包内，即使前缀是
///   `/usr/lib`）。这份名单是已知位置，不声称穷尽。
/// * 其余绝对路径、以及不带 `@` 的相对安装名 → `missing` + dangling：
///   静态无法把它们映射到包内条目，dyld 也会按 cwd/绝对路径去找。
///
/// ## 完整性的口径
///
/// `complete=false` 的四种来源，全部是**诚实性**而不是错误：
/// 1. 清单被预算截断（[ArtifactInventory.entriesComplete] 为 false）——
///    这时「找不到」与「没列进清单」分不开；
/// 2. 某个 `MachOFile` 没有解析出任何镜像（文件损坏/不是 Mach-O）；
/// 3. 边数达到 [defaultMaxEdges]；
/// 4. 需要 `@executable_path` 但主 bundle 路径未知（无法解析）。
///
/// `complete=false` 时规则层不得把「没有悬空边」读成「没有被注入」。
class IosLoadGraphScanner {
  IosLoadGraphScanner._();

  /// 默认边数上限（契约 §5.2：边 ≤5 000）。
  static const int defaultMaxEdges = 5000;

  /// 包内加载链对账。
  static LoadGraph scan({
    required List<IosMachOInput> binaries,
    required ArtifactInventory inventory,
    String? mainBundlePath,
    int maxEdges = defaultMaxEdges,
  }) {
    // 空输入是事实，不是失败：没有二进制就没有加载链，complete 不应被拉黑。
    if (binaries.isEmpty) {
      return LoadGraph(complete: inventory.entriesComplete);
    }

    final bundlePath = _pickMainBundlePath(mainBundlePath, binaries, inventory);
    final byPath = <String, ArtifactEntry>{
      for (final entry in inventory.entries) entry.path: entry,
    };
    // 解析候选：清单条目 + 已被解析的二进制本身。后者即使因清单截断没进
    // inventory，也**确实**在包里（我们刚解析过它的字节）。
    final knownPaths = <String>{...byPath.keys};
    for (final input in binaries) {
      final path = normalizeArchivePath(input.path);
      if (path.isNotEmpty) knownPaths.add(path);
    }

    final nodes = <String, LoadNode>{};
    final edgeKeys = <String>{};
    final edges = <LoadEdge>[];
    final danglingIds = <String>{};
    var complete = inventory.entriesComplete;
    var edgeLimitHit = false;

    void addNode(LoadNode node) {
      nodes.putIfAbsent(node.id, () => node);
    }

    void addEdge(
      String fromId,
      String toId,
      LoadEdgeKind kind,
      String location,
    ) {
      final key = '$fromId|$toId|${kind.name}';
      if (!edgeKeys.add(key)) return;
      final edge = LoadEdge(
        fromId: fromId,
        toId: toId,
        kind: kind,
        source: SecurityEvidenceSource.loadGraph,
        location: location,
      );
      edges.add(edge);
      if (!nodes.containsKey(toId)) {
        // 目标节点由调用点保证已建；这里只是兜底，避免悬空 id。
        addNode(LoadNode(
          id: toId,
          kind: LoadNodeKind.unknown,
          presentInPackage: false,
        ));
      }
      if (nodes[toId]!.presentInPackage == false) {
        danglingIds.add(edge.id);
      }
    }

    void addMissing(String sourceId, String target, String location) {
      final nodeId = 'missing:$target';
      addNode(LoadNode(
        id: nodeId,
        kind: LoadNodeKind.missing,
        presentInPackage: false,
      ));
      addEdge(sourceId, nodeId, LoadEdgeKind.machoLinkedLibrary, location);
    }

    void addResolved(String sourceId, String path, String location) {
      final nodeId = 'artifact:$path';
      addNode(LoadNode(
        id: nodeId,
        kind: _nodeKindFor(path, byPath),
        resolvedPath: path,
        presentInPackage: true,
      ));
      addEdge(sourceId, nodeId, LoadEdgeKind.machoLinkedLibrary, location);
    }

    outer:
    for (final input in binaries) {
      final path = normalizeArchivePath(input.path);
      if (path.isEmpty) {
        complete = false;
        continue;
      }

      final sourceId = 'artifact:$path';
      addNode(LoadNode(
        id: sourceId,
        kind: _nodeKindFor(path, byPath),
        resolvedPath: path,
        presentInPackage: true,
      ));

      final file = input.macho;
      if (file.images.isEmpty) {
        // 解析失败/空文件：不能声称遍历完整。
        complete = false;
        continue;
      }
      final isFat = file.images.length > 1;

      for (final image in file.images) {
        final arch = isFat ? ' (${image.cpuTypeName})' : '';

        // LC_RPATH：只为**包外绝对路径**建边。包内 rpath
        // （`@executable_path/Frameworks`）是正常布局，建边只会制造噪音；
        // 它作为 `@rpath` 的解析依据写进对应边的 location。
        for (var i = 0; i < image.rpaths.length; i++) {
          if (edges.length >= maxEdges) {
            edgeLimitHit = true;
            break outer;
          }
          final rpath = image.rpaths[i];
          if (!_isForeignAbsolutePath(rpath)) continue;
          final nodeId = 'rpath:$rpath';
          addNode(LoadNode(
            id: nodeId,
            kind: LoadNodeKind.unknown,
            presentInPackage: false,
          ));
          addEdge(
            sourceId,
            nodeId,
            LoadEdgeKind.machoRPath,
            'LC_RPATH#${i + 1}$arch',
          );
        }

        for (var i = 0; i < image.linkedLibraries.length; i++) {
          if (edges.length >= maxEdges) {
            edgeLimitHit = true;
            break outer;
          }
          final library = image.linkedLibraries[i];
          final base = 'LC_LOAD_DYLIB#${i + 1}$arch';
          if (library.isEmpty) {
            // 空安装名是畸形命令：记为不完整，但不编造边。
            complete = false;
            continue;
          }

          if (library.startsWith('@rpath/')) {
            final rest = library.substring('@rpath/'.length);
            final resolution = _resolveRPath(
              rest,
              binaryPath: path,
              image: image,
              bundlePath: bundlePath,
              knownPaths: knownPaths,
            );
            if (resolution == null) {
              addMissing(sourceId, library, '$base $library -> missing');
              continue;
            }
            final basis = resolution.rpath == null
                ? 'suffix match'
                : 'rpath ${resolution.rpath}';
            addResolved(
              sourceId,
              resolution.path,
              '$base $library -> ${resolution.path} ($basis)',
            );
            continue;
          }

          if (library.startsWith('@executable_path/')) {
            final rest = library.substring('@executable_path/'.length);
            if (bundlePath == null) {
              // 不知道主 bundle 就无法展开，不能假装「包里没有」。
              complete = false;
              addMissing(
                  sourceId, library, '$base -> missing (no main bundle)');
              continue;
            }
            final observed = _normalizeDots('$bundlePath/$rest');
            if (knownPaths.contains(observed)) {
              addResolved(sourceId, observed, '$base $library -> $observed');
            } else {
              addMissing(
                sourceId,
                library,
                '$base $library -> missing ($observed not in inventory)',
              );
            }
            continue;
          }

          if (library.startsWith('@loader_path/')) {
            final rest = library.substring('@loader_path/'.length);
            final observed = _normalizeDots('${_dirName(path)}/$rest');
            if (knownPaths.contains(observed)) {
              addResolved(sourceId, observed, '$base $library -> $observed');
            } else {
              addMissing(
                sourceId,
                library,
                '$base $library -> missing ($observed not in inventory)',
              );
            }
            continue;
          }

          // 越狱/注入位置即使在 /usr/lib 下也不是系统库：必须记 dangling。
          if (!_isJailbreakPath(library) && _isSystemLibrary(library)) {
            // 系统库：不建包内边，也不建节点，计入「已处理」。
            continue;
          }

          addMissing(sourceId, library, '$base $library -> missing');
        }
      }
    }

    if (edgeLimitHit) complete = false;

    return LoadGraph(
      nodes: nodes.values.toList(),
      edges: edges,
      // 排序保证同一份输入得到同一份输出（与 Android 侧一致）。
      danglingEdgeIds: danglingIds.toList()..sort(),
      complete: complete,
    );
  }

  // ---------------------------------------------------------------------
  // 路径解析
  // ---------------------------------------------------------------------

  /// `@rpath/X` 的解析。返回 `null` 表示包内没有对得上的条目。
  static _Resolution? _resolveRPath(
    String rest, {
    required String binaryPath,
    required MachOImage image,
    required String? bundlePath,
    required Set<String> knownPaths,
  }) {
    // 1) 按本镜像声明的 rpath 逐条展开（dyld 的语义）。
    for (final rpath in image.rpaths) {
      final dir = _expandSearchPath(
        rpath,
        binaryPath: binaryPath,
        bundlePath: bundlePath,
      );
      if (dir == null) continue;
      final candidate = _normalizeDots('$dir/$rest');
      if (knownPaths.contains(candidate)) {
        return _Resolution(candidate, rpath);
      }
    }
    // 2) 回退：包内路径后缀匹配。优先 `Frameworks/`，再取最短、字典序最小。
    final fallback = _bestSuffixMatch(rest, knownPaths);
    if (fallback == null) return null;
    return _Resolution(fallback, null);
  }

  /// 展开一条 `LC_RPATH`；无法静态展开（相对路径、@executable_path 但
  /// 主 bundle 未知）时返回 `null`。
  ///
  /// 相对 rpath 按 dyld 的语义是相对**当前工作目录**，静态不可知，
  /// 因此不参与解析（也不把它当包内依据）。
  static String? _expandSearchPath(
    String rpath, {
    required String binaryPath,
    required String? bundlePath,
  }) {
    if (rpath == '@executable_path') return bundlePath;
    if (rpath.startsWith('@executable_path/')) {
      if (bundlePath == null) return null;
      return _normalizeDots(
        '$bundlePath/${rpath.substring('@executable_path/'.length)}',
      );
    }
    if (rpath == '@loader_path') return _dirName(binaryPath);
    if (rpath.startsWith('@loader_path/')) {
      return _normalizeDots(
        '${_dirName(binaryPath)}/${rpath.substring('@loader_path/'.length)}',
      );
    }
    if (rpath.startsWith('/')) return _normalizeDots(rpath);
    return null;
  }

  /// 包内路径后缀匹配：`rest` 可能是 `Foo.framework/Foo`。
  static String? _bestSuffixMatch(String rest, Set<String> knownPaths) {
    final suffix = '/$rest';
    String? best;
    var bestRank = 0;
    for (final path in knownPaths) {
      if (path != rest && !path.endsWith(suffix)) continue;
      final rank = _prefersFrameworks(path) ? 2 : 1;
      final better = best == null
          ? true
          : rank != bestRank
              ? rank > bestRank
              : path.length != best.length
                  ? path.length < best.length
                  : path.compareTo(best) < 0;
      if (better) {
        best = path;
        bestRank = rank;
      }
    }
    return best;
  }

  static bool _prefersFrameworks(String path) =>
      path.contains('/Frameworks/') || path.startsWith('Frameworks/');

  static bool _isSystemLibrary(String path) {
    for (final prefix in _systemPrefixes) {
      if (path.startsWith(prefix)) return true;
    }
    return false;
  }

  /// 已知的越狱/注入位置。**不声称穷尽**，只覆盖设计文档点到的几处。
  static bool _isJailbreakPath(String path) {
    for (final prefix in _jailbreakPrefixes) {
      if (path.startsWith(prefix)) return true;
    }
    return false;
  }

  static bool _isForeignAbsolutePath(String path) {
    if (!path.startsWith('/')) return false;
    return !_isSystemLibrary(path);
  }

  static LoadNodeKind _nodeKindFor(
    String path,
    Map<String, ArtifactEntry> byPath,
  ) {
    final entry = byPath[path];
    if (entry != null) return _nodeKind(entry.kind);
    final lower = path.toLowerCase();
    if (lower.contains('.framework/')) return LoadNodeKind.framework;
    if (lower.endsWith('.dylib')) return LoadNodeKind.dylib;
    return LoadNodeKind.machO;
  }

  static LoadNodeKind _nodeKind(ArtifactKind kind) => switch (kind) {
        ArtifactKind.machO => LoadNodeKind.machO,
        ArtifactKind.dylib => LoadNodeKind.dylib,
        ArtifactKind.framework => LoadNodeKind.framework,
        // 可执行文件（主程序/appex/Watch）都是 Mach-O 镜像。
        ArtifactKind.nestedCodeBundle => LoadNodeKind.machO,
        ArtifactKind.elf => LoadNodeKind.elf,
        ArtifactKind.dex => LoadNodeKind.dex,
        ArtifactKind.script => LoadNodeKind.script,
        _ => LoadNodeKind.unknown,
      };

  static String? _pickMainBundlePath(
    String? provided,
    List<IosMachOInput> binaries,
    ArtifactInventory inventory,
  ) {
    if (provided != null && provided.trim().isNotEmpty) {
      final normalized = normalizeArchivePath(provided.trim());
      return normalized.isEmpty ? null : normalized;
    }
    return _inferMainBundle(binaries, inventory);
  }

  /// 从二进制路径/清单条目里推断主 `.app`：优先 `Payload/<X>.app`。
  static String? _inferMainBundle(
    List<IosMachOInput> binaries,
    ArtifactInventory inventory,
  ) {
    final candidates = <String>[
      for (final input in binaries) normalizeArchivePath(input.path),
      for (final entry in inventory.entries) entry.path,
    ];

    for (final path in candidates) {
      if (path.isEmpty) continue;
      final segments = path.split('/');
      for (var i = 1; i < segments.length; i++) {
        if (segments[i - 1] == 'Payload' &&
            segments[i].toLowerCase().endsWith('.app')) {
          return segments.sublist(0, i + 1).join('/');
        }
      }
    }
    for (final path in candidates) {
      if (path.isEmpty) continue;
      final segments = path.split('/');
      for (var i = 0; i < segments.length; i++) {
        if (segments[i].toLowerCase().endsWith('.app')) {
          return segments.sublist(0, i + 1).join('/');
        }
      }
    }
    return null;
  }

  static String _dirName(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  /// 归一化 `.` / `..`，并去掉多余的分隔符。
  ///
  /// 只用于**包内路径**比较（`@executable_path/../Frameworks/...` 这类写法
  /// 必须还原成稳定比较键）；不用于展示，展示用原始安装名。
  static String _normalizeDots(String path) {
    final out = <String>[];
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(segment);
    }
    return out.join('/');
  }

  static const List<String> _systemPrefixes = [
    '/usr/lib/',
    '/System/Library/',
    '/System/iOSSupport/',
  ];

  static const List<String> _jailbreakPrefixes = [
    '/Library/MobileSubstrate/',
    '/usr/lib/frida/',
    '/usr/lib/libsubstrate',
    '/Library/Frameworks/CydiaSubstrate.framework/',
    '/var/jb/',
    '/private/preboot/',
  ];
}

class _Resolution {
  const _Resolution(this.path, this.rpath);

  /// 命中的包内路径。
  final String path;

  /// 命中的 `LC_RPATH`；后缀回退命中时为 `null`。
  final String? rpath;
}
