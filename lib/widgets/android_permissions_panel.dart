import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:flutter/material.dart';

/// 权限清单面板（「权限」Tab）。
///
/// 与旧的「一行一个包名」列表相比，这里补上三件事：
/// 1. **官方说明**：Android 平台对每条框架权限的定义（跟随界面语言）；
/// 2. **保护级别**：`protectionLevel` 的原始分类与附加标志，用于解释「这条
///    权限普通应用根本申请不到」；
/// 3. **风险分组**：按「能读到什么/能做什么」分成高风险、敏感、普通、系统、
///    未知五档。
///
/// 风险分级是**本工具的策略**，不是 Android 的官方分类 —— 平台只分
/// dangerous/normal/signature，而 dangerous 里既有通讯录也有通知，全标红会让
/// 提示失去意义。所以卡片底部固定放一句说明，避免用户把「高风险」读成
/// 「这个应用有问题」。
class AndroidPermissionsPanel extends StatelessWidget {
  const AndroidPermissionsPanel({super.key, required this.permissions});

  final List<String> permissions;

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final meta = AndroidMetadata.instance;

    final entries = [
      for (final name in permissions) _PermissionEntry.of(name, meta),
    ];

    if (entries.isEmpty) {
      return Card(
        child: ListTile(
          title: Text(t.apk_info.permissions),
          subtitle: Text('-'),
        ),
      );
    }

    final groups = <AndroidPermissionRisk, List<_PermissionEntry>>{};
    for (final entry in entries) {
      groups.putIfAbsent(entry.risk, () => []).add(entry);
    }
    for (final list in groups.values) {
      list.sort((a, b) => a.shortName.compareTo(b.shortName));
    }

    final counts = {
      for (final risk in AndroidPermissionRisk.values)
        risk: groups[risk]?.length ?? 0,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.apk_info.permission_summary(count: entries.length),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final risk in AndroidPermissionRisk.values)
                      if (counts[risk]! > 0)
                        _RiskChip(
                          risk: risk,
                          label: '${_riskLabel(t, risk)} ${counts[risk]}',
                        ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  t.apk_info.permission_risk_note,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ),
        for (final risk in AndroidPermissionRisk.values)
          if (groups[risk] != null)
            _RiskGroupCard(
              risk: risk,
              title: t.apk_info.permission_group_header(
                risk: _riskLabel(t, risk),
                count: groups[risk]!.length,
              ),
              entries: groups[risk]!,
              t: t,
            ),
      ],
    );
  }

  static String _riskLabel(Translations t, AndroidPermissionRisk risk) {
    return switch (risk) {
      AndroidPermissionRisk.high => t.apk_info.permission_risk_high,
      AndroidPermissionRisk.sensitive => t.apk_info.permission_risk_sensitive,
      AndroidPermissionRisk.normal => t.apk_info.permission_risk_normal,
      AndroidPermissionRisk.system => t.apk_info.permission_risk_system,
      AndroidPermissionRisk.unknown => t.apk_info.permission_risk_unknown,
    };
  }
}

class _PermissionEntry {
  _PermissionEntry({
    required this.name,
    required this.shortName,
    required this.label,
    required this.description,
    required this.protection,
    required this.risk,
  });

  final String name;
  final String shortName;
  final String? label;
  final String? description;
  final AndroidProtection? protection;
  final AndroidPermissionRisk risk;

  factory _PermissionEntry.of(String name, AndroidMetadata meta) {
    const prefix = 'android.permission.';
    final shortName =
        name.startsWith(prefix) ? name.substring(prefix.length) : name;
    return _PermissionEntry(
      name: name,
      shortName: shortName,
      label: meta.permissionLabel(name),
      description: meta.permissionDescription(name),
      protection: meta.protectionOf(name),
      risk: meta.riskOf(name),
    );
  }
}

class _RiskGroupCard extends StatelessWidget {
  const _RiskGroupCard({
    required this.risk,
    required this.title,
    required this.entries,
    required this.t,
  });

