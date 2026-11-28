import 'dart:ui' as ui;

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/providers/parsed_file_cache.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/utils/diff_labels.dart';
import 'package:apk_info_tool/utils/format.dart';
import 'package:apk_info_tool/widgets/export_diff_dialog.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:apk_info_tool/widgets/package_icon_metrics.dart';
import 'package:apk_info_tool/widgets/platform_tag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// 版本差异页（V4 版式，对应 `docs/prototypes/ui-redesign-v4/screens/05-diff.html`）。
///
/// ## 入口形态
///
/// 独立页面，页内选两个文件（`docs/plans/V2.4.0_PROGRESS.md` §17.4-3 的定案）。
/// 不挂在概览页的多选上：概览页是**固定一屏**版式，加多选会挤压既有布局；
/// 而独立页面不动任何现有页面的状态。
///
/// ## 数据从哪来
///
/// **不自己解析文件**。解析流程（任务句柄、阶段回调、取消、代际计数）只存在于
/// 分析页，复制一份出来迟早会对不上 —— 那正是「导入后没反应」这个 bug 的成因。
/// 本页只从 [parsedFileCacheProvider] 里取**已经解析过**的包，因此用户的操作
/// 顺序是「在分析页解析两个包 → 切到本页比较」。
///
/// ## 三态与「说不清」必须分开
///
/// 差异只有四种结局，本页把它们**分成两个区**：
/// - 新增 / 删除 / 变更 → 「字段差异」「集合差异」；
/// - 无法比较（任一侧「我们没读到」）→ 单独一个区，且带原因。
///
/// 把后者并进前者会让「这次说不清」被读成「两边一样」或「新增了一项」——
/// 那正是本项目一直在挡的「没查到 ≠ 没有」。
class DiffPage extends ConsumerStatefulWidget {
  const DiffPage({super.key});

  /// 单个集合里最多列出的成员数。
  ///
  /// 网络域名可以上千条，而本页的集合卡片是一次性构建的（不是懒构建的列表）。
  /// 超出部分**如实标注还有多少条没显示**，而不是静默截断 —— 截断本身不丢
  /// 结论（条数照常显示），但必须让读者知道列表不全。
  static const maxMembersPerList = 200;

  @override
  ConsumerState<DiffPage> createState() => _DiffPageState();
}

/// 摘要条右侧的分段筛选：原型里是纯装饰，这里做成**真的能用** ——
/// 一屏同时铺字段、集合、无法比较三块，窗口小时要滚很久，筛选比装饰有用。
enum _DiffTab { all, fields, sets, unknown }

class _DiffPageState extends ConsumerState<DiffPage> {
  String? _leftPath;
  String? _rightPath;

  /// 用户显式选过、或按过「重新选择」之后，不再自动填「最近两个包」。
  /// 否则「重新选择」刚清空就被自动填回来，按钮看起来像没反应。
  bool _manualPick = false;

  /// 字段表默认只铺前 8 行（原型同款），其余折在页脚按钮后面。
  bool _showAllFields = false;

  _DiffTab _tab = _DiffTab.all;

  static const int _previewRows = 8;

