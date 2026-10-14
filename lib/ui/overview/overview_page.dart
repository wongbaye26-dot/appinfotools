import 'dart:io';
import 'dart:ui' as ui;

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:apk_info_tool/widgets/export_report_dialog.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// 应用概览页。
///
/// 用户打开应用后的默认落地页。**整页固定一屏、不上下滚动**：
/// - Hero 区：未导入文件时是引导横幅，导入后变成「当前文件状态面板」
/// - 统计：一行三个卡片
/// - 最近文件：占据剩余空间，列表自身可滚动
///
/// 布局按窗口宽度自适应（`LayoutBuilder`）：窄窗口收紧间距、状态卡片
/// 改为两列两行。
class OverviewPage extends ConsumerStatefulWidget {
  const OverviewPage({super.key});

  @override
  ConsumerState<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends ConsumerState<OverviewPage> {
  bool _dragging = false;

  /// 窄窗口阈值：低于它时收紧间距、状态卡片两列排布。
  static const _compactWidth = 900.0;

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
    // 只存在于那里。概览页只负责发起请求并把用户带过去。
    ref.read(pendingOpenRequestProvider.notifier).request(filePath);
    ref.read(shellNavigationProvider.notifier).navigate('analysis');
  }

  bool _isSupported(String filePath) => isSupportedPackagePath(filePath);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final fileState = ref.watch(currentFileStateProvider);
    final apkInfo = ref.watch(currentApkInfoProvider);
    final isParsing = ref.watch(isParsingProvider);
    final recentFiles = ref.watch(recentFilesProvider);

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        final files = details.files;
        if (files.isEmpty) return;
        final filePath = files.first.path;
        if (_isSupported(filePath)) {
          _openFile(filePath);
        } else {
          _showInvalidFileSnack(filePath);
        }
      },
      child: Container(
        color: _dragging
            ? colorScheme.primaryContainer.withValues(alpha: 0.3)
            : theme.scaffoldBackgroundColor,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < _compactWidth;
            final gap = compact ? 14.0 : 20.0;
            final pad = compact ? 16.0 : 24.0;

            return Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hero 区
                  if (fileState.filePath == null)
                    _buildWelcomeHero(context, compact)
                  else
                    _buildCurrentFilePanel(
                        context, fileState, apkInfo, isParsing, compact),
                  SizedBox(height: gap),
                  // 统计
                  _buildStatsPanel(context, recentFiles),
                  SizedBox(height: gap),
                  // 最近文件（占满剩余空间，列表自身滚动）
                  Expanded(child: _buildRecentFiles(context, recentFiles)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _showInvalidFileSnack(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    final name = p.basename(filePath);
    final colorScheme = Theme.of(context).colorScheme;

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

  // ---------------------------------------------------------------------
  // 引导横幅（未导入文件时）
  // ---------------------------------------------------------------------

  Widget _buildWelcomeHero(BuildContext context, bool compact) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 20 : 28),
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
        ),
      ),
      child: Row(
        children: [
          AppLogo(size: compact ? 48 : 56),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  t.overview.subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    const _FeatureChip(
                      icon: Icons.android,
                      label: 'APK / XAPK / APKM / APKS',
                      color: Colors.green,
                    ),
                    const _FeatureChip(
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
                const SizedBox(height: 10),
                const _DropHint(),
              ],
            ),
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(t.overview.open_file),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 当前文件状态面板
  // ---------------------------------------------------------------------

  Widget _buildCurrentFilePanel(
    BuildContext context,
    FileState fileState,
    ApkInfo? apkInfo,
    bool isParsing,
    bool compact,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final analysis = fileState.analysis;
    final isIos = fileState.platform == PackagePlatform.ios;

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

    final (String signatureText, Color signatureColor) =
        _signatureStatus(fileState, analysis, isIos);
    final (String securityText, Color securityColor) =
        _securityStatus(analysis?.security, isParsing);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 18 : 24),
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
          // 上半：图标 + 四行文字 + 按钮。
          //
          // `IntrinsicHeight` + `stretch` 让图标高度**等于右侧文字列的高度**
          // （用户明确要求）：文字行数或字号变化时图标自动跟着变，
          // 不用手算像素。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildIconBox(context, apkInfo, analysis, isIos, compact),
                SizedBox(width: compact ? 14 : 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 第 1 行：平台 + 「当前文件」
                      Row(
                        children: [
                          Icon(
                            isIos ? Icons.apple : Icons.android,
                            size: 13,
                            color: isIos ? Colors.grey : Colors.green,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            t.overview.current_file,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.hintColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 第 2 行：应用名
                      Text(
                        appName.isNotEmpty ? appName : t.overview.no_file,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      // 第 3 行：标识符（可复制）
                      _CopyableLine(text: identifier, monospace: true),
                      const SizedBox(height: 2),
                      // 第 4 行：版本
                      Text(
                        version.isNotEmpty ? 'v$version' : '-',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: compact ? 10 : 16),
                // 操作按钮（竖排，避免窄窗口挤成一团）
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => ref
                          .read(shellNavigationProvider.notifier)
                          .navigate('analysis'),
                      icon: const Icon(Icons.analytics_outlined, size: 16),
                      label: Text(t.overview.view_details),
                    ),
                    const SizedBox(height: 8),
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
          ),
          SizedBox(height: compact ? 14 : 18),
          // 下半：四个状态卡片
          _buildStatusCards(
            context,
            compact,
            isIos: isIos,
            sizeText: RecentFilesManager.formatSize(fileState.fileSize ?? 0),
            signatureText: signatureText,
            signatureColor: signatureColor,
            securityText: securityText,
            securityColor: securityColor,
          ),
          const SizedBox(height: 10),
          // 拖放提示：原先底部有一张占满宽度的大卡片，去掉后收成这里一行。
          const _DropHint(),
        ],
      ),
    );
  }

  /// 图标容器。
  ///
  /// 宽度固定、高度由外层 `IntrinsicHeight` + `stretch` 拉伸到与右侧文字
  /// 列等高（用户要求「图标高度跟右边四行文字一样」）。
  ///
  /// **刻意不用 `AspectRatio`**：它在 `IntrinsicHeight` 下会报出偏大的
  /// 内在宽度（实测在 800px 窗口里把整行挤溢出 102px），而这里的诉求
  /// 只是「高度对齐」，宽度固定反而更可控。
  Widget _buildIconBox(
    BuildContext context,
    ApkInfo? apkInfo,
    PackageAnalysisResult? analysis,
    bool isIos,
    bool compact,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SizedBox(
      width: compact ? 76 : 92,
      child: GestureDetector(
        // 右键打开导出菜单
        onSecondaryTapUp: isIos
            ? null
            : (details) => _showIconExportMenu(
                  context,
                  details.globalPosition,
                  apkInfo,
                ),
        child: Stack(
          children: [
            Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.07),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: isIos
                  ? IosIconThumbnail(
                      resolution: analysis?.ios?.icon,
                      size: double.infinity,
                    )
                  : (apkInfo?.mainIconImage != null
                      ? RawImage(
                          image: apkInfo!.mainIconImage,
                          fit: BoxFit.contain,
                        )
                      : Center(
                          child: Icon(
                            Icons.android,
                            size: 28,
                            color: theme.hintColor.withValues(alpha: 0.4),
                          ),
                        )),
            ),
            // 导出角标（仅 Android：iOS 的图标来源不支持多候选导出）
            if (!isIos && apkInfo != null)
              Positioned(
                right: 3,
                bottom: 3,
                child: Material(
                  color: colorScheme.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(7),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(7),
                    onTap: () => _showIconExportMenu(
                      context,
                      _iconMenuAnchor(context),
                      apkInfo,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.download,
                        size: 12,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 图标菜单的锚点（图标左下角）。
  Offset _iconMenuAnchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    return box.localToGlobal(Offset(0, box.size.height));
  }

  Widget _buildStatusCards(
    BuildContext context,
    bool compact, {
    required bool isIos,
    required String sizeText,
    required String signatureText,
    required Color signatureColor,
    required String securityText,
    required Color securityColor,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    final cards = [
      _StatusCard(
        icon: isIos ? Icons.apple : Icons.android,
        label: t.overview.status_platform,
        value: isIos ? 'iOS' : 'Android',
        color: isIos ? Colors.grey : Colors.green,
      ),
      _StatusCard(
        icon: Icons.sd_storage_outlined,
        label: t.overview.status_size,
        value: sizeText,
        color: colorScheme.primary,
      ),
      _StatusCard(
        icon: Icons.verified_outlined,
        label: t.overview.status_signature,
        value: signatureText,
        color: signatureColor,
      ),
      _StatusCard(
        icon: Icons.security,
        label: t.overview.status_security,
        value: securityText,
        color: securityColor,
      ),
    ];

    // 窄窗口：两列两行；宽窗口：一行四个。
    if (compact) {
      return Column(
        children: [
          Row(children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 10),
            Expanded(child: cards[1]),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: cards[2]),
            const SizedBox(width: 10),
            Expanded(child: cards[3]),
          ]),
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: cards[i]),
        ],
      ],
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

  /// 安全状态：解析中 / 未检测 / 未发现风险 / N 项发现。
  ///
  /// 「未检测」不能显示成绿色 —— 那是「没查到」，不是「没问题」。
  (String, Color) _securityStatus(
    SecurityAnalysisResult? security,
    bool isParsing,
  ) {
    if (isParsing) return (t.overview.status_parsing, Colors.blue);
    if (security == null) return (t.overview.security_not_run, Colors.grey);
    final count = security.findings.length;
    if (count == 0) return (t.overview.security_clean, Colors.green);
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

  /// 图标导出菜单：PNG / SVG / 原始文件。
  Future<void> _showIconExportMenu(
    BuildContext context,
    Offset position,
    ApkInfo? apkInfo,
  ) async {
    if (apkInfo == null) return;
    final index = ref.read(selectedIconIndexProvider);

    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'png',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.image_outlined, size: 18),
            title: Text(t.icon.export_as_png),
          ),
        ),
        PopupMenuItem(
          value: 'svg',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.code, size: 18),
            title: Text(t.icon.export_as_svg),
          ),
        ),
        PopupMenuItem(
          value: 'raw',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
            title: Text(t.icon.export_original),
          ),
        ),
      ],
    );
    if (choice == null || !mounted) return;
    await _exportIcon(choice, apkInfo, index);
  }

  Future<void> _exportIcon(String kind, ApkInfo apkInfo, int index) async {
    try {
      final baseName =
          (apkInfo.label ?? 'icon').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final extension = switch (kind) {
        'png' => 'png',
        'svg' => 'svg',
        _ => 'bin',
      };
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.icon.export_icon,
        fileName: '$baseName-$index.$extension',
        type: FileType.custom,
        allowedExtensions: [extension],
        lockParentWindow: true,
      );
      if (savePath == null) return;

      if (kind == 'png') {
        final image = await apkInfo.renderIconForExport(index);
        if (image == null) throw StateError('icon render failed');
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('icon encode failed');
        await File(savePath).writeAsBytes(data.buffer.asUint8List());
      } else if (kind == 'svg') {
        final svg = await apkInfo.exportSvgString(index);
        if (svg == null) throw StateError(t.icon.error_svg_conversion);
        await File(savePath).writeAsString(svg);
      } else {
        // 原始文件：取该候选在 APK 里的原始字节（PNG / WebP / XML），
        // 不经任何重编码 —— 这才是「原始」的意义。
        final candidates = apkInfo.iconCandidates;
        if (index < 0 || index >= candidates.length) {
          throw StateError('icon candidate out of range');
        }
        final bytes = candidates[index].rawBytes;
        if (bytes == null) throw StateError('no raw bytes');
        await File(savePath).writeAsBytes(bytes);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.icon.export_success)),
      );
    } catch (e) {
      log.warning('export icon failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.icon.export_failed(error: '$e'))),
      );
    }
  }

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

  // ---------------------------------------------------------------------
  // 统计
  // ---------------------------------------------------------------------

  Widget _buildStatsPanel(
    BuildContext context,
    List<RecentFileEntry> recentFiles,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    final total = recentFiles.length;
    final androidCount =
        recentFiles.where((e) => e.platform == 'android').length;
    final iosCount = recentFiles.where((e) => e.platform == 'ios').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(text: t.overview.statistics),
        const SizedBox(height: 10),
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
                color: Colors.green,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.apple,
                label: 'iOS',
                value: '$iosCount',
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // 最近文件
  // ---------------------------------------------------------------------

  Widget _buildRecentFiles(
    BuildContext context,
    List<RecentFileEntry> recentFiles,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SectionLabel(text: t.overview.recent_files),
            const Spacer(),
            if (recentFiles.isNotEmpty)
              TextButton(
                onPressed: () => ref.read(recentFilesProvider.notifier).clear(),
                child: Text(t.overview.clear),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: recentFiles.isEmpty
              ? _buildEmptyRecentFiles(context)
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: recentFiles.length,
                  itemBuilder: (context, i) => _RecentFileTile(
                    entry: recentFiles[i],
                    onTap: () => _openFile(recentFiles[i].path),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyRecentFiles(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history,
            size: 28,
            color: theme.hintColor.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 8),
          Text(
            t.overview.no_recent_files,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.hintColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            t.overview.recent_files_hint,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.hintColor.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分区标题。
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    );
  }
}

/// 可复制的单行文本（标识符）。
///
/// 包名 / Bundle ID 是用户最常拿去搜索或比对的字段，值得给一个显式的
/// 复制入口，而不是让用户手动划选。
class _CopyableLine extends StatelessWidget {
  final String text;
  final bool monospace;

  const _CopyableLine({required this.text, this.monospace = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = monospace
        ? theme.textTheme.bodySmall?.copyWith(
            color: theme.hintColor,
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
          )
        : theme.textTheme.bodySmall;

    return Row(
      children: [
        Flexible(
          child: SelectableText(
            text.isNotEmpty ? text : '-',
            style: style,
            maxLines: 1,
          ),
        ),
        if (text.isNotEmpty)
          IconButton(
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.only(left: 4),
            constraints: const BoxConstraints(),
            tooltip: t.home.copy_content,
            icon: Icon(Icons.content_copy, color: theme.hintColor),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(t.home.copied_content(content: text)),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// 拖放提示（一行小字，放在 Hero 区里）。
class _DropHint extends StatelessWidget {
  const _DropHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.cloud_upload_outlined,
          size: 12,
          color: theme.hintColor.withValues(alpha: 0.6),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            t.overview.drop_zone_hint,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.hintColor.withValues(alpha: 0.7),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// 状态卡片。
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
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
          const SizedBox(height: 5),
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          // `Flexible` + 省略号：`Wrap` 在窄窗口下给的空间可能小于标签
          // 的自然宽度（`APK / XAPK / APKM / APKS` 尤其长），不给收缩
          // 余地就会直接撑破整行。
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color.withValues(alpha: 0.9),
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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

  const _RecentFileTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAndroid = entry.platform == 'android';
    final isIos = entry.platform == 'ios';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: theme.dividerColor.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isAndroid
                      ? Icons.android
                      : isIos
                          ? Icons.apple
                          : Icons.insert_drive_file,
                  size: 16,
                  color: isAndroid
                      ? Colors.green
                      : isIos
                          ? Colors.grey
                          : theme.hintColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    entry.fileName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${RecentFilesManager.formatSize(entry.size)} · ${entry.timeAgo()}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
