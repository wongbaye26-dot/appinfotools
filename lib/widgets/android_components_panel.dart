import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ComponentType;
import 'package:flutter/material.dart';

import 'package:apk_info_tool/gen/strings.g.dart';

/// Android 组件（activity / service / receiver / provider）列表。
///
/// 取代早先「一整块 [SelectableText]、按 `maxLines` 截断」的展示方式：那种写法
/// 在组件多的时候只画前几行，其余内容既看不见、也复制不全，卡片 heights 还和
/// 其它 Tab 的卡片对不上。这里按类型分组，每行给出类名、导出状态与访问限制，
/// 高度由内容决定 —— 组件再多也只是把列表撑长，不会再被裁掉。
class AndroidComponentsPanel extends StatelessWidget {
  final List<AndroidComponent> components;

  const AndroidComponentsPanel({super.key, required this.components});

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (components.isEmpty) {
      return Card(
        child: ListTile(
          title: Text(t.apk_info.components),
          subtitle: Text(t.base.no_data),
        ),
      );
    }

    final byType = <ComponentType, List<AndroidComponent>>{};
    for (final component in components) {
      byType.putIfAbsent(component.type, () => []).add(component);
    }

    final exported =
        components.where((component) => component.effectivelyExported).length;

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
                    Icon(Icons.widgets_outlined, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        t.apk_info.components_summary(
                          count: components.length,
                          exported: exported,
                        ),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final type in ComponentType.values)
                      if (byType[type] != null)
                        _TypeChip(
                          label: '${_typeLabel(t, type)} ${byType[type]!.length}',
                        ),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (final type in ComponentType.values)
          if (byType[type] != null)
            _TypeCard(
              type: type,
              components: byType[type]!,
            ),
      ],
    );
  }

  static String _typeLabel(Translations t, ComponentType type) {
    return switch (type) {
      ComponentType.activity => t.apk_info.component_type_activity,
      ComponentType.activityAlias => t.apk_info.component_type_activity_alias,
      ComponentType.service => t.apk_info.component_type_service,
      ComponentType.receiver => t.apk_info.component_type_receiver,
      ComponentType.provider => t.apk_info.component_type_provider,
    };
  }
}

/// 一种组件类型的卡片：标题 + 计数，下面是逐条记录。
class _TypeCard extends StatelessWidget {
  final ComponentType type;
  final List<AndroidComponent> components;

  const _TypeCard({required this.type, required this.components});

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    AndroidComponentsPanel._typeLabel(t, type),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  // 元素名是 manifest 里的原文，保留等宽字体便于与 AXMl 对照。
                  '${type.elementName} · ${components.length}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < components.length; i++) ...[
            if (i > 0)
              Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
            _ComponentRow(component: components[i]),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _ComponentRow extends StatelessWidget {
  final AndroidComponent component;

  const _ComponentRow({required this.component});

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final chips = <Widget>[];
    if (component.exported != null) {
      chips.add(_FlagChip(
        label: component.exported!
            ? t.apk_info.exported
            : t.apk_info.not_exported,
        // 导出本身不是缺陷：带 permission 的导出是正常设计，没带才值得注意。
        tone: component.exported!
            ? (component.permission == null && component.readPermission == null
                ? _Tone.warning
                : _Tone.accent)
            : _Tone.neutral,
      ));
    } else if (component.effectivelyExported) {
      chips.add(_FlagChip(
        label: t.apk_info.exported_by_default,
        tone: _Tone.warning,
      ));
    }
    if (component.permission != null) {
      chips.add(_FlagChip(
        label: '${t.apk_info.component_permission}=${component.permission}',
        tone: _Tone.accent,
      ));
    }
    if (component.readPermission != null) {
      chips.add(_FlagChip(
        label: 'read=${component.readPermission}',
        tone: _Tone.accent,
      ));
    }
    if (component.writePermission != null) {
      chips.add(_FlagChip(
        label: 'write=${component.writePermission}',
        tone: _Tone.accent,
      ));
    }
    if (component.authorities != null) {
      chips.add(_FlagChip(
        label: 'authorities=${component.authorities}',
        tone: _Tone.neutral,
      ));
    }
    if (component.grantUriPermissions == true) {
      chips.add(_FlagChip(
        label: 'grantUriPermissions',
        tone: _Tone.warning,
      ));
    }

    final actions = <String>[
      for (final filter in component.intentFilters) ...filter.actions,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            component.name ?? t.apk_info.component_unnamed,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontSize: 12,
              color: scheme.onSurface,
            ),
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: chips),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _actionPreview(actions),
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// action 列表可能很长（浏览器类组件常有十几个），预览前 3 个即可，
  /// 完整值仍可选中复制 —— 这里只是不要让一行把卡片撑得过宽。
  static String _actionPreview(List<String> actions) {
    const limit = 3;
    if (actions.length <= limit) return actions.join('\n');
    return '${actions.take(limit).join('\n')}\n+${actions.length - limit}';
  }
}

enum _Tone { neutral, accent, warning }

class _FlagChip extends StatelessWidget {
  final String label;
  final _Tone tone;

  const _FlagChip({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (background, foreground, border) = switch (tone) {
      _Tone.warning => (
          scheme.tertiaryContainer.withValues(alpha: 0.55),
          scheme.onTertiaryContainer,
          scheme.tertiary.withValues(alpha: 0.35),
        ),
      _Tone.accent => (
          scheme.primaryContainer.withValues(alpha: 0.55),
          scheme.onPrimaryContainer,
          scheme.primary.withValues(alpha: 0.3),
        ),
      _Tone.neutral => (
          scheme.surfaceContainerHighest.withValues(alpha: 0.7),
          scheme.onSurfaceVariant,
          scheme.outlineVariant,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;

  const _TypeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
