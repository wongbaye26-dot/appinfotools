import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/file_rename.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 弹出「重命名文件」对话框。
///
/// 返回 `null` 表示用户取消（或直接关掉了对话框）；否则返回 [RenameResult]。
///
/// **调用方负责后续动作**（把新路径重新打开）—— 概览页与分析页对「重新
/// 打开」的做法本来就不同（一个留在概览页看状态卡片，一个切到分析页），
/// 那是它们各自的语义，不该被塞进对话框里。提示文案则由
/// [reportRenameOutcome] 统一处理，两处不会各说各话。
///
/// 对话框**只有这一份实现**：概览页的 Hero 与分析页的「文件」行各有入口，
/// 此前是两份几乎一样、细节不同的 `AlertDialog`（默认名规则不同、确认按钮
/// 一个是 `TextButton` 一个是……各写各的），用户看到的是两个长得不一样的
/// 重命名窗口。
Future<RenameResult?> showRenameFileDialog(
  BuildContext context, {
  required String filePath,
  required String displayName,
  required String versionName,
}) {
  final extension = p.extension(filePath).toLowerCase();
  final targetExtension = extension.isNotEmpty
      ? extension
      : (filePath.toLowerCase().endsWith('.ipa') ? '.ipa' : '.apk');

  final appName = displayName.trim();
  final version = versionName.trim();

  // 默认名：应用名 + 版本 + 原后缀。
  //
  // 两个输入都可能取不到（解析还没出结果、或包里就没声明），因此逐级退化 ——
  // 最后一级退回**原文件名**，那是唯一一定成立的事实。早先这里直接拼
  // `'$displayName-$versionName$ext'`，取不到时用户看到的是 `--.apk`。
  final defaultName = appName.isEmpty
      ? p.basename(filePath)
      : (version.isEmpty
          ? '$appName$targetExtension'
          : '$appName-$version$targetExtension');

  return showDialog<RenameResult>(
    context: context,
    builder: (_) => _RenameFileDialog(
      filePath: filePath,
      defaultName: defaultName,
      appName: appName,
      version: version,
      extension: targetExtension,
    ),
  );
}

/// 统一处理重命名结果的提示，返回**需要重新打开的新路径**（不需要时为 `null`）。
///
/// 成功 / 失败 / 取消三态的措辞与时长只在这里定义一次。此前概览页与分析页
/// 各写一份 switch，文案会各自漂移 —— 而且其中一处把「用户取消了保存面板」
/// 也弹了一次提示。
String? reportRenameOutcome(BuildContext context, RenameResult result) {
  final messenger = ScaffoldMessenger.of(context);
  switch (result.outcome) {
    case RenameOutcome.cancelled:
      return null;
    case RenameOutcome.failed:
      messenger.showSnackBar(
        SnackBar(content: Text('${t.rename.failed}: ${result.error}')),
      );
      return null;
    case RenameOutcome.renamed:
    case RenameOutcome.savedElsewhere:
      messenger.showSnackBar(SnackBar(content: Text(t.rename.success)));
      return result.path;
  }
}

/// 重命名对话框本体。
///
/// 版式与「导出报告」对话框同一套：标题左侧带图标、内容固定宽度、
/// 上方一个只读的「当前值」框、下方是控件、动作用 `TextButton`（取消）+
/// `FilledButton.icon`（确认）。四页的对话框因此看起来是同一个应用里的。
class _RenameFileDialog extends StatefulWidget {
  final String filePath;
  final String defaultName;
  final String appName;
  final String version;
  final String extension;

  const _RenameFileDialog({
    required this.filePath,
    required this.defaultName,
    required this.appName,
    required this.version,
    required this.extension,
  });

  @override
  State<_RenameFileDialog> createState() => _RenameFileDialogState();
}

class _RenameFileDialogState extends State<_RenameFileDialog> {
  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormFieldState<String>>();

  /// 改名进行中（含 macOS 上弹出的保存面板）。
  ///
  /// 只用来禁用按钮防重复提交 —— 不画转圈：改名本身很快，慢的那一步是
  /// 用户自己在系统面板里选路径，画个转圈反而像卡住了。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.defaultName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _appNameOnly => '${widget.appName}${widget.extension}';

  String get _nameWithVersion =>
      '${widget.appName}-v${widget.version}${widget.extension}';

  Future<void> _confirm() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);

    // 三级回退（就地改名 → 复制+删除 → 保存对话框）都封在 `renameFile` 里：
    // macOS 沙箱只授予「用户选中的那一个文件」的写权限，不含它所在的目录，
    // 前两条都会 EPERM 失败。
    final result = await renameFile(
      File(widget.filePath),
      newName: _controller.text,
      saveDialogTitle: t.rename.rename_file,
    );

    if (!mounted) return;

    // 保存面板被取消**不算失败**，对话框留在原地 —— 用户可以改个名再试。
    // 关掉它等于把「我想改名但选错了目录」变成「重来一次」。
    if (result.outcome == RenameOutcome.cancelled) {
      setState(() => _busy = false);
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.drive_file_rename_outline, color: colorScheme.primary),
          const SizedBox(width: 12),
          Text(t.rename.rename_file),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 改的是哪个文件 —— 路径是事实，且用户需要确认自己没点错行。
            // 只读展示（可选中复制），不在这里编辑：路径本身不能改。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.15),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.file_info.file,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Tooltip(
                    message: widget.filePath,
                    child: Text(
                      widget.filePath,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontFamilyFallback: const ['Menlo', 'Courier'],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              t.rename.new_file_name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controller,
              autofocus: true,
              key: _formKey,
              enabled: !_busy,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onFieldSubmitted: (_) => _confirm(),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return t.rename.name_cannot_be_empty;
                }
                // 与「打开文件」用同一份判定：能打开什么，就能改成什么。
                // 此前这里手抄了一份 `.apk/.xapk/.apkm/.apks/.ipa` 的清单，
                // 于是「下载渠道加的 `.apk.1` 后缀」能打开、却改不回去。
                if (!isSupportedPackagePath(value.trim())) {
                  return t.rename.must_end_with_apk;
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _controller.text = widget.defaultName,
                  child: Text(t.rename.default_name),
                ),
                OutlinedButton(
                  onPressed:
                      _busy ? null : () => _controller.text = _appNameOnly,
                  child: Text(t.rename.app_name_only),
                ),
                OutlinedButton(
                  onPressed:
                      _busy ? null : () => _controller.text = _nameWithVersion,
                  child: Text(t.rename.name_with_version),
                ),
              ],
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
          onPressed: _busy ? null : _confirm,
          icon: const Icon(Icons.check, size: 18),
          label: Text(t.base.confirm),
        ),
      ],
    );
  }
}
