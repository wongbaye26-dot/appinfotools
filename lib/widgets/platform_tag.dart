import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:flutter/material.dart';

/// 平台标签：文字 + 颜色的小徽章。
///
/// **文字是主要载体，颜色只是让它更容易被扫到。** 只靠颜色区分平台，在色觉
/// 障碍下等于没有区分 —— 这条约定在详情页已经写过一次，这里把它做成唯一实现，
/// 免得「最近文件」与「版本对比」各写一版、各自漂移。
///
/// `Android` / `iOS` 是产品名，**不翻译**（与概览页统计卡片上的写法一致）；
/// 未知平台显示 `—`，不猜。
class PlatformTag extends StatelessWidget {
  final PackagePlatform platform;

  /// 字号。列表行用 10，卡片里可以放大一点。
  final double fontSize;

  const PlatformTag({
    super.key,
    required this.platform,
    this.fontSize = 10,
  });

  /// 从「最近文件」记录里的字符串构造。
  ///
  /// 那边为了 JSON 兼容存的是 `'android'` / `'ios'` / `null`。**只在这一处
  /// 做字符串到枚举的转换** —— 散在各个调用点的 `== 'android'` 写错了编译器
  /// 不会说话。
  factory PlatformTag.fromId(String? id, {double fontSize = 10}) => PlatformTag(
        platform: switch (id) {
          'android' => PackagePlatform.android,
          'ios' => PackagePlatform.ios,
          _ => PackagePlatform.unknown,
        },
        fontSize: fontSize,
      );

  /// 标签文字。
  static String labelOf(PackagePlatform platform) => switch (platform) {
        PackagePlatform.android => 'Android',
        PackagePlatform.ios => 'iOS',
        PackagePlatform.unknown => '—',
      };

  /// 标签颜色。
  static Color colorOf(PackagePlatform platform, ThemeData theme) =>
      switch (platform) {
        PackagePlatform.android => Colors.green,
        PackagePlatform.ios => Colors.grey,
        PackagePlatform.unknown => theme.hintColor,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorOf(platform, theme);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        labelOf(platform),
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
