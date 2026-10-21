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

  /// 安装页。
  ///
  /// 排在「分析」之后、「对比」之前：它和分析一样是「拿到一个包之后的下一步」，
  /// 而且比版本对比更常用。
  ///
  /// 这个导航项**曾经被删掉过**（当时对应的 `APKInstallPage` 只是个「开发中」
  /// 占位，点进去什么也做不了）。现在它是真的能装 —— 选包、USB/无线连设备、
  /// 安装都在这一页完成。
  static NavigationItem install() => NavigationItem(
        id: 'install',
        label: t.nav.install,
        icon: Icons.install_mobile_outlined,
        selectedIcon: Icons.install_mobile,
      );

  /// 版本差异页。
  ///
  /// 排在「分析」之后、「设置」之前：它是分析的下游动作（先解析两个包，
  /// 再比较），放在设置前面才符合「常用功能靠上」的顺序。
  static NavigationItem diff() => NavigationItem(
        id: 'diff',
        label: t.nav.diff,
        icon: Icons.compare_arrows_outlined,
        selectedIcon: Icons.compare_arrows,
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
        install(),
        diff(),
        settings(),
      ];
}
