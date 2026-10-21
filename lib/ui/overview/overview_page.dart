import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/utils/architecture_label.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/file_rename.dart';
import 'package:apk_info_tool/utils/ios_icon_decoder.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
import 'package:apk_info_tool/utils/recent_icon_cache.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:apk_info_tool/widgets/arch_badge.dart';
import 'package:apk_info_tool/widgets/copy_icon_button.dart';
import 'package:apk_info_tool/widgets/export_report_dialog.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:apk_info_tool/widgets/package_icon_metrics.dart';
import 'package:apk_info_tool/widgets/platform_tag.dart';
import 'package:apk_info_tool/widgets/rename_file_dialog.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ipa_parser/ipa_parser.dart' show IosIconResolution;
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

  /// 详细信息网格**最多显示几项**（用户要求 6 项，由我们选）。
  ///
  /// 选的是「打开一个包时最常被复制走的那几项」：文件名 / 版本 / 构建号 /
  /// 最低系统 / SHA-256，以及各自平台最有用的第 6 项（Android 是 targetSdk、
  /// iOS 是可执行文件名）。
  ///
  /// **被去掉的是 SHA-1 与 MD5** —— SHA-256 是现在的通用口径，另两个只在
  /// 与旧记录比对时才有用；它们在分析页与导出的报告里仍然都在，不是删掉了
  /// 能力，只是不占概览页这块地方。
  ///
  /// 少两项还顺带让网格从 3 行变 2 行：概览页是固定一屏布局，这一块每矮一行
  /// 就把高度还给底部的「最近文件」。
  static const maxDetailCells = 6;

  @override
  ConsumerState<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends ConsumerState<OverviewPage> {
  bool _dragging = false;

  /// 拖拽高亮的看门狗。
  ///
  /// 高亮的熄灭原本只依赖 `onDragExited`，但 `desktop_drop` 并不保证这个
  /// 回调一定送达 —— 拖放被系统取消、或拖拽影像在应用卡顿时被丢弃，都可能
  /// 让 `_dragging` 永远停在 `true`，界面上就是一层擦不掉的浮层。
  ///
  /// 这里用「拖拽期间的事件流」当心跳：只要还在窗口上方，macOS 会持续发
  /// `draggingUpdated`；安静超过 [_dragWatchdogTimeout] 就说明拖拽已经结束。
  ///
  /// **它只是安全网，不是信号源。** 清早了也没有副作用：高亮是纯装饰，
  /// `onDragDone` 是否触发由 `desktop_drop` 自己的状态机决定，与这里无关。
  Timer? _dragWatchdog;

  static const Duration _dragWatchdogTimeout = Duration(seconds: 5);

  /// 窄窗口阈值：低于它时收紧间距、状态卡片两列排布。
  static const _compactWidth = 900.0;

  /// 详细信息网格之外的部分（头部 + 状态卡片 + 统计 + 间距 + 内边距）
  /// 大约占的高度。
  ///
  /// 页面是**固定一屏**布局，Hero 长高了就必须有东西让位，否则底部会被
  /// 直接裁掉 —— 用户看到的是一个残缺的界面，而不是「内容有点多」。
  ///
  /// 620 是在两档真实尺寸上量出来的（内容区 = 窗口宽 − 侧栏 240 − 内边距）：
  /// - 1280×800（默认窗口，内容区 1040×800）→ 网格 180px，正好三行铺满 iOS
  ///   的全部字段；
  /// - 900×600（允许的最小窗口，内容区 660×600）→ 减去后为负，网格收起，
  ///   统计与最近文件都放得下。
  ///
  /// **V2.4.1 起再加上共享页头**：概览页原先没有页头，V2.4.1 为了和
  /// 分析 / 版本对比 / 设置三个页面统一，加了 `PageHeader`（标题 32 +
  /// 间距 6 + 单行副标题 20 = 58px，副标题已钉成一行，见 `PageHeader`）。
  /// 同时三个动作按钮从 Hero 竖排挪到了页头右上角（紧凑尺寸，30px 高，
  /// 不撑高页头）。不补这 60px，概览页在默认窗口下底栏会溢出 ——
  /// `test/overview_layout_test.dart` 立刻变红。
  ///
  /// 用估算值而不是精确测量：精确测量要在布局前拿到子项高度，只能靠
  /// `IntrinsicHeight`，而它和内部的 `ListView` 不兼容（debug 下会断言失败）。
  /// `test/overview_layout_test.dart` 用真实渲染钉住这个常量。
  ///
  /// **V2.5.0 的文件路径行没有动这个常量**：它挂在「当前文件」那一行上
  /// （横向，不占高度），不是新开一行。实测 1040×800 下 Hero 502px、
  /// 底部「最近文件」只剩 30px —— 再长高 20px 就会溢出，这条路走不通。
  static const _chromeHeightEstimate = 620.0 + 60.0;

  /// 网格显示的**门槛**（不是它的高度）。
  ///
  /// 网格本身是 `Wrap`，高度由字段自然撑开，不滚动；这里只决定「够不够地方
  /// 显示它」—— 低于门槛整块收起（返回 `SizedBox.shrink()`），把高度让给
  /// 底部的统计与最近文件。
  static const _detailGridMaxHeight = 180.0;

  @override
  void dispose() {
    _dragWatchdog?.cancel();
    super.dispose();
  }

  /// 进入拖拽态，并开始心跳。
  void _beginDrag() {
    if (!_dragging) setState(() => _dragging = true);
    _restartDragWatchdog();
  }

  /// 拖拽期间有事件到达 —— 推迟看门狗。
  void _touchDrag() {
    if (!_dragging) return;
    _restartDragWatchdog();
  }

  /// 退出拖拽态。
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

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      dialogTitle: t.open.select_apk_file,
      allowedExtensions: kPickableExtensions,
      lockParentWindow: true,
    );
    final filePath = result?.files.single.path;
    if (filePath != null) {
      _openFile(filePath, navigate: false);
    }
  }

  /// 打开一个文件。
  ///
  /// [navigate] 决定是否跳到分析页：
  /// - **拖放**进来时不跳 —— 用户还在概览页，Hero 区会就地显示解析进度与
  ///   状态卡片，想看细节再点「查看详情」；
  /// - 点「打开文件」或最近文件时跳 —— 那是用户明确的「我要看这个」。
  void _openFile(String filePath, {bool navigate = true}) {
    if (!File(filePath).existsSync()) return;

    // 交给分析页去解析：解析流水线（任务句柄、阶段回调、取消、代际计数）
    // 只存在于那里。概览页只负责发起请求。
    ref.read(pendingOpenRequestProvider.notifier).request(filePath);
    if (navigate) {
      ref.read(shellNavigationProvider.notifier).navigate('analysis');
    }
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

    // 只有**当前可见**的那一页才接收拖放。
    //
    // `AppShell` 用 `IndexedStack` 承载三个页面，它们同时在树里、并且
    // **布局尺寸完全重叠**。而 `desktop_drop` 的通道是全局的：一次拖放会
    // 扇出给所有已注册的 `DropTarget`，每个再各自按自己的渲染盒判「是否
    // 在界内」—— 重叠的盒子全都判定为在界内，于是**一次拖放会触发两次
    // `openApk`**（概览页发请求、分析页自己再开一次），两条解析流水线同时
    // 跑同一个文件。`desktop_drop` 的文档也明确要求「被挡住时把 target
    // 关掉」。`IndexedStack` 通过 `Visibility.of` 告诉子页自己可不可见。
    final visible = Visibility.of(context);

    return DropTarget(
      enable: visible,
      onDragEntered: (_) => _beginDrag(),
      // `onDragUpdated` 是拖拽期间的心跳，用来喂看门狗。
      onDragUpdated: (_) => _touchDrag(),
      onDragExited: (_) => _endDrag(),
      onDragDone: (details) {
        _endDrag();
        final files = details.files;
        if (files.isEmpty) return;
        final filePath = files.first.path;
        if (_isSupported(filePath)) {
          // 拖入不跳转：留在概览页看状态卡片。
          _openFile(filePath, navigate: false);
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
            // 窄窗口的纵向节奏要收紧：V2.4.1 加了 58px 的共享页头之后，
            // 最小窗口（内容区 660×600）里页头 + Hero + 统计 + 最近文件
            // 正好差十几像素放不下。收紧的是**间距**，不是内容 ——
            // 底部「最近文件」至少要 44px（分区标题 + 空状态文案），
            // 这一段实测能拿回 16px。
            final gap = compact ? 10.0 : 20.0;
            final pad = compact ? 16.0 : 24.0;
            // 网格「显不显示」由窗口高度决定（门槛见 _detailGridMaxHeight）。
            final gridHeight = (constraints.maxHeight - _chromeHeightEstimate)
                .clamp(0.0, _detailGridMaxHeight);

            return Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 页头：与 分析 / 版本对比 / 设置 同一个 `PageHeader`
                  // （此前概览页根本没有页头，标题只在 Hero 里显示当前包名，
                  //  用户切到别的页面再回来就找不到「这是哪一页」）。
                  PageHeader(
                    title: t.nav.overview,
                    subtitle: t.overview.subtitle,
                    // 三个动作放在**页头右上角** —— 版本对比页的「导出对比报告」
                    // 就在這個位置，四个页面因此是同一个路数。
                    //
                    // 它们原先竖排挤在 Hero 里（把「四个状态卡片」顶出首屏）。
                    // 竖排那一列比左侧文字列还高 —— 实测最小窗口下 Hero 因此
                    // 多出 56px（392 → 336），而概览页是固定一屏布局，
                    // 这 56px 直接从底部「最近文件」里扣。
                    //
                    // 「查看详情 / 导出报告」在没有文件时置灰，与版本对比页
                    // 「没选两个包时导出按钮置灰」同一条口径。
                    //
                    // **窄窗口只留图标**（`iconOnly`）：三个带文字的按钮在
                    // 660px 内容区里会把标题列挤到几十像素，标题一个字一行地
                    // 竖排下去。图标按钮约 160px，标题与副标题都放得下。
                    // 详见 `_HeaderActionButton`。
                    actions: [
                      _HeaderActionButton(
                        iconOnly: compact,
                        onPressed: _pickFile,
                        icon: Icons.folder_open,
                        label: t.overview.open_file,
                        filled: true,
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
                      _HeaderActionButton(
                        iconOnly: compact,
                        onPressed: fileState.analysis == null
                            ? null
                            : () => _exportReport(fileState),
                        icon: Icons.description_outlined,
                        label: t.overview.export_report,
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 8 : 18),
                  // Hero 区
                  if (fileState.filePath == null)
                    _buildWelcomeHero(context, compact)
                  else
                    _buildCurrentFilePanel(context, fileState, apkInfo,
                        isParsing, compact, gridHeight),
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
    double gridHeight,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final analysis = fileState.analysis;
    final platform = fileState.platform;
    final isIos = platform == PackagePlatform.ios;

    final filePath = fileState.filePath ?? '';
    final fileName = filePath.isEmpty ? '' : p.basename(filePath);

    final String appName;
    final String identifier;
    final String version;
    final String build;
    final String minSystem;
    final String targetSdk;
    final String executable;
    if (isIos) {
      final ios = analysis?.ios;
      appName = ios?.preferredName.value ?? '';
      identifier = ios?.bundleIdentifier.value ?? '';
      version = ios?.shortVersion.value ?? '';
      build = ios?.buildNumber.value ?? '';
      minSystem = ios?.minimumOSVersion.value ?? '';
      targetSdk = '';
      executable = ios?.executableName.value ?? '';
    } else {
      appName = apkInfo?.label ?? '';
      identifier = apkInfo?.packageName ?? '';
      version = apkInfo?.versionName ?? '';
      build = apkInfo?.versionCode?.toString() ?? '';
      minSystem = apkInfo?.sdkVersion?.toString() ?? '';
      targetSdk = apkInfo?.targetSdkVersion?.toString() ?? '';
      executable = '';
    }

    // 标题优先用解析出来的应用名；还没解析出结果时退回**文件名**。
    //
    // 文件名是事实（用户拖进来的就是它），不是猜测。此前这里在解析期间显示
    // 「未加载文件」，等于把「正在读」说成了「什么都没有」。
    final title = appName.isNotEmpty ? appName : fileName;

    // 架构位数（从 Mach-O / ABI 推断）。
    //
    // 判定只有一份实现（`architectureLabelOf`）—— 详情页的应用信息卡也要
    // 显示同一项，两处各写一遍迟早会分叉。
    final architectureLabel = architectureLabelOf(analysis);

    final (String signatureText, Color signatureColor) =
        _signatureStatus(fileState, analysis, isIos);
    final (String securityText, Color securityColor) =
        _securityStatus(analysis?.security, isParsing);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 16 : 24),
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
                      // 第 1 行：平台 + 「当前文件」+ 架构位数 + **文件路径**
                      //
                      // 路径挂在这一行而不是自己占一行：概览页是**固定一屏**
                      // 布局（见 `_chromeHeightEstimate`），多一行就要从底部
                      // 的「最近文件」里扣 20px，而 1040×800 下那 20px 已经
                      // 是最后一口气（实测 Hero 502px、底栏只剩 30px）。
                      // 这一行本身只有 15px 高，横向还有大量空白 —— 把路径
                      // 放进来是零高度成本，而且「当前文件」旁边正是它该在
                      // 的位置。
                      //
                      // 同时它也**不随窗口高度收起**：路径此前只在「详细信息」
                      // 网格里，而网格在矮窗口下会整块收起 —— 于是「这个包在
                      // 磁盘上哪儿、我要改个名」这个最常见的诉求，恰好在最
                      // 需要它的尺寸下看不见。网格是**可选**补充，路径不是。
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
                          if (architectureLabel != null) ...[
                            const SizedBox(width: 8),
                            ArchBadge(label: architectureLabel),
                          ],
                          if (filePath.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: _FilePathLine(
                                path: filePath,
                                onRename: () => _showRenameDialog(
                                  filePath: filePath,
                                  displayName:
                                      appName.isNotEmpty ? appName : fileName,
                                  versionName: version,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 第 2 行：应用名（可复制）
                      _CopyableLine(
                        text: title,
                        placeholder: t.overview.no_file,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // 第 3 行：标识符（可复制）
                      _CopyableLine(text: identifier, monospace: true),
                      const SizedBox(height: 2),
                      // 第 4 行：版本（可复制）
                      _CopyableLine(
                        text: version.isEmpty
                            ? ''
                            : (build.isEmpty
                                ? 'v$version'
                                : 'v$version ($build)'),
                        placeholder: '-',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                // 操作按钮已移到页头右上角（见上面的 `PageHeader.actions`）。
                // Hero 这里只剩图标 + 身份文字，于是它矮了一大截 ——
                // 固定一屏的概览页因此反而把高度让回给统计与最近文件。
              ],
            ),
          ),
          SizedBox(height: compact ? 14 : 18),
          // 下半：四个状态卡片（值都可复制）
          _buildStatusCards(
            context,
            compact,
            isIos: isIos,
            platformKnown: platform != PackagePlatform.unknown,
            sizeText: RecentFilesManager.formatSize(fileState.fileSize ?? 0),
            signatureText: signatureText,
            signatureColor: signatureColor,
            securityText: securityText,
            securityColor: securityColor,
          ),
          // 状态卡片与详细信息之间的间距。
          //
          // 12 → 10（V2.4.7）：网格项数从最多 8 项收到 6 项之后，**满 6 项**时
          // 这一段仍差 1px 放不下（默认窗口 1040×800 实测溢出 1px）。这一块
          // 的固定开销一直是估算值，网格的真实高度没算进去；按本项目一贯的
          // 做法**动间距、不动内容**。
          SizedBox(height: compact ? 10 : 12),
          // 详细信息：每一项都带复制入口。
          //
          // 之前 Hero 区只有「应用名 / 标识符 / 版本」三行，而用户最常拿去
          // 搜索、比对、贴给别人看的恰恰是哈希、构建号、最低系统这些 ——
          // 它们只能去分析页翻。这里补齐，并保证**每个值都能一键复制**。
          _buildDetailGrid(
            context,
            fileState: fileState,
            minSystem: minSystem,
            targetSdk: targetSdk,
            executable: executable,
            minSystemLabel:
                isIos ? t.overview.field_min_os : t.overview.field_min_sdk,
            maxHeight: gridHeight,
          ),
          if (!compact) ...[
            const SizedBox(height: 10),
            // 拖放提示：原先底部有一张占满宽度的大卡片，去掉后收成这里一行。
            // 窄窗口高度紧张时不显示，把空间留给最近文件列表。
            const _DropHint(),
          ],
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

    // 图标必须是**正方形** —— 真实的 App 图标就是圆角正方形。
    //
    // 外层 Hero 行是按右侧文字列的高度拉伸的（实测 92 宽 × 109 高），如果让
    // 图标跟着拉伸，`BoxFit.contain` 会在上下各留 8.7px 的 `colorScheme.surface`
    // 深色条 —— 用户看到的就是图标外那一圈「黑边」。
    //
    // 所以这里固定成正方形并居中：多出来的高度由 Hero 卡片自己的背景填充，
    // 而不是一个深色的空框。圆角按 iOS 图标的比例给（约 22.4%），比原来写死的
    // 14px（15%）更接近真实图标。
    // 尺寸与圆角取自共享定义（`PackageIconMetrics`）—— 分析页 Hero 卡片与
    // 版本对比槽位用的是同一份，改一处三处一起变。
    final side = compact
        ? PackageIconMetrics.compactHeroSide
        : PackageIconMetrics.heroSide;
    final radius = PackageIconMetrics.radiusOf(side);

    return Center(
      child: SizedBox.square(
        dimension: side,
        child: GestureDetector(
          // 右键打开导出菜单
          onSecondaryTapUp: isIos
              ? (_) => _exportIosIcon(analysis?.ios?.icon)
              : (details) => _showIconExportMenu(
                    context,
                    details.globalPosition,
                    apkInfo,
                  ),
          child: Stack(
            children: [
              Container(
                // 供版式测试定位：断言这个框是**正方形**（见上方注释）。
                key: const ValueKey('overview_hero_icon'),
                width: double.infinity,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(radius),
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
                            // cover 而不是 contain：图块必须被填满。
                            // 源图不是正方形时 contain 会在两侧露出底色，
                            // 又变成一圈「黑边」。
                            fit: BoxFit.cover,
                          )
                        : Center(
                            child: Icon(
                              Icons.android,
                              size: 28,
                              color: theme.hintColor.withValues(alpha: 0.4),
                            ),
                          )),
              ),
              // 导出角标（Android / iOS 都支持）
              if ((isIos && analysis?.ios?.icon != null) ||
                  (!isIos && apkInfo != null))
                Positioned(
                  right: 3,
                  bottom: 3,
                  child: Builder(
                    // 用 `Builder` 拿到**按钮自己**的 context：早先传的是整个
                    // 图标区域的 context，锚点算出来在图标左下角，菜单弹得
                    // 离按钮很远。
                    builder: (btnContext) => Material(
                      color: colorScheme.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(7),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(7),
                        onTap: () => isIos
                            ? _exportIosIcon(analysis?.ios?.icon)
                            : _showIconExportMenu(
                                context,
                                _anchorOf(btnContext),
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
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 取某个 widget 左上角在屏幕上的坐标，用作菜单锚点。
  Offset _anchorOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    return box.localToGlobal(Offset.zero);
  }

  Widget _buildStatusCards(
    BuildContext context,
    bool compact, {
    required bool isIos,
    required bool platformKnown,
    required String sizeText,
    required String signatureText,
    required Color signatureColor,
    required String securityText,
    required Color securityColor,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    // 解析还没出结果时**不能**把平台写成 Android。
    //
    // `FileState.platform` 是由已到位的解析结果派生的，未知就是未知。此前
    // 这里对未知一律渲染成「Android」—— 拖入一个 IPA 的头几秒里，界面会
    // 明确告诉你这是个 Android 包。
    final platformText = isIos ? 'iOS' : (platformKnown ? 'Android' : '—');

    final cards = [
      _StatusCard(
        icon: isIos
            ? Icons.apple
            : (platformKnown ? Icons.android : Icons.help_outline),
        label: t.overview.status_platform,
        value: platformText,
        color: isIos
            ? Colors.grey
            : (platformKnown ? Colors.green : colorScheme.onSurfaceVariant),
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

  /// 弹出重命名对话框（入口在 Hero 的文件路径行上，见 [_FilePathLine]）。
  ///
  /// 对话框本身只有一份实现（`showRenameFileDialog`），与分析页共用 ——
  /// 此前两页各写一个长得不一样的 `AlertDialog`。
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

    // 提示文案三态统一（见 `reportRenameOutcome`）；这里只决定**重新打开**
    // 的方式：概览页留在原地更新状态卡片，不跳分析页。
    final newPath = reportRenameOutcome(context, result);
    if (newPath != null) _openFile(newPath, navigate: false);
  }

  /// 详细信息网格 —— 每个值都能一键复制。
  ///
  /// 用 `Wrap` 而不是手算列数：单元的最小宽度不同（哈希比构建号长得多），
  /// 交给 `Wrap` 决定一行放几个，比在代码里按窗口宽度分支更不容易出错。
  ///
  /// **取不到的字段直接不出现**，不渲染成空串。空串会被读成「这个包没有」，
  /// 而真相是「我们还没读到」—— 那两件事的结论相反。
  ///
  /// [maxHeight] 是这块内容能占的高度。页面是固定一屏的，窗口矮的时候
  /// 网格不能把底部的「最近文件」挤出去 —— 放不下就让网格自己滚动，
  /// 再放不下就整块收起（宁可少显示，也不要显示一半被裁掉）。
  Widget _buildDetailGrid(
    BuildContext context, {
    required FileState fileState,
    required String minSystem,
    required String targetSdk,
    required String executable,
    required String minSystemLabel,
    required double maxHeight,
  }) {
    final theme = Theme.of(context);

    // 「详细信息」这行小标题 + 间距本身就要 26px 左右，留不出这些就别显示了。
    if (maxHeight < 90) return const SizedBox.shrink();

    final hashPlaceholder =
        fileState.isComputingHash ? t.file_info.computing_hash : '';

    final analysis = fileState.analysis;
    final android = analysis?.android;
    final ios = analysis?.ios;

    /// 列表型字段的**条数**。读不到（`absent` / `unsupported` / `failed`）
    /// 时返回 `null` —— 「没读到」不能渲染成 0，那会被读成「一个都没有」。
    String? countOf(FieldValue<List<Object?>>? value) {
      if (value == null || !value.hasValue) return null;
      return '${value.value!.length}';
    }

    final abi = android?.nativeCodes;
    final permissionCount = countOf(android?.permissions);
    final componentCount = countOf(android?.components);
    final deviceFamily = ios?.deviceFamily.hasValue ?? false
        ? DetailRenderer.deviceFamily(ios!.deviceFamily.value, t)
        : null;
    final nestedBundleCount =
        ios == null ? null : '${ios.nestedBinaries.length}';

    // **顺序即优先级** —— 渲染时只取前 `maxDetailCells` 项，见那里的说明。
    //
    // **不重复 Hero 已经显示过的东西**（V2.4.8）：文件名、版本、构建号在
    // Hero 上都有（应用名 / 包名 / `v1.4.1 (14102)` / 完整路径），网格再列
    // 一遍纯属占位。空出来的三格换成「Hero 上没有、但一眼想知道」的：
    // ABI、权限数、组件数（iOS 侧是设备类型、可执行文件、嵌套包数）。
    final cells = <Widget>[
      // 1. 最低系统
      if (minSystem.isNotEmpty)
        _CopyField(label: minSystemLabel, value: minSystem),
      // 2. 目标 SDK（Android）/ 设备类型（iOS）
      if (targetSdk.isNotEmpty)
        _CopyField(label: t.overview.field_target_sdk, value: targetSdk)
      else if (deviceFamily != null && deviceFamily.isNotEmpty)
        _CopyField(label: t.ios_info.device_family, value: deviceFamily),
      // 3. ABI（Android）/ 可执行文件（iOS）
      if (abi != null && abi.hasValue && abi.value!.isNotEmpty)
        _CopyField(label: t.apk_info.abi, value: abi.value!.join(' '))
      else if (executable.isNotEmpty)
        _CopyField(label: t.overview.field_executable, value: executable),
      // 4. 权限数（Android）/ 嵌套包数（iOS）
      if (permissionCount != null)
        _CopyField(
          label: t.overview.field_permission_count,
          value: permissionCount,
        )
      else if (nestedBundleCount != null)
        _CopyField(
          label: t.overview.field_nested_bundle_count,
          value: nestedBundleCount,
        ),
      // 5. 组件数（Android；iOS 没有对应概念，自然不出现）
      if (componentCount != null)
        _CopyField(
          label: t.overview.field_component_count,
          value: componentCount,
        ),
      // 6. 哈希：最常被拿去比对的一项，也是最需要「不用手划选」的一项。
      if (fileState.sha256Hash != null)
        _CopyField(
          label: t.file_info.sha256,
          value: fileState.sha256Hash!,
          monospace: true,
        )
      else if (hashPlaceholder.isNotEmpty)
        _CopyField(
          label: t.file_info.sha256,
          value: hashPlaceholder,
        ),
    ];

    if (cells.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.info_outline, size: 12, color: theme.hintColor),
            const SizedBox(width: 5),
            Text(
              t.overview.field_details,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // 详细信息网格：直接展开，不内部滚动。窗口矮时由最近文件让位。
        LayoutBuilder(
          builder: (context, constraints) {
            // **单元格等宽，列数由可用宽度决定。**
            //
            // 早先给每个单元一个 `maxWidth`，`Wrap` 会把单元撑到那个
            // 上限，于是在 1000px 宽的内容区里一行只放得下一个 ——
            // 十来个字段排成一条竖线，把 Hero 顶到两倍高。
            const spacing = 8.0;
            final width = constraints.maxWidth;
            final columns = width >= 900 ? 3 : (width >= 560 ? 2 : 1);
            final cellWidth = (width - (columns - 1) * spacing) / columns;

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                // 顺序即优先级：超出 `maxDetailCells` 的自然不显示。
                for (final cell in cells.take(OverviewPage.maxDetailCells))
                  SizedBox(width: cellWidth, child: cell),
              ],
            );
          },
        ),
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
    // Android 的签名验证要 apksigner，是**可关闭的设置项**。关掉时显示
    // 「已在设置中关闭」，不要显示「未验证」—— 后者读起来像「验了但没通过」。
    if (!isIos && !Config.enableSignature.value) {
      return (t.overview.sig_disabled, Colors.grey);
    }
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
    // 「没开」与「没跑成」必须分开：前者是用户的设置，后者是结果缺失。
    // 都显示「未检测」的话，用户会以为工具坏了。
    if (!Config.enableSecurityAudit.value) {
      return (t.overview.security_disabled, Colors.grey);
    }
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

  /// 导出 iOS 图标为 PNG。
  ///
  /// 与 Android 侧不同：iOS 图标只有一个候选（最高分辨率），
  /// 因此菜单直接简化为「保存 PNG」。
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
                    onTap: () =>
                        _openFile(recentFiles[i].path, navigate: false),
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
      // 页面是固定一屏的：窗口矮的时候这块会被压到几十像素。图标 + 两行字
      // 大约要 70px，压过头就会在框里溢出（渲染成一条黄黑警示带）。
      // 按可用高度决定画多少，而不是硬撑着画。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showIcon = constraints.maxHeight >= 96;
          final showHint = constraints.maxHeight >= 72;
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showIcon) ...[
                Icon(
                  Icons.history,
                  size: 28,
                  color: theme.hintColor.withValues(alpha: 0.35),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                t.overview.no_recent_files,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor.withValues(alpha: 0.7),
                ),
              ),
              if (showHint) ...[
                const SizedBox(height: 2),
                Text(
                  t.overview.recent_files_hint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ],
          );
        },
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

/// 可复制的单行文本。
///
/// 包名 / Bundle ID / 应用名 / 版本号都是用户最常拿去搜索或比对的字段，
/// 值得给一个显式的复制入口，而不是让用户手动划选。
class _CopyableLine extends StatelessWidget {
  final String text;

  /// 文本为空时显示的占位符。
  final String placeholder;

  /// 文本样式。为空时用 `bodySmall`。
  final TextStyle? style;

  final bool monospace;

  const _CopyableLine({
    required this.text,
    this.placeholder = '-',
    this.style,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = style ?? theme.textTheme.bodySmall;
    final effective = monospace
        ? base?.copyWith(
            color: theme.hintColor,
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
          )
        : base;

    return Row(
      children: [
        Flexible(
          child: SelectableText(
            text.isNotEmpty ? text : placeholder,
            style: effective,
            maxLines: 1,
          ),
        ),
        CopyIconButton(text: text),
      ],
    );
  }
}

/// Hero 区竖排操作按钮的共享封装。
///
/// 窄窗口时自动收紧内边距和字号，防止 Hero 卡片溢出。
/// 概览页页头右上角的动作按钮（位置与版本对比页的「导出对比报告」一致）。
///
/// **窄窗口只显示图标**（`iconOnly`，带 tooltip）：三个带文字的按钮在英文下
/// 实测 570px 宽，660px 的内容区里会把标题列挤到几十像素；三个图标按钮只要
/// 约 160px，标题与副标题都放得下。宽窗口恢复文字，主操作「打开文件」
/// 仍然是显眼的实心按钮。
///
/// 带文字时也用**紧凑尺寸**：默认尺寸三个按钮实测 687px 宽，会把标题列挤到
/// 289px、副标题被省略号截断；紧凑尺寸合计 570px，默认窗口下标题列还有
/// 407px，副标题（英文 378px）完整可见。概览页是固定一屏布局，页头每高一
/// 像素都要从底部「最近文件」里扣，所以这里宁小勿大。
///
/// 样式用**中性的 `ButtonStyle`**（而不是 `OutlinedButton.styleFrom`）：
/// 同一个 style 要同时喂给 `FilledButton.icon` 和 `OutlinedButton.icon`，
/// 用某一家的 `styleFrom` 会把那一家的前景/背景色一起带过去。
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
      // 图标按钮：tooltip 补回被省掉的文字，功能不靠猜。
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
      minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      ),
      textStyle: WidgetStatePropertyAll(
        theme.textTheme.labelMedium?.copyWith(fontSize: 12),
      ),
    );

    final effectiveIcon = Icon(icon, size: 15);
    final effectiveLabel = Text(label);

    if (filled) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: effectiveIcon,
        label: effectiveLabel,
        style: style,
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: effectiveIcon,
      label: effectiveLabel,
      style: style,
    );
  }
}

/// Hero 区里的「文件路径」行：路径 + 复制 + 重命名。
///
/// **为什么用 `Text` 而不是 `SelectableText`**：`SelectableText` 的
/// `maxLines` 只是裁剪，不加省略号 —— 超出的部分根本不会被绘制，而被吃掉的
/// 恰好是路径尾部（也就是文件名）。这里宁可要一个明确的「…」，完整值交给
/// 悬停提示与复制按钮。
///
/// **高度被钉死在 [_lineHeight]。** 这一行挂在「当前文件」那一行上，而那一行
/// 只有 15px 高；`CopyIconButton` / `IconButton` 的**固有高度**是 M3 的 40px
/// 最小点按尺寸（`constraints: BoxConstraints()` 压得住实际布局，压不住
/// `IntrinsicHeight` 量的那个数）。不钉的话整行会被撑高 24px —— 概览页是
/// **固定一屏**布局，实测身份行 96 → 120px，底部「最近文件」立刻溢出。
/// 文案的 `height: 1.1` 是为了让 11px 的行盒落进这个高度，不然会被裁掉
/// 下缘。
///
/// 重命名走与详情页同一套三级回退（[renameFile]）：macOS 沙箱下就地改名
/// 会以 `EPERM` 失败，只能由用户在保存对话框里重新授权目标路径。
class _FilePathLine extends StatelessWidget {
  final String path;

  /// 点重命名时调用；由页面负责弹对话框与执行改名。
  final VoidCallback onRename;

  const _FilePathLine({required this.path, required this.onRename});

  /// 与「当前文件」那一行的文本高度持平，见类文档。
  static const double _lineHeight = 15;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SizedBox(
      height: _lineHeight,
      child: Row(
        children: [
          // 文件夹图标是这一行的语义标识（其余几行靠内容自明：应用名 /
          // 标识符 / 版本）。tooltip 补回被省掉的文字，功能不靠猜。
          Tooltip(
            message: t.overview.field_file_path,
            child:
                Icon(Icons.folder_outlined, size: 12, color: theme.hintColor),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Tooltip(
              message: path,
              child: Text(
                path,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Menlo', 'Courier'],
                  fontSize: 11,
                  // 行盒压到 12.1px，才落得进 _lineHeight（见类文档）。
                  height: 1.1,
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          CopyIconButton(
            text: path,
            tooltip: path,
            iconSize: 13,
            color: colorScheme.primary,
          ),
          Tooltip(
            message: t.rename.rename_file,
            child: IconButton(
              icon: const Icon(Icons.drive_file_rename_outline, size: 13),
              color: colorScheme.primary,
              padding: const EdgeInsets.only(left: 4),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              splashRadius: 13,
              onPressed: onRename,
            ),
          ),
        ],
      ),
    );
  }
}

/// 详细信息网格里的一个字段：标签 + 值 + 复制按钮。
///
/// 值一律用 `SelectableText`（可以手动划选）**并且**给一个复制按钮 ——
/// 哈希这种长串靠划选几乎不可能选全。
///
/// 宽度由调用方决定（`_buildDetailGrid` 按可用宽度等分列），这里不做任何
/// 宽度约束 —— 有约束就会把 `Wrap` 的排布带偏。
class _CopyField extends StatelessWidget {
  final String label;
  final String value;
  final bool monospace;

  const _CopyField({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final valueStyle = monospace
        ? theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
            color: colorScheme.onSurfaceVariant,
          )
        : theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.hintColor,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: valueStyle,
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 4),
              // tooltip 直接显示完整值：单元宽度有限，哈希会被截断，
              // 而截断后的哈希没有任何用。
              CopyIconButton(
                text: value,
                tooltip: value,
                iconSize: 13,
                color: colorScheme.primary,
              ),
            ],
          ),
        ],
      ),
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
///
/// 值同样可复制：窗口矮的时候详细信息网格会收起（页面是固定一屏的），
/// 那几项就不能只剩「看得见、拿不走」。
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
          Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 2),
              CopyIconButton(
                text: value,
                iconSize: 11,
                color: theme.hintColor.withValues(alpha: 0.7),
              ),
            ],
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
///
/// 一行里给出三件事：**真实应用图标**、文件名、平台与体积/时间。
/// 平台此前只靠一个 16px 的通用图标表示（Android 小绿人 / iOS 苹果），
/// 而现在 APK 与 IPA 的图标长得都不一样了 —— 再不给文字标签，用户就没法
/// 一眼分出「这是哪个平台的包」，只能靠认图标。
class _RecentFileTile extends StatelessWidget {
  final RecentFileEntry entry;
  final VoidCallback onTap;

  const _RecentFileTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 平台判断只在这里发生一次：`PlatformTag` 负责「字符串 → 枚举 → 文案与
    // 颜色」，本地不再写 `== 'android'` 这类判断。
    final platform = PlatformTag.fromId(entry.platform).platform;
    final platformColor = PlatformTag.colorOf(platform, theme);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: theme.dividerColor.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              children: [
                _RecentFileIcon(
                  iconFile: entry.iconFile,
                  fallback: switch (platform) {
                    PackagePlatform.android => Icons.android,
                    PackagePlatform.ios => Icons.apple,
                    PackagePlatform.unknown => Icons.insert_drive_file,
                  },
                  fallbackColor: platformColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.fileName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          // 平台是**文字**，不只是颜色 —— 只靠颜色区分在
                          // 色觉障碍下等于没有区分（与详情页同一条约定）。
                          PlatformTag(platform: platform),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '${RecentFilesManager.formatSize(entry.size)}'
                              ' · ${entry.timeAgo()}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.hintColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (entry.platform == null)
                  Icon(
                    Icons.help_outline,
                    size: 14,
                    color: theme.hintColor.withValues(alpha: 0.6),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 最近文件里的应用图标：优先用缓存的真实图标，取不到时退回平台通用图标。
///
/// 缓存是**异步**读的（要解析缓存目录），因此这里必须是一个有状态的组件：
/// 首帧先画通用图标，拿到文件后换上去。缓存命中时这个切换是同一帧内的，
/// 用户看不到闪烁。
class _RecentFileIcon extends StatefulWidget {
  final String? iconFile;
  final IconData fallback;
  final Color fallbackColor;

  const _RecentFileIcon({
    required this.iconFile,
    required this.fallback,
    required this.fallbackColor,
  });

  @override
  State<_RecentFileIcon> createState() => _RecentFileIconState();
}

class _RecentFileIconState extends State<_RecentFileIcon> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _RecentFileIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.iconFile != widget.iconFile) _resolve();
  }

  Future<void> _resolve() async {
    final file = await RecentIconCache.fileFor(widget.iconFile);
    if (!mounted) return;
    if (file?.path == _file?.path) return;
    setState(() => _file = file);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = _file;

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(7),
      ),
      clipBehavior: Clip.antiAlias,
      child: file == null
          ? Center(
              child: Icon(
                widget.fallback,
                size: 16,
                color: widget.fallbackColor,
              ),
            )
          : Image.file(
              file,
              width: 32,
              height: 32,
              // cover：图标本来就是圆角正方形，按原比例居中裁切而不是拉伸。
              fit: BoxFit.cover,
              // 缓存文件可能被外部删掉（或写坏了）—— 那时退回通用图标，
              // 而不是让整个列表报红。
              errorBuilder: (_, __, ___) => Center(
                child: Icon(
                  widget.fallback,
                  size: 16,
                  color: widget.fallbackColor,
                ),
              ),
            ),
    );
  }
}
