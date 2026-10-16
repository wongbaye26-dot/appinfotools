import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/providers/parsed_file_cache.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/utils/diff_labels.dart';
import 'package:apk_info_tool/utils/format.dart';
import 'package:apk_info_tool/widgets/export_diff_dialog.dart';
import 'package:apk_info_tool/widgets/title_value_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// 版本差异页（V2.4.0 阶段 5.2）。
///
/// ## 入口形态
///
/// 独立页面，页内选两个文件（`docs/plans/V2.4.0_PROGRESS.md` §17.4-3 的定案）。
/// 不挂在概览页的多选上：概览页是**固定一屏**版式（`_chromeHeightEstimate`
/// 那一套预算），加多选会挤压既有布局；而独立页面不动任何现有页面的状态。
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

class _DiffPageState extends ConsumerState<DiffPage> {
  String? _leftPath;
  String? _rightPath;

  @override
  Widget build(BuildContext context) {
    final cache = ref.watch(parsedFileCacheProvider);
    final paths = cache.keys.toList();

    // 默认选「最近解析的两个」：用户刚解析完两个版本切过来，就该直接看到结果。
    // 只在**两侧都没显式选过**时自动填 —— 否则会把用户的选择覆盖掉。
    var leftPath = _leftPath;
    var rightPath = _rightPath;
    if (leftPath == null && rightPath == null && paths.length >= 2) {
      leftPath = paths[paths.length - 2];
      rightPath = paths.last;
    }

    // 导出按钮只在「真的有一份可比对的差异」时可点：跨平台、缺一侧、
    // 或两边是同一个包时导出的东西没有意义。
    final pair = _comparablePair(cache, leftPath, rightPath);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 页头走共享的 `PageHeader`（概览 / 分析 / 设置也是它）。
          // 此前这里是页面内联的一个 Row，另外三个页面又是另外三种做法。
          PageHeader(
            title: t.diff.title,
            subtitle: t.diff.subtitle,
            actions: [
              FilledButton.tonalIcon(
                onPressed:
                    pair == null ? null : () => _export(pair.left, pair.right),
                icon: const Icon(Icons.download, size: 18),
                label: Text(t.diff.export_action),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (paths.length < 2)
            _buildNotEnough()
          else ...[
            _buildSlots(cache, leftPath, rightPath),
            const SizedBox(height: 20),
            ..._buildBody(cache, leftPath, rightPath),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.compare_arrows, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(t.diff.pick_empty, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              t.diff.need_two,
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 4),
            Text(
              t.diff.pick_hint,
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => ref
                  .read(shellNavigationProvider.notifier)
                  .navigate('analysis'),
              child: Text(t.diff.go_analysis),
            ),
          ],
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _SlotCard(
            label: t.diff.slot_left,
            state: leftPath == null ? null : cache[leftPath],
            // 另一侧已选的文件不再出现在自己的候选里：比较同一个包没有意义，
            // 而它恰恰是「随手一选」最容易选到的那一个。
            excludePath: rightPath,
            cache: cache,
            onPick: (path) => setState(() => _leftPath = path),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _SlotCard(
            label: t.diff.slot_right,
            state: rightPath == null ? null : cache[rightPath],
            excludePath: leftPath,
            cache: cache,
            onPick: (path) => setState(() => _rightPath = path),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 正文

  List<Widget> _buildBody(
    Map<String, FileState> cache,
    String? leftPath,
    String? rightPath,
  ) {
    final theme = Theme.of(context);
    if (leftPath == null || rightPath == null) {
      return [
        _note(t.diff.need_both),
      ];
    }

    final left = cache[leftPath];
    final right = cache[rightPath];
    final leftAnalysis = left?.analysis;
    final rightAnalysis = right?.analysis;
    if (leftAnalysis == null || rightAnalysis == null) {
      return [
        _note(t.diff.need_both),
      ];
    }

    // 跨平台比较没有意义：Android 与 iOS 的专属字段会**全部**落进
    // added / removed，那是噪音而不是差异。拦住并说清楚。
    if (!samePlatform(leftAnalysis, rightAnalysis)) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 20, color: theme.colorScheme.error),
                const SizedBox(width: 10),
                Expanded(child: Text(t.diff.platform_mismatch)),
              ],
            ),
          ),
        ),
      ];
    }

    // 三端同源：这里与 Markdown / JSON 报告都走 `diffOf`（见适配层注释）。
    final diff = diffOf(leftAnalysis, rightAnalysis);

    final fieldChanges = diff.fields
        .where((f) =>
            f.kind == DiffKind.added ||
            f.kind == DiffKind.removed ||
            f.kind == DiffKind.changed)
        .toList();
    final fieldUnknown =
        diff.fields.where((f) => f.kind == DiffKind.unknown).toList();
    final setChanges =
        diff.sets.where((s) => s.comparable && !s.isSame).toList();
    final setUnknown = diff.sets.where((s) => !s.comparable).toList();

