import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';

/// Android 安全 Tab 的「结构化证据」卡片：制品清单与加载链。
///
/// 这两个结果以前只在审计内部参与「盗 U」链判定，报告里恒为 `null`，
/// 用户看不到结论背后的盘点范围。现在把它们原样呈现，并明确标出截断/
/// 不完整 —— **有证据不等于结论成立**，这里不重新判级。
class SecurityEvidenceCard extends StatelessWidget {
  final ArtifactInventory? artifacts;
  final LoadGraph? loadGraph;

  const SecurityEvidenceCard({
    super.key,
    this.artifacts,
    this.loadGraph,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;
    final rows = <Widget>[];

    final inventory = artifacts;
    if (inventory != null) {
      rows.add(_row(
        theme,
        Icons.inventory_2_outlined,
        t.security.evidence_artifacts_summary(
          count: inventory.inventoriedEntries,
          total: inventory.totalEntries,
        ),
      ));
      if (!inventory.entriesComplete) {
        rows.add(_row(
          theme,
          Icons.content_cut,
          t.security.evidence_artifacts_truncated,
          warning: true,
        ));
      }
      for (final code in inventory.skippedCodes) {
        rows.add(_row(theme, Icons.info_outline, code));
      }
      if (inventory.entries.isNotEmpty) {
        rows.add(_viewButton(
          context,
          t.security.evidence_view_artifacts(count: inventory.entries.length),
          () => showDialog<void>(
            context: context,
            builder: (_) => _ArtifactDialog(inventory: inventory),
          ),
        ));
      }
    }

    final graph = loadGraph;
    if (graph != null) {
      rows.add(_row(
        theme,
        Icons.account_tree_outlined,
        t.security.evidence_load_graph_summary(
          nodes: graph.nodes.length,
          edges: graph.edges.length,
        ),
      ));
      if (graph.danglingEdgeIds.isNotEmpty) {
        rows.add(_row(
          theme,
          Icons.link_off,
          t.security.evidence_load_graph_dangling(
            count: graph.danglingEdgeIds.length,
          ),
        ));
      }
      if (!graph.complete) {
        rows.add(_row(
          theme,
          Icons.info_outline,
          t.security.evidence_load_graph_incomplete,
          warning: true,
        ));
      }
      if (!graph.isEmpty) {
        rows.add(_viewButton(
          context,
          t.security.evidence_view_load_graph(count: graph.edges.length),
          () => showDialog<void>(
            context: context,
            builder: (_) => _LoadGraphDialog(graph: graph),
          ),
        ));
      }
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.security.evidence_title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...rows,
          ],
        ),
      ),
    );
  }

  Widget _viewButton(BuildContext context, String label, VoidCallback onTap) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 30),
        ),
        child: Text(label, style: theme.textTheme.labelSmall),
      ),
    );
  }

  Widget _row(
    ThemeData theme,
    IconData icon,
    String text, {
    bool warning = false,
  }) {
    final color = warning
        ? theme.colorScheme.tertiary
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtifactDialog extends StatelessWidget {
  final ArtifactInventory inventory;

  const _ArtifactDialog({required this.inventory});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;
    return AlertDialog(
      title: Text(t.security.evidence_title),
      content: SizedBox(
        width: 920,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(theme, [
              t.security.evidence_artifact_path,
              t.security.evidence_artifact_kind,
              t.security.evidence_artifact_size,
              t.security.evidence_artifact_hash,
            ]),
            const Divider(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: inventory.entries.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final entry = inventory.entries[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: SelectableText(
                            entry.path,
                            maxLines: 2,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            entry.kind.name,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Text(
                            _size(entry.sizeBytes),
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            entry.sha256 ?? '—',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (!inventory.entriesComplete)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t.security.evidence_artifacts_truncated,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.security.evidence_center_close),
        ),
      ],
    );
  }

  Widget _header(ThemeData theme, List<String> labels) {
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            flex: [5, 2, 1, 3][i],
            child: Text(labels[i], style: style),
          ),
      ],
    );
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _LoadGraphDialog extends StatelessWidget {
  final LoadGraph graph;

  const _LoadGraphDialog({required this.graph});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;
    return AlertDialog(
      title: Text(t.security.evidence_title),
      content: SizedBox(
        width: 860,
        height: 560,
        child: ListView(
          children: [
            Text(
              '${t.security.evidence_graph_nodes}  ${graph.nodes.length}',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            for (final node in graph.nodes)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        node.id,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    Text(node.kind.name, style: theme.textTheme.labelSmall),
                    const SizedBox(width: 8),
                    if (!node.presentInPackage)
                      Text(
                        t.security.evidence_graph_missing,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(height: 24),
            Text(
              '${t.security.evidence_graph_edges}  ${graph.edges.length}',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            for (final edge in graph.edges)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      '${edge.fromId} → ${edge.toId}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      '${edge.kind.label} · ${edge.location}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.security.evidence_center_close),
        ),
      ],
    );
  }
}
