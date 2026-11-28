import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/analysis_run.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/providers/analysis_run_provider.dart';
import 'package:apk_info_tool/utils/analysis_run_repository.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 本地分析历史。
///
/// 只读 run 仓库的摘要；打开原包会重新解析，不偷偷使用旧结果。删除只删
/// 快照文件，不碰用户的原安装包。
class HistoryPage extends ConsumerStatefulWidget {
  /// 测试可注入临时仓库；生产为 null，从 provider 取应用支持目录。
  final AnalysisRunRepository? repository;

  /// 测试可注入同步假加载；生产为 null。
  final Future<List<AnalysisRunSummary>> Function()? loader;

  const HistoryPage({super.key, this.repository, this.loader});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  late Future<List<AnalysisRunSummary>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<AnalysisRunSummary>> _load() async {
    final loader = widget.loader;
    if (loader != null) return loader();
    final injected = widget.repository;
    if (injected != null) {
      return injected.list(limit: 100);
    }
    final repo = await ref.read(analysisRunRepositoryProvider.future);
    return repo.list(limit: 100);
  }

  void _refresh() => setState(() => _future = _load());

  Future<void> _open(AnalysisRunSummary run) async {
    if (!File(run.packagePath).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.history.missing)),
      );
      return;
    }
    ref.read(pendingOpenRequestProvider.notifier).request(run.packagePath);
    ref.read(shellNavigationProvider.notifier).navigate('analysis');
  }

  Future<void> _showSnapshot(AnalysisRunSummary run) async {
    final AnalysisRunRepository repo;
    final injected = widget.repository;
    if (injected != null) {
      repo = injected;
    } else {
      repo = await ref.read(analysisRunRepositoryProvider.future);
    }
    final full = await repo.read(run.id);
    final snapshot = full?.snapshot;
    if (!mounted) return;
    if (snapshot == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.history.snapshot_missing)),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _SnapshotDialog(snapshot: snapshot),
    );
  }

  Future<void> _delete(AnalysisRunSummary run) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.history.delete_title),
        content: Text(t.history.delete_body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.base.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.history.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = await ref.read(analysisRunRepositoryProvider.future);
    await repo.delete(run.id);
    if (!mounted) return;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          child: PageHeader(
            kicker: 'WORKSPACE / HISTORY',
            title: t.history.title,
            subtitle: t.history.subtitle,
            actions: [
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(t.history.refresh),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: FutureBuilder<List<AnalysisRunSummary>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('${snapshot.error}'));
              }
              final runs = snapshot.data ?? const <AnalysisRunSummary>[];
              if (runs.isEmpty) {
                return Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(V4Radius.card),
                      border:
                          Border.all(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.history,
                            size: 40, color: theme.colorScheme.primary),
                        const SizedBox(height: 12),
                        Text(t.history.empty_title,
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          t.history.empty_body,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                itemCount: runs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) => _HistoryTile(
                  run: runs[index],
                  onOpen: _open,
                  onDelete: _delete,
                  onSnapshot: _showSnapshot,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final AnalysisRunSummary run;
  final Future<void> Function(AnalysisRunSummary) onOpen;
  final Future<void> Function(AnalysisRunSummary) onDelete;
  final Future<void> Function(AnalysisRunSummary) onSnapshot;

  const _HistoryTile({
    required this.run,
    required this.onOpen,
    required this.onDelete,
    required this.onSnapshot,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final exists = File(run.packagePath).existsSync();
    final statusColor = switch (run.status) {
      AnalysisRunStatus.success => V4Colors.mint,
      AnalysisRunStatus.partial => V4Colors.amber,
      AnalysisRunStatus.failed => V4Colors.danger,
      AnalysisRunStatus.cancelled => scheme.onSurfaceVariant,
      AnalysisRunStatus.running => V4Colors.blue,
      AnalysisRunStatus.queued => scheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              run.platform == PackagePlatform.ios
                  ? Icons.phone_iphone
                  : Icons.android,
              size: 20,
              color: run.platform == PackagePlatform.ios
                  ? V4Colors.blue
                  : V4Colors.mint,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        (run.appName ?? '').isEmpty
                            ? run.packagePath.split('/').last
                            : run.appName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        run.status.name.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: statusColor,
                          fontFamily: 'monospace',
                          fontSize: 8.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  run.packagePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmt(run.startedAt.toLocal())}'
                  '${run.completedAt == null ? '' : ' → ${_fmt(run.completedAt!.toLocal())}'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: t.history.view_snapshot,
            onPressed: run.hasSnapshot ? () => onSnapshot(run) : null,
            icon: const Icon(Icons.description_outlined, size: 18),
          ),
          TextButton.icon(
            onPressed: exists ? () => onOpen(run) : null,
            icon: const Icon(Icons.open_in_new, size: 15),
            label: Text(t.history.open),
          ),
          IconButton(
            tooltip: t.history.delete,
            onPressed: () => onDelete(run),
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }

  static String _fmt(DateTime dt) =>
      '${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}';

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// 只读展示一次分析的存档报告。
///
/// 历史页的「打开」是重新解析原包；这里展示的是**当时**写入的 JSON 快照，
/// 两者语义不同，所以标题、提示和按钮都分开写，避免用户误以为结果被复用。
class _SnapshotDialog extends StatelessWidget {
  final Map<String, dynamic> snapshot;

  const _SnapshotDialog({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pretty = const JsonEncoder.withIndent('  ').convert(snapshot);
    final findings = snapshot['findings'];
    final libraries = snapshot['libraries'];
    final permissions = (snapshot['application'] is Map)
        ? (snapshot['application'] as Map)['permissionDetails']
        : null;
    final facts = <String>[
      if (snapshot['reportSchemaVersion'] != null)
        'schema v${snapshot['reportSchemaVersion']}',
      if (snapshot['generatedAt'] != null) '${snapshot['generatedAt']}',
      if (findings is List) '${findings.length} findings',
      if (permissions is List) '${permissions.length} permissions',
      if (libraries is Map && libraries['identifiedSdkCount'] != null)
        '${libraries['identifiedSdkCount']} SDKs',
    ];
    return AlertDialog(
      title: Text(t.history.snapshot_title),
      content: SizedBox(
        width: 720,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.history.snapshot_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (facts.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                facts.join(' · '),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    pretty,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${pretty.length} chars',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: pretty));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t.history.snapshot_copied)),
            );
          },
          child: Text(t.history.copy_snapshot),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.base.close),
        ),
      ],
    );
  }
}
