import 'package:flutter/material.dart';

/// 四个页面共用的页头：左边标题 + 副标题，右边操作。
///
/// ## 为什么要有这个东西
///
/// 此前四个页面的页头**四种做法**：概览页在 Hero 里用 `titleLarge`
/// 显示当前包名；分析页是 `AppBar` 里的「分析」+ 四个图标动作；版本对比页是
/// 页面内联的一个 `Row`（`headlineSmall` 标题 + 副标题 + 右上角导出按钮）；
/// 设置页是 `AppBar` 里的孤立标题。同一个应用里四个页面四种头部，
/// 用户每切一页都要重新找一遍「标题在哪、按钮在哪」。
///
/// 现在统一成这一份：**左边标题（+副标题），右边操作**。版本对比页本来就是
/// 这个做法（也是用户说要照着做的那一个），把它抽出来给四个页面共用。
///
/// ## 怎么用
///
/// 放进页面滚动内容的最前面（页面自己管 padding），例如：
///
/// ```dart
/// SingleChildScrollView(
///   padding: const EdgeInsets.all(24),
///   child: Column(children: [
///     PageHeader(title: t.nav.overview, subtitle: t.overview.subtitle),
///     ...
///   ]),
/// )
/// ```
///
/// ## 副标题只占一行
///
/// 副标题是一句话说明，**不折行**（窄窗口用省略号截断）。折行会把页头从
/// 58px 撑到 78–98px：概览页是固定一屏布局，页头多出来的每一像素都要从
/// 底部的「最近文件」里扣（实测默认窗口溢 1px、最小窗口溢 16px）。
/// 高度可预期，四个页面的版式才真正一致。
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;

  /// 副标题：一句话说明这一页干什么。可以没有（例如分析页紧跟 Tab 栏）。
  final String? subtitle;

  /// 右上角的操作。空列表时右边不留空隙。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      // 顶部对齐而不是居中：副标题可能折行，居中的话标题会被推着上下动。
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                // 标题也钉成一行：动作区（`Wrap`）在 `Row` 里按**自身固有宽度**
                // 占位，标题列被挤到几十像素时，没有 maxLines 的标题会一个字
                // 一行地竖排下去（实测最小窗口下撑到 282px 高）。
                // 宁可省略号，也不要一列竖排的标题。
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  // 一行到底：见类文档「副标题只占一行」。
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
            ],
          ),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(width: 16),
          // 用 Wrap 而不是 Row：窗口一窄，操作按钮要能换行，
          // 而不是被挤成一团或者溢出（概览页 Hero 原来就吃过这个亏）。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.end,
            children: actions,
          ),
        ],
      ],
    );
  }
}
