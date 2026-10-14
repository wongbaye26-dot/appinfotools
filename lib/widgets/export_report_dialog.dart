import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

/// 导出格式。
enum ExportFormat { markdown, json }

/// 导出范围。
enum ExportScope { full, securityOnly }

/// 现代化导出报告对话框。
///
/// 提供格式选择、范围选择和导出进度指示。
class ExportReportDialog extends StatefulWidget {
  final PackageAnalysisResult analysis;

  const ExportReportDialog({
    super.key,
    required this.analysis,
  });

  @override
  State<ExportReportDialog> createState() => _ExportReportDialogState();
}

class _ExportReportDialogState extends State<ExportReportDialog> {
  ExportFormat _format = ExportFormat.markdown;
  ExportScope _scope = ExportScope.full;
  bool _exporting = false;

  String get _fileExtension => switch (_format) {
        ExportFormat.markdown => 'md',
        ExportFormat.json => 'json',
      };

  String get _suggestedFileName {
    final base = widget.analysis.fileName.value ?? 'package';
    final stem = path.basenameWithoutExtension(base);
    final suffix = switch (_scope) {
      ExportScope.full => '${widget.analysis.platform.name}_report',
      ExportScope.securityOnly => '${widget.analysis.platform.name}_security',
    };
    return '${stem}_$suffix.$_fileExtension';
  }

  Future<void> _doExport() async {
    setState(() => _exporting = true);

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.report.export_action,
        fileName: _suggestedFileName,
        type: FileType.custom,
        allowedExtensions: [_fileExtension],
        lockParentWindow: true,
      );

      if (savePath == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }

      final now = DateTime.now();
      final content = switch (_format) {
        ExportFormat.markdown => AnalysisReport.render(
            widget.analysis,
            t,
            generatedAt: now,
          ),
        ExportFormat.json => AnalysisReport.renderJson(
            widget.analysis,
            generatedAt: now,
          ),
      };

      await File(savePath).writeAsString(content);

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasSecurity = widget.analysis.security != null;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.description_outlined, color: colorScheme.primary),
          const SizedBox(width: 12),
          Text(t.report.export_action),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: _exporting
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    t.report.exporting,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 格式选择
                  Text(
                    t.report.format,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ExportFormat>(
                    segments: const [
                      ButtonSegment(
                        value: ExportFormat.markdown,
                        label: Text('Markdown'),
                        icon: Icon(Icons.description),
                      ),
                      ButtonSegment(
                        value: ExportFormat.json,
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
                  const SizedBox(height: 24),
                  // 范围选择
                  Text(
                    t.report.scope,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ExportScope>(
                    segments: [
                      ButtonSegment(
                        value: ExportScope.full,
                        label: Text(t.report.full_report),
                        icon: const Icon(Icons.article),
                      ),
                      ButtonSegment(
                        value: ExportScope.securityOnly,
                        label: Text(t.report.security_only),
                        icon: const Icon(Icons.security),
                        enabled: hasSecurity,
                      ),
                    ],
                    selected: {_scope},
                    onSelectionChanged: (set) {
                      if (set.isNotEmpty) {
                        setState(() => _scope = set.first);
                      }
                    },
                  ),
                  if (!hasSecurity) ...[
                    const SizedBox(height: 8),
                    Text(
                      t.report.security_not_performed,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  // 文件名预览
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
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _suggestedFileName,
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
                label: Text(t.report.export_action),
              ),
            ],
    );
  }
}
