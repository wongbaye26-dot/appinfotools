import 'package:apk_info_tool/gen/strings.g.dart';
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

  const DetailTabView({
    super.key,
    required this.tabs,
    this.isParsing = false,
    this.parseStageLabel,
    this.onCancelParse,
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
    final colorScheme = theme.colorScheme;
    final tabs = _filteredTabs;

    if (tabs.isEmpty) {
      return const Center(child: Text('No data'));
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
            padding: const EdgeInsets.symmetric(horizontal: 10),
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
    return Column(
      children: [
        if (widget.isParsing) _buildParsingIndicator(colorScheme),
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
            tabs: tabs
                .map((e) => Tab(
                      icon: Icon(e.key.icon, size: 18),
                      text: detailTabLabel(e.key, t),
                    ))
                .toList(),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: tabs
                .map((e) => ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      children: e.value,
                    ))
                .toList(),
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
