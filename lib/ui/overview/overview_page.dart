import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:apk_info_tool/widgets/export_report_dialog.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// 应用概览页。
///
/// 用户打开应用后的默认落地页，提供：
/// - Hero 横幅：欢迎语与快捷操作
/// - 统计指标：文件分析历史汇总
/// - 拖放区域：支持直接拖入文件，拖入时显示预览
/// - 最近分析列表：快速访问历史文件
/// - 空状态：首次使用时的引导
class OverviewPage extends ConsumerStatefulWidget {
  const OverviewPage({super.key});

  @override
  ConsumerState<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends ConsumerState<OverviewPage> {
  bool _dragging = false;

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      dialogTitle: t.open.select_apk_file,
      allowedExtensions: kPickableExtensions,
      lockParentWindow: true,
    );
    final filePath = result?.files.single.path;
    if (filePath != null) {
      _openFile(filePath);
    }
  }

  void _openFile(String filePath) {
    if (!File(filePath).existsSync()) return;

    // 交给分析页去解析：解析流水线（任务句柄、阶段回调、取消、代际计数）
    // 只存在于那里。概览页只负责发起请求并把用户带过去 —— 早先这里自己
    // 写了一份 FileState，看起来「打开了」，实际没有任何解析发生。
    ref.read(pendingOpenRequestProvider.notifier).request(filePath);
    ref.read(shellNavigationProvider.notifier).navigate('analysis');
  }

  /// 检查文件是否受支持。
  bool _isSupported(String filePath) => isSupportedPackagePath(filePath);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 概览页常驻在 IndexedStack 里，切回来时不会重建 —— 订阅这两个
    // provider 才能在「分析完成」「切换文件」时刷新统计与 Hero 面板。
    ref.watch(recentFilesRevisionProvider);
    final fileState = ref.watch(currentFileStateProvider);
    final apkInfo = ref.watch(currentApkInfoProvider);
    final isParsing = ref.watch(isParsingProvider);

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        final files = details.files;
        if (files.isNotEmpty) {
          final filePath = files.first.path;
          if (_isSupported(filePath)) {
            _openFile(filePath);
          } else {
            _showInvalidFileSnack(filePath);
          }
        }
      },
      child: Container(
        color: _dragging
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : theme.scaffoldBackgroundColor,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hero 区：已导入文件时显示「当前文件状态面板」，
              // 否则显示引导横幅。两者占据同一位置（设计稿的红框）。
              if (fileState.filePath == null)
                _buildHeroBanner(context)
              else
                _buildCurrentFilePanel(context, fileState, apkInfo, isParsing),
              const SizedBox(height: 32),
              // 统计指标
              _buildStatsPanel(context),
              const SizedBox(height: 32),
              // 快捷操作区
              _buildQuickActions(context),
              const SizedBox(height: 32),
              // 最近文件列表
              _buildRecentFiles(context),
              const SizedBox(height: 32),
              // 拖放提示（仅在非拖放状态时显示静态提示）
              if (!_dragging) _buildDropZone(context),
            ],
          ),
        ),
      ),
    );
  }

  void _showInvalidFileSnack(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    final name = p.basename(filePath);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline, color: colorScheme.error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ext.isEmpty
                    ? '"$name" ${t.open.invalid_file_type}'
                    : '"$name" ($ext) ${t.open.invalid_file_type}',
              ),
            ),
          ],
        ),
        backgroundColor: colorScheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 当前文件状态面板（设计稿红框区）。
  ///
  /// 展示刚导入 / 正在分析的那个包：图标、名称、标识符、版本，外加四个
  /// 状态卡片（平台 / 大小 / 签名 / 安全）与操作按钮。
  ///
  /// 未导入任何文件时这个面板不出现 —— 那时显示 [_buildHeroBanner] 的引导。
  Widget _buildCurrentFilePanel(
    BuildContext context,
    FileState fileState,
    ApkInfo? apkInfo,
    bool isParsing,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final analysis = fileState.analysis;
    final isIos = fileState.platform == PackagePlatform.ios;

    // 名称 / 标识符 / 版本：两个平台的取值位置完全不同。
    final String appName;
    final String identifier;
    final String version;
    if (isIos) {
      final ios = analysis?.ios;
      appName = ios?.preferredName.value ?? '';
      identifier = ios?.bundleIdentifier.value ?? '';
      version = ios?.shortVersion.value ?? '';
    } else {
      appName = apkInfo?.label ?? '';
      identifier = apkInfo?.packageName ?? '';
      version = apkInfo?.versionName ?? '';
    }

    // 四个状态卡片的数据源。
    final sizeText = RecentFilesManager.formatSize(fileState.fileSize ?? 0);

    final (String signatureText, Color signatureColor) = _signatureStatus(
      fileState,
      analysis,
      isIos,
    );
    final (String securityText, Color securityColor) = _securityStatus(
      analysis?.security,
      isParsing,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer.withValues(alpha: 0.55),
            colorScheme.secondaryContainer.withValues(alpha: 0.35),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 应用图标
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: isIos
                    ? IosIconThumbnail(
                        resolution: analysis?.ios?.icon, size: 56)
                    : (apkInfo?.mainIconImage != null
                        ? RawImage(
                            image: apkInfo!.mainIconImage,
                            fit: BoxFit.contain,
                          )
                        : Center(
                            child: Icon(
                              Icons.android,
                              size: 26,
                              color: theme.hintColor.withValues(alpha: 0.4),
                            ),
                          )),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isIos ? Icons.apple : Icons.android,
                          size: 14,
                          color: isIos ? Colors.grey : Colors.green,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          t.overview.current_file,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.hintColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      appName.isNotEmpty ? appName : t.overview.no_file,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      identifier.isNotEmpty ? identifier : '-',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                        fontFamily: 'monospace',
                        fontFamilyFallback: const ['Menlo', 'Courier'],
                      ),
                    ),
                    if (version.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'v$version',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 操作按钮
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => ref
                        .read(shellNavigationProvider.notifier)
                        .navigate('analysis'),
                    icon: const Icon(Icons.analytics_outlined, size: 16),
                    label: Text(t.overview.view_details),
                  ),
                  FilledButton.icon(
                    onPressed: fileState.analysis == null
                        ? null
                        : () => _exportReport(fileState),
                    icon: const Icon(Icons.description_outlined, size: 16),
                    label: Text(t.overview.export_report),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          // 四个状态卡片
          Row(
            children: [
              Expanded(
                child: _StatusCard(
                  icon: isIos ? Icons.apple : Icons.android,
                  label: t.overview.status_platform,
                  value: isIos ? 'iOS' : 'Android',
                  color: isIos ? Colors.grey : Colors.green,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatusCard(
                  icon: Icons.sd_storage_outlined,
                  label: t.overview.status_size,
                  value: sizeText,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatusCard(
                  icon: Icons.verified_outlined,
                  label: t.overview.status_signature,
                  value: signatureText,
                  color: signatureColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatusCard(
                  icon: Icons.security,
                  label: t.overview.status_security,
                  value: securityText,
                  color: securityColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 签名状态：Android 读 `signature`，iOS 读 codesign 结果。
  ///
  /// 四种状态必须分开显示 —— 把「工具不可用」说成「验证失败」会把没装
  /// 工具的机器误报成恶意应用，反过来则是更危险的方向。
  (String, Color) _signatureStatus(
    FileState fileState,
    PackageAnalysisResult? analysis,
    bool isIos,
  ) {
    final status =
        isIos ? analysis?.ios?.codeSign?.status : fileState.signature?.status;
    return switch (status) {
      SignatureStatus.verified => (t.overview.sig_verified, Colors.green),
      SignatureStatus.verificationFailed => (t.overview.sig_failed, Colors.red),
      SignatureStatus.unknown => (t.overview.sig_unknown, Colors.orange),
      _ => (t.overview.sig_none, Colors.grey),
    };
  }

  /// 安全状态：未开启审计 / 未跑完 / 有发现 / 无发现。
  (String, Color) _securityStatus(
    SecurityAnalysisResult? security,
    bool isParsing,
  ) {
    if (isParsing) return (t.overview.status_parsing, Colors.blue);
    if (security == null) return (t.overview.security_not_run, Colors.grey);
    final count = security.findings.length;
    if (count == 0) return (t.overview.security_clean, Colors.green);
    // 有 P0/P1 就用红色，否则橙色 —— 与安全卡片的风险配色一致。
    final severe = security.findings.any(
      (f) =>
          f.severity == SecuritySeverity.p0 ||
          f.severity == SecuritySeverity.p1,
    );
    return (
      t.overview.security_findings(count: count),
      severe ? Colors.red : Colors.orange
    );
  }

  /// 从 Hero 面板直接导出报告。
  ///
  /// 刻意不接收 `BuildContext` 参数：跨 `await` 之后必须用 `State.context`
  /// 才能被 `mounted` 正确守护，传入的 context 无法判断是否仍然有效。
  Future<void> _exportReport(FileState fileState) async {
    final analysis = fileState.analysis;
    if (analysis == null) return;
    final result = await showDialog(
      context: context,
      builder: (_) => ExportReportDialog(analysis: analysis),
    );
    if (!mounted) return;
    if (result == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.report.export_success)),
      );
    } else if (result != null && result != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.report.export_failed(error: '$result'))),
      );
    }
  }

  Widget _buildHeroBanner(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer.withValues(alpha: 0.6),
            colorScheme.secondaryContainer.withValues(alpha: 0.4),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppLogo(size: 56),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.overview.subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _FeatureChip(
                icon: Icons.android,
                label: 'APK / XAPK / APKM / APKS',
                color: Colors.green,
              ),
              _FeatureChip(
                icon: Icons.apple,
                label: 'IPA',
                color: Colors.grey,
              ),
              _FeatureChip(
                icon: Icons.security,
                label: t.overview.feature_security,
                color: Colors.orange,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 统计指标面板。
  ///
  /// 从最近文件历史中汇总：总分析次数、平台分布、最近分析时间。
  Widget _buildStatsPanel(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final recentFiles = RecentFilesManager.load();

    final total = recentFiles.length;
    final androidCount =
        recentFiles.where((e) => e.platform == 'android').length;
    final iosCount = recentFiles.where((e) => e.platform == 'ios').length;
    final unknownCount = total - androidCount - iosCount;
    final lastAnalyzed = recentFiles.isNotEmpty ? recentFiles.first : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.overview.statistics,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.analytics_outlined,
                label: t.overview.stat_analyzed,
                value: '$total',
                sublabel: total == 1
                    ? t.overview.stat_package
                    : t.overview.stat_packages,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.android,
                label: 'Android',
                value: '$androidCount',
                sublabel: unknownCount > 0 && androidCount == 0
                    ? '+$unknownCount unknown'
                    : null,
                color: Colors.green,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.apple,
                label: 'iOS',
                value: '$iosCount',
                sublabel: null,
                color: Colors.grey,
              ),
            ),
          ],
        ),
        if (lastAnalyzed != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.dividerColor.withValues(alpha: 0.15),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.access_time,
                  size: 16,
                  color: theme.hintColor,
                ),
                const SizedBox(width: 8),
                Text(
                  t.overview.last_analyzed(name: lastAnalyzed.fileName),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                const Spacer(),
                Text(
                  lastAnalyzed.timeAgo(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.overview.quick_actions,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _ActionCard(
                icon: Icons.folder_open,
                label: t.overview.open_file,
                description: t.overview.open_file_desc,
                onTap: _pickFile,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionCard(
                icon: Icons.analytics,
                label: t.overview.go_to_analysis,
                description: t.overview.go_to_analysis_desc,
                onTap: () {
                  ref
                      .read(shellNavigationProvider.notifier)
                      .navigate('analysis');
                },
                color: colorScheme.secondary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRecentFiles(BuildContext context) {
    final theme = Theme.of(context);
    final recentFiles = RecentFilesManager.load();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              t.overview.recent_files,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (recentFiles.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await RecentFilesManager.clear();
                  setState(() {});
                },
                child: Text(t.overview.clear),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (recentFiles.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.dividerColor.withValues(alpha: 0.15),
                width: 1,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.history,
                  size: 32,
                  color: theme.hintColor.withValues(alpha: 0.4),
                ),
                const SizedBox(height: 8),
                Text(
                  t.overview.no_recent_files,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.hintColor.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  t.overview.recent_files_hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          )
        else
          ...recentFiles.map((entry) => _RecentFileTile(
                entry: entry,
                onTap: () => _openFile(entry.path),
              )),
      ],
    );
  }

  /// 拖放区域。
  ///
  /// 静态状态下显示引导提示；拖入文件时显示「释放以分析」状态。
  Widget _buildDropZone(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 拖入中状态：显示释放提示
    if (_dragging) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: colorScheme.primary.withValues(alpha: 0.3),
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.touch_app,
              size: 40,
              color: colorScheme.primary.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              t.overview.release_to_analyze,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              t.overview.drop_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      );
    }

    // 静态状态：默认引导提示
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(48),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.2),
          width: 1,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_upload_outlined,
            size: 48,
            color: theme.hintColor.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            t.overview.drop_zone_title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.hintColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            t.overview.drop_zone_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.hintColor.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 统计指标卡片。
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? sublabel;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.sublabel,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const Spacer(),
                Text(
                  value,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (sublabel != null)
              Text(
                sublabel!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 功能特性标签。
class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _FeatureChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color.withValues(alpha: 0.9),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// 最近文件条目。
class _RecentFileTile extends StatelessWidget {
  final RecentFileEntry entry;
  final VoidCallback onTap;

  const _RecentFileTile({
    required this.entry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAndroid = entry.platform == 'android';
    final isIos = entry.platform == 'ios';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isAndroid
                        ? Colors.green.withValues(alpha: 0.1)
                        : isIos
                            ? Colors.grey.withValues(alpha: 0.1)
                            : theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isAndroid
                        ? Icons.android
                        : isIos
                            ? Icons.apple
                            : Icons.insert_drive_file,
                    size: 18,
                    color: isAndroid
                        ? Colors.green
                        : isIos
                            ? Colors.grey
                            : theme.hintColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.fileName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${RecentFilesManager.formatSize(entry.size)} · ${entry.timeAgo()}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.hintColor.withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 状态卡片。
///
/// 左侧图标 + 上方标签 + 下方数值，用在 Hero 面板的四个状态位。
class _StatusCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatusCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 快捷操作卡片。
class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
  final Color color;

  const _ActionCard({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 24, color: color),
              ),
              const SizedBox(height: 16),
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
