import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/utils/android_version.dart';
import 'package:apk_info_tool/utils/architecture_label.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/format.dart';
import 'package:apk_info_tool/utils/ios_icon_decoder.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
import 'package:apk_info_tool/widgets/batch_rename_dialog.dart';
import 'package:apk_info_tool/widgets/export_report_dialog.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:apk_info_tool/widgets/manifest_partial_banner.dart';
import 'package:apk_info_tool/widgets/package_icon_metrics.dart';
import 'package:apk_info_tool/widgets/platform_tag.dart';
import 'package:apk_info_tool/widgets/recent_app_icon.dart';
import 'package:apk_info_tool/widgets/rename_file_dialog.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, DexEntry, NativeLibraryEntry;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ipa_parser/ipa_parser.dart' show IosIconResolution;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

/// 应用概览页（V4 · Paper & Signal）。
///
/// 结构照 `docs/prototypes/ui-redesign-v4/renders/02-overview-active.png`：
/// 页头（kicker + 标题 + 副标题 + 动作）→ 左「当前目标」卡 + 右「POSTURE」
/// 卡 → 四张证据统计卡 → 左「最近分析」表 + 右「会话日志」。
///
/// 还没有打开文件时（`01-overview-empty.png`）：整宽引导卡（左文案 + 右拖放
/// 区与引擎表）→ 四张统计卡 → 最近分析 + 右栏「环境 / 流水线」。
///
/// 页面在**高度不足时整体滚动**，不再像旧版那样把「最近文件」压到几十像素：
/// 原型本身就是一屏scrollable的版式，硬塞一屏在任何窗口尺寸下都会溢。
class OverviewPage extends ConsumerStatefulWidget {
  const OverviewPage({super.key});

