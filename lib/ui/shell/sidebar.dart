import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/ui/shell/navigation_item.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:flutter/material.dart';

/// 侧边栏展开宽度（V4：浮动白面板）。
///
/// V4 的视觉需要比旧版更宽的品牌区与更舒展的导航项；同时仍要给内容区留下
/// 足够空间。窗口窄于 [compactBreakpoint] 时改用 [_compactWidth] 图标栏。
const double kSidebarWidth = 232;

/// 收起后的图标栏宽度。
const double kSidebarCollapsedWidth = 76;

/// 展开 / 收起的窗口宽分界。
const double kSidebarCompactBreakpoint = 900;

/// V4 浮动侧边栏。
///
/// 只负责导航与品牌展示，不持有业务状态。收起状态由 [AppShell] 管理，因此
/// 键盘 / 按钮触发的状态变化只有一处来源。
class AppSidebar extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onItemSelected;

  /// 是否处于图标栏状态。
  final bool collapsed;

  /// 点击收起 / 展开按钮。为 null 时不显示按钮（便于独立测试）。
  final VoidCallback? onToggleCollapsed;

  const AppSidebar({
    super.key,
    required this.selectedId,
    required this.onItemSelected,
    this.collapsed = false,
    this.onToggleCollapsed,
  });

  /// 版本号文本。`packageInfo` 未初始化时（单元测试）返回空串，不抛。
  static String versionText() {
    try {
      return 'v${packageInfo.version}';
    } catch (_) {
      return '';
    }
  }

  /// 展开 / 紧凑的分界（窗口宽）。
  static const double compactBreakpoint = kSidebarCompactBreakpoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = collapsed ? kSidebarCollapsedWidth : kSidebarWidth;
    final dark = theme.brightness == Brightness.dark;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 420),
      curve: const Cubic(0.22, 1.0, 0.36, 1.0),
      width: width,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: dark ? 0.9 : 0.75),
        ),
        boxShadow: [
          BoxShadow(
            color: (dark ? Colors.black : V4Colors.ink)
                .withValues(alpha: dark ? 0.28 : 0.055),
            blurRadius: 34,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment:
              collapsed ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            _buildBrand(context, collapsed: collapsed),
            if (!collapsed)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
                child: Text(
                  'PACKAGE INSPECTOR',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                    letterSpacing: 1.7,
                    fontSize: 8.5,
                  ),
                ),
              ),
            if (collapsed && onToggleCollapsed != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _CollapseButton(
                  collapsed: true,
                  onPressed: onToggleCollapsed!,
                ),
              ),
            const Divider(height: 1, indent: 18, endIndent: 18),
            const SizedBox(height: 12),
            Expanded(
              child: Builder(
                builder: (context) {
                  final items = _orderedItems();
                  return ListView.builder(
                    padding: EdgeInsets.symmetric(
                      horizontal: collapsed ? 10 : 12,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return _V4NavTile(
                        item: item,
                        selected: item.id == selectedId,
                        compact: collapsed,
                        onTap: () => onItemSelected(item.id),
                      );
                    },
                  );
                },
              ),
            ),
            if (!collapsed)
              LayoutBuilder(
                builder: (context, constraints) {
                  // 收起动画过渡期宽度不足时先隐藏，避免一帧 overflow。
                  if (constraints.maxWidth < 120) {
                    return const SizedBox.shrink();
                  }
                  return const Padding(
                    padding: EdgeInsets.fromLTRB(18, 0, 18, 8),
                    child: _SidebarHint(
                      icon: Icons.lock_outline,
                      text: 'LOCAL ONLY',
                      trailing: 'NO UPLOAD',
                    ),
                  );
                },
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                collapsed ? 10 : 18,
                6,
                collapsed ? 10 : 18,
                16,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compactFooter = collapsed || constraints.maxWidth < 180;
                  if (compactFooter) {
                    return Tooltip(
                      message: 'AppInfoTool ${AppSidebar.versionText()}',
                      child: Icon(
                        Icons.info_outline,
                        size: 15,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    );
                  }
                  return Row(
                    children: [
                      Icon(
                        Icons.language,
                        size: 13,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'STATIC INSPECTOR',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                          fontSize: 8,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        AppSidebar.versionText(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                          fontSize: 9,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrand(BuildContext context, {required bool collapsed}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 收起动画的中间宽度可能已经容不下品牌行；按**实际宽**退化成图标，
        // 而不是靠外部 collapsed 单帧切换，避免过渡期 overflow。
        if (collapsed || constraints.maxWidth < 160) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 18, 10, 12),
            child: Tooltip(
              message: t.title,
              child: const AppLogo(size: 34),
            ),
          );
        }
        return _buildExpandedBrand(context, theme, scheme);
      },
    );
  }

  Widget _buildExpandedBrand(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 10, 2),
      child: Row(
        children: [
          const AppLogo(size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.45,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'APPINFOTOOL',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                    letterSpacing: 1.1,
                    fontSize: 8,
                  ),
                ),
              ],
            ),
          ),
          if (onToggleCollapsed != null)
            _CollapseButton(collapsed: false, onPressed: onToggleCollapsed!),
        ],
      ),
    );
  }

  /// 导航固定顺序：概览 / 分析 / 版本对比 / 安装 / 设置。
  ///
  /// 与 `AppNavigation.items()` 的模型解耦，避免为了视觉顺序改动导航数据。
  List<NavigationItem> _orderedItems() {
    final all = AppNavigation.items();
    NavigationItem byId(String id) => all.firstWhere((item) => item.id == id);
    return [
      byId('overview'),
      byId('analysis'),
      byId('history'),
      byId('diff'),
      byId('install'),
      byId('settings'),
    ];
  }
}

class _CollapseButton extends StatelessWidget {
  final bool collapsed;
  final VoidCallback onPressed;

  const _CollapseButton({required this.collapsed, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: collapsed ? '展开侧栏' : '收起侧栏',
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(
              collapsed
                  ? Icons.keyboard_double_arrow_right
                  : Icons.keyboard_double_arrow_left,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _V4NavTile extends StatelessWidget {
  final NavigationItem item;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _V4NavTile({
    required this.item,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 收起动画期间宽度会短暂落在两者之间；按实际宽度切换图标栏布局，
        // 避免「已经窄了但还按展开布局」造成过渡帧 overflow。
        final isCompact = compact || constraints.maxWidth < 80;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
        final radius = BorderRadius.circular(13);

        final tile = Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              borderRadius: radius,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                height: 44,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.10)
                      : Colors.transparent,
                  borderRadius: radius,
                ),
                child: Row(
                  mainAxisAlignment: isCompact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    if (!isCompact)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 260),
                        width: 3,
                        height: selected ? 18 : 0,
                        margin: const EdgeInsets.only(right: 11, left: 5),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    Icon(
                      selected ? item.effectiveIcon : item.icon,
                      size: isCompact ? 20 : 18,
                      color: fg,
                    ),
                    if (!isCompact) ...[
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: selected ? scheme.onSurface : fg,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );

        if (isCompact) {
          return Tooltip(message: item.label, preferBelow: false, child: tile);
        }
        return tile;
      },
    );
  }
}

class _SidebarHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final String trailing;

  const _SidebarHint({
    required this.icon,
    required this.text,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: V4Colors.mint),
          const SizedBox(width: 6),
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 8,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          Text(
            trailing,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 7.5,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
