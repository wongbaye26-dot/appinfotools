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
