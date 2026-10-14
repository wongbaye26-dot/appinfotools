import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 复制一段文本并给出反馈。
///
/// 抽成函数而不是每个组件各写一遍：复制入口遍布概览页与详情页的每一张卡片，
/// 反馈文案与时长必须一致，否则同一件事在不同页面表现不同。
Future<void> copyToClipboard(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(t.home.copied_content(content: text)),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 统一的小号复制按钮。
///
/// 详情页的每一张字段卡片、概览页的状态卡片与信息网格都用它 —— 尺寸、颜色、
/// 提示文案只在一处定义。图标按钮的默认尺寸是 48px，塞进一行「标题 — 值」
/// 里会把行高撑开一倍，因此这里把 `visualDensity` 与 `constraints` 都收紧。
class CopyIconButton extends StatelessWidget {
  /// 要复制的文本。为空时**不渲染按钮** —— 一个点下去什么也不会发生的
  /// 按钮比没有按钮更糟。
  final String text;

  /// 悬停提示。默认用「复制」。
  final String? tooltip;

  final double iconSize;
  final Color? color;

  const CopyIconButton({
    super.key,
    required this.text,
    this.tooltip,
    this.iconSize = 14,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip ?? t.home.copy_content,
      child: IconButton(
        iconSize: iconSize,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.only(left: 4),
        constraints: const BoxConstraints(),
        splashRadius: iconSize,
        icon: Icon(
          Icons.content_copy,
          size: iconSize,
          color: color ?? theme.hintColor,
        ),
        onPressed: () => copyToClipboard(context, text),
      ),
    );
  }
}
