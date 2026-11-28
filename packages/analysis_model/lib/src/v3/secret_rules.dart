// 敏感信息规则表（V3 F01）。
//
// 取舍：只收「格式唯一、误报可接受」的凭证；不做泛化的高熵字符串检测 ——
// 那会把 base64 资源、哈希常量全炸出来。需要泛化时由用户在 Profile 里显式启用。
//
// 每条规则必须给：稳定 id、类型、可信度、以及**是否取捕获组**（有些规则的
// 完整匹配包含 `api_key = "…"` 之类上下文，真正要脱敏的是组 1）。

import 'secret_match.dart';

class SecretRule {
  /// 稳定规则 id，进指纹；改名 = 换规则，必须同时升规则版本。
  final String id;

  final SecretKind kind;
  final SecretConfidence confidence;

  /// 用于查找的表达式。
  final RegExp pattern;

  /// 命中后取哪个捕获组作为「值」；0 = 整个匹配。
  final int valueGroup;

  const SecretRule({
    required this.id,
    required this.kind,
    required this.confidence,
    required this.pattern,
    this.valueGroup = 0,
  });
}

/// 规则版本；与 `SecretScanner.extractorId` 一起进报告，便于解释「为什么这次没扫到」。
const String secretRulesVersion = '1';

final List<SecretRule> secretRules = List.unmodifiable([
  SecretRule(
    id: 'secret.aws-access-key',
    kind: SecretKind.awsAccessKey,
    confidence: SecretConfidence.high,
    pattern: RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  ),
  SecretRule(
    id: 'secret.google-api-key',
    kind: SecretKind.googleApiKey,
    confidence: SecretConfidence.high,
    pattern: RegExp(r'\bAIza[0-9A-Za-z_\-]{35}\b'),
  ),
  SecretRule(
    id: 'secret.github-token',
    kind: SecretKind.githubToken,
    confidence: SecretConfidence.high,
    pattern: RegExp(r'\bgh[pousr]_[A-Za-z0-9]{36,255}\b'),
  ),
  SecretRule(
    id: 'secret.slack-token',
    kind: SecretKind.slackToken,
    confidence: SecretConfidence.high,
    pattern: RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{10,}\b'),
  ),
  SecretRule(
    id: 'secret.stripe-live-key',
    kind: SecretKind.stripeSecretKey,
    confidence: SecretConfidence.high,
    pattern: RegExp(r'\b[sr]k_live_[0-9A-Za-z]{20,}\b'),
  ),
  SecretRule(
    id: 'secret.private-key-header',
    kind: SecretKind.privateKey,
    confidence: SecretConfidence.high,
    pattern:
        RegExp(r'-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----'),
  ),
  SecretRule(
    id: 'secret.jwt',
    kind: SecretKind.jwt,
    confidence: SecretConfidence.medium,
    pattern: RegExp(
        r'\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b'),
  ),
  SecretRule(
    id: 'secret.credential-assignment',
    kind: SecretKind.genericCredential,
    confidence: SecretConfidence.medium,
    // 必须同时有「敏感词 + 赋值符号 + 引号包裹的值」，避免把普通注释算进来。
    // Dart 不支持 `(?i)` 内联标志，用 caseSensitive: false。
    pattern: RegExp(
      r'''\b(?:api[_-]?key|secret|token|password|passwd)\b\s*[:=]\s*["']([A-Za-z0-9_\-\.]{16,})["']''',
      caseSensitive: false,
    ),
    valueGroup: 1,
  ),
]);
