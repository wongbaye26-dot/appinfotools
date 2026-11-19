import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/batch_rename.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:apk_info_tool/utils/package_identity.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 选择多个包，按“应用名 / 应用名-版本”批量重命名。
Future<void> pickAndBatchRename(BuildContext context) async {
  final picked = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    type: FileType.custom,
    allowedExtensions: [
      for (final extension in kPickableExtensions)
        if (!extension.contains('.')) extension,
    ],
  );
  if (picked == null || picked.files.isEmpty) return;
  if (!context.mounted) return;
  final paths = [
    for (final file in picked.files)
      if (file.path case final path?) path,
  ];
  if (paths.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (_) => BatchRenameDialog(paths: paths),
  );
}

/// 一个待重命名项：路径 + 读到的身份信息。
typedef _RenameItem = ({
  String path,
  PackageIdentity identity,
});

/// 批量重命名对话框。
///
/// 公开是为了能被 widget 测试直接构造（`_prepare` 里的读取要换成假实现，
/// 真实实现跑在独立 isolate 上，widget 测试的 fake-async 区等不到它）。
class BatchRenameDialog extends StatefulWidget {
  final List<String> paths;

  /// 读取「应用名 + 版本」。默认走真实解析；测试注入假实现。
  final Future<PackageIdentity> Function(String path) identityReader;

  const BatchRenameDialog({
    super.key,
    required this.paths,
    this.identityReader = readPackageIdentity,
  });

  @override
  State<BatchRenameDialog> createState() => _BatchRenameDialogState();
}

class _BatchRenameDialogState extends State<BatchRenameDialog> {
  final List<_RenameItem> _items = [];
  var _prepared = 0;
  var _preparing = true;
  var _busy = false;
  var _includeVersion = true;

  /// 上一次执行的结果（只在有失败时保留，用于显示「为什么失败」）。
  List<BatchRenameResult> _failures = const [];

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    for (final path in widget.paths) {
      // 只读「名字 + 版本」：不跑安全审计、不渲染图标。
      // 读取本身在独立 isolate 里，界面不会因为解析而卡住。
      final identity = await widget.identityReader(path);
      if (!mounted) return;
      setState(() {
        _items.add((path: path, identity: identity));
        _prepared = _items.length;
      });
    }
    if (!mounted) return;
    setState(() => _preparing = false);
  }

  List<BatchRenamePlan> get _plans => buildBatchRenamePlans(
        [
          for (final item in _items)
            (
              path: item.path,
              appName: item.identity.hasAppName
                  ? item.identity.appName
                  : p.basenameWithoutExtension(item.path),
              version: item.identity.version,
            ),
        ],
        includeVersion: _includeVersion,
      );

  /// 有多少条会真的改名（其余已经是目标名字）。
  int _pendingCount(List<BatchRenamePlan> plans) =>
      plans.where((plan) => !plan.isNoop).length;

  Future<void> _apply() async {
    // **先取 messenger**：`pop()` 之后这个 dialog 的 `context` 已经失效，
    // 再去 `ScaffoldMessenger.of(context)` 会抛「deactivated widget」——
    // 而那时文件其实已经改好了，用户看到的却是报错。
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _failures = const [];
    });
    final results = await batchRenameFiles(_plans);
    if (!mounted) return;
    final failed = results.where((r) => !r.ok).toList();
    setState(() {
      _busy = false;
      _failures = failed;
    });
    if (failed.isEmpty) {
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text(t.rename.batch_done(count: results.length))),
      );
    }
  }

  /// 失败原因 → 一句能看懂的话。
  String _failureText(BatchRenameResult result) {
    final detail = result.error?.toString() ?? '';
    return switch (result.reason) {
      BatchRenameFailureReason.sourceMissing => t.rename.batch_fail_missing,
      BatchRenameFailureReason.targetExists => t.rename.batch_fail_exists,
      _ => t.rename.batch_fail_io(detail: detail),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plans = _preparing ? const <BatchRenamePlan>[] : _plans;
    final pending = _pendingCount(plans);
    final fallbackCount =
        _items.where((item) => !item.identity.hasAppName).length;

    return AlertDialog(
      title: Text(t.rename.batch_title),
      content: SizedBox(
        width: 620,
        child: _preparing
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(t.rename.batch_progress(
                    done: _prepared,
                    total: widget.paths.length,
                  )),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.rename.batch_include_version),
                    value: _includeVersion,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _includeVersion = value),
                  ),
                  if (fallbackCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        t.rename.batch_fallback(count: fallbackCount),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: plans.length,
                      itemBuilder: (context, index) {
                        final plan = plans[index];
                        final item = _items[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            switch (item.identity.platform) {
                              PackageIdentityPlatform.ios => Icons.phone_iphone,
                              PackageIdentityPlatform.android => Icons.android,
                              PackageIdentityPlatform.unknown =>
                                Icons.insert_drive_file_outlined,
                            },
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          title: Text(
                            p.basename(plan.sourcePath),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            plan.newName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: plan.isNoop
                                  ? theme.colorScheme.onSurfaceVariant
                                  : theme.colorScheme.primary,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (_failures.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      t.rename.batch_failure_title(count: _failures.length),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final result in _failures)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${p.basename(result.plan.sourcePath)} → '
                                '${result.plan.newName}：${_failureText(result)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.base.cancel),
        ),
        FilledButton.icon(
          onPressed: _busy || _preparing || pending == 0 ? null : _apply,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.drive_file_rename_outline, size: 18),
          label: Text(t.rename.batch_apply),
        ),
      ],
    );
  }
}
