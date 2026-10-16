import 'package:flutter/material.dart';

/// 架构位数徽章：`64-bit` / `32-bit` / `64/32-bit`。
///
/// 值由 `architectureLabelOf` 从**文件里的真实结构**推断（Mach-O 镜像的段
/// 位数 / 容器里的 ABI 名），取不到时调用方不渲染这个徽章 —— 不猜。
///
/// 概览页的 Hero、分析页的应用信息卡、版本对比的槽位都显示同一项，因此样式
/// 只有这一份实现。此前它是概览页里一个私有的 `_ArchChip`，别处想用只能再抄
/// 一遍。
class ArchBadge extends StatelessWidget {
  final String label;

  final double fontSize;

  const ArchBadge({super.key, required this.label, this.fontSize = 10});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: colorScheme.primary,
        ),
      ),
    );
  }
}