    return [
      _buildSummary(diff, fieldChanges.length, setChanges.length),
      if (fieldChanges.isNotEmpty) ...[
        _sectionHeader(t.diff.section_fields),
        for (final f in fieldChanges) _buildFieldCard(f),
      ],
      if (setChanges.isNotEmpty) ...[
        _sectionHeader(t.diff.section_sets),
        for (final s in setChanges) _buildSetCard(s),
      ],
      if (fieldUnknown.isNotEmpty || setUnknown.isNotEmpty) ...[
        _sectionHeader(t.diff.section_unknown),
        _note(t.diff.unknown_field_hint),
        for (final f in fieldUnknown) _buildFieldCard(f),
        if (setUnknown.isNotEmpty) _note(t.diff.unknown_set_hint),
        for (final s in setUnknown) _buildSetCard(s),
      ],
    ];
  }

  Widget _buildSummary(PackageDiff diff, int fieldCount, int setCount) {
    final theme = Theme.of(context);
    final total = fieldCount + setCount;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  diff.hasChanges
                      ? Icons.difference_outlined
                      : Icons.check_circle_outline,
                  size: 20,
                  color: diff.hasChanges
                      ? theme.colorScheme.primary
                      : theme.hintColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    diff.hasChanges
                        ? t.diff.summary_changes(count: total)
                        : t.diff.summary_same,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            // 「无法比较」的条数单独报。并进上面那一句会让「这次说不清」
            // 被读成「没有差异」。
            if (diff.unknownFieldCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                t.diff.summary_unknown(count: diff.unknownFieldCount),
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFieldCard(FieldDiff f) {
    return Card(
      child: TitleValueLayout(
        title: DiffLabels.field(f.id, t),
        value: '${DiffLabels.value(f.id, f.left, t)}'
            '  →  '
            '${DiffLabels.value(f.id, f.right, t)}',
        end: _KindBadge(kind: f.kind),
        // 值是两个值的组合（`A → B`），不是一个「可复制的事实」。
        copyable: false,
      ),
    );
  }

  Widget _buildSetCard(SetDiff s) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    DiffLabels.set(s.id, t),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (!s.comparable)
                  const _KindBadge(kind: DiffKind.unknown)
                else if (s.isSame)
                  Text(
                    t.diff.common_count(count: s.common.length),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
              ],
            ),
            // 每组**自带标题**，不靠图标区分。图标在某些字体/主题下会退化成
            // 一个方块，而「这一串是新增还是删除」是这张卡片唯一要说的事。
            if (s.added.isNotEmpty) ...[
              const SizedBox(height: 10),
              _memberGroup(
                title: t.diff.added_count(count: s.added.length),
                kind: DiffKind.added,
                members: s.added,
              ),
            ],
            if (s.removed.isNotEmpty) ...[
              const SizedBox(height: 10),
              _memberGroup(
                title: t.diff.removed_count(count: s.removed.length),
                kind: DiffKind.removed,
                members: s.removed,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 一组集合成员（新增或删除），带自己的标题与条数。
  Widget _memberGroup({
    required String title,
    required DiffKind kind,
    required List<String> members,
  }) {
    final theme = Theme.of(context);
    final color = _KindBadge.colorOf(kind, theme);
    final shown = members.take(DiffPage.maxMembersPerList).toList();
    final hidden = members.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        for (final m in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  kind == DiffKind.added ? Icons.add : Icons.remove,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SelectableText(
                    m,
                    style: theme.textTheme.bodyMedium,
                    minLines: 1,
                  ),
                ),
              ],
            ),
          ),
        // 截断必须说出来。条数照常显示，但读者要知道列表不全。
        if (hidden > 0)
          Text(
            t.diff.truncated_members(count: hidden),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
      ],
    );
  }

  Widget _sectionHeader(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _note(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
    );
  }
}

/// 差异类型的小标签。
///
/// **颜色不是唯一的信息载体** —— 每个标签都带文字。颜色只是让人一眼扫到
/// 「这几条是同一类」，读不读得出结论不依赖颜色。
class _KindBadge extends StatelessWidget {
  final DiffKind kind;

  const _KindBadge({required this.kind});

  static Color colorOf(DiffKind kind, ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return switch (kind) {
      DiffKind.added =>
        isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
      DiffKind.removed =>
        isDark ? const Color(0xFFEF5350) : const Color(0xFFC62828),
      DiffKind.changed =>
        isDark ? const Color(0xFFFFCA28) : const Color(0xFFF57F17),
      // 与安全卡片的 INFO 用同一档灰蓝，避免再引入一种「中性色」。
      DiffKind.same ||
      DiffKind.unknown =>
        isDark ? const Color(0xFF90A4AE) : const Color(0xFF607D8B),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorOf(kind, theme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        DiffLabels.kind(kind, t),
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// 一个文件槽：显示已选的包，或「选择应用包」。
class _SlotCard extends StatelessWidget {
  final String label;
  final FileState? state;
  final String? excludePath;
  final Map<String, FileState> cache;
  final ValueChanged<String> onPick;

  const _SlotCard({
    required this.label,
    required this.state,
    required this.excludePath,
    required this.cache,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final analysis = state?.analysis;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            if (state == null || analysis == null)
              Text(
                t.diff.select,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.hintColor),
              )
            else ...[
              Text(
                analysis.fileName.value ?? state!.filePath ?? '',
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                _slotSubtitle(analysis, state!.fileSize),
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                maxLines: 2,
              ),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _pick(context),
                child: Text(state == null ? t.diff.select : t.diff.change),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 槽位副标题：包标识 · 版本 · 文件大小。三项都可能缺失（`FieldValue`
  /// 的状态），缺了就不显示那一段，**不写占位符**。
  static String _slotSubtitle(PackageAnalysisResult a, int? fileSize) {
    final id = a.packageId.value;
    final version = a.version.value;
    return [
      if (id != null && id.isNotEmpty) id,
      if (version != null && version.isNotEmpty) version,
      if (fileSize != null) formatFileSize(fileSize),
    ].join('  ·  ');
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
                    _slotSubtitle(entry.value.analysis!, entry.value.fileSize),
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