  final AndroidPermissionRisk risk;
  final String title;
  final List<_PermissionEntry> entries;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: _riskColor(theme, risk).withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(_riskIcon(risk), size: 18, color: _riskColor(theme, risk)),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
          ),
          for (final entry in entries) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.label ?? entry.shortName,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry.name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (entry.description != null)
                          Text(
                            entry.description!,
                            style: theme.textTheme.bodySmall,
                          )
                        else
                          Text(
                            entry.protection == null
                                ? t.apk_info.permission_custom
                                : t.apk_info.permission_no_description,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (entry.protection != null) ...[
                    const SizedBox(width: 12),
                    _ProtectionChip(protection: entry.protection!, t: t),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 保护级别徽标：正文只写基本级别（dangerous/signature/normal…），附加标志
/// （runtime、privileged…）放进 tooltip —— 它们对「普通应用能不能拿到这条
/// 权限」的结论有影响，但一行 chip 塞不下。
class _ProtectionChip extends StatelessWidget {
  const _ProtectionChip({required this.protection, required this.t});

  final AndroidProtection protection;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    final level = switch (protection.base) {
      AndroidProtectionBase.dangerous => t.apk_info.permission_base_dangerous,
      AndroidProtectionBase.signature => t.apk_info.permission_base_signature,
      AndroidProtectionBase.signatureOrSystem =>
        t.apk_info.permission_base_signature_or_system,
      AndroidProtectionBase.internal => t.apk_info.permission_base_internal,
      AndroidProtectionBase.normal => t.apk_info.permission_base_normal,
    };
    final details = [
      '0x${protection.raw.toRadixString(16)}',
      ...protection.flags.map((flag) => _flagLabel(flag, t)),
    ].join(', ');
    return Tooltip(
      message: t.apk_info.permission_protection(level: '$level ($details)'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          level,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}

/// protectionLevel 的标志位（`privileged`、`runtime`…）在数据里是稳定标识符，
/// 界面按语言翻译；遇到未知标志位原样显示，而不是吞掉它。
String _flagLabel(String flag, Translations t) => switch (flag) {
      'privileged' => t.apk_info.protection_flag_privileged,
      'development' => t.apk_info.protection_flag_development,
      'appop' => t.apk_info.protection_flag_appop,
      'pre23' => t.apk_info.protection_flag_pre23,
      'installer' => t.apk_info.protection_flag_installer,
      'verifier' => t.apk_info.protection_flag_verifier,
      'preinstalled' => t.apk_info.protection_flag_preinstalled,
      'setup' => t.apk_info.protection_flag_setup,
      'instant' => t.apk_info.protection_flag_instant,
      'runtime' => t.apk_info.protection_flag_runtime,
      'oem' => t.apk_info.protection_flag_oem,
      'vendorPrivileged' => t.apk_info.protection_flag_vendor_privileged,
      'textClassifier' => t.apk_info.protection_flag_text_classifier,
      'wellbeing' => t.apk_info.protection_flag_wellbeing,
      'documenter' => t.apk_info.protection_flag_documenter,
      'configurator' => t.apk_info.protection_flag_configurator,
      'incidentReportApprover' =>
        t.apk_info.protection_flag_incident_report_approver,
      'appPredictor' => t.apk_info.protection_flag_app_predictor,
      'module' => t.apk_info.protection_flag_module,
      'companion' => t.apk_info.protection_flag_companion,
      'retailDemo' => t.apk_info.protection_flag_retail_demo,
      'recents' => t.apk_info.protection_flag_recents,
      'role' => t.apk_info.protection_flag_role,
      'knownSigner' => t.apk_info.protection_flag_known_signer,
      _ => flag,
    };

class _RiskChip extends StatelessWidget {
  const _RiskChip({required this.risk, required this.label});

  final AndroidPermissionRisk risk;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = _riskColor(Theme.of(context), risk);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

Color _riskColor(ThemeData theme, AndroidPermissionRisk risk) {
  return switch (risk) {
    AndroidPermissionRisk.high => theme.colorScheme.error,
    AndroidPermissionRisk.sensitive => theme.colorScheme.tertiary,
    AndroidPermissionRisk.normal => theme.colorScheme.primary,
    AndroidPermissionRisk.system => theme.colorScheme.secondary,
    AndroidPermissionRisk.unknown => theme.colorScheme.outline,
  };
}

IconData _riskIcon(AndroidPermissionRisk risk) {
  return switch (risk) {
    AndroidPermissionRisk.high => Icons.gpp_bad_outlined,
    AndroidPermissionRisk.sensitive => Icons.privacy_tip_outlined,
    AndroidPermissionRisk.normal => Icons.check_circle_outline,
    AndroidPermissionRisk.system => Icons.shield_outlined,
    AndroidPermissionRisk.unknown => Icons.help_outline,
  };
}
