import 'dart:io';

import 'package:apk_parser/apk_parser.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/libchecker_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

/// 「库识别」Tab。
///
/// 数据链路：ZIP 目录里的原生库 + manifest 组件 + DEX 里的类名/包名，交给
/// LibChecker 规则匹配，再按 SDK 归组。识别在**打开这个 Tab 时才做** ——
/// 一次完整扫描要读全部 DEX（几十 MB），把它塞进常规解析会让每次双击 APK
/// 都多等几秒，而大多数用户并不看这一页。
class AndroidLibrariesSection extends StatefulWidget {
  const AndroidLibrariesSection({
    super.key,
    required this.apkPath,
    required this.packageName,
    required this.components,
    required this.structure,
  });

  final String apkPath;
  final String? packageName;
  final List<AndroidComponent> components;
  final ContainerStructure structure;

  @override
  State<AndroidLibrariesSection> createState() =>
      _AndroidLibrariesSectionState();
}

class _AndroidLibrariesSectionState extends State<AndroidLibrariesSection> {
  /// 按路径缓存：切 Tab 会重建 widget，但没必要重扫同一份 APK。
  /// 键里带文件大小与修改时间，同一路径被替换后会自动重扫。
  static final Map<String, _LibraryScanOutcome> _cache = {};

  _LibraryScanOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant AndroidLibrariesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apkPath != widget.apkPath) _start();
  }

  Future<void> _start() async {
    final key = _cacheKey(widget.apkPath);
    final cached = _cache[key];
    if (cached != null) {
      setState(() => _outcome = cached);
      return;
    }
    setState(() => _outcome = null);
    _LibraryScanOutcome outcome;
    try {
      outcome = _LibraryScanOutcome(
        report: await _scan(),
        rules: LibCheckerData.loaded,
      );
    } catch (error) {
      outcome = _LibraryScanOutcome(error: error.toString());
    }
    if (!mounted) return;
    _cache[key] = outcome;
    // 只保留最近几份：报告本身不大，但用户可能连着打开几十个包，
    // 无上限的静态缓存会把内存一直攥着。Map 保持插入顺序，删最早的那份。
    while (_cache.length > 8) {
      _cache.remove(_cache.keys.first);
    }
    setState(() => _outcome = outcome);
  }

  Future<LibraryReport> _scan() async {
    final rules = await LibCheckerData.ensureLoaded();
    // 图标表与规则分开加载：读不到图标只影响观感，不影响识别结论。
    await LibCheckerData.ensureIconsLoaded();
    final reader = ApkReader();
    try {
      final opened = await reader.open(widget.apkPath);
      if (!opened.isOk) {
        throw StateError('open failed: ${opened.description}');
      }
      final entryNames = reader.listFiles();
      final dexPattern = RegExp(r'^classes\d*\.dex$');
      var signals = DexLibrarySignals.empty;
      var scannedBytes = 0;
      // 总量上限：DEX 扫的是类定义表，几十 MB 的包在桌面端也能接受，
      // 但畸形/超大包会把「打开 Tab」变成一次无上限的读取。超限后
      // 停止扫描并标记 truncated —— 结论宁可不全，也不能卡死界面。
      const maxTotalDexBytes = 96 * 1024 * 1024;
      for (final name in entryNames.where(dexPattern.hasMatch)) {
        final bytes = reader.readFile(name);
        if (bytes == null) continue;
        if (scannedBytes + bytes.length > maxTotalDexBytes) {
          signals = signals.merge(DexLibrarySignals.truncatedMarker);
          break;
        }
        scannedBytes += bytes.length;
        signals = signals.merge(DexLibraryScanner.scan(bytes));
      }
      return LibraryDetector.detect(
        rules: rules,
        packageName: widget.packageName ?? '',
        nativeLibraries: widget.structure.nativeLibraries,
        components: widget.components,
        dex: signals,
        archiveEntries: entryNames.toSet(),
      );
    } finally {
      reader.close();
    }
  }

  /// 文件大小 + 修改时间。取不到 stat 时退回路径本身（宁可多扫一次，
  /// 也不要因为拿不到时间戳就永久用旧结果）。
  static String _cacheKey(String path) {
    try {
      final stat = File(path).statSync();
      return '$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } on FileSystemException {
      return path;
    }
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    if (outcome == null) {
      final t = TranslationProvider.of(context).translations;
      return Card(
        child: ListTile(
          leading: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(t.libraries.scanning),
        ),
      );
    }
    if (outcome.error != null) {
      final t = TranslationProvider.of(context).translations;
      return Card(
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text(t.libraries.load_failed(error: outcome.error!)),
        ),
      );
    }
    return _LibrariesView(
      report: outcome.report!,
      rules: outcome.rules,
      dexFileCount: widget.structure.dexFiles.length,
    );
  }
}

