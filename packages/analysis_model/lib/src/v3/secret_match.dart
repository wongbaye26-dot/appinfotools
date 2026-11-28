// 敏感信息命中（V3 F01）。
//
// 三条硬约束：
// 1. 模型里**不保存明文**：只存脱敏值与值的 SHA-256 前缀；
// 2. 定位要可复现：`location` 用「包内路径 / 归档内条目」的稳定写法；
// 3. 处置要稳定：`id` 复用 FindingFingerprint，规则/位置/值任一变化才变。

import 'finding_fingerprint.dart';

/// 敏感信息类型。新增类型要同步报告与 UI 的排序。
enum SecretKind {
  awsAccessKey,
  googleApiKey,
  githubToken,
  slackToken,
  stripeSecretKey,
  jwt,
  privateKey,
  genericCredential;

  static SecretKind? fromName(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// 命中可信度。`high` 只给格式唯一、误报极低的规则。
enum SecretConfidence {
  high,
  medium,
  low;

  static SecretConfidence fromName(String? value) {
    for (final confidence in values) {
      if (confidence.name == value) return confidence;
    }
    return low;
  }
}

/// 一条敏感信息命中。
class SecretMatch {
  /// 稳定指纹（`v1:<32hex>`），与 `FindingFingerprint` 同源。
  final String id;

  final String ruleId;
  final SecretKind kind;
  final SecretConfidence confidence;

  /// 脱敏展示值，例如 `AKIA…MPLE`。**永远不含完整明文**。
  final String redactedValue;

  /// 值的 SHA-256 前 16 位；用于去重与「同一条」判定。
  final String valueSha256;

  /// 位置：`lib/…/classes.dex` 或 `assets/x.zip!payload.json`。
  final String location;

  /// 命中前后文（同样脱敏、压成单行、截断）。
  final String contextRedacted;

  /// 产出该命中的扫描器 id。
  final String extractorId;

  const SecretMatch({
    required this.id,
    required this.ruleId,
    required this.kind,
    required this.confidence,
    required this.redactedValue,
    required this.valueSha256,
    required this.location,
    required this.contextRedacted,
    required this.extractorId,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'ruleId': ruleId,
        'kind': kind.name,
        'confidence': confidence.name,
        'redactedValue': redactedValue,
        'valueSha256': valueSha256,
        'location': location,
        'context': contextRedacted,
        'extractorId': extractorId,
      };

  static SecretMatch fromJson(Map<String, Object?> json) {
    final ruleId = (json['ruleId'] as String?)?.trim() ?? '';
    if (ruleId.isEmpty) {
      throw const FormatException('secretMatch.ruleId is required');
    }
    final location = (json['location'] as String?)?.trim() ?? '';
    final valueSha256 = (json['valueSha256'] as String?)?.trim() ?? '';
    return SecretMatch(
      id: (json['id'] as String?)?.trim().isNotEmpty == true
          ? json['id'] as String
          : FindingFingerprint.of(
              ruleId: ruleId,
              platform: 'any',
              location: location,
              value: valueSha256,
            ),
      ruleId: ruleId,
      kind: SecretKind.fromName(json['kind'] as String?) ??
          SecretKind.genericCredential,
      confidence: SecretConfidence.fromName(json['confidence'] as String?),
      redactedValue: (json['redactedValue'] as String?) ?? '',
      valueSha256: valueSha256,
      location: location,
      contextRedacted: (json['context'] as String?) ?? '',
      extractorId: (json['extractorId'] as String?) ?? '',
    );
  }
}
