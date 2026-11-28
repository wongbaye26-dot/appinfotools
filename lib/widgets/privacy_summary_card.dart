import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/utils/privacy_inventory.dart';
import 'package:flutter/material.dart';

/// 隐私概览卡：权限风险分布 + 高敏权限 + iOS 用途声明。
///
/// 刻意不把 SDK 清单塞进来：SDK 在「库识别」Tab 有完整的分组与证据，
/// 这里再列一遍会出现两个不同步的列表。卡片只用一行提示指向它。
class PrivacySummaryCard extends StatelessWidget {
  final PrivacyInventory inventory;

  const PrivacySummaryCard({super.key, required this.inventory});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;
    final risks = [
      AndroidPermissionRisk.high,
      AndroidPermissionRisk.sensitive,
      AndroidPermissionRisk.normal,
      AndroidPermissionRisk.system,
      AndroidPermissionRisk.unknown,
    ].where((risk) => inventory.countOf(risk) > 0).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.privacy_tip_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  t.privacy.title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  t.privacy
                      .permission_count(count: '${inventory.totalPermissions}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!inventory.permissionsRead)
              Text(t.privacy.not_read, style: theme.textTheme.bodySmall)
            else if (risks.isEmpty)
              Text(t.base.no_data, style: theme.textTheme.bodySmall)
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final risk in risks)
                    _RiskChip(
                      label: _riskLabel(risk, t),
                      count: inventory.countOf(risk),
                      risk: risk,
                    ),
                ],
              ),
            if (inventory.notable.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final permission in inventory.notable.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(
                          Icons.circle,
                          size: 7,
                          color: permission.risk == AndroidPermissionRisk.high
                              ? theme.colorScheme.error
                              : theme.colorScheme.tertiary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              permission.label ?? permission.shortName,
                              style: theme.textTheme.bodyMedium,
                            ),
                            if (permission.description != null)
                              Text(
                                permission.description!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (inventory.notable.length > 6)
                Text(
                  t.privacy.more(count: '${inventory.notable.length - 6}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
            if (inventory.iosUsageKeys.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                t.privacy
                    .usage_count(count: '${inventory.iosUsageKeys.length}'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                inventory.iosUsageKeys.join(' · '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'Menlo',
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.hub_outlined,
                    size: 13, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    inventory.librariesRead
                        ? t.privacy.sdk_count(count: '${inventory.sdks.length}')
                        : t.privacy.sdk_hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _riskLabel(AndroidPermissionRisk risk, Translations t) =>
      switch (risk) {
        AndroidPermissionRisk.high => t.apk_info.permission_risk_high,
        AndroidPermissionRisk.sensitive => t.apk_info.permission_risk_sensitive,
        AndroidPermissionRisk.normal => t.apk_info.permission_risk_normal,
        AndroidPermissionRisk.system => t.apk_info.permission_risk_system,
        AndroidPermissionRisk.unknown => t.apk_info.permission_risk_unknown,
      };
}

class _RiskChip extends StatelessWidget {
  final String label;
  final int count;
  final AndroidPermissionRisk risk;

  const _RiskChip({
    required this.label,
    required this.count,
    required this.risk,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (risk) {
      AndroidPermissionRisk.high => scheme.error,
      AndroidPermissionRisk.sensitive => scheme.tertiary,
      AndroidPermissionRisk.normal => scheme.primary,
      AndroidPermissionRisk.system => scheme.secondary,
      AndroidPermissionRisk.unknown => scheme.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '$label · $count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
