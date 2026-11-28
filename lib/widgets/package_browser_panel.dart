// 文件浏览器（V3 F04）：树 / 搜索 / 预览。
//
// 只做「看」，不做修改：包是只读证据，预览也不会写回。
// 所有读取都走 `PackageArchiveTree`（共享预算），不会因为点开一个 200 MB
// 的 assets 条目把内存打满。

import 'dart:convert';

import 'package:archive_safety/archive_safety.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/format.dart';
import 'package:apk_info_tool/utils/package_archive_tree.dart';

class PackageBrowserPanel extends StatefulWidget {
  final String packagePath;

  const PackageBrowserPanel({super.key, required this.packagePath});

  @override
  State<PackageBrowserPanel> createState() => _PackageBrowserPanelState();
}

class _PackageBrowserPanelState extends State<PackageBrowserPanel> {
  Future<(PackageArchiveTree?, PackageTreeResult)>? _loading;
  PackageArchiveTree? _tree;
  ArchiveTree? _archiveTree;
  String? _failure;
  final TextEditingController _search = TextEditingController();
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PackageBrowserPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packagePath != widget.packagePath) {
      _tree?.close();
      _tree = null;
      _expanded.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _tree?.close();
    _search.dispose();
    super.dispose();
  }

  void _load() {
    final future = PackageArchiveTree.open(widget.packagePath);
    _loading = future;
    future.then((result) {
      if (!mounted) return;
      final (tree, treeResult) = result;
      setState(() {
        _tree = tree;
        _archiveTree = treeResult.tree;
        _failure = treeResult.failure;
        // 顶层目录默认展开一层：第一屏就能看到 lib/ res/ assets/ 的分布。
        for (final node
            in treeResult.tree?.root.children ?? const <ArchiveNode>[]) {
          if (node.isDirectory) _expanded.add(node.path);
        }
      });
    });
  }

  List<ArchiveNode> _visibleRows(ArchiveNode root, String query) {
    final rows = <ArchiveNode>[];
    void walk(ArchiveNode node) {
      for (final child in node.children) {
        if (query.isNotEmpty) {
          if (child.path.toLowerCase().contains(query)) {
            rows.add(child);
          }
          walk(child);
          continue;
        }
        rows.add(child);
        if (child.isDirectory && _expanded.contains(child.path)) walk(child);
      }
    }

    walk(root);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.folder_open_outlined,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(t.browser.title,
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 10),
                if (_archiveTree != null)
                  Text(
                    '${_archiveTree!.entryCount} ${t.browser.entries}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                const Spacer(),
                SizedBox(
                  width: 240,
                  height: 32,
                  child: TextField(
                    controller: _search,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 16),
                      hintText: t.browser.search_hint,
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            if (_archiveTree?.truncated == true) ...[
              const SizedBox(height: 8),
              _Notice(
                text: t.browser
                    .truncated(codes: _archiveTree!.skippedCodes.join(', ')),
                tone: _NoticeTone.warning,
              ),
            ],
            const SizedBox(height: 10),
            if (_loading == null)
              const SizedBox.shrink()
            else if (_failure != null)
              _Notice(text: _failure!, tone: _NoticeTone.error)
            else if (_archiveTree == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              _buildRows(context, t),
          ],
        ),
      ),
    );
  }

  Widget _buildRows(BuildContext context, Translations t) {
    final query = _search.text.trim().toLowerCase();
    final rows = _visibleRows(_archiveTree!.root, query);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(t.browser.empty,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }
    final shown = rows.take(400).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final node in shown)
          _BrowserRow(
            node: node,
            depth: _depthOf(node),
            expanded: _expanded.contains(node.path),
            onTap: () {
              if (node.isDirectory || node.isNestedArchive) {
                setState(() {
                  if (!_expanded.remove(node.path)) _expanded.add(node.path);
                });
                return;
              }
              _openPreview(context, t, node);
            },
          ),
        if (rows.length > shown.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t.browser.more_rows(count: '${rows.length - shown.length}'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
      ],
    );
  }

  int _depthOf(ArchiveNode node) {
    if (node.path.contains('!')) {
      return '!'.allMatches(node.path).length + node.name.split('/').length;
    }
    return node.path.split('/').length - 1;
  }

  Future<void> _openPreview(
      BuildContext context, Translations t, ArchiveNode node) async {
    final tree = _tree;
    if (tree == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _PreviewDialog(tree: tree, node: node),
    );
  }
}

class _BrowserRow extends StatelessWidget {
  final ArchiveNode node;
  final int depth;
  final bool expanded;
  final VoidCallback onTap;

