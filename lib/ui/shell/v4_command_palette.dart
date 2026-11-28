import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/shell/navigation_item.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
import 'package:apk_info_tool/widgets/recent_app_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 顶栏搜索入口：跳页面 + 重新打开最近分析过的包。
///
/// 不搜索包内部数据（权限名、字符串、DEX 内容）—— 那需要索引与后台任务，
/// 现在做会把「搜索」变成慢查询。原型里的搜索框写着「搜索包名、规则、报告」，
/// 当前产品能如实兑现的是「包名（最近分析）」与「页面」，所以面板只列这两类，
/// 空结果时明确说没有，不假装搜过。
Future<void> showV4CommandPalette(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (_) => _V4CommandPalette(
      onSelectPage: (id) {
        ref.read(shellNavigationProvider.notifier).navigate(id);
      },
      onSelectFile: (path) {
        ref.read(pendingOpenRequestProvider.notifier).request(path);
        ref.read(shellNavigationProvider.notifier).navigate('analysis');
      },
    ),
  );
}

class _V4CommandPalette extends ConsumerStatefulWidget {
  final ValueChanged<String> onSelectPage;
  final ValueChanged<String> onSelectFile;

  const _V4CommandPalette({
    required this.onSelectPage,
    required this.onSelectFile,
  });

  @override
  ConsumerState<_V4CommandPalette> createState() => _V4CommandPaletteState();
}

class _V4CommandPaletteState extends ConsumerState<_V4CommandPalette> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final query = _query.trim().toLowerCase();

    final pages = AppNavigation.items()
        .where((item) => item.label.toLowerCase().contains(query))
        .toList();

    // 最近文件按路径名匹配 —— 这里没有索引可言，一次线性过滤足够了。
    final recent = ref
        .watch(recentFilesProvider)
        .where((entry) =>
            query.isEmpty || entry.path.toLowerCase().contains(query))
        .take(6)
        .toList();

    void choosePage(NavigationItem item) {
      Navigator.of(context).pop();
      widget.onSelectPage(item.id);
    }

    void chooseFile(RecentFileEntry entry) {
      Navigator.of(context).pop();
      widget.onSelectFile(entry.path);
    }

    final hasAny = pages.isNotEmpty || recent.isNotEmpty;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
                child: Text(
                  t.shell.command_title,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextField(
                controller: _controller,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: t.shell.search_hint,
                ),
                onChanged: (value) => setState(() => _query = value),
                onSubmitted: (_) {
                  if (pages.isNotEmpty) {
                    choosePage(pages.first);
                  } else if (recent.isNotEmpty) {
                    chooseFile(recent.first);
                  }
                },
              ),
              const SizedBox(height: 10),
              if (!hasAny)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: Text(
                      t.shell.command_empty,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (pages.isNotEmpty) ...[
                        _SectionLabel(t.shell.command_pages),
                        for (final item in pages)
                          _Entry(
                            icon: item.icon,
                            title: item.label,
                            onTap: () => choosePage(item),
                          ),
                      ],
                      if (recent.isNotEmpty) ...[
                        _SectionLabel(t.shell.command_recent_files),
                        for (final entry in recent)
                          _Entry(
                            leading: RecentAppIcon(
                              iconFile: entry.iconFile,
                              fallback: entry.platform == 'ios'
                                  ? Icons.apple
                                  : Icons.android,
                              fallbackColor: entry.platform == 'ios'
                                  ? const Color(0xFF3A3A3C)
                                  : const Color(0xFF3DDC84),
                              size: 24,
                              radius: 6,
                            ),
                            title: _fileName(entry.path),
                            subtitle: entry.path,
                            onTap: () => chooseFile(entry),
                          ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? path : parts.last;
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _Entry({
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              leading ??
                  Icon(icon ?? Icons.chevron_right,
                      size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
