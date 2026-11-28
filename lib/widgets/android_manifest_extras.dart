import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:flutter/material.dart';

/// 屏幕密度数值 → 资源限定符名。
///
/// 只列 AOSP 定义的档位；厂商自定义密度（如 280/420）原样显示数字 ——
/// 猜一个最近的档位反而会误导。
String androidDensityLabel(int value) => switch (value) {
      120 => 'ldpi (120)',
      160 => 'mdpi (160)',
      213 => 'tvdpi (213)',
      240 => 'hdpi (240)',
      320 => 'xhdpi (320)',
      480 => 'xxhdpi (480)',
      640 => 'xxxhdpi (640)',
      _ => '$value dpi',
    };

/// 语言标签的人话名字：`zh-CN` → `中文（中国）`（界面语言为中文时）。
///
/// 三段名称都来自 Android 平台的本地化表；缺哪段就少显示哪段，绝不拼出
/// `null`。连语言名都没有时退回标签本身，保证列表不会出现空行。
String androidLocaleLabel(String tag, Translations t) {
  final meta = AndroidMetadata.instance;
  final names = meta.localeNames(tag);
  final language = names.language;
  if (language == null || language.isEmpty) {
    final autonym = names.autonym;
    return autonym == null || autonym.isEmpty ? tag : '$tag · $autonym';
  }
  final variant = [names.script, names.region]
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .join(t.locale.variant_sep);
  final composed = variant.isEmpty
      ? language
      : t.locale.with_variant(language: language, variant: variant);
  final autonym = names.autonym;
  if (autonym == null || autonym.isEmpty || autonym == language) {
    return composed;
  }
  return '$composed · $autonym';
}

/// 硬件/软件特性卡片：必需与可选两组，带平台给的说明。
///
/// 说明表只覆盖常见特性（118 条），查不到就只显示名称 —— 编一句解释比
/// 不解释更糟，读者会当成官方说法。
class AndroidFeaturesCard extends StatelessWidget {
  final List<String> required;
  final List<String> optional;

  const AndroidFeaturesCard({
    super.key,
    required this.required,
    required this.optional,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = AndroidMetadata.instance;
    final items = <Widget>[];

    void addGroup(String title, List<String> values) {
      if (values.isEmpty) return;
      items.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(
          '$title (${values.length})',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ));
      for (final feature in values) {
        final description = meta.featureDescription(feature);
        items.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                feature,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (description != null && description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ));
      }
    }

    addGroup(t.apk_info.features_required, required);
    addGroup(t.apk_info.features_optional, optional);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.apk_info.features,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (items.isEmpty)
              Text(
                t.apk_info.features_none,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ...items,
          ],
        ),
      ),
    );
  }
}

/// 语言/地区列表：每行 `标签 · 本地化名称`。
class AndroidLocalesCard extends StatelessWidget {
  final List<String> locales;

  const AndroidLocalesCard({super.key, required this.locales});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.apk_info.languages, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final tag in locales)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 72,
                      child: SelectableText(
                        tag,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        androidLocaleLabel(tag, t),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