  const _BrowserRow({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDir = node.isDirectory || node.isNestedArchive;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.only(
          left: 4.0 + depth * 14.0,
          top: 5,
          bottom: 5,
          right: 4,
        ),
        child: Row(
          children: [
            Icon(
              isDir
                  ? (expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right)
                  : _iconFor(node),
              size: 15,
              color: isDir ? colorScheme.primary : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  color: node.duplicate ? colorScheme.error : null,
                ),
              ),
            ),
            if (node.isNestedArchive) ...[
              const SizedBox(width: 8),
              Text(
                'ZIP',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colorScheme.primary,
                ),
              ),
            ],
            if (!node.isDirectory) ...[
              const SizedBox(width: 10),
              Text(
                formatFileSize(node.size),
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(ArchiveNode node) {
    final name = node.name.toLowerCase();
    if (name.endsWith('.xml')) return Icons.code;
    if (name.endsWith('.dex')) return Icons.memory;
    if (name.endsWith('.so') || name.endsWith('.dylib')) return Icons.extension;
    if (name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (name.endsWith('.json') ||
        name.endsWith('.txt') ||
        name.endsWith('.properties')) {
      return Icons.article_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

class _PreviewDialog extends StatefulWidget {
  final PackageArchiveTree tree;
  final ArchiveNode node;

  const _PreviewDialog({required this.tree, required this.node});

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  static const int _maxBytes = 256 * 1024;

  PackageEntryRead? _read;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final read = widget.tree.readEntry(widget.node.path, maxBytes: _maxBytes);
    setState(() {
      _read = read;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 860,
          maxHeight: size.height * 0.78,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.node.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t.browser.copy_path,
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.node.path));
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : (_read?.isOk != true
                        ? Center(
                            child: Text(
                              '${t.browser.unreadable}: ${_read?.skipCode ?? '-'}',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          )
                        : _buildBody(context, _read!.bytes!)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Uint8List bytes) {
    final image = _imageIfAny(bytes);
    if (image != null) {
      return Center(child: Image(image: image, fit: BoxFit.contain));
    }
    final text = _textIfAny(bytes);
    if (text != null) {
      return SingleChildScrollView(
        child: SelectableText(
          text,
          style: const TextStyle(
              fontFamily: 'monospace', fontSize: 11.5, height: 1.45),
        ),
      );
    }
    return SingleChildScrollView(
      child: SelectableText(
        _hexDump(bytes),
        style: const TextStyle(
            fontFamily: 'monospace', fontSize: 11.5, height: 1.45),
      ),
    );
  }

  ImageProvider? _imageIfAny(Uint8List bytes) {
    if (bytes.length > 4) {
      final isPng = bytes[0] == 0x89 && bytes[1] == 0x50;
      final isJpeg = bytes[0] == 0xFF && bytes[1] == 0xD8;
      final isGif = bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46;
      final isWebp = bytes.length > 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50;
      if (isPng || isJpeg || isGif || isWebp) return MemoryImage(bytes);
    }
    return null;
  }

  /// 只在「能完整按 UTF-8 解码且可打印比例足够」时按文本显示，
  /// 否则退回 hex —— 避免把二进制显示成乱码方块。
  String? _textIfAny(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    final sample =
        bytes.length > 64 * 1024 ? bytes.sublist(0, 64 * 1024) : bytes;
    final String decoded;
    try {
      decoded = utf8.decode(sample);
    } catch (_) {
      return null;
    }
    final printable = decoded.runes
        .where((r) => r == 9 || r == 10 || r == 13 || r >= 32)
        .length;
    if (printable / decoded.runes.length < 0.95) return null;
    if (bytes.length <= 64 * 1024) return decoded;
    return '$decoded\n\n… (${bytes.length} bytes, preview truncated)';
  }

  String _hexDump(Uint8List bytes) {
    final buffer = StringBuffer();
    final limit = bytes.length > 4096 ? 4096 : bytes.length;
    for (var i = 0; i < limit; i += 16) {
      final end = i + 16 > limit ? limit : i + 16;
      final line = bytes.sublist(i, end);
      final hex =
          line.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      final ascii = line
          .map((b) => b >= 32 && b < 127 ? String.fromCharCode(b) : '.')
          .join();
      buffer.writeln('${i.toRadixString(16).padLeft(8, '0')}  '
          '${hex.padRight(47)}  $ascii');
    }
    if (bytes.length > limit) {
      buffer.writeln('… (${bytes.length} bytes total)');
    }
    return buffer.toString();
  }
}

enum _NoticeTone { warning, error }

class _Notice extends StatelessWidget {
  final String text;
  final _NoticeTone tone;

  const _Notice({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color =
        tone == _NoticeTone.error ? colorScheme.error : colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: color)),
    );
  }
}
