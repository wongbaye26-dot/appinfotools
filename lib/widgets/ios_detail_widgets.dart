import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:flutter/material.dart';
import 'package:ipa_parser/ipa_parser.dart' show IosIconResolution;

/// iOS 系统强调色。
///
/// 固定为 iOS 系统蓝（`#007AFF`），**不随应用主题色漂移**。
/// 这是为了让 iOS 页面在视觉上保持平台辨识度。
Color get iosAccent => const Color(0xFF007AFF);

Color _iosAccentBg(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  return brightness == Brightness.dark
      ? const Color(0xFF0A84FF).withValues(alpha: 0.15)
      : const Color(0xFF007AFF).withValues(alpha: 0.08);
}

Color _iosAccentBorder(BuildContext context) {
  final brightness = Theme.of(context).brightness;
  return brightness == Brightness.dark
      ? const Color(0xFF0A84FF).withValues(alpha: 0.3)
      : const Color(0xFF007AFF).withValues(alpha: 0.2);
}

/// iOS 详情页 Hero 卡片。
///
/// 展示应用的大图标、平台徽标、应用名、Bundle ID 和版本号。
/// 作为「应用信息」分组的视觉焦点，替代传统的逐行字段展示。
class IosHeroCard extends StatelessWidget {
  final String appName;
  final String bundleId;
  final String version;
  final String buildNumber;
  final IosIconResolution? icon;

  /// 卡片右侧的附加内容（当前用来放复制 Bundle ID 的按钮）。
  ///
  /// 做成一等参数而不是让调用方在卡片下面再贴一个 `Align` —— 那样复制按钮
  /// 会飘在卡片外的空白里，看起来和这张卡片没关系。
  final Widget? trailing;

  const IosHeroCard({
    super.key,
    required this.appName,
    required this.bundleId,
    required this.version,
    required this.buildNumber,
    this.icon,
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
          color: _iosAccentBorder(context),
          width: 1,
        ),
      ),
      color: _iosAccentBg(context),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 大图标
            Container(
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
                  ? IosIconThumbnail(resolution: icon, size: 72)
                  : Center(
                      child: Icon(
                        Icons.app_shortcut,
                        size: 32,
                        color: theme.hintColor.withValues(alpha: 0.4),
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
                      color: iosAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: iosAccent.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.apple,
                          size: 12,
                          color: iosAccent,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'iOS',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: iosAccent,
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
                  // Bundle ID（等宽字体）
                  SelectableText(
                    bundleId,
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
                      version.isNotEmpty
                          ? (buildNumber.isNotEmpty
                              ? 'v$version ($buildNumber)'
                              : 'v$version')
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

/// iOS 风格信息卡片。
///
/// 圆角 10、淡蓝底、细边框、标题小字淡化、标识符等宽。
/// 用于展示 Bundle ID、Team ID、UUID 等标识符类信息。
class IosInfoCard extends StatelessWidget {
  final String title;
  final String value;
  final bool isIdentifier;
  final Widget? trailing;

  const IosInfoCard({
    super.key,
    required this.title,
    required this.value,
    this.isIdentifier = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: _iosAccentBorder(context),
          width: 1,
        ),
      ),
      color: _iosAccentBg(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题（小字淡化）
                  Text(
                    title,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 值（标识符用等宽）
                  SelectableText(
                    value.isNotEmpty ? value : '-',
                    style: isIdentifier
                        ? theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                            fontFamilyFallback: const ['Menlo', 'Courier'],
                          )
                        : theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// iOS 签名状态徽章。
///
/// 用颜色编码展示签名验证结果：
/// - 通过：绿色
/// - 失败：红色
/// - 未执行：灰色
class IosSignatureBadge extends StatelessWidget {
  final bool? verified;

  const IosSignatureBadge({super.key, this.verified});

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
