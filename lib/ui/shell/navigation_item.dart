import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';

/// 侧边栏导航项的数据模型。
///
/// 与 [Pages] 解耦：导航项是 UI 层的概念，而 [Pages] 是旧版页面标识。
/// 重构期间允许两者独立演进。
@immutable
class NavigationItem {
  final String id;
  final String label;
  final IconData icon;
  final IconData? selectedIcon;

  const NavigationItem({
    required this.id,
    required this.label,
    required this.icon,
    this.selectedIcon,
  });

  IconData get effectiveIcon => selectedIcon ?? icon;
}

/// 内置导航项定义。
///
/// 顺序即侧边栏显示顺序。
///
/// 标签通过 [t.nav] 动态获取以支持 i18n，因此用工厂方法而非 const。
class AppNavigation {
  static NavigationItem overview() => NavigationItem(
        id: 'overview',
        label: t.nav.overview,
        icon: Icons.dashboard_outlined,
        selectedIcon: Icons.dashboard,
      );

  static NavigationItem analysis() => NavigationItem(
        id: 'analysis',
        label: t.nav.analysis,
        icon: Icons.analytics_outlined,
        selectedIcon: Icons.analytics,
      );

  static NavigationItem settings() => NavigationItem(
        id: 'settings',
        label: t.nav.settings,
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      );

  static List<NavigationItem> items() => [
        overview(),
        analysis(),
        settings(),
      ];
}
