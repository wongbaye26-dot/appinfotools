// 归档文件树（V3 F04 文件浏览器的基础）。
//
// 为什么放在 archive_safety 而不是某个解析器里：树只关心「ZIP 里有什么」，
// 与 APK/IPA 语义无关；而这里必须复用同一条解压预算，否则文件浏览器会成为
// 绕过预算的后门（一屏预览就能把一个 2 GiB 的包解开）。
//
// 规则：
// - 普通条目只读中央目录里的声明大小，不解压；
// - 嵌套归档（zip/jar/apk/xapk/ipa 或魔数为 `PK\x03\x04`）才调用
//   `readForNesting` 解压，并受层数/字节/条目三重上限约束；
// - 嵌套用 `!` 分隔（`assets/x.zip!payload.dex`），与 `ArtifactIdentity` 一致；
// - 任何上限触发都写进 `skippedCodes`，不静默截断。

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 树中的一个节点。
class ArchiveNode {
  /// 完整路径；嵌套归档内层用 `!` 分隔。
  final String path;

  /// 最后一段名字。
  final String name;

  final bool isDirectory;

  /// 声明大小（解压后）；目录为 0。
  final int size;

  /// 是否是「被展开过的嵌套归档」（节点自身仍是文件，children 是内部条目）。
  final bool isNestedArchive;

  /// 同路径重复出现（畸形 zip）时置 true，不覆盖第一个。
  final bool duplicate;

  final List<ArchiveNode> children;

  const ArchiveNode({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size = 0,
    this.isNestedArchive = false,
    this.duplicate = false,
    this.children = const [],
  });

  ArchiveNode? child(String name) {
    for (final node in children) {
      if (node.name == name) return node;
    }
    return null;
  }

  @override
  String toString() =>
      'ArchiveNode($path, dir=$isDirectory, size=$size, children=${children.length})';
}

/// 文件树 + 统计。
class ArchiveTree {
  final ArchiveNode root;

  /// 已收录的条目数（不含合成的目录节点）。
  final int entryCount;

  /// 是否因为预算被截断。
  final bool truncated;

  /// 触发上限的稳定 code（`tree.entryLimit` / `tree.depthLimit` /
  /// `tree.nestedBytes` / `tree.duplicatePath` / `tree.nestedUndecodable`）。
  final List<String> skippedCodes;

  const ArchiveTree({
    required this.root,
    required this.entryCount,
    this.truncated = false,
    this.skippedCodes = const [],
  });

  /// 深度优先遍历全部节点（含目录与嵌套内部条目）。
  Iterable<ArchiveNode> get all {
    final out = <ArchiveNode>[];
    void walk(ArchiveNode node) {
      out.add(node);
      for (final child in node.children) {
        walk(child);
      }
    }

    walk(root);
    return out;
  }
}

/// 建树上限。默认值对齐现有清单预算，避免出现「浏览器比分析更吃内存」。
class ArchiveTreeLimits {
  /// 最多收录多少个条目（含嵌套内部条目）。
  final int maxEntries;

  /// 嵌套归档最多展开几层（1 = 只展开第一层嵌套）。
  final int maxNestedDepth;

  /// 所有嵌套归档解压后的总字节上限。
  final int maxNestedBytes;

  /// 单个嵌套归档的解压上限。
  final int maxNestedEntryBytes;

  const ArchiveTreeLimits({
    this.maxEntries = 20000,
    this.maxNestedDepth = 2,
    this.maxNestedBytes = 64 * 1024 * 1024,
    this.maxNestedEntryBytes = 16 * 1024 * 1024,
  });
}

/// 从已解码的 [Archive] 建树。
class ArchiveTreeBuilder {
  const ArchiveTreeBuilder._();

  static final RegExp _nestedExtensions =
      RegExp(r'\.(zip|jar|apk|xapk|apkm|apks|ipa)$', caseSensitive: false);