  @override
  Widget build(BuildContext context) {
    final cache = ref.watch(parsedFileCacheProvider);
    final paths = cache.keys.toList();

    // 默认选「最近解析的两个」：用户刚解析完两个版本切过来，就该直接看到结果。
    // 只在**用户没动过**时自动填 —— 否则会把用户的选择覆盖掉。
    var leftPath = _leftPath;
    var rightPath = _rightPath;
    if (!_manualPick &&
        leftPath == null &&
        rightPath == null &&
        paths.length >= 2) {
      leftPath = paths[paths.length - 2];
      rightPath = paths.last;
    }

    // 导出按钮只在「真的有一份可比对的差异」时可点：跨平台、缺一侧、
    // 或两边是同一个包时导出的东西没有意义。
    final pair = _comparablePair(cache, leftPath, rightPath);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(26, 4, 30, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PageHead(
            onReselect: () => setState(() {
              _manualPick = true;
              _leftPath = null;
              _rightPath = null;
            }),
            onExport:
                pair == null ? null : () => _export(pair.left, pair.right),
          ),
          const SizedBox(height: 16),
          if (paths.length < 2)
            _buildNotEnough()
          else ...[
            _buildSlots(cache, leftPath, rightPath),
            const SizedBox(height: 12),
            ..._buildBody(cache, leftPath, rightPath, pair),
          ],
        ],
      ),
    );
  }

  /// 两侧都选好、同平台、且不是同一个包时，返回那一对分析结果。
  ({PackageAnalysisResult left, PackageAnalysisResult right})? _comparablePair(
    Map<String, FileState> cache,
    String? leftPath,
    String? rightPath,
  ) {
    if (leftPath == null || rightPath == null) return null;
    if (leftPath == rightPath) return null;
    final left = cache[leftPath]?.analysis;
    final right = cache[rightPath]?.analysis;
    if (left == null || right == null) return null;
    if (!samePlatform(left, right)) return null;
    return (left: left, right: right);
  }

  Future<void> _export(
    PackageAnalysisResult left,
    PackageAnalysisResult right,
  ) async {
    final result = await showDialog<Object?>(
      context: context,
      builder: (context) => ExportDiffDialog(left: left, right: right),
    );
    if (!mounted) return;
    // 对话框把「取消」返回成 null、成功返回 true、失败返回异常对象 ——
    // 三种情况要分开，否则用户取消一次也会看到「导出失败」。
    if (result == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == true
              ? t.diff.export_success
              : t.diff.export_failed(error: '$result'),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 门槛状态

  /// 缓存里不足两个已解析的包。
  Widget _buildNotEnough() {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    // 收窄并居中：空状态铺满整行会像一条横幅，读起来也不聚拢。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: _V4Card(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 34),
          child: Column(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: pal.violet.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.compare_arrows_rounded,
                  size: 22,
                  color: pal.violet,
                ),
              ),
              const SizedBox(height: 14),
          Text(
            t.diff.pick_empty,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: pal.ink,
            ),
          ),
              const SizedBox(height: 8),
              Text(
                t.diff.need_two,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: pal.ink2),
              ),
              const SizedBox(height: 4),
              Text(
                t.diff.pick_hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: pal.ink3),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => ref
                    .read(shellNavigationProvider.notifier)
                    .navigate('analysis'),
                child: Text(t.diff.go_analysis),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 两个槽

  Widget _buildSlots(
    Map<String, FileState> cache,
    String? leftPath,
    String? rightPath,
  ) {
    final icons = ref.watch(parsedFileIconsProvider);
    return Stack(
      alignment: Alignment.center,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SlotCard(
                isNew: false,
                state: leftPath == null ? null : cache[leftPath],
                // 图标从**图标副本**里取，不取 `state.apkInfo.mainIconImage`：
                // 换文件时 `ApkInfo.dispose()` 会把那个 `ui.Image` 释放掉，先解析
                // 的那个包因此丢图标（实测：左侧槽位只剩平台通用图标）。
                icon: leftPath == null ? null : icons[leftPath],
                // 另一侧已选的文件不再出现在自己的候选里：比较同一个包没有意义，
                // 而它恰恰是「随手一选」最容易选到的那一个。
                excludePath: rightPath,
                cache: cache,
                onPick: (path) => setState(() => _leftPath = path),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _SlotCard(
                isNew: true,
                state: rightPath == null ? null : cache[rightPath],
                icon: rightPath == null ? null : icons[rightPath],
                excludePath: leftPath,
                cache: cache,
                onPick: (path) => setState(() => _rightPath = path),
              ),
            ),
          ],
        ),
        // 中间的圆形箭头：两侧谁是谁，一眼看到方向。
        IgnorePointer(
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _Pal.of(Theme.of(context)).surface,
              shape: BoxShape.circle,
              border: Border.all(color: _Pal.of(Theme.of(context)).line),
            ),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 13,
              color: _Pal.of(Theme.of(context)).violet,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 主体三态

  List<Widget> _buildBody(
    Map<String, FileState> cache,
    String? leftPath,
    String? rightPath,
    ({PackageAnalysisResult left, PackageAnalysisResult right})? pair,
  ) {
    if (pair == null) {
      final left = leftPath == null ? null : cache[leftPath]?.analysis;
      final right = rightPath == null ? null : cache[rightPath]?.analysis;
      if (left == null || right == null) {
        return [_hintCard(t.diff.need_both, Icons.compare_arrows_rounded)];
      }
      // 跨平台比较没有意义：两边的字段集合都不一样，硬比只会显示一堆
      // 「新增 / 删除」。这里明确说清楚，而不是给一张看起来很唬人的表。
      if (!samePlatform(left, right)) {
        return [
          _hintCard(
            t.diff.platform_mismatch,
            Icons.swap_horiz_rounded,
            warn: true,
          ),
        ];
      }
      return [_hintCard(t.diff.need_both, Icons.compare_arrows_rounded)];
    }

    final left = pair.left;
    final right = pair.right;
    final diff = diffOf(left, right);

    // 四态分家：变化归变化，「说不清」单独成区（见类注释）。
    final fieldChanges = diff.fields
        .where((f) => f.kind != DiffKind.same && f.kind != DiffKind.unknown)
        .toList();
    final fieldUnknown =
        diff.fields.where((f) => f.kind == DiffKind.unknown).toList();
    final setChanges =
        diff.sets.where((s) => s.comparable && !s.isSame).toList();
    final setUnknown = diff.sets.where((s) => !s.comparable).toList();
    final unknownCount = fieldUnknown.length + setUnknown.length;
    // 命中规则的 id（`ANDROID-ALLOW-BACKUP`）只在引擎里稳定，界面上要换成人话
    // —— 结论句在 `security.findings` 里，得从两侧结果里建索引。
    final ruleTitles = DiffLabels.findingTitles(left, right, t);

    return [
      _SummaryStrip(
        fieldCount: fieldChanges.length,
        setCount: setChanges.length,
        unknownCount: unknownCount,
        tab: _tab,
        onTab: (next) => setState(() => _tab = next),
      ),
      const SizedBox(height: 14),
      LayoutBuilder(
        builder: (context, constraints) {
          final leftColumn = _buildLeftColumn(
            left: left,
            right: right,
            fieldChanges: fieldChanges,
            fieldUnknown: fieldUnknown,
            setChanges: setChanges,
            setUnknown: setUnknown,
            ruleTitles: ruleTitles,
          );
          final rail = _buildRail(
            left: left,
            right: right,
            fieldUnknown: fieldUnknown,
            setChanges: setChanges,
            setUnknown: setUnknown,
          );
          // 两栏的门槛比原来低（900 而不是 1180）：V4 的左表只有 4 列，
          // 900 就能铺开；再窄就单栏，右栏落到下面。
          if (constraints.maxWidth < 900) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [leftColumn, const SizedBox(height: 14), rail],
            );
          }
          final railWidth = (constraints.maxWidth * 0.28).clamp(300.0, 380.0);
          // 用内容高度而不是等高：左栏带集合差异后会比右栏高很多，
          // 若强制等高把 policy 顶到栏底，它就落到首屏之外了。
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: leftColumn),
              const SizedBox(width: 14),
              SizedBox(width: railWidth, child: rail),
            ],
          );
        },
      ),
      const SizedBox(height: 14),
      _buildFootnote(
        leftVersion: left.version.value,
        rightVersion: right.version.value,
      ),
    ];
  }

  /// 门槛态/说明态的一张卡：图标 + 一句话。
  Widget _hintCard(String text, IconData icon, {bool warn = false}) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return _V4Card(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: warn ? pal.amber : pal.ink3),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: warn ? pal.amber : pal.ink2,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 左栏（表）

  Widget _buildLeftColumn({
    required PackageAnalysisResult left,
    required PackageAnalysisResult right,
    required List<FieldDiff> fieldChanges,
    required List<FieldDiff> fieldUnknown,
    required List<SetDiff> setChanges,
    required List<SetDiff> setUnknown,
    required Map<String, String> ruleTitles,
  }) {
    final showFields = _tab == _DiffTab.all || _tab == _DiffTab.fields;
    final showSets = _tab == _DiffTab.all || _tab == _DiffTab.sets;
    final showUnknown = _tab == _DiffTab.all || _tab == _DiffTab.unknown;
    if (!(showFields && fieldChanges.isNotEmpty) &&
        !(showSets && setChanges.isNotEmpty) &&
        !(showUnknown && (fieldUnknown.isNotEmpty || setUnknown.isNotEmpty))) {
      return _hintCard(t.diff.summary_same, Icons.check_circle_outline_rounded);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showFields && fieldChanges.isNotEmpty) ...[
          _FieldTableCard(
            left: left,
            right: right,
            changes: fieldChanges,
            showAll: _showAllFields,
            previewRows: _previewRows,
            onToggle: () =>
                setState(() => _showAllFields = !_showAllFields),
          ),
          const SizedBox(height: 14),
        ],
        if (showSets && setChanges.isNotEmpty) ...[
          _SetTableCard(changes: setChanges, ruleTitles: ruleTitles),
          const SizedBox(height: 14),
        ],
        if (showUnknown && (fieldUnknown.isNotEmpty || setUnknown.isNotEmpty))
          _UnknownCard(
            fields: fieldUnknown,
            sets: setUnknown,
            ruleTitles: ruleTitles,
          ),
      ],
    );
  }

  // -------------------------------------------------------------- 右栏（rail）

  Widget _buildRail({
    required PackageAnalysisResult left,
    required PackageAnalysisResult right,
    required List<FieldDiff> fieldUnknown,
    required List<SetDiff> setChanges,
    required List<SetDiff> setUnknown,
  }) {
    final addedOf = <String, int>{
      for (final s in setChanges) s.id: s.added.length,
    };
    final dexLeft = left.android?.structure?.dexFileCount;
    final dexRight = right.android?.structure?.dexFileCount;
    // 「多出来的」只取正差：少了一个 DEX 不是「新增」，也不是安全线索。
    final addedDex = (dexLeft != null && dexRight != null && dexRight > dexLeft)
        ? dexRight - dexLeft
        : 0;
    final addedPerms = addedOf['android.permissions'] ?? 0;
    final addedAbi = addedOf['android.nativeCodes'] ?? 0;
    final addedFindings = addedOf['security.findings'] ?? 0;

    final findings = _setOf(setChanges, 'security.findings');
    final findingsLeft =
        findings == null ? null : findings.common.length + findings.removed.length;
    final findingsRight =
        findings == null ? null : findings.common.length + findings.added.length;

    final unknownCount = fieldUnknown.length + setUnknown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryCard(
          packageSame: _samePackage(left, right),
          addedDex: addedDex,
          addedPerms: addedPerms,
          addedAbi: addedAbi,
          findingsLeft: findingsLeft,
          findingsRight: findingsRight,
          addedFindings: addedFindings,
        ),
        const SizedBox(height: 12),
        if (unknownCount > 0) ...[
          _UnknownNoticeCard(
            count: unknownCount,
            fieldCount: fieldUnknown.length,
            setCount: setUnknown.length,
          ),
          const SizedBox(height: 12),
        ],
        if (addedDex > 0 || addedPerms > 0 || addedAbi > 0) ...[
          _ChecklistCard(
            addedDex: addedDex,
            addedPerms: addedPerms,
            addedAbi: addedAbi,
          ),
          const SizedBox(height: 12),
        ],
        const _PolicyCard(),
      ],
    );
  }

  // -------------------------------------------------------------- 摘要条等

  Widget _buildFootnote({
    String? leftVersion,
    String? rightVersion,
  }) {
    final pal = _Pal.of(Theme.of(context));
    final from = leftVersion ?? '—';
    final to = rightVersion ?? '—';
    return Row(
      children: [
        Expanded(
          child: Text(
            '${_P.footnoteBrand} / $from → $to',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _mono(pal.ink3, size: 9, spacing: 0.5, height: 1.2),
          ),
        ),
        Text(
          _P.footnoteMeta,
          style: _mono(pal.ink3, size: 9, spacing: 0.5, height: 1.2),
        ),
      ],
    );
  }

  static bool _samePackage(PackageAnalysisResult a, PackageAnalysisResult b) {
    final l = a.packageId.value;
    final r = b.packageId.value;
    return l != null && l.isNotEmpty && l == r;
  }

  static SetDiff? _setOf(List<SetDiff> sets, String id) {
    for (final s in sets) {
      if (s.id == id) return s;
    }
    return null;
  }
}

