// 敏感信息面板（V3 F01 前半）：只显示脱敏值、定位与指纹。
//
// 明文永不进 UI 树：这里拿到的是 `SecretMatch.redactedValue` 与哈希，
// 「显式查看明文」属于后续阶段的危险操作，需要二次确认与单独流程。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/secret_scan_service.dart';

class SecretScanPanel extends StatefulWidget {
  final String packagePath;
  final Future<SecretScanReport?> Function(String path) loader;

  const SecretScanPanel({
    super.key,
    required this.packagePath,
    this.loader = SecretScanService.scan,
  });

  @override
  State<SecretScanPanel> createState() => _SecretScanPanelState();
}

class _SecretScanPanelState extends State<SecretScanPanel> {
  Future<SecretScanReport?>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader(widget.packagePath);
  }

  @override
  void didUpdateWidget(covariant SecretScanPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packagePath != widget.packagePath) {
      _future = widget.loader(widget.packagePath);
    }
  }

  Future<void> _copyFingerprint(SecretMatch match) async {
    await Clipboard.setData(ClipboardData(text: match.id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.secrets.copied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final theme = Theme.of(context);
    return FutureBuilder<SecretScanReport?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(t.secrets.scanning),
                ],
              ),
            ),
          );
        }
        final report = snapshot.data;
        if (report == null) {
          return Card(
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(t.secrets.failed),
            ),
          );
        }
        if (report.isEmpty) {
          return Card(
            child: ListTile(
              leading: const Icon(Icons.verified_outlined),
              title: Text(t.secrets.empty),
              subtitle: Text(t.secrets.scope(
                entries: '${report.scannedEntries}',
                dex: '${report.scannedDexFiles}',
              )),
            ),
          );
        }

        final kinds = [
          for (final kind in SecretKind.values)
            if (report.countOf(kind) > 0) kind,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.key_outlined,
                            size: 18, color: theme.colorScheme.error),
                        const SizedBox(width: 8),
                        Text(t.secrets.title,
                            style: theme.textTheme.titleSmall),
                        const SizedBox(width: 10),
                        Text('${report.matches.length}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.error,
                            )),
                        const Spacer(),
                        if (report.truncated)
                          Chip(
                            label: Text(t.secrets.truncated),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t.secrets.scope(
                        entries: '${report.scannedEntries}',
                        dex: '${report.scannedDexFiles}',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t.secrets.heuristic_note,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (kinds.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final kind in kinds)
                            Chip(
                              label: Text(
                                '${_kindLabel(kind, t)} '
                                '${report.countOf(kind)}',
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            for (final kind in kinds)
              _KindCard(kind: kind, report: report, onCopy: _copyFingerprint),
          ],
        );
      },
    );
  }
}

class _KindCard extends StatelessWidget {
  final SecretKind kind;
  final SecretScanReport report;
  final void Function(SecretMatch) onCopy;

  const _KindCard({
    required this.kind,
    required this.report,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final matches =
        report.matches.where((match) => match.kind == kind).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_kindLabel(kind, t)} · ${matches.length}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            for (final match in matches)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            match.redactedValue,
                            style: const TextStyle(
                              fontFamily: 'Menlo',
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '${match.location} · v1:${match.valueSha256}',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t.secrets.copy_fingerprint,
                      iconSize: 16,
                      icon: const Icon(Icons.copy_all_outlined),
                      onPressed: () => onCopy(match),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _kindLabel(SecretKind kind, Translations t) => switch (kind) {
      SecretKind.awsAccessKey => t.secrets.kind_aws,
      SecretKind.googleApiKey => t.secrets.kind_google,
      SecretKind.githubToken => t.secrets.kind_github,
      SecretKind.slackToken => t.secrets.kind_slack,
      SecretKind.stripeSecretKey => t.secrets.kind_stripe,
      SecretKind.privateKey => t.secrets.kind_private_key,
      SecretKind.jwt => t.secrets.kind_jwt,
      SecretKind.genericCredential => t.secrets.kind_generic,
    };
