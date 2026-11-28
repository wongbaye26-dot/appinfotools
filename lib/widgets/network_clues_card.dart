import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';

/// 静态网络线索卡：域名 / IPv4 / IPv6 / URL / WebSocket。
///
/// 只展示包里写了什么；**不表示运行时访问过**。措辞和布局都守住这条边界。
class NetworkCluesCard extends StatelessWidget {
  final NetworkFacts network;

  const NetworkCluesCard({super.key, required this.network});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tr = TranslationProvider.of(context).translations;
    final clues = network.clues;
    if (clues.isEmpty) return const SizedBox.shrink();

    final counts = <NetworkClueType, int>{};
    for (final clue in clues) {
      counts[clue.type] = (counts[clue.type] ?? 0) + 1;
    }

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.language,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr.security.network_clues_title(count: clues.length),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _NetworkCluesDialog(network: network),
                  ),
                  child: Text(tr.security.network_clues_view_all),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in counts.entries)
                  _chip(theme, '${entry.key.name} ${entry.value}'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              tr.security.network_clues_limitation,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Text(text, style: theme.textTheme.labelSmall),
      );
}

class _NetworkCluesDialog extends StatelessWidget {
  final NetworkFacts network;

  const _NetworkCluesDialog({required this.network});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tr = TranslationProvider.of(context).translations;
    return AlertDialog(
      title: Text(tr.security.network_clues_title(count: network.clues.length)),
      content: SizedBox(
        width: 900,
        height: 560,
        child: ListView.separated(
          itemCount: network.clues.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final clue = network.clues[index];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(
                      clue.type.name.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: SelectableText(
                      clue.value,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: SelectableText(
                      clue.sourcePath ?? '—',
                      maxLines: 2,
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
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr.security.evidence_center_close),
        ),
      ],
    );
  }
}
