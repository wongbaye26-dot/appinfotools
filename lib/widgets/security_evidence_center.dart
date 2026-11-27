import 'package:flutter/material.dart';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';

/// 本次分析的证据中心：按稳定 ID 汇总所有 Finding 引用的证据。
class SecurityEvidenceCenterCard extends StatelessWidget {
  final List<SecurityEvidence> evidence;

  const SecurityEvidenceCenterCard({super.key, required this.evidence});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;
    final scheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(V4Radius.card),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.inventory_2_outlined,
                    size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  t.security.evidence_center_title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (evidence.isNotEmpty)
                  Text(
                    t.security.evidence_center_count(count: evidence.length),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (evidence.isEmpty)
              Text(
                t.security.evidence_center_empty,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else ...[
              for (final item in evidence.take(4)) _EvidenceRow(item: item),
              if (evidence.length > 4)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => _EvidenceDialog(evidence: evidence),
                    ),
                    child: Text(t.security.evidence_center_view_all),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EvidenceRow extends StatelessWidget {
  final SecurityEvidence item;

  const _EvidenceRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = TranslationProvider.of(context).translations;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              item.evidenceId,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 9,
                color: scheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AnalysisReport.locationText(item, t),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  AnalysisReport.detailText(item, t),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            item.source.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }
}

class _EvidenceDialog extends StatelessWidget {
  final List<SecurityEvidence> evidence;

  const _EvidenceDialog({required this.evidence});

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    return AlertDialog(
      title: Text(t.security.evidence_center_title),
      content: SizedBox(
        width: 680,
        height: 480,
        child: ListView.separated(
          itemCount: evidence.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _EvidenceRow(item: evidence[index]),
          ),
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