// ============================================================== 页头

class _PageHead extends StatelessWidget {
  final VoidCallback onReselect;
  final VoidCallback? onExport;

  const _PageHead({required this.onReselect, required this.onExport});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 眉标：原型在页内也印一遍（外壳顶栏那条只标分组）。
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.diff.kicker_root,
                    style: _mono(
                      pal.ink3,
                      size: 9,
                      weight: FontWeight.w700,
                      spacing: 1.6,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '/',
                    style: _mono(pal.ink3.withValues(alpha: 0.6),
                        size: 9, spacing: 1.2, height: 1.2),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    t.diff.kicker_leaf,
                    style: _mono(
                      pal.violet,
                      size: 9,
                      weight: FontWeight.w700,
                      spacing: 1.6,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                t.diff.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                  height: 1.05,
                  color: pal.ink,
                ),
              ),
              const SizedBox(height: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 630),
                child: Text(
                  t.diff.subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: pal.ink3,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 20),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: onReselect,
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: Text(t.diff.reselect),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  foregroundColor: pal.ink2,
                  side: BorderSide(color: pal.line),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                  textStyle: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: onExport,
                icon: const Icon(Icons.download_rounded, size: 15),
                label: Text(t.diff.export_action),
                style: FilledButton.styleFrom(
                  backgroundColor: pal.ink,
                  foregroundColor: pal.surface,
                  disabledBackgroundColor: pal.ink.withValues(alpha: 0.10),
                  disabledForegroundColor: pal.ink3,
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                  textStyle: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================== 槽位

/// 一个文件槽：显示已选的包，或「选择应用包」。
class _SlotCard extends StatelessWidget {
  final bool isNew;
  final FileState? state;

  /// 该包的图标副本（Android 侧）；`null` 时退回平台通用图标。
  final ui.Image? icon;

  final String? excludePath;
  final Map<String, FileState> cache;
  final ValueChanged<String> onPick;

  const _SlotCard({
    required this.isNew,
    required this.state,
    required this.icon,
    required this.excludePath,
    required this.cache,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    final analysis = state?.analysis;
    final isIos = analysis?.platform == PackagePlatform.ios;

    return _V4Card(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      // 右侧槽位用强调色描边：新版本是「要看的那个」。
      borderColor: isNew ? pal.violet.withValues(alpha: 0.28) : pal.line,
      child: InkWell(
        onTap: () => _pick(context),
        borderRadius: BorderRadius.circular(18),
        child: Row(
          children: [
            if (state == null || analysis == null)
              Icon(Icons.add_circle_outline_rounded,
                  size: 30, color: pal.ink3)
            else
              _SlotIcon(state: state!, icon: icon, isIos: isIos, side: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state == null || analysis == null)
                    Text(
                      t.diff.select,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: pal.ink2,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else ...[
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _slotName(analysis, state!),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: pal.ink,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        PlatformTag(platform: analysis.platform, fontSize: 9),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _slotMeta(analysis, state!.fileSize),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _mono(pal.ink3, size: 10, spacing: 0.2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            _SlotTag(isNew: isNew, isIos: isIos),
          ],
        ),
      ),
    );
  }

  /// 槽位标题：应用名 · 版本。
  ///
  /// 用应用名而不是文件名：两个版本的文件名常常只差一个数字，扫一眼分不开；
  /// 应用名 + 版本才是「这是哪个包的哪个版本」。名字缺失时退回文件名。
  static String _slotName(PackageAnalysisResult a, FileState state) {
    final name = a.appName.value ?? a.fileName.value ?? p.basename(state.filePath ?? '');
    final version = a.version.value;
    return version == null || version.isEmpty ? name : '$name · $version';
  }

  /// 槽位副标题：包标识 · 大小 · DEX 数 · 权限数。
  ///
  /// 每一项都可能缺失（`FieldValue` 的状态）—— 缺了就不显示那一段，
  /// **不写 0**：「没读到」和「是 0」在这页是两件必须区分的事。
  static String _slotMeta(PackageAnalysisResult a, int? fileSize) {
    final id = a.packageId.value;
    final dex = a.android?.structure?.dexFileCount;
    final perms = a.android?.permissions.value?.length;
    return [
      if (id != null && id.isNotEmpty) id,
      if (fileSize != null) formatFileSize(fileSize),
      if (dex != null) '$dex DEX',
      if (perms != null) '$perms ${t.diff.sets.android_permissions}',
    ].join(' · ');
  }

  Future<void> _pick(BuildContext context) async {
    // 另一侧已选的包不出现在候选里（比较同一个包没有意义）。
    final candidates = cache.entries.where((e) => e.key != excludePath).toList()
      ..sort((a, b) => p.basename(a.key).compareTo(p.basename(b.key)));

    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t.diff.pick_title),
        children: [
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(t.diff.pick_empty),
            ),
          for (final entry in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(entry.key),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.value.analysis?.fileName.value ?? entry.key,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.value.analysis == null
                        ? ''
                        : _slotMeta(
                            entry.value.analysis!, entry.value.fileSize),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    if (picked != null) onPick(picked);
  }
}

/// 槽位右上角的 OLD APK / NEW APK 标。
class _SlotTag extends StatelessWidget {
  final bool isNew;
  final bool isIos;

  const _SlotTag({required this.isNew, required this.isIos});

  @override
  Widget build(BuildContext context) {
    final pal = _Pal.of(Theme.of(context));
    final label = '${isNew ? t.diff.slot_new_tag : t.diff.slot_old_tag} '
        '${isIos ? 'IPA' : 'APK'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: isNew ? pal.violet.withValues(alpha: 0.10) : pal.surface2,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: isNew ? pal.violet.withValues(alpha: 0.30) : pal.line,
        ),
      ),
      child: Text(
        label,
        style: _mono(
          isNew ? pal.violet : pal.ink3,
          size: 8,
          weight: FontWeight.w700,
          spacing: 0.6,
          height: 1.1,
        ),
      ),
    );
  }
}

class _SlotIcon extends StatelessWidget {
  final FileState state;

  /// Android 图标的**副本**（见 `parsedFileIconsProvider`）。
  ///
  /// 刻意不读 `state.apkInfo!.mainIconImage`：那个 `ui.Image` 会在换文件时
  /// 被 `ApkInfo.dispose()` 释放，先解析的包因此丢图标。
  final ui.Image? icon;

  final bool isIos;
  final double side;

  const _SlotIcon({
    required this.state,
    required this.icon,
    required this.isIos,
    this.side = PackageIconMetrics.slotSide,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final apkIcon = icon;
    final iosCandidate = state.ipaAnalysis?.icon?.candidates.firstOrNull;

    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(PackageIconMetrics.radiusOf(side)),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.15)),
      ),
      clipBehavior: Clip.antiAlias,
      child: isIos
          ? (iosCandidate != null
              ? IosIconImage(candidate: iosCandidate, size: side)
              : _fallback(theme, Icons.apple))
          : (apkIcon != null
              ? RawImage(
                  image: apkIcon,
                  // cover 而不是 contain：源图不是正方形时 contain 会在两侧
                  // 露出底色，看起来像一圈黑边（与概览页 Hero 同一条取舍）。
                  fit: BoxFit.cover,
                )
              : _fallback(theme, Icons.android)),
    );
  }

