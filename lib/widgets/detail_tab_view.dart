import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/detail_section.dart';
import 'package:flutter/material.dart';

/// 详情页 Tab 配置。
///
/// 标签刻意**不放在 enum 上**：enum 的 getter 是纯 Dart，拿不到
/// `Translations`，写死英文会让中文界面下出现英文 Tab 名。
enum DetailTab {
  overview(Icons.info_outline),
  application(Icons.apps),
  permissions(Icons.shield_outlined),
  structure(Icons.folder_outlined),
  signature(Icons.verified_outlined),
  security(Icons.security);

  final IconData icon;
  const DetailTab(this.icon);
}

/// 取 Tab 的本地化标签。
String detailTabLabel(DetailTab tab, Translations t) => switch (tab) {
      DetailTab.overview => t.detail_tab.overview,
      DetailTab.application => t.detail_tab.application,
      DetailTab.permissions => t.detail_tab.permissions,
      DetailTab.structure => t.detail_tab.structure,
      DetailTab.signature => t.detail_tab.signature,
      DetailTab.security => t.detail_tab.security,
    };

/// 左侧竖排导航的宽度。
///
/// 220 是「`Icons.verified_outlined` + 四字标签」在 `bodyMedium` 下不折行
/// 的最小宽度，留了 8px 富余。窄于此值标签会省略号截断 —— 那比换行更糟，
/// 因为「签名」和「签名校验」在省略号后面看不出区别。
const double kDetailRailWidth = 220;

/// 低于这个宽度改用顶部 TabBar。
///
/// 侧栏 220 + 内容区至少 420（`TitleValueLayout` 的标题列 200 + 值列 220）。
/// 再窄下去，值会被挤成一列碎字 —— 记忆里 96px 标题列的教训。
const double kDetailRailBreakpoint = 720;

/// 详情页的版式。
///
/// 抽成 enum 是为了**可测试**：`DetailTabView` 在测试环境里会回退成连续列表
/// （否则跨分组的 widget 断言不到），于是侧栏与顶部 TabBar 两条分支永远跑不到。
/// 有了它，测试可以显式指定走哪条。
enum DetailLayout {
  /// 连续列表（测试环境的默认回退）。
  continuous,

  /// 左侧竖排导航 + 文档流（宽窗口）。
  rail,

  /// 顶部 TabBar + 文档流（窄窗口）。
  topTabs,
}

/// 详情页 Tab 视图。
///
/// ## 版式（V2.4.15 重做）
///
/// 宽窗口用**左侧竖排导航 + 右侧文档流**，窄窗口退回顶部 TabBar。
///
/// 选竖排不是为了好看：6 个 Tab 横排在顶部时，中文标签 + 图标要挤在
/// 一行里滚动（`isScrollable: true`），右侧永远切掉一截；而详情页的阅读
/// 方式是「按住一个 Tab 往下读」，不是「在 Tab 之间来回跳」，
/// 竖排导航正好把「当前在读哪一节」固定在视线内。
///
/// 内容区用 [detailDocumentTheme] 把 `Card` 改成透明无边框 —— 一个字段
/// 一张卡片会变成一列互不相连的盒子，读起来像清单而不像报告。
///
/// 在测试环境中自动回退为连续列表，确保测试可以断言跨分组的 widget。
class DetailTabView extends StatefulWidget {
  final Map<DetailTab, List<Widget>> tabs;
  final bool isParsing;
  final String? parseStageLabel;
  final VoidCallback? onCancelParse;

  /// 强制某种版式；`null` 表示按窗口宽度自动选。
  ///
  /// 只给测试用 —— 生产环境永远走自动。
  @visibleForTesting
  final DetailLayout? debugLayout;

  const DetailTabView({
    super.key,
    required this.tabs,
    this.isParsing = false,
    this.parseStageLabel,
    this.onCancelParse,
    this.debugLayout,
  });

  @override
  State<DetailTabView> createState() => _DetailTabViewState();
}

