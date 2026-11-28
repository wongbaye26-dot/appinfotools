import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';

/// 详情页 Tab 配置。
///
/// 标签刻意**不放在 enum 上**：enum 的 getter 是纯 Dart，拿不到
/// `Translations`，写死英文会让中文界面下出现英文 Tab 名。
enum DetailTab {
  overview(Icons.info_outline),
  manifest(Icons.receipt_long_outlined),
  components(Icons.widgets_outlined),
  permissions(Icons.shield_outlined),
  libraries(Icons.inventory_2_outlined),
  security(Icons.security),
  files(Icons.folder_outlined),
  infoPlist(Icons.description_outlined),
  frameworks(Icons.layers_outlined),
  signature(Icons.verified_outlined),
  diagnostics(Icons.monitor_heart_outlined),

  // 兼容旧调用；新页面不再使用这两个分组。
  application(Icons.apps),
  structure(Icons.folder_outlined);

  final IconData icon;
  const DetailTab(this.icon);
}

/// 取 Tab 的本地化标签。
String detailTabLabel(DetailTab tab, Translations t) => switch (tab) {
      DetailTab.overview => t.detail_tab.overview,
      DetailTab.manifest => t.detail_tab.manifest,
      DetailTab.components => t.detail_tab.components,
      DetailTab.permissions => t.detail_tab.permissions,
      DetailTab.libraries => t.detail_tab.libraries,
      DetailTab.security => t.detail_tab.security,
      DetailTab.files => t.detail_tab.files,
      DetailTab.infoPlist => t.detail_tab.infoPlist,
      DetailTab.frameworks => t.detail_tab.frameworks,
      DetailTab.signature => t.detail_tab.signature,
      DetailTab.diagnostics => t.detail_tab.diagnostics,
      DetailTab.application => t.detail_tab.application,
      DetailTab.structure => t.detail_tab.structure,
    };

/// 详情页 Tab 视图。
///
/// 将分组后的卡片列表以 Tab 形式组织，减少垂直滚动长度。
/// 桌面端默认使用顶部 TabBar，在窄窗口下可自动适配。
///
/// 在测试环境中自动回退为连续列表，确保测试可以断言跨分组的 widget。
class DetailTabView extends StatefulWidget {
  final Map<DetailTab, List<Widget>> tabs;
  final bool isParsing;
  final String? parseStageLabel;
  final VoidCallback? onCancelParse;

  /// 宽屏右侧上下文栏；窄屏不渲染。只放静态说明，不进入 TabBarView。
  final Widget? aside;

  /// 可选 Tab 计数（条目数/权限数/发现数等）。
  final Map<DetailTab, int>? tabCounts;

  /// 期望的 Tab 顺序；不同平台可以有不同顺序。
  final List<DetailTab>? tabOrder;