  Widget _fallback(ThemeData theme, IconData icon) => Center(
        child: Icon(
          icon,
          size: 20,
          color: theme.hintColor.withValues(alpha: 0.4),
        ),
      );
}

// ============================================================== 摘要条

class _SummaryStrip extends StatelessWidget {
  final int fieldCount;
  final int setCount;
  final int unknownCount;
  final _DiffTab tab;
  final ValueChanged<_DiffTab> onTab;

  const _SummaryStrip({
    required this.fieldCount,
    required this.setCount,
    required this.unknownCount,
    required this.tab,
    required this.onTab,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);

    final stats = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        _Stat(value: fieldCount, label: t.diff.stat_field_changes, color: pal.ink),
        const SizedBox(width: 26),
        _Stat(value: setCount, label: t.diff.stat_set_changes, color: pal.ink),
        const SizedBox(width: 26),
        _Stat(
          value: unknownCount,
          label: t.diff.section_unknown,
          color: pal.amber,
        ),
      ],
    );

    final chips = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _TabChip(
          key: const Key('diff.tab.all'),
          label: t.diff.tab_all,
          selected: tab == _DiffTab.all,
          onTap: () => onTab(_DiffTab.all),
        ),
        _TabChip(
          key: const Key('diff.tab.fields'),
          label: '${t.diff.tab_fields} $fieldCount',
          selected: tab == _DiffTab.fields,
          onTap: fieldCount == 0 ? null : () => onTab(_DiffTab.fields),
        ),
        _TabChip(
          key: const Key('diff.tab.sets'),
          label: '${t.diff.tab_sets} $setCount',
          selected: tab == _DiffTab.sets,
          onTap: setCount == 0 ? null : () => onTab(_DiffTab.sets),
        ),
        _TabChip(
          key: const Key('diff.tab.unknown'),
          label: '${t.diff.section_unknown} $unknownCount',
          selected: tab == _DiffTab.unknown,
          amber: true,
          onTap: unknownCount == 0 ? null : () => onTab(_DiffTab.unknown),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: pal.surface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: pal.line),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [stats, const SizedBox(height: 10), chips],
            );
          }
          return Row(children: [stats, const Spacer(), chips]);
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final int value;
  final String label;
  final Color color;

  const _Stat({required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$value',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1,
            letterSpacing: -0.6,
            color: color,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11,
            color: pal.ink3,
          ),
        ),
      ],
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool amber;

  /// `null` = 这一类当前没有内容，点了也只会看到空表，所以不给点。
  final VoidCallback? onTap;

  const _TabChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.amber = false,
  });

  @override
  Widget build(BuildContext context) {
    final pal = _Pal.of(Theme.of(context));
    final enabled = onTap != null;
    final fg = selected
        ? pal.surface
        : (amber ? pal.amber : pal.ink2).withValues(alpha: enabled ? 1 : 0.45);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 23,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? pal.ink : (amber ? pal.amber.withValues(alpha: 0.10) : pal.surface2),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected ? pal.ink : (amber ? pal.amber.withValues(alpha: 0.25) : pal.line),
          ),
        ),
        child: Text(
          label,
          style: _mono(fg, size: 9, weight: FontWeight.w700, spacing: 0.4, height: 1.1),
        ),
      ),
    );
  }
}

