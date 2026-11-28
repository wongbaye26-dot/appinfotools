import 'package:flutter/material.dart';

/// 分析页的空态 / 加载态 / 失败态面板。
///
/// 这是页面级状态，不是详情卡片：没有结果时不应该渲染一屏 `-`，因为那会把
/// 「没有解析」误读成「包里没有这项信息」。面板只负责把状态和下一步动作讲
/// 清楚，具体详情由页面在 [AnalysisPageStatus.success]/[partial] 时渲染。
class AnalysisStatePanel extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool loading;

  const AnalysisStatePanel({
    super.key,
    required this.title,
    required this.body,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 30),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: colors.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.outlineVariant),
                ),
                alignment: Alignment.center,
                child: loading
                    ? const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.6),
                      )
                    : Icon(
                        icon ?? Icons.info_outline,
                        size: 28,
                        color: colors.onSurfaceVariant,
                      ),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: 19,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: Icon(
                    loading ? Icons.close : Icons.folder_open,
                    size: 18,
                  ),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 有结果、但部分数据没解析出来时的页面级提示。
///
/// 与 `ManifestPartialBanner` 的关系：那个更具体、只说明清单；这个说明整个
/// 页面处于 [AnalysisPageStatus.partial]，并给出重试入口。详情里的具体缺口
/// 仍由各自的卡片解释，不在这里重复。
class AnalysisPartialBanner extends StatelessWidget {
  final String title;
  final String body;
  final String retryLabel;
  final VoidCallback? onRetry;

  const AnalysisPartialBanner({
    super.key,
    required this.title,
    required this.body,
    required this.retryLabel,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.tertiary.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.incomplete_circle_outlined,
            color: colors.onSecondaryContainer,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
                ),
              ],
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: Text(retryLabel),
            ),
        ],
      ),
    );
  }
}
