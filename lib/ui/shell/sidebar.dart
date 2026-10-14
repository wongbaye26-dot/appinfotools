import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/ui/shell/navigation_item.dart';
import 'package:flutter/material.dart';

/// 应用侧边栏导航组件。
///
/// 响应式行为：
/// - 宽窗口（>= 800px）：240px 展开模式，显示图标 + 文字标签
/// - 窄窗口（< 800px）：64px 紧凑模式，仅显示图标，Tooltip 显示标签
///
/// 包含：
/// - Logo / 应用名称区域
/// - 导航项列表（可点击切换）
/// - 底部操作区（平台图标 + 版本号）
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

  /// 版本号文本，处理未初始化的情况（如单元测试）。
  static String _versionText() {
    try {
      return 'v${packageInfo.version}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 800;
        return isCompact
            ? _CompactSidebar(
                selectedId: selectedId,
                onItemSelected: onItemSelected,
              )
            : _ExpandedSidebar(
                selectedId: selectedId,
                onItemSelected: onItemSelected,
              );
      },
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
      width: 240,
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
          // 底部
          Padding(
            padding: const EdgeInsets.all(16.0),
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

  Widget _buildExpandedLogo(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 16, 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.inventory_2,
              size: 20,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'Package Inspector',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                    fontSize: 11,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 24, 14, 16),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.inventory_2,
                size: 20,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
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
          // 底部（仅版本号，竖排）
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