// ============================================================== 字段差异表

class _FieldTableCard extends StatelessWidget {
  final PackageAnalysisResult left;
  final PackageAnalysisResult right;
  final List<FieldDiff> changes;
  final bool showAll;
  final int previewRows;
  final VoidCallback onToggle;

  const _FieldTableCard({
    required this.left,
    required this.right,
    required this.changes,
    required this.showAll,
    required this.previewRows,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    final hidden = showAll ? 0 : (changes.length - previewRows).clamp(0, changes.length);
    final visible = showAll ? changes : changes.take(previewRows).toList();

    return _V4Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 卡头：图标 + 标题 + 「按影响排序」的说明标。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Icon(Icons.swap_vert_rounded, size: 15, color: pal.violet),
                const SizedBox(width: 8),
                Text(
                  t.diff.section_fields,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: pal.ink,
                  ),
                ),
                const Spacer(),
                _PlainChip(t.diff.sorted_by_impact),
              ],
            ),
          ),
          _TableHead(
            columns: [
              t.diff.col_field,
              '${left.version.value ?? '—'} / ${t.diff.col_old}',
              '${right.version.value ?? '—'} / ${t.diff.col_new}',
              t.diff.col_change,
            ],
          ),
          for (var i = 0; i < visible.length; i++)
            _FieldRow(
              diff: visible[i],
              showTopBorder: true,
            ),
          if (hidden > 0 || showAll)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: pal.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      showAll
                          ? t.diff.section_fields
                          : t.diff.fields_hidden(count: hidden),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _mono(pal.ink3, size: 10, spacing: 0.2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _SmallButton(
                    label: showAll
                        ? t.diff.show_less
                        : '${t.diff.show_all} ${changes.length}',
                    onTap: onToggle,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TableHead extends StatelessWidget {
  final List<String> columns;

  const _TableHead({required this.columns});

  @override
  Widget build(BuildContext context) {
    final pal = _Pal.of(Theme.of(context));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: pal.surface2,
        border: Border(
          top: BorderSide(color: pal.line),
          bottom: BorderSide(color: pal.line),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            Expanded(
              flex: _kTableFlex[i],
              child: Text(
                columns[i].toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _mono(
                  pal.ink3,
                  size: 9,
                  weight: FontWeight.w700,
                  spacing: 0.9,
                  height: 1.1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 四列的比例（FIELD / OLD / NEW / CHANGE），与原型 28/26/26/20 对齐。
const List<int> _kTableFlex = [28, 26, 26, 20];

class _FieldRow extends StatelessWidget {
  final FieldDiff diff;
  final bool showTopBorder;

  const _FieldRow({required this.diff, required this.showTopBorder});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    final oldText = DiffLabels.value(diff.id, diff.left, t);
    final newText = DiffLabels.value(diff.id, diff.right, t);

    return Container(
      constraints: const BoxConstraints(minHeight: 42),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: showTopBorder
          ? BoxDecoration(border: Border(top: BorderSide(color: pal.line)))
          : null,
      child: Row(
        children: [
          Expanded(
            flex: _kTableFlex[0],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DiffLabels.field(diff.id, t),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: pal.ink,
                  ),
                ),
                const SizedBox(height: 3),
                // 机器 id 只用来核对（报告/JSON 里是它），所以压到极小一档。
                Text(
                  _shortId(diff.id),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _mono(pal.ink3, size: 9, spacing: 0.2, height: 1.2),
                ),
              ],
            ),
          ),
          Expanded(
            flex: _kTableFlex[1],
            child: Text(
              oldText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _mono(pal.ink3, size: 10.5, spacing: 0.1, height: 1.35),
            ),
          ),
          Expanded(
            flex: _kTableFlex[2],
            child: Text(
              newText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _mono(
                pal.ink,
                size: 10.5,
                weight: FontWeight.w600,
                spacing: 0.1,
                height: 1.35,
              ),
            ),
          ),
          Expanded(
            flex: _kTableFlex[3],
            child: Align(
              alignment: Alignment.centerLeft,
              child: _ChangeChip(kind: diff.kind),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================== 集合差异表

class _SetTableCard extends StatelessWidget {
  final List<SetDiff> changes;
  final Map<String, String> ruleTitles;

  const _SetTableCard({required this.changes, required this.ruleTitles});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return _V4Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Icon(Icons.join_full_rounded, size: 15, color: pal.violet),
                const SizedBox(width: 8),
                Text(
                  t.diff.section_sets,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: pal.ink,
                  ),
                ),
                const Spacer(),
                _PlainChip('${t.diff.col_added} / ${t.diff.col_removed}'),
              ],
            ),
          ),
          for (var i = 0; i < changes.length; i++)
            _SetRow(
              diff: changes[i],
              showTopBorder: true,
              ruleTitles: ruleTitles,
            ),
        ],
      ),
    );
  }
}

class _SetRow extends StatelessWidget {
  final SetDiff diff;
  final bool showTopBorder;
  final Map<String, String> ruleTitles;

  const _SetRow({
    required this.diff,
    required this.showTopBorder,
    required this.ruleTitles,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    final added = diff.added.take(DiffPage.maxMembersPerList).toList();
    final removed = diff.removed.take(DiffPage.maxMembersPerList).toList();
    final truncated = diff.added.length - added.length +
        diff.removed.length -
        removed.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: showTopBorder
          ? BoxDecoration(border: Border(top: BorderSide(color: pal.line)))
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DiffLabels.set(diff.id, t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: pal.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _shortId(diff.id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _mono(pal.ink3, size: 9, spacing: 0.2, height: 1.2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // 条数照实报：只说「变了」不说「变了几条」等于没说。
              if (added.isNotEmpty)
                Text(
                  t.diff.added_count(count: diff.added.length),
                  style: _mono(pal.mint, size: 10, weight: FontWeight.w600),
                ),
              if (added.isNotEmpty && removed.isNotEmpty)
                const SizedBox(width: 10),
              if (removed.isNotEmpty)
                Text(
                  t.diff.removed_count(count: diff.removed.length),
                  style: _mono(pal.danger, size: 10, weight: FontWeight.w600),
                ),
            ],
          ),
          if (added.isNotEmpty || removed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in added)
                  _MemberChip(
                    label: DiffLabels.member(
                      diff.id,
                      m,
                      t,
                      ruleTitles: ruleTitles,
                    ),
                    color: pal.mint,
                  ),
                for (final m in removed)
                  _MemberChip(
                    label: DiffLabels.member(
                      diff.id,
                      m,
                      t,
                      ruleTitles: ruleTitles,
                    ),
                    color: pal.danger,
                  ),
              ],
            ),
            if (truncated > 0) ...[
              const SizedBox(height: 6),
              Text(
                t.diff.truncated_members(count: truncated),
                style: _mono(pal.ink3, size: 9, spacing: 0.2),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _MemberChip extends StatelessWidget {
  final String label;
  final Color color;

  const _MemberChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      // 成员可能是很长的包名/域名：限制宽度并截断，否则一条就把整行撑满。
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _mono(color, size: 9.5, weight: FontWeight.w600, spacing: 0.1),
      ),
    );
  }
}

// ============================================================== 无法比较

/// 「我们没读到」的字段与集合：单独一张卡，**不能**并进差异表。
class _UnknownCard extends StatelessWidget {
  final List<FieldDiff> fields;
  final List<SetDiff> sets;
  final Map<String, String> ruleTitles;

  const _UnknownCard({
    required this.fields,
    required this.sets,
    required this.ruleTitles,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return _V4Card(
      borderColor: pal.amber.withValues(alpha: 0.18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Icon(Icons.help_outline_rounded, size: 15, color: pal.amber),
                const SizedBox(width: 8),
                Text(
                  t.diff.section_unknown,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: pal.ink,
                  ),
                ),
                const Spacer(),
                _PlainChip('${fields.length + sets.length}'),
              ],
            ),
          ),
          if (fields.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                t.diff.unknown_field_hint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: pal.ink3, fontSize: 11),
              ),
            ),
            const SizedBox(height: 8),
            for (final f in fields)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: pal.line)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 26,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            DiffLabels.field(f.id, t),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: pal.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _shortId(f.id),
                            style: _mono(pal.ink3, size: 9, spacing: 0.2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 40,
                      child: Text(
                        '${DiffLabels.value(f.id, f.left, t)} → '
                        '${DiffLabels.value(f.id, f.right, t)}',
                        style: _mono(pal.ink2, size: 9.5, height: 1.4),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ChangeChip(kind: DiffKind.unknown),
                  ],
                ),
              ),
          ],
          if (sets.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                t.diff.unknown_set_hint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: pal.ink3, fontSize: 11),
              ),
            ),
            for (final s in sets)
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          DiffLabels.set(s.id, t),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: pal.ink,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _shortId(s.id),
                          style: _mono(pal.ink3, size: 9, spacing: 0.2),
                        ),
                        const Spacer(),
                        _ChangeChip(kind: DiffKind.unknown),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      _memberSummary(s),
                      style: _mono(pal.ink2, size: 9.5, height: 1.5),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 无法比较的集合：两侧各自读到什么就列什么（截断处照实说还有多少）。
  String _memberSummary(SetDiff s) {
    String side(List<String> members) {
      if (members.isEmpty) return t.diff.value_absent;
      final shown = members.take(DiffPage.maxMembersPerList).toList();
      final rest = members.length - shown.length;
      final body = shown
          .map((m) => DiffLabels.member(s.id, m, t, ruleTitles: ruleTitles))
          .join(t.diff.list_sep);
      return rest > 0 ? '$body ${t.diff.truncated_members(count: rest)}' : body;
    }

    return '${t.diff.report_left}: ${side(s.removed.isEmpty && s.common.isEmpty ? const [] : [...s.removed, ...s.common])}\n'
        '${t.diff.report_right}: ${side([...s.added, ...s.common])}';
  }
}

