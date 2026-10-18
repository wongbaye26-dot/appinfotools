import 'package:apk_info_tool/widgets/detail_tab_view.dart';
import 'package:flutter/material.dart';

/// 详情页里一个章节的标题。
///
/// ## 为什么从 `info_page` 提到这里
///
/// 它原先是 `info_page` 的私有类 `_SectionHeader`。详情页要做成「文档流」
/// 之后，[DetailTabView] 必须能认出「这一项是标题」—— 否则会在标题与
/// 内容之间也画一条分隔线，与标题自带的渐变线叠成双线。
///
/// 判断类型需要类型可见，所以提出来成为公开组件。顺带让 iOS 侧也能复用
/// 同一份标题排版，而不是各写一条竖条。
class DetailSectionHeader extends StatelessWidget {
  final String title;

  /// 这个标题之后的内容属于哪个 Tab。
  ///
  /// 只有**第一个**标题需要填：`info_page` 用它把后续卡片分到对应的 Tab 里
  /// （见 `_groupCardsByTab`）。为 `null` 表示「沿用当前 Tab」。
  final DetailTab? tab;

  const DetailSectionHeader({super.key, required this.title, this.tab});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      // 上方留白比下方大：标题与**上一节内容**要拉开，与本节第一行要紧。
      // 这个不对称是「章节感」的来源；两边一样宽时会像普通字段行。
      padding: const EdgeInsets.only(top: 22, bottom: 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              color: colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 9),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: colorScheme.primary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    colorScheme.primary.withValues(alpha: 0.18),
                    colorScheme.primary.withValues(alpha: 0.02),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情页内容区的「文档流」主题。
///
/// ## 它解决的问题
///
/// 详情页此前是「一个字段一张 `Card`」—— 35 处 `Card(child: TitleValueLayout(...))`。
/// 每个 `Card` 自带 4px 外边距、圆角边框与表面色，于是屏幕上是一列
/// **互不相连的小盒子**，扫读时视线要不断跨越边框，读起来像清单而不像报告。
///
/// 这里在**不修改调用点**的前提下把卡片改成：
///
/// - `color: transparent` —— 与页面同底，盒子消失；
/// - `elevation: 0` / `side: none` —— 无阴影、无边框；
/// - `margin: EdgeInsets.zero` —— 去掉卡片的 4px 外边距，
///   行与行之间只剩 [TitleValueLayout] 自己的 `vertical: 8`，
///   分隔线由 [DetailTabView] 统一画。
///
/// 用主题覆盖而不是逐个改 43 处调用点：那些 `Card` 也服务于「这张卡要突出」
/// 的场合（Hero 卡、安全发现卡），逐个改会把两类语义压平。
ThemeData detailDocumentTheme(ThemeData base) {
  return base.copyWith(
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide.none,
      ),
    ),
  );
}

/// 内容区里两项之间的细分割线。
///
/// 比 `Divider` 更淡、更短：报告里的表格线是**提示**而不是**边界**。
class DetailRowDivider extends StatelessWidget {
  const DetailRowDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 1,
        color: theme.dividerColor.withValues(alpha: 0.12),
      ),
    );
  }
}
