import 'security_finding.dart';

/// 加载链：谁加载了谁，以及目标是否在包内。
///
/// 这是「包内库」与「运行时下载/解密加载」的分界线。事实层只记录边；
/// 规则层根据 `presentInPackage == false` 产出「悬空加载边」。
class LoadGraph {
  final List<LoadNode> nodes;
  final List<LoadEdge> edges;

  /// 目标不在包内的边 id（`fromId->toId`）。
  final List<String> danglingEdgeIds;

  /// 本次遍历是否完整（被预算/解析失败截断时为 false）。
  final bool complete;

  const LoadGraph({
    this.nodes = const [],
    this.edges = const [],
    this.danglingEdgeIds = const [],
    this.complete = true,
  });

  bool get isEmpty => nodes.isEmpty && edges.isEmpty;

  bool get hasDanglingEdges => danglingEdgeIds.isNotEmpty;

  LoadNode? node(String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  List<LoadEdge> edgesFrom(String id) => [
        for (final edge in edges)
          if (edge.fromId == id) edge
      ];

  @override
  String toString() => 'LoadGraph(${nodes.length} nodes, '
      '${edges.length} edges, ${danglingEdgeIds.length} dangling, '
      'complete=$complete)';
}

/// 加载节点类型。
enum LoadNodeKind {
  dex,
  elf,
  machO,
  dylib,
  framework,
  script,
  missing,
  unknown
}

/// 加载边的类型。
enum LoadEdgeKind {
  systemLoadLibrary,
  systemLoad,
  dexClassLoader,
  inMemoryDexLoader,
  nativeDlopen,
  nativeDlsym,
  machoLinkedLibrary,
  machoWeakLinked,
  machoRPath,
  bundleEntryReference,
  unknown;

  String get label => switch (this) {
        LoadEdgeKind.systemLoadLibrary => 'System.loadLibrary',
        LoadEdgeKind.systemLoad => 'System.load',
        LoadEdgeKind.dexClassLoader => 'DexClassLoader',
        LoadEdgeKind.inMemoryDexLoader => 'InMemoryDexClassLoader',
        LoadEdgeKind.nativeDlopen => 'native dlopen',
        LoadEdgeKind.nativeDlsym => 'native dlsym',
        LoadEdgeKind.machoLinkedLibrary => 'LC_LOAD_DYLIB',
        LoadEdgeKind.machoWeakLinked => 'LC_LOAD_WEAK_DYLIB',
        LoadEdgeKind.machoRPath => 'LC_RPATH',
        LoadEdgeKind.bundleEntryReference => 'bundle entry reference',
        LoadEdgeKind.unknown => 'unknown',
      };
}

/// 一个加载节点。
class LoadNode {
  /// 稳定 id：`artifact:<path>` / `runtime:<name>` / `missing:<name>`。
  final String id;

  final LoadNodeKind kind;

  /// 解析到的包内路径；`null` = 没映射到包内条目。
  final String? resolvedPath;

  /// 目标是否在包内。
  final bool presentInPackage;

  const LoadNode({
    required this.id,
    required this.kind,
    this.resolvedPath,
    this.presentInPackage = false,
  });

  @override
  String toString() => 'LoadNode($id, ${kind.name}, '
      'path=$resolvedPath, present=$presentInPackage)';
}

/// 一条加载边。
class LoadEdge {
  final String fromId;
  final String toId;
  final LoadEdgeKind kind;

  /// 证据来源（加载命令 / 调用点 / 制品清单）。
  final SecurityEvidenceSource source;

  /// 位置：`Lcom/...@0x12` / `LC_LOAD_DYLIB#3`。
  final String location;

  const LoadEdge({
    required this.fromId,
    required this.toId,
    required this.kind,
    required this.source,
    required this.location,
  });

  String get id => '$fromId->$toId';

  @override
  String toString() => 'LoadEdge($id, ${kind.name}, $source, $location)';
}