// ============================================================== 右栏卡片

class _SummaryCard extends StatelessWidget {
  final bool packageSame;
  final int addedDex;
  final int addedPerms;
  final int addedAbi;
  final int? findingsLeft;
  final int? findingsRight;
  final int addedFindings;

  const _SummaryCard({
    required this.packageSame,
    required this.addedDex,
    required this.addedPerms,
    required this.addedAbi,
    required this.findingsLeft,
    required this.findingsRight,
    required this.addedFindings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    final rows = <Widget>[
      if (addedPerms > 0)
        _LedgerRow(
          icon: Icons.shield_outlined,
          label: t.diff.rail_added_permissions,
          value: '$addedPerms',
        ),
      if (addedDex > 0)
        _LedgerRow(
          icon: Icons.folder_zip_outlined,
          label: t.diff.rail_added_dex,
          value: '$addedDex',
        ),
      if (addedFindings > 0)
        _LedgerRow(
          icon: Icons.warning_amber_rounded,
          label: t.diff.rail_added_findings,
          value: '$addedFindings',
        ),
    ];

    return _V4Card(
      padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 14, color: pal.violet),
              const SizedBox(width: 8),
              Text(
                t.diff.rail_summary,
                style: _mono(
                  pal.ink,
                  size: 10.5,
                  weight: FontWeight.w700,
                  spacing: 0.8,
                ),
              ),
              const Spacer(),
              _PlainChip(t.diff.rail_read_only),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            _narrative(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: pal.ink2,
              fontSize: 11.5,
              height: 1.7,
            ),
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (var i = 0; i < rows.length; i++)
              Container(
                decoration: i == 0
                    ? null
                    : BoxDecoration(
                        border: Border(top: BorderSide(color: pal.line)),
                      ),
                child: rows[i],
              ),
          ],
        ],
      ),
    );
  }

  /// 一句话摘要。
  ///
  /// 只陈述**算得出来**的事：包名是否一致、多出多少 DEX / ABI / 权限、
  /// 安全发现从几条到几条。算不出来的（例如「新增了什么能力」）不编。
  ///
  /// 句子的拼接方式（分句分隔符、句末、枚举连接词）也走语言包：英文需要
  /// `A, B and C` 而中文需要 `A、B 与 C`，硬编码任何一种都会让另一种语言读着别扭。
  String _narrative() {
    final parts = <String>[
      packageSame ? t.diff.narrative_pkg_same : t.diff.narrative_pkg_diff,
    ];

    final added = <String>[
      if (addedDex > 0) t.diff.narrative_dex(count: addedDex),
      if (addedAbi > 0) t.diff.narrative_abi(count: addedAbi),
      if (addedPerms > 0) t.diff.narrative_permissions(count: addedPerms),
    ];
    if (added.isNotEmpty) {
      parts.add(t.diff.narrative_newer_adds(items: _joinList(added)));
    }

    final l = findingsLeft;
    final r = findingsRight;
    if (l != null && r != null && l != r) {
      parts.add(t.diff.narrative_findings(from: l, to: r));
    }

    return '${parts.join(t.diff.sentence_sep)}${t.diff.sentence_end}'
        '${(added.isNotEmpty || addedFindings > 0) ? t.diff.narrative_review_advice : t.diff.narrative_no_capability_advice}';
  }
}

