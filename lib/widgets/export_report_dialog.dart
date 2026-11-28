import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/report_exporter.dart';
import 'package:apk_info_tool/utils/report_extras.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

/// 导出格式。
enum ExportFormat { markdown, json, html }

/// 导出范围。
enum ExportScope { full, securityOnly }

/// 现代化导出报告对话框。
///
/// 提供格式选择、范围选择和导出进度指示。
class ExportReportDialog extends StatefulWidget {
  final PackageAnalysisResult analysis;

  /// 安装包路径。给了才能把「库识别」写进报告（需要重新读 DEX / 原生库）；
  /// 为 `null` 时报告退回不含库识别的旧结构，不会假装「没有 SDK」。
  final String? archivePath;

  const ExportReportDialog({
    super.key,
    required this.analysis,
    this.archivePath,
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
        ExportFormat.html => 'html',
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

    final now = DateTime.now();
    // 范围选择必须真的生效：早先 `_scope` 只影响了建议文件名，
    // 用户选「仅安全检测」仍然会导出一整份报告。
    final securityOnly = _scope == ExportScope.securityOnly;

    // 权限分级与库识别是异步的，而报告渲染是纯函数 —— 先采集再渲染。
    // 采集失败只让这两块缺席，不影响报告本体。
    ReportExtras? extras;
    try {
      extras = await ReportExtras.collect(
        result: widget.analysis,
        archivePath: widget.archivePath,
      );
    } catch (error) {
      debugPrint('ExportReportDialog: 采集报告补充数据失败: $error');
    }

    final content = switch (_format) {
      ExportFormat.markdown => AnalysisReport.render(
          widget.analysis,
          t,
          generatedAt: now,
          securityOnly: securityOnly,
          extras: extras,
        ),
      ExportFormat.json => AnalysisReport.renderJson(
          widget.analysis,
          generatedAt: now,
          t: t,
          securityOnly: securityOnly,
          extras: extras,
        ),
      ExportFormat.html => AnalysisReport.renderHtml(
          widget.analysis,
          t,
          generatedAt: now,
          securityOnly: securityOnly,
          extras: extras,
        ),
    };

    // 弹面板 + 写盘走共用实现：取消 / 成功 / 失败三态都由它分好，
    // 不会再出现「用户取消却报导出失败」。
    final outcome = await ReportExporter.save(
      t: t,
      dialogTitle: t.report.export_action,
      suggestedFileName: _suggestedFileName,
      content: content,
      allowedExtensions: [_fileExtension],
    );

    if (!mounted) return;
    if (outcome.isCancelled) {
      Navigator.of(context).pop();
    } else if (outcome.isSaved) {
      Navigator.of(context).pop(true);
    } else {
      Navigator.of(context).pop(outcome.failure);
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
        width: 440,
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
                      ButtonSegment(
                        value: ExportFormat.html,
                        label: Text('HTML'),
                        icon: Icon(Icons.language),
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
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: colorScheme.outlineVariant),
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
