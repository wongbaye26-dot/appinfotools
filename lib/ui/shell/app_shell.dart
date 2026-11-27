import 'package:apk_info_tool/pages/home_page.dart';
import 'package:apk_info_tool/pages/install_page.dart';
import 'package:apk_info_tool/pages/setting_page.dart';
import 'package:apk_info_tool/providers/parsed_file_cache.dart';
import 'package:apk_info_tool/ui/diff/diff_page.dart';
import 'package:apk_info_tool/ui/overview/overview_page.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/ui/shell/sidebar.dart';
import 'package:apk_info_tool/ui/shell/v4_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 应用全局外壳（V4 · Paper & Signal）。
///
/// 视觉结构：
/// - 暖纸工作区 + 极淡点阵；
/// - 左侧浮动白色侧边栏（宽 [kSidebarWidth]，可收至 [kSidebarCollapsedWidth]）；
/// - 右侧顶部命令条（位置 / 当前目标状态 / 版本）+ 页面内容。
///
/// 页面仍各自管理 `Scaffold` 与页内 `PageHeader`；外壳只负责 navigational
/// chrome，业务解析、导出、安装流程一行未动。
///
/// 主内容区通过 [IndexedStack] 保持各页面状态，切换时不丢失解析进度。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  // 落地页仍是「概览」：Hero / 拖放 / 最近文件都在这里。
  String _selectedNavId = 'overview';

  /// 用户主动收起侧栏。窄窗口下会强制进入图标栏，不覆盖这个选择。
  bool _collapsed = false;

  static const _pageKeys = [
    'overview',
    'analysis',
    'install',
    'diff',
    'settings'
  ];

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      const OverviewPage(),
      const HomePage(),
      const InstallPage(),
      const DiffPage(),
      const SettingPage(),
    ];

    // 差异页的数据源靠监听解析结果累积；必须在外壳创建时唤醒。
    ref.read(parsedFileCacheProvider);
    ref.read(parsedFileIconsProvider);
  }

  void _onNavSelected(String id) {
    if (_selectedNavId == id) return;
    setState(() {
      _selectedNavId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(shellNavigationProvider, (prev, next) {
      if (prev != null && prev.seq == next.seq) return;
      if (_pageKeys.contains(next.target) && _selectedNavId != next.target) {
        setState(() => _selectedNavId = next.target);
      }
    });

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < kSidebarCompactBreakpoint;
    final collapsed = _collapsed || compact;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: V4DotGridPainter(
                  scheme.onSurface.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.05 : 0.028,
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 22, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppSidebar(
                    selectedId: _selectedNavId,
                    onItemSelected: _onNavSelected,
                    collapsed: collapsed,
                    onToggleCollapsed: compact
                        ? null
                        : () => setState(() => _collapsed = !_collapsed),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      children: [
                        V4TopBar(selectedId: _selectedNavId),
                        const SizedBox(height: 4),
                        Expanded(
                          child: IndexedStack(
                            index: _pageKeys.indexOf(_selectedNavId),
                            children: _pages,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
