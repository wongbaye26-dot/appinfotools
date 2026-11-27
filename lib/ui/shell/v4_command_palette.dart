import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ui/shell/navigation_item.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 顶栏搜索入口：不搜索包内容，只做页面跳转。
///
/// 原型里这里是搜索框；当前产品没有全文搜索能力，所以先实现成明确的
/// **页面跳转面板**，不假装能搜安装包内部数据。
Future<void> showV4CommandPalette(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (_) => _V4CommandPalette(
      onSelect: (id) {
        ref.read(shellNavigationProvider.notifier).navigate(id);
      },
    ),
  );
}

class _V4CommandPalette extends StatefulWidget {
  final ValueChanged<String> onSelect;

  const _V4CommandPalette({required this.onSelect});

  @override
  State<_V4CommandPalette> createState() => _V4CommandPaletteState();
}

class _V4CommandPaletteState extends State<_V4CommandPalette> {
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
    final items = AppNavigation.items()
        .where(
            (item) => item.label.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    void choose(NavigationItem item) {
      Navigator.of(context).pop();
      widget.onSelect(item.id);
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
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
                  if (items.isNotEmpty) choose(items.first);
                },
              ),
              const SizedBox(height: 8),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: Text(
                      t.shell.command_empty,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in items)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: InkWell(
                            onTap: () => choose(item),
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 11,
                              ),
                              child: Row(
                                children: [
                                  Icon(item.icon,
                                      size: 18, color: scheme.onSurfaceVariant),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      item.label,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  Icon(Icons.keyboard_return,
                                      size: 14,
                                      color: scheme.onSurfaceVariant
                                          .withValues(alpha: 0.5)),
                                ],
                              ),
                            ),
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
