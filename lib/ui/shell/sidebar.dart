import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/ui/shell/navigation_item.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:flutter/material.dart';

/// 侧边栏展开模式的宽度。
///
/// 240 → 200（V2.4.6）：导航项只有四个、标签最长两个字，240px 里有近一半是
/// 空白，而右侧内容区为此少 40px。200px 装得下「概览 / 分析 / 对比 / 设置」
/// 加图标，且窄窗口的紧凑模式（< 800px）不受影响。
///
/// **改这个常量要连带看**：`main.dart` 的初始窗口宽度（按内容区 1040px 反推）、
/// `overview_layout_test.dart` 里那三档「内容区」尺寸的换算注释。
const double kSidebarWidth = 200;

/// 应用侧边栏导航组件。
///
/// 响应式行为：
/// - 宽窗口（>= 800px）：[kSidebarWidth] 展开模式，显示图标 + 文字标签
/// - 窄窗口（< 800px）：64px 紧凑模式，仅显示图标，Tooltip 显示标签
///
/// 包含：
/// - Logo（**只有 logo**，不再重复应用名与副标题）
/// - 导航项列表（可点击切换）
/// - 底部平台图标
///
/// 应用名与版本号**不在这里显示**：应用名已经在窗口标题栏上，版本号在设置页
/// 有一份 —— 侧边栏再写一遍只是把同一件事说三次，还占掉窄栏里最值钱的纵向
/// 空间。
///
/// 支持明暗模式自动适配。
class AppSidebar extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onItemSelected;

  const AppSidebar({
    super.key,
    required this.selectedId,
    required this.onItemSelected,
  });

  /// 版本号文本。`packageInfo` 未初始化时（单元测试）返回空串，不抛。
  static String _versionText() {
    try {
      return 'v${packageInfo.version}';
    } catch (_) {
      return '';
    }
  }

  /// 展开 / 紧凑的分界（窗口宽）。
  static const double compactBreakpoint = 800;

  @override
  Widget build(BuildContext context) {
    // **判据必须是「窗口宽」，不能是 `LayoutBuilder` 给的约束。**
    //
    // 侧边栏是 `Row` 的非弹性子项，而 `Row` 给非弹性子项的约束是
    // `BoxConstraints(maxHeight: …)` —— **主轴不设上限**。因此
    // `constraints.maxWidth` 恒为 `Infinity`，`< 800` 永远为假：这个响应式
    // 分支此前是**死代码**（实测 `Row` 内 `LayoutBuilder` 看到的是
    // `0.0<=w<=Infinity`）。`MediaQuery` 才是窗口的真实宽度。
    final isCompact = MediaQuery.sizeOf(context).width < compactBreakpoint;
    return isCompact
        ? _CompactSidebar(
            selectedId: selectedId,
            onItemSelected: onItemSelected,
          )
        : _ExpandedSidebar(
            selectedId: selectedId,
            onItemSelected: onItemSelected,
          );
  }
}

/// 展开模式侧边栏（240px，图标 + 文字）。
class _ExpandedSidebar extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onItemSelected;

  const _ExpandedSidebar({
    required this.selectedId,
    required this.onItemSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      width: kSidebarWidth,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          right: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo 区域
          _buildExpandedLogo(context),
          const SizedBox(height: 16),
          // 导航项
          Expanded(
            child: Builder(
              builder: (context) {
                final items = AppNavigation.items();
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _NavItemTile(
                      item: item,
                      isSelected: item.id == selectedId,
                      onTap: () => onItemSelected(item.id),
                      compact: false,
                    );
                  },
                );
              },
            ),
          ),
          // 底部：支持的两个平台 + 版本号。
          //
          // 版本号 V2.4.6 一度去掉、V2.4.7 按用户要求放回**原来的位置**
          // （侧边栏底栏）。它是用户报问题时要报的第一个信息，藏在设置页
          // 里等于没有。
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.android, size: 14, color: theme.hintColor),
                const SizedBox(width: 6),
                Icon(Icons.apple, size: 14, color: theme.hintColor),
                const Spacer(),
                Text(
                  AppSidebar._versionText(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 头部：logo + **应用名（在 logo 右边）**。
  ///
  /// V2.4.6 一度把应用名整块去掉（理由：窗口标题栏上已经有了），V2.4.7 按
  /// 用户要求加回来，但**只留名字那一行**：副标题「应用包分析工具」仍然是
  /// 纯噪音，在 200px 的窄栏里还要多吃一行高度。logo 也从 36 收到 32，
  /// 让「logo + 名字」整体与导航项的左边缘对齐得更好看。
  Widget _buildExpandedLogo(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 16, 6),
      child: Row(
        children: [
          const AppLogo(size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
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

/// 紧凑模式侧边栏（64px，仅图标 + Tooltip）。
class _CompactSidebar extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onItemSelected;

  const _CompactSidebar({
    required this.selectedId,
    required this.onItemSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      width: 64,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          right: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // 简化 Logo（仅图标）
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 24, 14, 16),
            child: AppLogo(size: 36),
          ),
          // 导航项
          Expanded(
            child: Builder(
              builder: (context) {
                final items = AppNavigation.items();
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _NavItemTile(
                      item: item,
                      isSelected: item.id == selectedId,
                      onTap: () => onItemSelected(item.id),
                      compact: true,
                    );
                  },
                );
              },
            ),
          ),
          // 底部：版本号（竖排）。64px 宽的栏里这是唯一放得下的形态，
          // 与展开模式一样是「底栏里的版本号」。
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: RotatedBox(
              quarterTurns: 3,
              child: Text(
                AppSidebar._versionText(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个导航项的可交互瓦片。
///
/// 选中态：左侧 3px 主色指示条 + 背景色填充 + 加粗文字。
/// 非选中态：透明背景 + 常规字重。
///
/// [compact] 为 true 时只显示图标，标签通过 Tooltip 展示。
class _NavItemTile extends StatelessWidget {
  final NavigationItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final bool compact;

  const _NavItemTile({
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final tile = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: isSelected
                  ? colorScheme.primaryContainer.withValues(alpha: 0.6)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment:
                  compact ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                // 左侧选中指示条（紧凑模式下居中显示在顶部）
                if (!compact)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 3,
                    height: isSelected ? 20 : 0,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(2),
                      ),
                    ),
                  ),
                if (!compact) const SizedBox(width: 13),
                // 图标
                Icon(
                  isSelected ? item.effectiveIcon : item.icon,
                  size: 20,
                  color: isSelected
                      ? colorScheme.primary
                      : theme.hintColor.withValues(alpha: 0.8),
                ),
                if (!compact) ...[
                  const SizedBox(width: 12),
                  // 标签
                  Text(
                    item.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected
                          ? colorScheme.primary
                          : theme.textTheme.bodyMedium?.color,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (compact) {
      return Tooltip(
        message: item.label,
        preferBelow: false,
        child: tile,
      );
    }
    return tile;
  }
}
