import 'package:apk_info_tool/pages/home_page.dart';
import 'package:apk_info_tool/pages/setting_page.dart';
import 'package:apk_info_tool/ui/overview/overview_page.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/ui/shell/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 应用全局外壳。
///
/// 桌面端：左侧固定侧边栏（240px）+ 右侧主内容区。
/// 窄窗口（< 600）：侧边栏收叠，通过后续添加的响应式机制处理。
///
/// 采用渐进式重构策略：
/// - Phase 1：侧边栏 + 现有页面（保留各页面的 Scaffold/AppBar）
/// - Phase 3：统一标题栏，移除子页面 AppBar
///
/// 主内容区通过 [IndexedStack] 保持各页面状态，切换时不丢失解析进度。
///
/// 各页面可通过 [ShellNavigation] provider 请求切换导航目标，
/// 无需直接操作 AppShell 的状态。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  // 落地页是「概览」：它承担引导职责（Hero 横幅、快捷操作、拖放区、
  // 最近文件）。早先默认停在「分析」页，用户打开应用看到的是一张空表格。
  String _selectedNavId = 'overview';

  // 「安装」原先在这里占了一个导航项，但对应的 `APKInstallPage` 只是一个
  // 「开发中」占位，点进去什么也做不了 —— 用户要求把没有的功能去掉，
  // 因此连同页面一起移除。真正的安装入口在分析页顶栏（`InstallDialog`）。
  static const _pageKeys = ['overview', 'analysis', 'settings'];

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      const OverviewPage(),
      const HomePage(),
      const SettingPage(),
    ];
  }

  void _onNavSelected(String id) {
    if (_selectedNavId == id) return;
    setState(() {
      _selectedNavId = id;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 监听外部页面发起的导航请求。
    //
    // 判据是**序号是否变化**，而不是 target 是否不同 —— 后者会让
    // 「从概览点前往分析 → 手动切回概览 → 再点前往分析」的第二次失效
    // （目标没变，listener 不触发）。
    ref.listen(shellNavigationProvider, (prev, next) {
      if (prev != null && prev.seq == next.seq) return;
      if (_pageKeys.contains(next.target) && _selectedNavId != next.target) {
        setState(() => _selectedNavId = next.target);
      }
    });

    return Scaffold(
      body: Row(
        children: [
          AppSidebar(
            selectedId: _selectedNavId,
            onItemSelected: _onNavSelected,
          ),
          Expanded(
            child: IndexedStack(
              index: _pageKeys.indexOf(_selectedNavId),
              children: _pages,
            ),
          ),
        ],
      ),
    );
  }
}