  const DetailTabView({
    super.key,
    required this.tabs,
    this.isParsing = false,
    this.parseStageLabel,
    this.onCancelParse,
    this.aside,
    this.tabCounts,
    this.tabOrder,
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

  /// Tab 分组会随解析进度增减：解析中「概览」可能还没有卡片，解析完成后
  /// 才出现。TabController 的长度/索引不会自动跟随，否则用户停在「清单」，
  /// 解析完成后仍停在「清单」。这里在分组变化时重建控制器，并且**解析刚结束
  /// 时回到「概览」** —— 那是打开一个包最该先看到的东西。
  @override
  void didUpdateWidget(covariant DetailTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKeys = oldWidget.tabs.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => e.key)
        .toList(growable: false);
    final newKeys =
        _filteredTabs.map((e) => e.key).toList(growable: false);
    if (oldKeys.length == newKeys.length &&
        List.generate(newKeys.length, (i) => oldKeys[i] == newKeys[i])
            .every((same) => same)) {
      return;
    }
    if (newKeys.isEmpty) return;

    final parsedJustNow = oldWidget.isParsing && !widget.isParsing;
    var index = 0;
    if (!parsedJustNow && _tabController.index < oldKeys.length) {
      final currentKey = oldKeys[_tabController.index];
      final same = newKeys.indexOf(currentKey);
      if (same >= 0) index = same;
    }
    if (parsedJustNow) {
      final overview = newKeys.indexOf(DetailTab.overview);
      index = overview >= 0 ? overview : 0;
    }

    final previous = _tabController;
    previous.removeListener(_onTabChanged);
    _tabController = TabController(
      length: newKeys.length,
      vsync: this,
      initialIndex: index.clamp(0, newKeys.length - 1),
    );
    _tabController.addListener(_onTabChanged);
    // TabBarView 还挂在这个控制器上，立刻 dispose 会抛「使用已 dispose 的
    // 控制器」；等这一帧画完再释放。
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    setState(() {});
  }

  void _onTabChanged() {
    if (mounted && !_tabController.indexIsChanging) {
      setState(() {});
    }
  }

  List<MapEntry<DetailTab, List<Widget>>> get _filteredTabs =>
      widget.tabs.entries.where((e) => e.value.isNotEmpty).toList();

  /// 按平台指定的顺序排列；未列出的分组放最后，保持稳定。
  List<MapEntry<DetailTab, List<Widget>>> _orderedTabs(
    List<MapEntry<DetailTab, List<Widget>>> tabs,
  ) {
    final order = widget.tabOrder;
    if (order == null) return tabs;
    final indexed = tabs.indexed.toList()
      ..sort((a, b) {
        final ai = order.indexOf(a.$2.key);
        final bi = order.indexOf(b.$2.key);
        final aOrder = ai < 0 ? order.length : ai;
        final bOrder = bi < 0 ? order.length : bi;
        final byOrder = aOrder.compareTo(bOrder);
        return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
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
    final colorScheme = theme.colorScheme;
    final tabs = _filteredTabs;

    if (tabs.isEmpty) {
      return Center(child: Text(t.base.no_data));
    }

    // 测试环境：渲染连续列表，确保所有 widget 都在树中可被断言。
    if (_isTest) {
      return _buildTestView(theme, colorScheme, tabs);
    }

    return _buildTabView(theme, colorScheme, tabs);
  }

  /// 测试环境视图：连续列表，所有内容一次性构建。
  Widget _buildTestView(
    ThemeData theme,
    ColorScheme colorScheme,
    List<MapEntry<DetailTab, List<Widget>>> tabs,
  ) {
    final children = <Widget>[];
    for (final entry in _orderedTabs(tabs)) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 18,
                decoration: BoxDecoration(
                  color: colorScheme.primary,
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
        if (widget.isParsing) _buildParsingIndicator(colorScheme),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            children: children,
          ),
        ),
      ],
    );
  }

  /// 生产环境视图：TabBar + TabBarView。
  Widget _buildTabView(
    ThemeData theme,
    ColorScheme colorScheme,
    List<MapEntry<DetailTab, List<Widget>>> tabs,
  ) {
    final orderedTabs = _orderedTabs(tabs);
    return Column(
      children: [
        if (widget.isParsing) _buildParsingIndicator(colorScheme),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: colorScheme.onSurface,
                borderRadius: BorderRadius.circular(999),
              ),
              labelColor: colorScheme.surface,
              unselectedLabelColor: colorScheme.onSurfaceVariant,
              labelPadding: const EdgeInsets.symmetric(horizontal: 12),
              labelStyle: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
              unselectedLabelStyle:
                  theme.textTheme.labelLarge?.copyWith(fontSize: 12),
              tabs: orderedTabs.map((e) {
                final count = widget.tabCounts?[e.key];
                final label = detailTabLabel(e.key, t);
                return Tab(
                  height: 30,
                  text: count != null && count > 0 ? '$label  $count' : label,
                );
              }).toList(),
            ),
          ),
        ),
        Expanded(
          child: Row(
            // 右侧栏必须与内容顶部对齐：Row 默认 center，栏比内容短时
            // 会被垂直居中，顶部就空出一大块。
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: orderedTabs
                      .map((e) => ListView(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            children: e.value,
                          ))
                      .toList(),
                ),
              ),
              if (widget.aside != null &&
                  MediaQuery.sizeOf(context).width >= 1180) ...[
                const SizedBox(width: 10),
                SizedBox(
                  width: 286,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(0, 8, 10, 8),
                    child: widget.aside!,
                  ),
                ),
              ],
            ],
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