class _LibraryScanOutcome {
  _LibraryScanOutcome({this.report, this.rules, this.error});

  final LibraryReport? report;
  final LibCheckerRules? rules;
  final String? error;
}

class _LibrariesView extends StatelessWidget {
  /// 规则来源仓库。归属文字可点，直接打开上游而不是让用户自己搜。
  static const _rulesRepository =
      'https://github.com/LibChecker/LibChecker-Rules';

  const _LibrariesView({
    required this.report,
    required this.rules,
    required this.dexFileCount,
  });

  final LibraryReport report;
  final LibCheckerRules? rules;
  final int dexFileCount;

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final theme = Theme.of(context);
    final totalHits = report.nativeGroups.length +
        report.componentGroups.length +
        report.dexGroups.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.inventory_2_outlined,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        t.libraries.identified_sdks(count: report.sdkCount),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (rules != null)
                      t.libraries
                          .rule_version(version: '${report.dataVersion}'),
                    t.libraries.scanned(
                      classes: report.dexClasses,
                      dex: dexFileCount,
                    ),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (report.kotlin || report.compose) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (report.kotlin) const _TechChip(label: 'Kotlin'),
                      if (report.compose)
                        const _TechChip(label: 'Jetpack Compose'),
                    ],
                  ),
                ],
                if (!report.dexScanned) ...[
                  const SizedBox(height: 10),
                  Text(
                    t.libraries.not_scanned,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (report.dexTruncated) ...[
                  const SizedBox(height: 10),
                  Text(
                    t.libraries
                        .truncated(limit: '${DexLibraryScanner.maxClasses}'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (totalHits == 0 && report.unmatchedNative.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.search_off),
              title: Text(t.libraries.no_hits),
            ),
          ),
        if (report.nativeGroups.isNotEmpty)
          _GroupSection(
            title: t.libraries.native_section,
            groups: report.nativeGroups,
            countLabel: (count) => t.libraries.hit_native(count: count),
            onTap: (group) => _showDetails(context, group),
            itemBuilder: _nativeLine,
          ),
        if (report.componentGroups.isNotEmpty)
          _GroupSection(
            title: t.libraries.components_section,
            groups: report.componentGroups,
            countLabel: (count) => t.libraries.hit_component(count: count),
            onTap: (group) => _showDetails(context, group),
            itemBuilder: _componentLine,
          ),
        if (report.dexGroups.isNotEmpty)
          _GroupSection(
            title: t.libraries.dex_section,
            groups: report.dexGroups,
            countLabel: (count) => t.libraries.hit_dex(count: count),
            onTap: (group) => _showDetails(context, group),
            itemBuilder: _dexLine,
          ),
        if (report.unmatchedNative.isNotEmpty)
          _UnmatchedNativeCard(libs: report.unmatchedNative),
        // 归属信息同时是入口：规则数据来自 LibChecker-Rules，读者可以点开
        // 仓库核对规则、提 issue，或按 README 重新生成打包数据。
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
          child: InkWell(
            onTap: () => _openSource(_rulesRepository),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.open_in_new,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      t.libraries.attribution,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _nativeLine(LibraryHit hit) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(hit.name, style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final abi in hit.abis) _AbiChip(label: abi),
                  ],
                ),
              ],
            ),
          ),
          Text(_formatSize(hit.size)),
        ],
      );

  Widget _componentLine(LibraryHit hit) => Row(
        children: [
          Expanded(
            child: Text(
              hit.name,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          _SourceChip(source: hit.source),
        ],
      );

  Widget _dexLine(LibraryHit hit) => Row(
        children: [
          Expanded(
            child: Text(
              hit.name,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          _SourceChip(source: hit.source),
        ],
      );

  void _showDetails(BuildContext context, LibraryGroup group) {
    final t = TranslationProvider.of(context).translations;
    final detail = rules?.detailFor(group.rule, LibCheckerData.detailLocale);
    final sourceLink = detail?.sourceLink;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            _SdkAvatar(label: group.label, size: 32, iconId: group.iconId),
            const SizedBox(width: 12),
            Expanded(child: Text(group.label)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (detail?.developer != null) ...[
                  Text('${t.libraries.developer}: ${detail!.developer}'),
                  const SizedBox(height: 8),
                ],
                SelectableText(
                  detail?.description ?? t.libraries.no_details,
                ),
                if (detail?.contributors.isNotEmpty ?? false) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${t.libraries.contributors}: ${detail!.contributors.join(', ')}',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ],
                if (sourceLink != null) ...[
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () => _openSource(sourceLink),
                    child: Text('${t.libraries.source}: $sourceLink'),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.base.close),
          ),
        ],
      ),
    );
  }

  static Future<void> _openSource(String link) async {
    final uri = Uri.tryParse(link);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;
    try {
      await launchUrl(uri);
    } catch (_) {
      // 打不开浏览器不是错误路径：链接本身已经显示在按钮上，可手动复制。
    }
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.title,
    required this.groups,
    required this.countLabel,
    required this.itemBuilder,
    required this.onTap,
  });

  final String title;
  final List<LibraryGroup> groups;
  final String Function(int count) countLabel;
  final Widget Function(LibraryHit hit) itemBuilder;
  final void Function(LibraryGroup group) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
          child: Text(title, style: theme.textTheme.titleSmall),
        ),
        for (final group in groups)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onTap(group),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _SdkAvatar(
                            label: group.label, size: 28, iconId: group.iconId),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            group.label,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Text(
                          countLabel(group.count),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 每张卡最多列三项：这一页的作用是「认出是谁」，完整
                    // 清单在详情弹窗里，否则一个 SDK 有几十个组件会淹没页面。
                    for (final hit in group.hits.take(3)) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: itemBuilder(hit),
                      ),
                    ],
                    if (group.hits.length > 3)
                      Text(
                        '另有 ${group.hits.length - 3} 项',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _UnmatchedNativeCard extends StatefulWidget {
  const _UnmatchedNativeCard({required this.libs});

  final List<NativeLibraryEntry> libs;

  @override
  State<_UnmatchedNativeCard> createState() => _UnmatchedNativeCardState();
}

class _UnmatchedNativeCardState extends State<_UnmatchedNativeCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final theme = Theme.of(context);
    final visible = _expanded ? widget.libs : widget.libs.take(3);
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: Text(t.libraries.unmatched_section),
            subtitle: Text(t.libraries.unmatched_hint),
            trailing: widget.libs.length > 3
                ? Icon(_expanded ? Icons.expand_less : Icons.expand_more)
                : null,
            onTap: widget.libs.length > 3
                ? () => setState(() => _expanded = !_expanded)
                : null,
          ),
          for (final lib in visible)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      lib.name,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  _AbiChip(label: lib.abi),
                  const SizedBox(width: 8),
                  Text(
                    _formatSize(lib.size),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SdkAvatar extends StatelessWidget {
  const _SdkAvatar({required this.label, required this.size, this.iconId});

  final String label;
  final double size;

  /// LibChecker 的图标 id；有对应 SVG 时显示厂商 LOGO，否则退回字母牌。
  final String? iconId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final svg = LibCheckerData.iconSvg(iconId);
    if (svg != null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        padding: EdgeInsets.all(size * 0.18),
        child: SvgPicture.string(
          svg,
          width: size,
          height: size,
          fit: BoxFit.contain,
        ),
      );
    }
    final color = _colorFor(label);
    final initial = label.isEmpty ? '?' : label.characters.first;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.48,
        ),
      ),
    );
  }

  /// 由名字派生颜色：同名恒同色，不依赖随机数（否则每次滚动都换颜色）。
  static Color _colorFor(String label) {
    var hash = 0;
    for (final unit in label.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.55, 0.45).toColor();
  }
}

class _TechChip extends StatelessWidget {
  const _TechChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _AbiChip extends StatelessWidget {
  const _AbiChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: theme.textTheme.labelSmall),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});

  final LibraryMatchSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (source) {
      LibraryMatchSource.exact => 'exact',
      LibraryMatchSource.regex => 'regex',
      LibraryMatchSource.action => 'action',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}
