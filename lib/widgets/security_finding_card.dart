import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';

/// 单条安全发现项的展示卡片。
///
/// 包含：
/// - 顶部：风险等级徽章 + 规则 ID + 置信度标签
/// - 标题：发现描述
/// - 展开区：证据列表、数据源/汇、建议、局限
///
/// 按严重程度使用不同颜色编码：
/// - P0 (Critical): 深红
/// - P1 (High): 橙红
/// - P2 (Medium): 琥珀
/// - P3 (Low): 蓝灰
/// - INFO: 蓝绿
/// - UNKNOWN: 灰
class SecurityFindingCard extends StatefulWidget {
  final SecurityFinding finding;

  const SecurityFindingCard({super.key, required this.finding});

  @override
  State<SecurityFindingCard> createState() => _SecurityFindingCardState();
}

class _SecurityFindingCardState extends State<SecurityFindingCard> {
  bool _expanded = false;

  Color _severityColor(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    return switch (widget.finding.severity) {
      SecuritySeverity.p0 =>
        isDark ? const Color(0xFFEF5350) : const Color(0xFFD32F2F),
      SecuritySeverity.p1 =>
        isDark ? const Color(0xFFFF7043) : const Color(0xFFE64A19),
      SecuritySeverity.p2 =>
        isDark ? const Color(0xFFFFCA28) : const Color(0xFFFBC02D),
      SecuritySeverity.p3 =>
        isDark ? const Color(0xFF90A4AE) : const Color(0xFF607D8B),
      SecuritySeverity.info =>
        isDark ? const Color(0xFF4DB6AC) : const Color(0xFF00897B),
      SecuritySeverity.unknown =>
        isDark ? const Color(0xFFB0BEC5) : const Color(0xFF78909C),
    };
  }

  Color _severityBackground(BuildContext context) {
    return _severityColor(context).withValues(alpha: 0.1);
  }

  String get _severityLabel => switch (widget.finding.severity) {
        SecuritySeverity.p0 => 'P0',
        SecuritySeverity.p1 => 'P1',
        SecuritySeverity.p2 => 'P2',
        SecuritySeverity.p3 => 'P3',
        SecuritySeverity.info => 'INFO',
        SecuritySeverity.unknown => '?',
      };

  String get _confidenceLabel => switch (widget.finding.confidence) {
        SecurityConfidence.confirmed => t.security.confidence_confirmed,
        SecurityConfidence.suspected => t.security.confidence_suspected,
        SecurityConfidence.independentCapability =>
          t.security.confidence_capability,
        SecurityConfidence.unknown => t.security.confidence_unknown,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final severityColor = _severityColor(context);
    final finding = widget.finding;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: severityColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部徽章行
              Row(
                children: [
                  // 严重程度徽章
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _severityBackground(context),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: severityColor.withValues(alpha: 0.4),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      _severityLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: severityColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 规则 ID
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      finding.ruleId,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.hintColor,
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // 置信度标签
                  _ConfidenceChip(label: _confidenceLabel),
                ],
              ),
              const SizedBox(height: 12),
              // 发现标题
              Text(
                AnalysisReport.findingText(finding, t),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              // 展开内容
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: _buildExpandedContent(context),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
              ),
              const SizedBox(height: 4),
              // 展开指示器
              Center(
                child: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: theme.hintColor.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedContent(BuildContext context) {
    final theme = Theme.of(context);
    final finding = widget.finding;
    final evidence = finding.evidence;
    // 关联 / 建议 / 局限都要走呈现层的本地化：引擎产出的是稳定 code +
    // 英文回退，直接读裸字段会在英文界面下显示中文（B11）。
    final relationship = AnalysisReport.relationshipText(finding, t);
    final recommendation = AnalysisReport.recommendationText(finding, t);
    final limitation = AnalysisReport.limitationText(finding, t);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 证据列表
          if (evidence.isNotEmpty) ...[
            Text(
              'Evidence',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...evidence.map((e) => _EvidenceTile(evidence: e)),
            const SizedBox(height: 16),
          ],
          // 数据源/汇
          if (finding.dataSource != null || finding.dataSink != null)
            _buildDataFlowRow(context),
          // 关联说明：这条结论的「依据链」走到哪一步、哪一段没证实。
          //
          // 与下面的「局限」是两件事：局限说的是**能力边界**（没做反汇编），
          // 关联说的是**这条结论自己的证据链**。只说「有风险」而不说依据到
          // 哪一步，读者无从复核 —— 这正是本项目可信度表达的核心。
          if (relationship != null && relationship.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildRelationship(context, relationship),
          ],
          // 建议
          if (recommendation.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildRecommendation(context, recommendation),
          ],
          // 局限
          if (limitation != null && limitation.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildLimitation(context, limitation),
          ],
        ],
      ),
    );
  }

  Widget _buildDataFlowRow(BuildContext context) {
    final finding = widget.finding;

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        if (finding.dataSource != null)
          _FlowChip(
            icon: Icons.arrow_upward,
            label: 'Source: ${finding.dataSource}',
          ),
        if (finding.dataSink != null)
          _FlowChip(
            icon: Icons.arrow_downward,
            label: 'Sink: ${finding.dataSink}',
          ),
      ],
    );
  }

  /// 关联说明。
  ///
  /// 与「局限」分开渲染：局限是能力边界（没做反汇编、预算截断），
  /// 关联是**这条结论自己的证据链**（哪一段只是同现、哪一段没证实）。
  Widget _buildRelationship(BuildContext context, String text) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.link, size: 14, color: theme.hintColor),
              const SizedBox(width: 6),
              Text(
                t.security.relationship,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(text, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _buildRecommendation(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lightbulb_outline,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLimitation(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: theme.hintColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 置信度小标签。
class _ConfidenceChip extends StatelessWidget {
  final String label;

  const _ConfidenceChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.hintColor.withValues(alpha: 0.8),
          fontSize: 10,
        ),
      ),
    );
  }
}

/// 数据流标签（Source/Sink）。
class _FlowChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _FlowChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: theme.hintColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.hintColor.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条证据的展示瓦片。
class _EvidenceTile extends StatelessWidget {
  final SecurityEvidence evidence;

  const _EvidenceTile({required this.evidence});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 位置信息
            if (evidence.location.isNotEmpty)
              Text(
                // 少数位置是给人读的描述（「N 个 DEX 的字符串」），要本地化。
                AnalysisReport.locationText(evidence, t),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            // 详情
            if (evidence.detail.isNotEmpty) ...[
              if (evidence.location.isNotEmpty) const SizedBox(height: 4),
              SelectableText(
                // 详情里的标签（引用 / 调用点 / 导入）也要本地化，
                // 引擎产出的是稳定 code + 英文回退。
                AnalysisReport.detailText(evidence, t),
                style: theme.textTheme.bodySmall,
              ),
            ],
            // 来源类型
            if (evidence.source != SecurityEvidenceSource.other) ...[
              const SizedBox(height: 4),
              Text(
                evidence.source.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor.withValues(alpha: 0.6),
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
