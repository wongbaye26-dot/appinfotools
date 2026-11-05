import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/batch_rename.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
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
  final paths = [for (final file in picked.files) file.path!];
  await showDialog<void>(
    context: context,
    builder: (_) => _BatchRenameDialog(paths: paths),
  );
}

class _BatchRenameDialog extends StatefulWidget {
  final List<String> paths;
  const _BatchRenameDialog({required this.paths});

  @override
  State<_BatchRenameDialog> createState() => _BatchRenameDialogState();
}

class _BatchRenameDialogState extends State<_BatchRenameDialog> {
  final List<({String path, String appName, String version})> _items = [];
  var _preparing = true;
  var _busy = false;
  var _includeVersion = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    for (final path in widget.paths) {
      String appName = p.basenameWithoutExtension(path);
      String version = '';
      try {
        final info = await getApkInfo(path);
        if (info != null) {
          appName = info.label?.trim().isNotEmpty == true
              ? info.label!.trim()
              : appName;
          version = info.versionName?.trim() ?? '';
        }
      } catch (_) {
        // 解析失败就用文件名，批量重命名不应该因此整体失败。
      }
      _items.add((path: path, appName: appName, version: version));
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _preparing = false);
  }

  List<BatchRenamePlan> get _plans => buildBatchRenamePlans(
        _items,
        includeVersion: _includeVersion,
      );

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final results = await batchRenameFiles(_plans);
    if (!mounted) return;
    final failed = results.where((r) => !r.ok).length;
    setState(() => _busy = false);
    if (failed == 0) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.rename.batch_done(count: results.length))),
      );
    } else {
      setState(() => _error = t.rename.batch_failed(count: failed));
    }
  }

  @override
  Widget build(BuildContext context) {
    final plans = _preparing ? const <BatchRenamePlan>[] : _plans;
    return AlertDialog(
      title: Text(t.rename.batch_title),
      content: SizedBox(
        width: 560,
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
                  Text(t.rename.batch_preparing),
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
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: plans.length,
                      itemBuilder: (context, index) {
                        final plan = plans[index];
                        return ListTile(
                          dense: true,
                          leading: Text('${index + 1}.'),
                          title: Text(
                            p.basename(plan.sourcePath),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            plan.newName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.base.cancel),
        ),
        FilledButton.icon(
          onPressed: _busy || _preparing || plans.isEmpty ? null : _apply,
          icon: const Icon(Icons.drive_file_rename_outline, size: 18),
          label: Text(t.rename.batch_apply),
        ),
      ],
    );
  }
}
