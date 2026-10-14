import 'dart:ui' as ui;

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';

/// Android 系统强调色。
///
/// 固定为 Material Green（`#4CAF50`），**不随应用主题色漂移**。
/// 这是为了让 Android 页面在视觉上保持平台辨识度。
Color get androidAccent => const Color(0xFF4CAF50);

Color _androidAccentBg(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  return brightness == Brightness.dark
      ? const Color(0xFF4CAF50).withValues(alpha: 0.12)
      : const Color(0xFF4CAF50).withValues(alpha: 0.08);
}

Color _androidAccentBorder(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  return brightness == Brightness.dark
      ? const Color(0xFF4CAF50).withValues(alpha: 0.3)
      : const Color(0xFF4CAF50).withValues(alpha: 0.2);
}

/// Android 详情页 Hero 卡片。
///
/// 展示应用的大图标、平台徽标、应用名、包名和版本号。
/// 作为「应用信息」分组的视觉焦点，替代传统的逐行字段展示。
class AndroidHeroCard extends StatelessWidget {
  final String appName;
  final String packageName;
  final String versionName;
  final String versionCode;
  final ui.Image? icon;

  /// 图标区域的右键回调。
  ///
  /// 候选图标切换与图标导出原先挂在「版本栏那张独立图标卡」上；图标去重后
  /// 只剩 Hero 卡片这一处，能力因此挪到这里，避免去重的同时丢功能。
  final void Function(Offset globalPosition)? onIconSecondaryTapUp;

  /// 卡片右侧的附加内容（当前用来放复制包名的按钮）。
  ///
  /// 做成一等参数而不是让调用方在卡片下面再贴一个 `Align` —— 那样复制按钮
  /// 会飘在卡片外的空白里，看起来和这张卡片没关系。
  final Widget? trailing;

  const AndroidHeroCard({
    super.key,
    required this.appName,
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    this.icon,
    this.onIconSecondaryTapUp,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: _androidAccentBorder(context),
          width: 1,
        ),
      ),
      color: _androidAccentBg(context),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 大图标
            GestureDetector(
              onSecondaryTapUp: onIconSecondaryTapUp == null
                  ? null
                  : (details) => onIconSecondaryTapUp!(details.globalPosition),
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: icon != null
                    ? RawImage(image: icon, fit: BoxFit.contain)
                    : Center(
                        child: Icon(
                          Icons.android,
                          size: 32,
                          color: theme.hintColor.withValues(alpha: 0.4),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 16),
            // 应用信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 平台徽标
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: androidAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: androidAccent.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.android,
                          size: 12,
                          color: androidAccent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Android',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: androidAccent,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 应用名
                  Text(
                    appName.isNotEmpty ? appName : '-',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // 包名（等宽字体）
                  SelectableText(
                    packageName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Menlo', 'Courier'],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 版本号
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      versionName.isNotEmpty
                          ? (versionCode.isNotEmpty
                              ? 'v$versionName ($versionCode)'
                              : 'v$versionName')
                          : '-',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Android 签名状态徽章。
///
/// 用颜色编码展示签名验证结果：
/// - 通过：绿色
/// - 失败：红色
/// - 未执行：灰色
class AndroidSignatureBadge extends StatelessWidget {
  final bool? verified;

  const AndroidSignatureBadge({super.key, this.verified});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;

    final (label, color, bgColor) = switch (verified) {
      true => (
          t.signature.status_verified,
          Colors.green,
          Colors.green.withValues(alpha: 0.1),
        ),
      false => (
          t.signature.status_failed,
          Colors.red,
          Colors.red.withValues(alpha: 0.1),
        ),
      null => (
          t.signature.status_tool_unavailable,
          theme.hintColor,
          theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
