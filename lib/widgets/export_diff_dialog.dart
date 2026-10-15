import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/diff_report.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// 差异报告的导出格式。
enum DiffExportFormat { markdown, json }

/// 导出**差异报告**的对话框。
///
/// 与 `ExportReportDialog` 分成两个组件而不是加一个开关：那个对话框的
/// 「范围」（完整 / 仅安全检测）概念在这里没有对应物 —— 差异报告只覆盖
/// 字段与集合，不存在「只看安全」的子集。硬塞进去会得到一个永远置灰的
/// 选项，或者一个点了没反应的选项。
///
/// 差异报告是**独立文档**（§17.4-4）：它有自己的 schema 版本号，不并进
/// 单文件报告。
class ExportDiffDialog extends StatefulWidget {
  final PackageAnalysisResult left;
  final PackageAnalysisResult right;

  const ExportDiffDialog({
    super.key,
    required this.left,
    required this.right,
  });

  @override
  State<ExportDiffDialog> createState() => _ExportDiffDialogState();
}

class _ExportDiffDialogState extends State<ExportDiffDialog> {
  DiffExportFormat _format = DiffExportFormat.markdown;
  bool _exporting = false;

  String get _extension => switch (_format) {
        DiffExportFormat.markdown => 'md',
        DiffExportFormat.json => 'json',
      };

  Future<void> _doExport() async {
    setState(() => _exporting = true);
    try {
      final generatedAt = DateTime.now();
      final suggested = DiffReport.suggestedFileName(
        widget.left,
        widget.right,
        extension: _extension,
        generatedAt: generatedAt,
      );

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.diff.export_action,
        fileName: suggested,
        type: FileType.custom,
        allowedExtensions: [_extension],
        lockParentWindow: true,
      );

      if (savePath == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }

      // 三端同源：这里与界面、JSON 都走 `DiffReport` / `diffOf` 那一份实现。
      final content = switch (_format) {
        DiffExportFormat.markdown => DiffReport.render(
            widget.left,
            widget.right,
            t,
            generatedAt: generatedAt,
          ),
        DiffExportFormat.json => DiffReport.renderJson(
            widget.left,
            widget.right,
            generatedAt: generatedAt,
          ),
      };

      await File(savePath).writeAsString(content);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) Navigator.of(context).pop(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final suggested = DiffReport.suggestedFileName(
      widget.left,
      widget.right,
      extension: _extension,
      generatedAt: DateTime.now(),
    );

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.difference_outlined, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(t.diff.export_action)),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: _exporting
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(t.report.exporting, style: theme.textTheme.bodyMedium),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.report.format,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<DiffExportFormat>(
                    segments: const [
                      ButtonSegment(
                        value: DiffExportFormat.markdown,
                        label: Text('Markdown'),
                        icon: Icon(Icons.description),
                      ),
                      ButtonSegment(
                        value: DiffExportFormat.json,
                        label: Text('JSON'),
                        icon: Icon(Icons.code),
                      ),
                    ],
                    selected: {_format},
                    onSelectionChanged: (set) {
                      if (set.isNotEmpty) {
                        setState(() => _format = set.first);
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  // 文件名预览。时间戳每次构建都变，但只到秒，肉眼看不出来。
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.dividerColor.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.report.file_name,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.hintColor),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          suggested,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                            fontFamilyFallback: const ['Menlo', 'Courier'],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: _exporting
          ? null
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t.base.cancel),
              ),
              FilledButton.icon(
                onPressed: _doExport,
                icon: const Icon(Icons.download, size: 18),
                label: Text(t.diff.export_action),
              ),
            ],
    );
  }
}