class _LedgerRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _LedgerRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Icon(icon, size: 13, color: pal.ink3),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: pal.ink2,
                fontSize: 11.5,
              ),
            ),
          ),
          Text(
            value,
            style: _mono(pal.ink3, size: 10, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// 琥珀色提示卡：有 N 项「我们没读到」。
class _UnknownNoticeCard extends StatelessWidget {
  final int count;
  final int fieldCount;
  final int setCount;

  const _UnknownNoticeCard({
    required this.count,
    required this.fieldCount,
    required this.setCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return Container(
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
      decoration: BoxDecoration(
        color: pal.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: pal.amber.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 14, color: pal.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.diff.unknown_title(count: count),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: pal.amber,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            t.diff.summary_unknown(count: fieldCount),
            style: theme.textTheme.bodySmall?.copyWith(
              color: pal.amber,
              fontSize: 11.5,
              height: 1.6,
            ),
          ),
          // 两类原因分开写：字段和集合各自的「没读到」不是同一件事。
          if (fieldCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              t.diff.unknown_field_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: pal.amber.withValues(alpha: 0.85),
                fontSize: 11,
                height: 1.6,
              ),
            ),
          ],
          if (setCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              t.diff.unknown_set_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: pal.amber.withValues(alpha: 0.85),
                fontSize: 11,
                height: 1.6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 复核清单：只列**真的多出来的**能力，没有就不摆一张空卡。
class _ChecklistCard extends StatelessWidget {
  final int addedDex;
  final int addedPerms;
  final int addedAbi;

  const _ChecklistCard({
    required this.addedDex,
    required this.addedPerms,
    required this.addedAbi,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    final items = <(IconData, String)>[
      if (addedDex > 0) (Icons.folder_zip_outlined, t.diff.check_dex),
      if (addedPerms > 0) (Icons.shield_outlined, t.diff.check_permissions),
      if (addedAbi > 0) (Icons.memory_rounded, t.diff.check_abi),
    ];

    return _V4Card(
      padding: const EdgeInsets.fromLTRB(17, 16, 17, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist_rounded, size: 14, color: pal.violet),
              const SizedBox(width: 8),
              Text(
                t.diff.rail_checklist,
                style: _mono(
                  pal.ink,
                  size: 10.5,
                  weight: FontWeight.w700,
                  spacing: 0.8,
                ),
              ),
              const Spacer(),
              _PlainChip('${items.length} ${t.diff.rail_items}'),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < items.length; i++)
            Container(
              height: 32,
              decoration: i == 0
                  ? null
                  : BoxDecoration(
                      border: Border(top: BorderSide(color: pal.line)),
                    ),
              child: Row(
                children: [
                  Icon(items[i].$1, size: 13, color: pal.ink3),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      items[i].$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: pal.ink2,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                  Text(
                    t.diff.rail_open,
                    style: _mono(pal.ink3, size: 8.5, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 差异口径说明：我们只报「实际变化」，且「未知」不算差异。
class _PolicyCard extends StatelessWidget {
  const _PolicyCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: pal.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: pal.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.diff.rail_policy,
            style: _mono(
              pal.ink,
              size: 10,
              weight: FontWeight.w700,
              spacing: 0.8,
            ),
          ),
          const SizedBox(height: 5),
          for (final line in <String>[
            t.diff.policy_line_1,
            t.diff.policy_line_2,
            t.diff.policy_line_3,
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: pal.ink3,
                  fontSize: 10.5,
                  height: 1.55,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================== 小部件

/// V4 卡片外壳。
///
/// 刻意不用 `Card`：`CardTheme` 只在 V4 主题下才是圆角 20 + 描边，
/// 而本页在测试里是被默认 Material 主题 pump 起来的 —— 那样出来的是另一套阴影。
class _V4Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? borderColor;

  const _V4Card({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = V4Radius.card,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = _Pal.of(theme);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? pal.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: padding == EdgeInsets.zero
          ? child
          : Padding(padding: padding, child: child),
    );
  }
}

class _PlainChip extends StatelessWidget {
  final String label;

  const _PlainChip(this.label);

  @override
  Widget build(BuildContext context) {
    final pal = _Pal.of(Theme.of(context));
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _mono(pal.ink3, size: 9, weight: FontWeight.w600, spacing: 0.6),
    );
  }
}

class _ChangeChip extends StatelessWidget {
  final DiffKind kind;

  const _ChangeChip({required this.kind});

  @override
  Widget build(BuildContext context) {
    final pal = _Pal.of(Theme.of(context));
    final color = switch (kind) {
      DiffKind.added => pal.mint,
      DiffKind.removed => pal.danger,
      DiffKind.changed => pal.violet,
      DiffKind.unknown => pal.amber,
      DiffKind.same => pal.ink3,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        DiffLabels.kind(kind, t),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _mono(color, size: 9, weight: FontWeight.w700, spacing: 0.2),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SmallButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = _Pal.of(Theme.of(context));
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: pal.ink2,
        backgroundColor: pal.surface,
        side: BorderSide(color: pal.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: _mono(
          Theme.of(context).colorScheme.onSurfaceVariant,
          size: 9,
          weight: FontWeight.w700,
          spacing: 0.4,
        ),
      ),
      child: Text(label),
    );
  }
}

// ============================================================== 样式辅助

/// 表头/等宽文本。原型里这些标签全是等宽小字，靠字距撑出「仪表」感。
TextStyle _mono(
  Color? color, {
  double size = 10,
  FontWeight weight = FontWeight.w600,
  double spacing = 0.4,
  double? height,
}) =>
    TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['SF Mono', 'Menlo', 'Courier New'],
      fontSize: size,
      fontWeight: weight,
      letterSpacing: spacing,
      height: height,
      color: color,
    );

/// 把模型 id 压成原型的短 id（`android.targetSdkVersion` → `targetSdkVersion`）。
///
/// 只去掉第一段命名空间：完整 id 太长，会把这列挤成两行；
/// 而报告/JSON 里仍然用完整 id，这里的短 id 只是给人核对的锚点。
String _shortId(String id) {
  final dot = id.indexOf('.');
  return dot < 0 ? id : id.substring(dot + 1);
}

/// 本页的色板。
///
/// 亮色直接用 V4 令牌；暗色从 `colorScheme` 与 V4 的深色档取 —— 只写死浅色
/// 常量会在暗色主题下变成「黑底黑字」。
class _Pal {
  const _Pal({
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.surface,
    required this.surface2,
    required this.violet,
    required this.mint,
    required this.amber,
    required this.danger,
  });

  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color line;
  final Color surface;
  final Color surface2;
  final Color violet;
  final Color mint;
  final Color amber;
  final Color danger;

  factory _Pal.of(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return _Pal(
      ink: scheme.onSurface,
      ink2: scheme.onSurfaceVariant,
      ink3: dark ? V4Colors.darkInk3 : V4Colors.ink3,
      line: dark ? V4Colors.darkLine : scheme.outlineVariant,
      surface: scheme.surface,
      surface2: dark ? V4Colors.darkSurface2 : V4Colors.surface2,
      violet: dark ? const Color(0xFF9C8CFF) : V4Colors.violet,
      mint: dark ? const Color(0xFF4FC79B) : V4Colors.mint,
      amber: dark ? const Color(0xFFE0A063) : V4Colors.amber,
      danger: dark ? const Color(0xFFF2768D) : V4Colors.danger,
    );
  }
}

// ============================================================== 不翻译的品牌署名

/// 页脚那两行是原型的品牌署名（产品名 + 版面签名），六种 locale 共用：
/// 里面没有可翻译的自然语言，翻掉就不再是同一个签名了。
///
/// 其余所有可见标签——包括表头、胶囊、清单与页脚说明这些「仪表盘」字样——
/// 全部走 `t.diff.*`（见 `assets/i18n/*.json`）。V4 的仪表感来自 `_mono()`
/// 的等宽字与字距，不来自英文单词：概览页的 `ENGINE` / `MODE` 同样译成
/// 引擎 / モード / 엔진。
abstract final class _P {
  static const footnoteBrand = 'V4 / PAPER & SIGNAL · COMPARE';
  static const footnoteMeta = 'FIELD-LEVEL · NO RUNTIME';
}

/// 按当前语言的枚举连接：中文 `A、B 与 C`，英文 `A, B and C`。
///
/// 分隔符本身也在语言包里（`t.diff.list_sep` / `t.diff.list_last_sep`）：
/// 顿号加「与」翻不成英文，`, ` 加 ` and ` 也翻不成中文。
String _joinList(List<String> items) {
  if (items.length == 1) return items.first;
  return '${items.sublist(0, items.length - 1).join(t.diff.list_sep)}'
      '${t.diff.list_last_sep}${items.last}';
}