  /// [readForNesting] 只为候选嵌套归档解压字节；普通条目完全不读内容。
  /// 返回 null 表示拒绝（超预算/不可读），会在 `skippedCodes` 里留下原因。
  static ArchiveTree build(
    Archive archive, {
    ArchiveTreeLimits limits = const ArchiveTreeLimits(),
    Uint8List? Function(ArchiveFile file)? readForNesting,
  }) {
    final root = _MutableNode.root();
    var entryCount = 0;
    var truncated = false;
    var nestedBytes = 0;
    final skipped = <String>{};

    // 嵌套归档内部的条目：第一段挂在归档节点下（路径用 `!` 连接），
    // 更深层用普通 `/`，与 `ArtifactIdentity.describe` 的语义一致。
    void addNested(_MutableNode parent, String relativePath, int size) {
      final segments =
          relativePath.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return;
      var current = parent;
      for (var i = 0; i < segments.length; i++) {
        final isLeaf = i == segments.length - 1;
        final segment = segments[i];
        final existing = current.childMutable(segment);
        if (existing != null) {
          if (isLeaf) {
            skipped.add('tree.duplicatePath');
            current.markChildDuplicate(segment);
            return;
          }
          current = existing;
          continue;
        }
        final path =
            i == 0 ? '${parent.path}!$segment' : '${current.path}/$segment';
        final node = _MutableNode(
          path: path,
          name: segment,
          isDirectory: !isLeaf,
          size: isLeaf ? size : 0,
        );
        current.addChild(node);
        current = node;
        if (isLeaf) entryCount++;
      }
    }

    bool addEntry(
      String fullPath, {
      int size = 0,
      bool isDirectory = false,
      ArchiveFile? nestedCandidate,
      int depth = 0,
    }) {
      final segments = fullPath.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return false;
      var current = root;
      for (var i = 0; i < segments.length; i++) {
        final isLeaf = i == segments.length - 1;
        final segment = segments[i];
        final existing = current.childMutable(segment);
        if (existing != null) {
          if (isLeaf) {
            skipped.add('tree.duplicatePath');
            current.markChildDuplicate(segment);
            return false;
          }
          current = existing;
          continue;
        }
        final node = _MutableNode(
          path: current.path.isEmpty ? segment : '${current.path}/$segment',
          name: segment,
          isDirectory: isLeaf ? isDirectory : true,
          size: isLeaf ? size : 0,
        );
        current.addChild(node);
        current = node;
        if (isLeaf) entryCount++;
      }
      if (nestedCandidate != null) {
        _expandNested(
          node: current,
          file: nestedCandidate,
          depth: depth,
          limits: limits,
          readForNesting: readForNesting,
          addNested: addNested,
          onNestedBytes: (bytes) => nestedBytes += bytes,
          nestedBytesUsed: () => nestedBytes,
          skipped: skipped,
          markTruncated: () => truncated = true,
          entryCount: () => entryCount,
        );
      }
      return true;
    }

    for (final file in archive.files) {
      if (entryCount >= limits.maxEntries) {
        truncated = true;
        skipped.add('tree.entryLimit');
        break;
      }
      if (!file.isFile) {
        addEntry(file.name, isDirectory: true);
        continue;
      }
      final candidate = _isNestedCandidate(file.name) ? file : null;
      addEntry(file.name,
          size: file.size, nestedCandidate: candidate, depth: 1);
    }

    return ArchiveTree(
      root: root.freeze(),
      entryCount: entryCount,
      truncated: truncated,
      skippedCodes: skipped.toList()..sort(),
    );
  }

  static bool _isNestedCandidate(String name) =>
      _nestedExtensions.hasMatch(name);

  static void _expandNested({
    required _MutableNode node,
    required ArchiveFile file,
    required int depth,
    required ArchiveTreeLimits limits,
    required Uint8List? Function(ArchiveFile file)? readForNesting,
    required void Function(_MutableNode parent, String relativePath, int size)
        addNested,
    required void Function(int bytes) onNestedBytes,
    required int Function() nestedBytesUsed,
    required Set<String> skipped,
    required void Function() markTruncated,
    required int Function() entryCount,
  }) {
    if (readForNesting == null) return;
    if (depth > limits.maxNestedDepth) {
      skipped.add('tree.depthLimit');
      return;
    }
    if (file.size > limits.maxNestedEntryBytes) {
      skipped.add('tree.nestedBytes');
      return;
    }
    final remaining = limits.maxNestedBytes - nestedBytesUsed();
    if (remaining <= 0 || file.size > remaining) {
      skipped.add('tree.nestedBytes');
      return;
    }
    final bytes = readForNesting(file);
    if (bytes == null) {
      skipped.add('tree.nestedUndecodable');
      return;
    }
    // 只认 PK\x03\x04：扩展名可以撒谎，魔数不能。
    if (bytes.length < 4 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4B ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      skipped.add('tree.nestedUndecodable');
      return;
    }
    onNestedBytes(bytes.length);

    Archive nested;
    try {
      nested = ZipDecoder().decodeBytes(bytes, verify: false);
    } catch (_) {
      skipped.add('tree.nestedUndecodable');
      return;
    }

    node.isNested = true;
    for (final inner in nested.files) {
      if (entryCount() >= limits.maxEntries) {
        markTruncated();
        skipped.add('tree.entryLimit');
        return;
      }
      if (!inner.isFile) continue;
      if (_isNestedCandidate(inner.name)) {
        // 只展开一层嵌套；更深层留给阶段 2 的按需加载，避免一次建树就解压整棵树。
        skipped.add('tree.nestedNotExpanded');
      }
      addNested(node, inner.name, inner.size);
    }
  }
}

/// 内部可变节点；对外只暴露不可变 [ArchiveNode]。
class _MutableNode {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  bool isNested;
  bool duplicate;
  final List<_MutableNode> _children;

  _MutableNode({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size = 0,
  })  : isNested = false,
        duplicate = false,
        _children = [];

  factory _MutableNode.root() =>
      _MutableNode(path: '', name: '', isDirectory: true);

  _MutableNode? childMutable(String name) {
    for (final node in _children) {
      if (node.name == name) return node;
    }
    return null;
  }

  void addChild(_MutableNode child) => _children.add(child);

  void markChildDuplicate(String name) {
    final existing = childMutable(name);
    if (existing != null) existing.duplicate = true;
  }

  ArchiveNode freeze() {
    final children = _children.map((c) => c.freeze()).toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return ArchiveNode(
      path: path,
      name: name,
      isDirectory: isDirectory,
      size: size,
      isNestedArchive: isNested,
      duplicate: duplicate,
      children: children,
    );
  }
}
