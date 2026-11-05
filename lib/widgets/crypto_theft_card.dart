import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';

/// 安全 Tab 的「盗 U」证据链卡片。
///
/// 它只呈现 [CryptoTheftAssessment] 的事实：五段链、缺失环节、官方基线状态
/// 与下一步动作。**不**在这里重新判级，也不把「疑似」写成「已证实」。
class CryptoTheftCard extends StatelessWidget {
  final CryptoTheftAssessment assessment;

  /// 密封校验；`null` = 未做/未注入摘要函数。
  final SealCheck? seal;

  /// 官方基线匹配；`null` = 未做/无基线库。
  final BaselineMatch? baseline;

  const CryptoTheftCard({
    super.key,
    required this.assessment,
    this.seal,
    this.baseline,
  });

  Color _color(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (assessment.severity) {
      SecuritySeverity.p0 =>
        dark ? const Color(0xFFEF5350) : const Color(0xFFD32F2F),
      SecuritySeverity.p1 =>
        dark ? const Color(0xFFFF7043) : const Color(0xFFE64A19),
      SecuritySeverity.p2 =>
        dark ? const Color(0xFFFFCA28) : const Color(0xFFFBC02D),
      SecuritySeverity.p3 =>
        dark ? const Color(0xFF90A4AE) : const Color(0xFF607D8B),
      SecuritySeverity.info =>
        dark ? const Color(0xFF4DB6AC) : const Color(0xFF00897B),
      SecuritySeverity.unknown =>
        dark ? const Color(0xFFB0BEC5) : const Color(0xFF78909C),
    };
  }

  String get _levelLabel => switch (assessment.level) {
        CryptoTheftLevel.none => t.security.crypto_risk.state_none,
        CryptoTheftLevel.capabilityOnly => t.theft.level_capability,
        CryptoTheftLevel.suspicious => t.theft.level_suspicious,
        CryptoTheftLevel.strongEvidence => t.theft.level_strong,
        CryptoTheftLevel.knownFamily => t.theft.level_strong,
        CryptoTheftLevel.unknown => t.theft.level_unknown,
      };

  String _stageLabel(ChainStage stage) => switch (stage) {
        ChainStage.capability => t.theft.stage_capability,
        ChainStage.source => t.theft.stage_source,
        ChainStage.injection => t.theft.stage_injection,
        ChainStage.payload => t.theft.stage_payload,
        ChainStage.family => t.theft.stage_family,
      };

  String _missingLabel(String whyCode) => switch (whyCode) {
        'missing.noCapability' => t.theft.missing_noCapability,
        'missing.noSource' => t.theft.missing_noSource,
        'missing.noInjection' => t.theft.missing_noInjection,
        'missing.noPayload' => t.theft.missing_noPayload,
        'missing.shellPacked' => t.theft.missing_shellPacked,
        'missing.noBaseline' => t.theft.missing_noBaseline,
        final other => other,
      };

  String get _baselineLabel {
    final id = assessment.baselineEntryId;
    if (id == null) return t.theft.baseline_none;
    // Phase C 还没有基线匹配字段；有 entryId 时按“命中”呈现，Phase E 再细分。
    return '${t.theft.baseline_match} ($id)';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _color(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.account_balance_wallet_outlined,
                    size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.security.crypto_risk.title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _levelLabel,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              t.theft.not_a_verdict,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            if (assessment.score != null) ...[
              const SizedBox(height: 4),
              Text(
                '${t.theft.score}: ${assessment.score}/100',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              t.theft.chain_title,
              style: theme.textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            for (final entry in assessment.chain) _stageRow(theme, entry),
            if (assessment.missing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                t.theft.missing_title,
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              for (final missing in assessment.missing)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '· ${_stageLabel(missing.stage)}: '
                    '${_missingLabel(missing.whyCode)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              '· ${t.theft.baseline_title}: $_baselineLabel'
              '${baseline?.entryId == null ? '' : ' (${baseline!.entryId})'}',
              style: theme.textTheme.bodySmall,
            ),
            if (seal case final seal?)
              Text(
                '· ${t.theft.seal_title}: ${_sealLabel(seal.state)} '
                '(${t.theft.seal_checked(checked: seal.entriesChecked, total: seal.entriesTotal)})',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            Text(
              t.theft.next_title,
              style: theme.textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            for (final text in [
              t.theft.next_clipboard,
              t.theft.next_signature,
              t.theft.next_official,
            ])
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('· $text', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  String _sealLabel(SealState state) => switch (state) {
        SealState.verified => t.theft.seal_verified,
        SealState.mismatch => t.theft.seal_mismatch,
        SealState.entryMissing => t.theft.seal_entry_missing,
        SealState.unsealed => t.theft.seal_unsealed,
        SealState.notChecked => t.theft.seal_not_checked,
        SealState.unknown => t.theft.seal_unknown,
      };

  Widget _stageRow(ThemeData theme, TechniqueEvidence entry) {
    final color = entry.supported
        ? (theme.brightness == Brightness.dark
            ? const Color(0xFF81C784)
            : const Color(0xFF2E7D32))
        : theme.hintColor;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            entry.supported
                ? Icons.check_circle_outline
                : Icons.radio_button_unchecked,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_stageLabel(entry.stage)} · '
                  '${entry.supported ? t.theft.stage_supported : t.theft.stage_missing}',
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
                if (entry.ruleIds.isNotEmpty)
                  Text(
                    entry.ruleIds.join(', '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