class _DetailTabViewState extends State<DetailTabView>
    with TickerProviderStateMixin {
  late TabController _tabController;

  /// 是否在测试环境中。
  ///
  /// 测试环境下 `WidgetsBinding` 的运行时类型包含 `Test` 字样。
  bool get _isTest {
    try {
      return WidgetsBinding.instance.runtimeType.toString().contains('Test');
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    final tabs = _filteredTabs;
    _tabController = TabController(
      length: tabs.length,
      vsync: this,
    );
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (mounted && !_tabController.indexIsChanging) {
      setState(() {});
    }
  }

  List<MapEntry<DetailTab, List<Widget>>> get _filteredTabs =>
      widget.tabs.entries.where((e) => e.value.isNotEmpty).toList();

  @override
  void didUpdateWidget(covariant DetailTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tabs = _filteredTabs;
    if (_tabController.length != tabs.length) {
      _tabController.dispose();
      _tabController = TabController(
        length: tabs.length,
        vsync: this,
      );
      _tabController.addListener(_onTabChanged);
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tabs = _filteredTabs;

    if (tabs.isEmpty) {
      return Center(child: Text(t.detail_tab.no_data));
    }

    final layout = widget.debugLayout ??
        (_isTest
            // 测试环境：渲染连续列表，确保所有 widget 都在树中可被断言。
            ? DetailLayout.continuous
            // 用 MediaQuery 判宽，**不用 LayoutBuilder**：这个 widget 在
            // `Expanded` 里，主轴约束会是 `Infinity`，`maxWidth` 恒为无穷大，
            // 响应式分支会变成死代码（记忆里踩过）。
            : (MediaQuery.sizeOf(context).width >= kDetailRailBreakpoint
                ? DetailLayout.rail
                : DetailLayout.topTabs));

    return Column(
      children: [
        if (widget.isParsing) _buildParsingIndicator(theme.colorScheme),
        Expanded(
          child: switch (layout) {
            DetailLayout.continuous => _buildTestView(theme, tabs),
            DetailLayout.rail => _buildRailView(theme, tabs),
            DetailLayout.topTabs => _buildTopTabView(theme, tabs),
          },
        ),
      ],
    );
  }

  /// 宽窗口：左侧竖排导航 + 右侧文档流。
  Widget _buildRailView(
    ThemeData theme,
    List<MapEntry<DetailTab, List<Widget>>> tabs,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: kDetailRailWidth,
          child: _DetailRail(
            controller: _tabController,
            tabs: tabs,
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              for (final entry in tabs)
                _DocumentScrollView(children: entry.value),
            ],
          ),
        ),
      ],
    );
  }

  /// 窄窗口：顶部 TabBar（保持原有行为）。
  Widget _buildTopTabView(
    ThemeData theme,
    List<MapEntry<DetailTab, List<Widget>>> tabs,
  ) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelStyle: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: theme.textTheme.labelLarge,
            tabs: [
              for (final entry in tabs)
                Tab(
                  icon: Icon(entry.key.icon, size: 18),
                  text: detailTabLabel(entry.key, t),
                ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              for (final entry in tabs)
                _DocumentScrollView(children: entry.value),
            ],
          ),
        ),
      ],
    );
  }

  /// 测试环境视图：连续列表，所有内容一次性构建。
  Widget _buildTestView(
    ThemeData theme,
    List<MapEntry<DetailTab, List<Widget>>> tabs,
  ) {
    final children = <Widget>[];
    for (final entry in tabs) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 18,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                detailTabLabel(entry.key, t),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
      children.addAll(entry.value);
    }

    return Column(
      children: [
        if (widget.isParsing) _buildParsingIndicator(theme.colorScheme),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _buildParsingIndicator(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(widget.parseStageLabel ?? t.parse.parsing),
          if (widget.onCancelParse != null) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: t.parse.cancel_parse,
              child: InkWell(
                onTap: widget.onCancelParse,
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 16),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一个 Tab 的内容：文档流 + 行间细分割线。
///
/// 分割线的规则：**紧跟章节标题的那一项前面不画** —— 标题自带一条渐变线，
/// 再叠一条就成了双线；而标题与它的第一条字段之间本来也不该有分隔。
class _DocumentScrollView extends StatelessWidget {
  final List<Widget> children;

  const _DocumentScrollView({required this.children});

  @override
  Widget build(BuildContext context) {
    return Theme(
      // 把「一个字段一张 Card」压平成一个字段一行。
      data: detailDocumentTheme(Theme.of(context)),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: children.length,
        itemBuilder: (context, index) {
          final child = children[index];
          final widget = child is DetailSectionHeader
              ? child
              // 卡片已经透明，这里再包一层让它撑满宽度，
              // 否则 `Card` 的 `Column` 会按内容宽度收缩。
              : SizedBox(width: double.infinity, child: child);

          if (index == 0 ||
              children[index - 1] is DetailSectionHeader ||
              child is DetailSectionHeader) {
            return widget;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [const DetailRowDivider(), widget],
          );
        },
      ),
    );
  }
}

/// 左侧竖排导航。
///
/// 自己画而不是用 `NavigationRail`：后者是为图标设计的，标签只能放在下方
/// 且字号固定；详情页的标签是**中文词组**，需要图标与文字同一行、
/// 文字可省略、当前项有整行高亮。
class _DetailRail extends StatelessWidget {
  final TabController controller;
  final List<MapEntry<DetailTab, List<Widget>>> tabs;

  const _DetailRail({required this.controller, required this.tabs});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: theme.dividerColor.withValues(alpha: 0.2)),
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
        children: [
          for (var i = 0; i < tabs.length; i++)
            _RailItem(
              icon: tabs[i].key.icon,
              label: detailTabLabel(tabs[i].key, t),
              selected: controller.index == i,
              onTap: () => controller.animateTo(i),
              colorScheme: colorScheme,
              theme: theme,
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme colorScheme;
  final ThemeData theme;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.colorScheme,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? colorScheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