  @override
  ConsumerState<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends ConsumerState<OverviewPage> {
  bool _dragging = false;

  /// 应用版本：设置页也显示，这里只用于引擎表。
  String _appVersion = '2.10.6';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _appVersion = info.version);
    }).catchError((Object _) {});
  }

  /// 拖拽高亮的看门狗：桌面端不保证一定收到 `onDragExited`。
  Timer? _dragWatchdog;
  static const Duration _dragWatchdogTimeout = Duration(seconds: 5);

  /// 低于该宽度时右栏下移、统计卡改两列。
  static const _compactWidth = 980.0;

  @override
  void dispose() {
    _dragWatchdog?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // 拖拽
  // ---------------------------------------------------------------------

  void _beginDrag() {
    if (!_dragging) setState(() => _dragging = true);
    _restartDragWatchdog();
  }

  void _touchDrag() {
    if (!_dragging) return;
    _restartDragWatchdog();
  }

  void _endDrag() {
    _dragWatchdog?.cancel();
    _dragWatchdog = null;
    if (_dragging) setState(() => _dragging = false);
  }

  void _restartDragWatchdog() {
    _dragWatchdog?.cancel();
    _dragWatchdog = Timer(_dragWatchdogTimeout, () {
      _dragWatchdog = null;
      if (!mounted) return;
      log.fine('overview: 拖拽事件流已停止，主动熄灭高亮');
      _endDrag();
    });
  }

  // ---------------------------------------------------------------------
  // 打开文件
  // ---------------------------------------------------------------------

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      dialogTitle: t.open.select_apk_file,
      allowedExtensions: kPickableExtensions,
      lockParentWindow: true,
    );
    final filePath = result?.files.single.path;
    if (filePath != null) _openFile(filePath, navigate: false);
  }

  /// 拖放留在概览页就地看进度；点「打开文件」/最近文件则跳分析页。
  void _openFile(String filePath, {bool navigate = true}) {
    if (!File(filePath).existsSync()) return;
    ref.read(pendingOpenRequestProvider.notifier).request(filePath);
    if (navigate) {
      ref.read(shellNavigationProvider.notifier).navigate('analysis');
    }
  }

  bool _isSupported(String filePath) => isSupportedPackagePath(filePath);

  // ---------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final fileState = ref.watch(currentFileStateProvider);
    final apkInfo = ref.watch(currentApkInfoProvider);
    final isParsing = ref.watch(isParsingProvider);
    final recentFiles = ref.watch(recentFilesProvider);

    final hasFile = fileState.filePath != null;
    final isIos = fileState.platform == PackagePlatform.ios;

    final title = hasFile
        ? (apkInfo?.label ?? p.basename(fileState.filePath!))
        : t.overview.open_file;
    final subtitle = hasFile
        ? [
            if ((apkInfo?.packageName ?? '').isNotEmpty) apkInfo!.packageName,
            if ((apkInfo?.versionName ?? '').isNotEmpty) apkInfo!.versionName,
            if (fileState.fileSize != null)
              formatFileSize(fileState.fileSize!),
          ].join(' · ')
        : t.overview.subtitle;

    // 一次拖放会扇出给所有 DropTarget；IndexedStack 里被遮住的页必须关门。
    final visible = Visibility.of(context);

    return DropTarget(
      enable: visible,
      onDragEntered: (_) => _beginDrag(),
      onDragUpdated: (_) => _touchDrag(),
      onDragExited: (_) => _endDrag(),
      onDragDone: (details) {
        _endDrag();
        final files = details.files;
        if (files.isEmpty) return;
        final filePath = files.first.path;
        if (_isSupported(filePath)) {
          _openFile(filePath, navigate: false);
        } else {
          _showInvalidFileSnack(filePath);
        }
      },
      child: Container(
        color: _dragging
            ? scheme.primaryContainer.withValues(alpha: 0.3)
            : theme.scaffoldBackgroundColor,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < _compactWidth;
            final pad = compact ? 16.0 : 20.0;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, pad + 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeader(
                    kicker: hasFile
                        ? t.overview.kicker_active
                        : t.overview.kicker_empty,
                    title: title,
                    subtitle: subtitle,
                    actions: _headerActions(fileState, compact),
                  ),
                  SizedBox(height: compact ? 12 : 16),
                  if (apkInfo?.parseFailureReason != null)
                    ManifestPartialBanner(
                      title: t.apk_info.partial_manifest_title,
                      body: t.apk_info.partial_manifest_body,
                    ),
                  if (!hasFile)
                    _buildEmptyBody(context, compact, recentFiles)
                  else
                    _buildActiveBody(
                      context,
                      compact,
                      fileState,
                      apkInfo,
                      isParsing,
                      isIos,
                      recentFiles,
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _headerActions(FileState fileState, bool compact) => [
        _HeaderActionButton(
          iconOnly: compact,
          onPressed: _pickFile,
          icon: Icons.folder_open,
          label: t.overview.open_file,
          filled: true,
        ),
        _HeaderActionButton(
          iconOnly: compact,
          onPressed: () => pickAndBatchRename(context),
          icon: Icons.playlist_add_check,
          label: t.rename.batch_title,
        ),
        _HeaderActionButton(
          iconOnly: compact,
          onPressed: fileState.analysis == null
              ? null
              : () => _exportReport(fileState),
          icon: Icons.description_outlined,
          label: t.overview.export_report,
        ),
        _HeaderActionButton(
          iconOnly: compact,
          onPressed: fileState.filePath == null
              ? null
              : () => ref
                  .read(shellNavigationProvider.notifier)
                  .navigate('analysis'),
          icon: Icons.analytics_outlined,
          label: t.overview.view_details,
        ),
      ];

  // ---------------------------------------------------------------------
  // 空态：引导卡 + 统计 + 最近分析 / 环境·流水线
  // ---------------------------------------------------------------------

  Widget _buildEmptyBody(
    BuildContext context,
    bool compact,
    List<RecentFileEntry> recentFiles,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildWelcomeCard(context, compact),
        const SizedBox(height: 16),
        _buildEmptyStats(context, compact, recentFiles),
        const SizedBox(height: 16),
        if (compact) ...[
          _buildRecentCard(context, recentFiles, compact: true),
          const SizedBox(height: 16),
          _buildEnvironmentCard(context),
          const SizedBox(height: 16),
          _buildPipelineCard(context),
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 8, child: _buildRecentCard(context, recentFiles)),
              const SizedBox(width: 16),
              SizedBox(
                width: 340,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildEnvironmentCard(context),
                    const SizedBox(height: 16),
                    _buildPipelineCard(context),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildWelcomeCard(BuildContext context, bool compact) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          t.overview.kicker_empty,
          style: theme.textTheme.labelSmall?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
            fontSize: 10,
            letterSpacing: 1.4,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          t.overview.hero_headline,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.24,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            t.overview.hero_body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.55,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(t.overview.choose_file),
            ),
            OutlinedButton.icon(
              onPressed: () => _showSupportedFormats(context),
              icon: const Icon(Icons.description_outlined, size: 18),
              label: Text(t.overview.support_formats),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 13,
              color: scheme.primary.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                t.overview.hero_footnote,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
      ],
    );

    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDropZone(context),
        const SizedBox(height: 12),
        _buildEngineTable(context),
      ],
    );

    return _SurfaceCard(
      padding: EdgeInsets.all(compact ? 20 : 28),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [left, const SizedBox(height: 18), right],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 6, child: left),
                const SizedBox(width: 28),
                Expanded(flex: 4, child: right),
              ],
            ),
    );
  }

  Widget _buildDropZone(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: _pickFile,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.45),
            width: 1.4,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [scheme.primary, scheme.tertiary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.upload_file,
                size: 22,
                color: scheme.onPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${t.overview.drop_open} '),
                  TextSpan(
                    text: t.overview.choose_package,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t.overview.drop_max_hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEngineTable(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = <(String, String)>[
      (t.overview.engine, '$_appVersion · ${t.overview.engine_builtin}'),
      (t.overview.mode, t.overview.mode_static),
      (t.overview.network, t.overview.network_off),
      (t.overview.baseline, '2 ANDROID / 0 IOS'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                children: [
                  Text(
                    rows[i].$1,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Menlo', 'Courier'],
                      fontSize: 10,
                      letterSpacing: 1.1,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    rows[i].$2,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Menlo', 'Courier'],
                      fontSize: 10,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyStats(
    BuildContext context,
    bool compact,
    List<RecentFileEntry> recentFiles,
  ) {
    final cards = [
      _EvidenceStat(
        icon: Icons.analytics_outlined,
        value: '${recentFiles.length}',
        label: t.overview.stat_analyzed_count,
        hint: recentFiles.isEmpty
            ? t.overview.no_recent_files
            : t.overview.recent_files_hint,
      ),
      _EvidenceStat(
        icon: Icons.schedule,
        value: '—',
        label: t.overview.stat_last,
        hint: t.overview.recent_files_hint,
      ),
      _EvidenceStat(
        icon: Icons.shield_outlined,
        value: '—',
        label: t.overview.stat_findings,
        hint: t.overview.status_parsing,
      ),
      _EvidenceStat(
        icon: Icons.description_outlined,
        value: 'JSON',
        label: t.overview.stat_report_format,
        hint: 'schema v9 · Markdown / JSON',
      ),
    ];
    return _StatRow(cards: cards, compact: compact);
  }

  // ---------------------------------------------------------------------
  // 有文件：Hero + POSTURE + 统计 + 最近分析 / 会话日志
  // ---------------------------------------------------------------------

  Widget _buildActiveBody(
    BuildContext context,
    bool compact,
    FileState fileState,
    ApkInfo? apkInfo,
    bool isParsing,
    bool isIos,
    List<RecentFileEntry> recentFiles,
  ) {
    final hero = _buildCurrentCard(
      context,
      fileState,
      apkInfo,
      isParsing,
      isIos,
      compact,
    );
    final posture = _buildPostureCard(fileState, isParsing);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact) ...[
          hero,
          const SizedBox(height: 16),
          posture,
        ] else
          // 两张卡必须等高：底边参差是原型里最明显的「没对齐」。
          // 行内没有可滚动组件（最近文件已改成 Column），IntrinsicHeight 安全。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: hero),
                const SizedBox(width: 16),
                SizedBox(width: 320, child: posture),
              ],
            ),
          ),
        const SizedBox(height: 16),
        _buildEvidenceStats(context, compact, fileState, apkInfo, isIos),
        const SizedBox(height: 16),
        if (compact) ...[
          _buildRecentCard(context, recentFiles, compact: true),
          const SizedBox(height: 16),
          _buildSessionLog(context, fileState, apkInfo),
        ] else
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 8, child: _buildRecentCard(context, recentFiles)),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
                  child: _buildSessionLog(context, fileState, apkInfo),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 当前目标卡：图标 + 名称 + 徽章 + 右侧 FILE 列 + 六格元数据表。
  Widget _buildCurrentCard(
    BuildContext context,
    FileState fileState,
    ApkInfo? apkInfo,
    bool isParsing,
    bool isIos,
    bool compact,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final analysis = fileState.analysis;

    final name = isIos
        ? (analysis?.ios?.preferredName.value ?? '')
        : (apkInfo?.label ?? '');
    final identifier = isIos
        ? (analysis?.ios?.bundleIdentifier.value ?? '')
        : (apkInfo?.packageName ?? '');
    final version = isIos
        ? [
            analysis?.ios?.shortVersion.value ?? '',
            analysis?.ios?.buildNumber.value ?? '',
          ].where((e) => e.isNotEmpty).join(' (')
        : (apkInfo?.versionName ?? '');
    final versionText = isIos
        ? (version.isEmpty ? '' : '$version)')
        : (apkInfo?.versionCode == null
            ? version
            : '$version (${apkInfo!.versionCode})');

    final chips = <Widget>[
      _Pill(
        icon: isIos ? Icons.apple : Icons.android,
        text: isIos ? 'iOS' : 'Android',
        color: isIos ? Colors.grey : Colors.green,
      ),
      if (architectureLabelOf(analysis) != null)
        _Pill(text: architectureLabelOf(analysis)!, mono: true),
      if (!isIos && apkInfo?.sdkVersion != null)
        _Pill(text: 'minSdk ${apkInfo!.sdkVersion}', mono: true),
      if (!isIos && apkInfo?.applicationDebuggable == true)
        _Pill(
          text: t.overview.debuggable_chip,
          color: scheme.tertiary,
          icon: Icons.bug_report_outlined,
        ),
      if (isParsing)
        _Pill(text: t.overview.status_parsing, color: scheme.primary),
    ];

    final detailCells = _metaCells(fileState, apkInfo, isIos);

    return _SurfaceCard(
      padding: EdgeInsets.all(compact ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildIcon(context, apkInfo, analysis, isIos),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      name.isEmpty ? p.basename(fileState.filePath ?? '') : name,
                      maxLines: 1,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      identifier,
                      maxLines: 1,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontFamilyFallback: const ['Menlo', 'Courier'],
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (versionText.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        versionText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 6, children: chips),
                  ],
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 16),
                _buildFileColumn(fileState, apkInfo),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: scheme.outlineVariant),
          const SizedBox(height: 12),
          _MetaTable(cells: detailCells),
        ],
      ),
    );
  }

  Widget _buildFileColumn(FileState fileState, ApkInfo? apkInfo) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sha = fileState.sha256Hash;

    String sizeText() {
      final size = fileState.fileSize ?? apkInfo?.apkSize ?? 0;
      return size == 0 ? '—' : formatFileSize(size);
    }

    return SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _MetaPair(label: t.overview.field_file, value: sizeText()),
          const SizedBox(height: 8),
          if (sha != null)
            _MetaPair(
              label: t.file_info.sha256,
              value: sha,
              mono: true,
              maxLines: 2,
              textAlign: TextAlign.right,
            )
          else if (fileState.isComputingHash)
            _MetaPair(
              label: t.file_info.sha256,
              value: t.file_info.computing_hash,
              mono: true,
            ),
          if (fileState.filePath != null && apkInfo != null) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () => _showRenameDialog(
                filePath: fileState.filePath!,
                displayName: apkInfo.label ?? '',
                versionName: apkInfo.versionName ?? '',
              ),
              icon: Icon(Icons.drive_file_rename_outline,
                  size: 13, color: scheme.primary),
              label: Text(
                t.rename.rename_file,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.primary),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 24),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 六格元数据（与原型一致：两行三列）。
  List<(String, String)> _metaCells(
    FileState fileState,
    ApkInfo? apkInfo,
    bool isIos,
  ) {
    final analysis = fileState.analysis;
    final android = analysis?.android;
    final ios = analysis?.ios;

    final componentsCount = android?.components.hasValue == true
        ? android!.components.value!.length
        : apkInfo?.components.length;
    final exportedCount = apkInfo?.components
            .where((c) => c.exported == true)
            .length ??
        0;

    final signatureText = _signatureText(fileState, isIos);
    final entryPoints = apkInfo?.launchableActivity
            .map((c) => c.name)
            .whereType<String>()
            .where((n) => n.isNotEmpty)
            .toList() ??
        const <String>[];

    if (isIos) {
      final frameworks = ios?.nestedBinaries.length ?? 0;
      final devices = ios?.deviceFamily.hasValue == true
          ? DetailRenderer.deviceFamily(ios!.deviceFamily.value, t)
          : '—';
      return [
        (t.overview.field_package, ios?.bundleIdentifier.value ?? '—'),
        (
          t.overview.field_version,
          [ios?.shortVersion.value, ios?.buildNumber.value]
              .whereType<String>()
              .where((e) => e.isNotEmpty)
              .join(' / ')
              .ifEmpty('—')
        ),
        (t.overview.field_signature, signatureText),
        (t.overview.field_min_os, (ios?.minimumOSVersion.value ?? '').ifEmpty('—')),
        (t.overview.field_frameworks, '$frameworks'),
        (t.overview.field_devices, devices),
      ];
    }

    final targetSdk = apkInfo?.targetSdkVersion;
    final componentsText = componentsCount == null
        ? '—'
        : exportedCount > 0
            ? '$componentsCount · ${t.overview.stat_hint_exported(count: '$exportedCount')}'
            : '$componentsCount';
    return [
      (t.overview.field_package, apkInfo?.packageName ?? '—'),
      (
        t.overview.field_version,
        apkInfo == null
            ? '—'
            : '${apkInfo.versionName ?? '—'}${apkInfo.versionCode == null ? '' : ' (${apkInfo.versionCode})'}'
      ),
      (t.overview.field_signature, signatureText),
      (
        t.overview.field_target_sdk,
        targetSdk == null ? '—' : AndroidVersion.describe(targetSdk)
      ),
      (t.overview.field_components, componentsText),
      (
        t.overview.field_entry_points,
        entryPoints.isEmpty
            ? t.overview.entry_points_none
            : entryPoints.take(2).join(' · ')
      ),
    ];
  }

  /// 签名一句话：方案 + 是否验证 / 未验证。
  String _signatureText(FileState fileState, bool isIos) {
    if (isIos) {
      final status = fileState.analysis?.ios?.codeSign?.status;
      return switch (status) {
        SignatureStatus.verified => t.overview.sig_verified,
        SignatureStatus.verificationFailed => t.overview.sig_failed,
        SignatureStatus.unknown => t.overview.sig_unknown,
        _ => t.overview.sig_none,
      };
    }
    final signature = fileState.signature;
    final schemes = <String>{
      ...?signature?.verifiedSchemes,
      ...?signature?.localCertificates.map((c) => c.scheme),
    }.toList()
      ..sort();
    final schemeText = schemes.isEmpty ? '' : schemes.join(' · ');
    final (statusText, _) = _signatureStatus(fileState);
    if (schemeText.isEmpty) return statusText;
    return '$schemeText · $statusText';
  }

  Widget _buildEvidenceStats(
    BuildContext context,
    bool compact,
    FileState fileState,
    ApkInfo? apkInfo,
    bool isIos,
  ) {
    final analysis = fileState.analysis;
    final android = analysis?.android;
    final ios = fileState.ipaAnalysis;

    final permissionsField = android?.permissions;
    final permissionsRead = permissionsField != null && permissionsField.hasValue;
    final permissions =
        permissionsRead ? permissionsField.value! : const <String>[];
    final highRisk = permissions
        .where((p) =>
            AndroidMetadata.instance.riskOf(p) == AndroidPermissionRisk.high)
        .length;

    final componentsField = android?.components;
    final componentsRead =
        componentsField != null && componentsField.hasValue;
    final components = componentsRead
        ? componentsField.value!
        : apkInfo?.components ?? const <AndroidComponent>[];
    final exported = components.where((c) => c.exported == true).length;

    final structure = apkInfo?.structure;
    final dexFiles = structure?.dexFiles ?? const <DexEntry>[];
    final dexBytes = dexFiles.fold<int>(0, (sum, d) => sum + d.size);
    final nativeLibs = structure?.nativeLibraries ?? const <NativeLibraryEntry>[];
    final abis = structure?.abis ?? const <String>[];

    final privacyCount =
        ios?.infoPlist?.privacyUsageDescriptions.value?.length ?? 0;
    final frameworkCount = ios?.nestedBinaries.length ?? 0;

    final cards = isIos
        ? <Widget>[
            _EvidenceStat(
              icon: Icons.shield_outlined,
              value: '$privacyCount',
              label: t.overview.stat_permissions,
              hint: t.ios_info.usage_descriptions,
            ),
            _EvidenceStat(
              icon: Icons.widgets_outlined,
              value: '${ios?.infoPlist?.urlSchemes.value?.length ?? 0}',
              label: t.ios_info.url_schemes,
              hint: t.ios_info.background_modes,
            ),
            _EvidenceStat(
              icon: Icons.memory,
              value: architectureLabelOf(analysis) ?? '—',
              label: t.overview.stat_dex_files,
              hint: 'Mach-O',
            ),
            _EvidenceStat(
              icon: Icons.extension_outlined,
              value: '$frameworkCount',
              label: t.overview.field_frameworks,
              hint: t.overview.field_devices,
            ),
          ]
        : <Widget>[
            _EvidenceStat(
              icon: Icons.shield_outlined,
              value: permissionsRead ? '${permissions.length}' : '—',
              label: t.overview.stat_permissions,
              hint: permissionsRead
                  ? t.overview.stat_hint_high_permissions(count: '$highRisk')
                  : t.overview.status_parsing,
            ),
            _EvidenceStat(
              icon: Icons.widgets_outlined,
              value: componentsRead ? '${components.length}' : '—',
              label: t.overview.stat_components,
              hint: componentsRead
                  ? t.overview.stat_hint_exported(count: '$exported')
                  : t.overview.status_parsing,
            ),
            _EvidenceStat(
              icon: Icons.memory,
              value: '${dexFiles.length}',
              label: t.overview.stat_dex_files,
              hint: dexBytes == 0 ? '—' : formatFileSize(dexBytes),
            ),
            _EvidenceStat(
              icon: Icons.inventory_2_outlined,
              value: '${nativeLibs.length}',
              label: t.overview.stat_native_libs,
              hint: abis.isEmpty ? '—' : abis.join(' · '),
            ),
          ];

    return _StatRow(cards: cards, compact: compact);
  }

  /// POSTURE：安全发现数 + 严重度分布 + 覆盖缺口。
  Widget _buildPostureCard(FileState fileState, bool isParsing) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final security = fileState.effectiveSecurityResult;
    final findings = security?.findings ?? const <SecurityFinding>[];
    final high = findings
        .where((f) =>
            f.severity == SecuritySeverity.p0 ||
            f.severity == SecuritySeverity.p1)
        .length;
    final review = findings
        .where((f) =>
            f.severity == SecuritySeverity.p2 ||
            f.severity == SecuritySeverity.p3)
        .length;
    final info = findings.length - high - review;
    final gaps = security?.coverage.gaps.length ?? 0;
    final covered =
        security == null ? 0 : security.coverage.applicable.length - gaps;
    final total = security?.coverage.applicable.length ?? 0;

    return _SurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'POSTURE / STATIC',
                style: _monoLabel(theme, letterSpacing: 1.2),
              ),
              const Spacer(),
              if (gaps > 0)
                _Pill(
                  text: '$gaps GAPS',
                  color: scheme.tertiary,
                  mono: true,
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                security == null ? '—' : '${findings.length}',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1,
                  letterSpacing: -1.5,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                t.overview.stat_findings,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _SeverityChip(label: 'HIGH', value: high, color: scheme.error),
              _SeverityChip(
                label: 'REVIEW',
                value: review,
                color: scheme.tertiary,
              ),
              _SeverityChip(
                label: 'INFO',
                value: info,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: scheme.outlineVariant),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${t.overview.stat_report_format} · $covered/$total',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                '${((total == 0 ? 0 : covered / total) * 100).round()}%',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: gaps == 0 ? Colors.green : scheme.tertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : covered / total,
              minHeight: 5,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 12),
          _PostureLink(
            icon: Icons.security,
            label: t.overview.status_security,
            trailing: '${findings.length}',
          ),
          _PostureLink(
            icon: Icons.layers_outlined,
            label: t.overview.field_details,
            trailing: isParsing ? '…' : '${security?.coverage.applicable.length ?? 0}',
          ),
          _PostureLink(
            icon: Icons.download_outlined,
            label: t.overview.export_report,
            trailing: 'MD / JSON',
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 最近分析
  // ---------------------------------------------------------------------

  Widget _buildRecentCard(
    BuildContext context,
    List<RecentFileEntry> recentFiles, {
    bool compact = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return _SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
            child: Row(
              children: [
                Icon(Icons.history, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  t.overview.recent_files,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _Pill(text: t.overview.recent_local_only, mono: true),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => ref
                      .read(shellNavigationProvider.notifier)
                      .navigate('history'),
                  icon: const Icon(Icons.tune, size: 14),
                  label: Text(t.overview.recent_manage),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Text(
                    t.overview.recent_col_file,
                    style: _monoLabel(theme, fontSize: 9.5),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    t.overview.recent_col_platform,
                    style: _monoLabel(theme, fontSize: 9.5),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    t.overview.recent_col_when,
                    style: _monoLabel(theme, fontSize: 9.5),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          if (recentFiles.isEmpty)
            _buildEmptyRecent(context)
          else
            // 用 Column 而不是 ListView：外层 IntrinsicHeight 需要可计算的高度，
            // 列表长度本身有上限（RecentFiles 最多保留 10 条），不需要滚动。
            Column(
              children: [
                for (var i = 0; i < recentFiles.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: scheme.outlineVariant),
                  _RecentRow(
                    entry: recentFiles[i],
                    onTap: () =>
                        _openFile(recentFiles[i].path, navigate: false),
                  ),
                ],
              ],
            ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  t.overview.recent_files_hint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  t.overview.recent_local_only,
                  style: _monoLabel(theme, fontSize: 9.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyRecent(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(
            Icons.folder_open,
            size: 30,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 10),
          Text(
            t.overview.no_recent_files,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.overview.recent_files_hint,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 会话日志（有文件时）
  // ---------------------------------------------------------------------

  Widget _buildSessionLog(
    BuildContext context,
    FileState fileState,
    ApkInfo? apkInfo,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final analysis = fileState.analysis;
    final structure = apkInfo?.structure;
    final signature = fileState.signature;
    final security = fileState.effectiveSecurityResult;

    final lines = <String>[
      if (structure != null)
        t.overview.session_manifest(count: '${structure.fileEntryCount}'),
      if (structure != null && structure.dexFiles.isNotEmpty)
        t.overview.session_dex(
          files: '${structure.dexFiles.length}',
          size: formatFileSize(
            structure.dexFiles.fold<int>(0, (s, d) => s + d.size),
          ),
        ),
      if (signature != null)
        t.overview.session_signature(
          schemes: <String>{
            ...signature.verifiedSchemes,
            ...signature.localCertificates.map((c) => c.scheme),
          }.join(' · ').ifEmpty('—'),
        ),
      if (security != null)
        t.overview.session_security(
          count: '${security.findings.length}',
          high: '${security.findings.where((f) => f.severity == SecuritySeverity.p0 || f.severity == SecuritySeverity.p1).length}',
        ),
      if (analysis?.android?.locales.hasValue == true)
        'locales · ${analysis!.android!.locales.value!.length}',
    ];

    return _SurfaceCard(
      zero: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                Icon(Icons.terminal, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  t.overview.session_log,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _Pill(text: t.overview.session_readonly, mono: true),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      line,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                        fontFamilyFallback: const ['Menlo', 'Courier'],
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ),
                if (lines.isEmpty)
                  Text(
                    t.overview.status_parsing,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              t.overview.session_local,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 环境 / 流水线（空态右栏）
  // ---------------------------------------------------------------------

  Widget _buildEnvironmentCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = <(IconData, String, String, Color)>[
      (Icons.code, t.overview.env_parser, t.overview.env_ready, Colors.green),
      (
        Icons.verified_outlined,
        t.overview.env_signature,
        t.overview.env_ready,
        Colors.green
      ),
      (Icons.usb, t.overview.env_adb, t.overview.env_optional, scheme.tertiary),
      (
        Icons.dataset_outlined,
        t.overview.env_baseline,
        t.overview.env_not_set,
        scheme.onSurfaceVariant
      ),
    ];

    return _SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                Icon(Icons.layers_outlined, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  t.overview.environment,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                _Pill(
                  text: t.overview.env_ready,
                  color: Colors.green,
                  mono: true,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                children: [
                  Icon(row.$1, size: 13, color: row.$4),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      row.$2,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    row.$3,
                    style: _monoLabel(theme, fontSize: 9.5, color: row.$4),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPipelineCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final steps = <(String, String)>[
      ('01 DROP', t.overview.pipeline_drop),
      ('02 PARSE', t.overview.pipeline_parse),
      ('03 EVIDENCE', t.overview.pipeline_evidence),
      ('04 EXPORT', t.overview.pipeline_export),
    ];

    return _SurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.route_outlined, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                t.overview.pipeline,
                style: _monoLabel(theme, letterSpacing: 1.1),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 20,
            runSpacing: 12,
            children: [
              for (final step in steps)
                SizedBox(
                  width: 120,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.$1,
                        style: _monoLabel(
                          theme,
                          fontSize: 9,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        step.$2,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 小工具
  // ---------------------------------------------------------------------

  Widget _buildIcon(
    BuildContext context,
    ApkInfo? apkInfo,
    PackageAnalysisResult? analysis,
    bool isIos,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const side = PackageIconMetrics.heroSide;
    final radius = PackageIconMetrics.radiusOf(side);

    return SizedBox.square(
      dimension: side,
      child: GestureDetector(
        onSecondaryTapUp: isIos
            ? (_) => _exportIosIcon(analysis?.ios?.icon)
            : (details) => _showIconExportMenu(
                  context,
                  details.globalPosition,
                  apkInfo,
                ),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: isIos
              ? IosIconThumbnail(
                  resolution: analysis?.ios?.icon,
                  size: double.infinity,
                )
              : (apkInfo?.mainIconImage != null
                  ? RawImage(image: apkInfo!.mainIconImage, fit: BoxFit.cover)
                  : Center(
                      child: Icon(
                        Icons.android,
                        size: 28,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                    )),
        ),
      ),
    );
  }

  TextStyle? _monoLabel(
    ThemeData theme, {
    double fontSize = 10,
    double letterSpacing = 1.1,
    Color? color,
  }) =>
      theme.textTheme.labelSmall?.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Menlo', 'Courier'],
        fontSize: fontSize,
        letterSpacing: letterSpacing,
        color: color ?? theme.colorScheme.onSurfaceVariant,
      );

  void _showInvalidFileSnack(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    final name = p.basename(filePath);
    final scheme = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.error, size: 18),
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
        backgroundColor: scheme.errorContainer,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showSupportedFormats(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.overview.support_formats),
        content: Text(t.overview.drop_zone_hint),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.base.cancel),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 签名 / 安全文案（沿用旧实现的三态口径）
  // ---------------------------------------------------------------------

  (String, Color) _signatureStatus(FileState fileState) {
    if (!Config.enableSignature.value) {
      return (t.overview.sig_disabled, Colors.grey);
    }
    return switch (fileState.signature?.status) {
      SignatureStatus.verified => (t.overview.sig_verified, Colors.green),
      SignatureStatus.verificationFailed => (t.overview.sig_failed, Colors.red),
      SignatureStatus.unknown => (t.overview.sig_unknown, Colors.orange),
      _ => (t.overview.sig_none, Colors.grey),
    };
  }

  // ---------------------------------------------------------------------
  // 重命名 / 图标导出 / 报告导出
  // ---------------------------------------------------------------------

  Future<void> _showRenameDialog({
    required String filePath,
    required String displayName,
    required String versionName,
  }) async {
    final result = await showRenameFileDialog(
      context,
      filePath: filePath,
      displayName: displayName,
      versionName: versionName,
    );
    if (!mounted || result == null) return;
    final newPath = reportRenameOutcome(context, result);
    if (newPath != null) _openFile(newPath, navigate: false);
  }

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

  Future<void> _exportIosIcon(IosIconResolution? resolution) async {
    final candidates = resolution?.candidates ?? [];
    if (candidates.isEmpty) return;

    try {
      final result = await IosIconDecoder.decode(candidates.first);
      if (!result.hasImage) {
        throw StateError(result.failure ?? 'decode failed');
      }
      final image = result.image!;

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.icon.export_icon,
        fileName: 'icon.png',
        type: FileType.custom,
        allowedExtensions: ['png'],
        lockParentWindow: true,
      );
      if (savePath == null) return;

      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('icon encode failed');
      await File(savePath).writeAsBytes(data.buffer.asUint8List());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.icon.export_success)),
      );
    } catch (e) {
      log.warning('export iOS icon failed: $e');
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
      builder: (_) =>
          ExportReportDialog(analysis: analysis, archivePath: fileState.filePath),
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
}

// ---------------------------------------------------------------------------
// 共享小组件
// ---------------------------------------------------------------------------

class _SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final bool zero;

  const _SurfaceCard({
    required this.child,
    this.padding,
    this.zero = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: zero ? EdgeInsets.zero : (padding ?? const EdgeInsets.all(16)),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(V4Radius.panel),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? color;
  final bool mono;

  const _Pill({required this.text, this.icon, this.color, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: c),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: mono ? 'monospace' : null,
                fontFamilyFallback:
                    mono ? const ['Menlo', 'Courier'] : null,
                fontSize: mono ? 10 : 11,
                color: c,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeverityChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _SeverityChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        '$label $value',
        style: theme.textTheme.labelSmall?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Menlo', 'Courier'],
          fontSize: 9.5,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PostureLink extends StatelessWidget {
  final IconData icon;
  final String label;
  final String trailing;

  const _PostureLink({
    required this.icon,
    required this.label,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            trailing,
            style: theme.textTheme.labelSmall?.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['Menlo', 'Courier'],
              fontSize: 10,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _EvidenceStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final String hint;

  const _EvidenceStat({
    required this.icon,
    required this.value,
    required this.label,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                  height: 1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Icon(
              icon,
              size: 15,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final List<Widget> cards;
  final bool compact;

  const _StatRow({required this.cards, required this.compact});

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Column(
        children: [
          for (var i = 0; i < cards.length; i += 2) ...[
            if (i > 0) const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: cards[i]),
                const SizedBox(width: 10),
                Expanded(
                  child: i + 1 < cards.length
                      ? cards[i + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ],
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
}

class _MetaTable extends StatelessWidget {
  final List<(String, String)> cells;

  const _MetaTable({required this.cells});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget cell((String, String) data) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data.$1.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Menlo', 'Courier'],
                  fontSize: 9,
                  letterSpacing: 0.9,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              SelectableText(
                data.$2,
                maxLines: 1,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );

    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 3) {
      if (i > 0) {
        rows.add(Divider(height: 1, color: scheme.outlineVariant));
      }
      final rowCells = cells.skip(i).take(3).toList();
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < 3; j++) ...[
                if (j > 0)
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: scheme.outlineVariant,
                  ),
                Expanded(
                  child: rowCells.length > j
                      ? cell(rowCells[j])
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: rows),
    );
  }
}

class _MetaPair extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final int maxLines;
  final TextAlign textAlign;

  const _MetaPair({
    required this.label,
    required this.value,
    this.mono = false,
    this.maxLines = 1,
    this.textAlign = TextAlign.left,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: textAlign == TextAlign.right
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          textAlign: textAlign,
          style: theme.textTheme.labelSmall?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
            fontSize: 8.5,
            letterSpacing: 0.8,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          value,
          textAlign: textAlign,
          style: theme.textTheme.labelSmall?.copyWith(
            fontFamily: mono ? 'monospace' : null,
            fontFamilyFallback: mono ? const ['Menlo', 'Courier'] : null,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  final RecentFileEntry entry;
  final VoidCallback onTap;

  const _RecentRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final platform = PlatformTag.fromId(entry.platform).platform;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            RecentAppIcon(
              iconFile: entry.iconFile,
              fallback: switch (platform) {
                PackagePlatform.android => Icons.android,
                PackagePlatform.ios => Icons.apple,
                PackagePlatform.unknown => Icons.insert_drive_file,
              },
              fallbackColor: PlatformTag.colorOf(platform, theme),
              size: 26,
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.fileName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    RecentFilesManager.formatSize(entry.size),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: PlatformTag(platform: platform),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                _relativeTime(entry.analyzedAt, t),
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 页头动作按钮（紧凑尺寸；窄窗口只留图标）。
class _HeaderActionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool filled;
  final bool iconOnly;

  const _HeaderActionButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    this.filled = false,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (iconOnly) {
      final iconWidget = Icon(icon, size: 18);
      return filled
          ? IconButton.filled(
              onPressed: onPressed,
              tooltip: label,
              icon: iconWidget,
            )
          : IconButton.outlined(
              onPressed: onPressed,
              tooltip: label,
              icon: iconWidget,
            );
    }

    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      ),
      textStyle: WidgetStatePropertyAll(
        theme.textTheme.labelMedium?.copyWith(fontSize: 12),
      ),
    );
    final iconWidget = Icon(icon, size: 15);
    final text = Text(label);
    if (filled) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: iconWidget,
        label: text,
        style: style,
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: iconWidget,
      label: text,
      style: style,
    );
  }
}

String _relativeTime(DateTime at, Translations t) {
  final diff = DateTime.now().difference(at);
  if (diff.inSeconds < 60) return t.overview.recent_just_now;
  if (diff.inMinutes < 60) {
    return t.overview.recent_minutes_ago(count: diff.inMinutes);
  }
  if (diff.inHours < 24) {
    return t.overview.recent_hours_ago(count: diff.inHours);
  }
  if (diff.inDays < 7) return t.overview.recent_days_ago(count: diff.inDays);
  final d = at.toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

extension _StringIfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
