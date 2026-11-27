import 'package:flutter/material.dart';

/// 一条**信息性**的安全范围说明（不是错误，也不是风险结论）。
///
/// 与 `ManifestPartialBanner` 的区别是语义与颜色：那个表示「清单只解析了
/// 一部分，结果可能不完整」，用 errorContainer；FairPlay 加密不是解析失败，
/// 而是「可执行内容的明文本来就看不到」，用 tertiaryContainer，避免把范围
/// 说明渲染成故障。
class SecurityNoticeBanner extends StatelessWidget {
  final String title;
  final String body;

  const SecurityNoticeBanner({
    super.key,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.tertiary.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, color: colors.onTertiaryContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.onTertiaryContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onTertiaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
