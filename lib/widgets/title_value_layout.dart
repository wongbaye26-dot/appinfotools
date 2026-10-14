import 'package:apk_info_tool/providers/ui_config_provider.dart';
import 'package:apk_info_tool/widgets/copy_icon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一行「标题 — 值」。
///
/// 高度必须**跟着内容走**。`SelectableText` 会把 `maxLines` 当成高度预留：
/// 只给 `maxLines` 而不给 `minLines` 时，一行内容也按 `maxLines` 行高排版
/// （实测 `maxLines=6` 的单行卡片高 136px，补上 `minLines=1` 后 56px）。
/// 默认行数是 6，于是「值只有一行」的卡片会空出五行的空白，而标题因为
/// 交叉轴居中而飘在卡片正中间 —— 看起来像卡片里塞了一行莫名其妙的内容。
///
/// 因此 `minLines` 默认取 1，**不留给调用方**：漏传一次就多出一百多像素的
/// 空白，而漏传是肉眼很难发现、代码评审也很难注意到的。
class TitleValueLayout extends ConsumerWidget {
  final String title;
  final String value;
  final Widget? end;
  final int? minLines;
  final int? maxLines;
  final double? titleWidth;

  /// 历史遗留的开关，**当前没有任何效果**：实现一律用 [SelectableText] 渲染
  /// 值。保留字段是为了不改动 Android 侧二十多处调用点的行为 —— 那些没传
  /// `selectable` 的卡片一旦真的按 `false` 渲染成 [Text]，用户就不能再选中
  /// 复制包名、版本号了。
  final bool selectable;

  final bool singleLine;

  /// 是否在值后面给一个复制按钮。默认给。
  ///
  /// **默认值必须是 true**：项目约定是「每个字段都能快捷复制」，逐个调用点
  /// 去传 `copyable: true` 迟早会漏掉几张卡片 —— 而漏掉的那张在界面上完全
  /// 看不出来，只有用户想复制时才发现。值为空时按钮不渲染（点了也没用）。
  ///
  /// 显式传 `false` 的场景：值本身不是「可复制的事实」，例如一句解释性文案。
  final bool copyable;

  /// 标题与值的样式覆盖。
  ///
  /// iOS 详情页要换一套排版（标题更小更淡、标识符用等宽字体），但**行结构
  /// 必须共用**：另写一份行布局出来，两边迟早会在对齐、留白、可选中这些细节
  /// 上分叉。因此把样式做成可注入的，而不是复制一个组件。
  final TextStyle? titleStyle;
  final TextStyle? valueStyle;

  const TitleValueLayout({
    super.key,
    required this.title,
    required this.value,
    this.end,
    this.minLines,
    this.maxLines,
    this.titleWidth,
    this.selectable = false,
    this.singleLine = false,
    this.copyable = true,
    this.titleStyle,
    this.valueStyle,
  });

  /// 实际传给 [SelectableText] 的 `minLines`。
  ///
  /// 夹紧到 `maxLines` 以内：`SelectableText` 会断言
  /// `minLines <= maxLines`，而调用方把「最大行数」设置调小（设置页允许）
  /// 之后，写死的 `minLines: 1` 加上 `maxLines: 0` 就会直接崩掉。
  int get _resolvedMinLines {
    final requested = minLines ?? 1;
    final max = maxLines;
    if (max == null) return requested;
    return requested > max ? max : requested;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configTitleWidth =
        ref.watch(uiConfigStateProvider.select((value) => value.titleWidth));
    final valueStyle =
        this.valueStyle ?? Theme.of(context).textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        // 值有多行时标题要贴第一行，而不是在整块内容里垂直居中 ——
        // 居中会让标题看起来像内容中间另起的一行。
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题部分
          SizedBox(
            width: titleWidth ?? configTitleWidth,
            child: Text(
              title,
              style: titleStyle ??
                  const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                  ),
            ),
          ),
          const SizedBox(width: 16),
          // 内容部分
          Expanded(
            child: singleLine
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      value,
                      style: valueStyle,
                      minLines: 1,
                      maxLines: 1,
                    ),
                  )
                : SelectableText(
                    value,
                    style: valueStyle,
                    minLines: _resolvedMinLines,
                    maxLines: maxLines,
                  ),
          ),
          if (copyable && value.isNotEmpty) CopyIconButton(text: value),
          if (end != null) ...[
            const SizedBox(width: 8),
            end!,
          ],
        ],
      ),
    );
  }
}
