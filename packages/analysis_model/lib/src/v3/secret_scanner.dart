// 敏感信息扫描器（V3 F01）。
//
// 输入是**已解码的文本**，不负责读 zip：这样同一套规则既能扫 DEX 字符串，
// 也能扫 Info.plist、assets JSON 与用户粘贴的片段。
//
// 预算与脱敏：
// - 单次扫描有字节上限与命中上限，超限写进 `skippedCodes`；
// - 返回的 `SecretMatch` 不含明文；上下文里的命中值也被替换成脱敏值。

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'finding_fingerprint.dart';
import 'secret_match.dart';
import 'secret_rules.dart';

typedef SecretMatchPredicate = bool Function(SecretMatch match);

/// 扫描上限。
class SecretScanLimits {
  /// 单次扫描的文本字节上限（UTF-8）。
  final int maxBytes;

  /// 总命中上限。
  final int maxMatches;

  /// 单条规则的命中上限。
  final int maxMatchesPerRule;

  /// 上下文窗口（命中前后各多少字符）。
  final int contextRadius;

  const SecretScanLimits({
    this.maxBytes = 4 * 1024 * 1024,
    this.maxMatches = 200,
    this.maxMatchesPerRule = 50,
    this.contextRadius = 40,
  });
}

/// 扫描结果。
class SecretScanOutcome {
  final List<SecretMatch> matches;
  final int scannedBytes;
  final bool truncated;
  final List<String> skippedCodes;

  const SecretScanOutcome({
    this.matches = const [],
    this.scannedBytes = 0,
    this.truncated = false,
    this.skippedCodes = const [],
  });
}

/// 脱敏工具；报告与 UI 共用，避免两处写出不同规则。
class SecretRedactor {
  const SecretRedactor._();

  /// 长度 ≥16 留前 4 后 4；8–15 留前 2 后 2；更短全掩。
  static String redact(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '***';
    if (trimmed.length >= 16) {
      return '${trimmed.substring(0, 4)}…${trimmed.substring(trimmed.length - 4)}';
    }
    if (trimmed.length >= 8) {
      return '${trimmed.substring(0, 2)}…${trimmed.substring(trimmed.length - 2)}';
    }
    return '***';
  }
}

class SecretScanner {
  const SecretScanner._();

  /// 进报告与证据的扫描器 id；规则变化时必须同时改这里。
  static const String extractorId = 'secret.regex.v$secretRulesVersion';

  /// 扫描一段文本。
  ///
  /// [location] 由调用方给：包内路径（嵌套用 `!`），用于稳定指纹。
  static SecretScanOutcome scanText(
    String text, {
    required String location,
    SecretScanLimits limits = const SecretScanLimits(),
    List<SecretRule> rules = const [],
  }) {
    final skipped = <String>{};
    final effectiveRules = rules.isEmpty ? secretRules : rules;
    final bytes = utf8.encode(text);
    var body = text;
    var truncated = false;
    if (bytes.length > limits.maxBytes) {
      // 按字节截断需要避免切断 UTF-8 序列：先用字节切片再解码（allowMalformed）。
      body =
          utf8.decode(bytes.sublist(0, limits.maxBytes), allowMalformed: true);
      truncated = true;
      skipped.add('secret.byteLimit');
    }

    final matches = <SecretMatch>[];
    final seen = <String>{};

    for (final rule in effectiveRules) {
      var ruleCount = 0;
      for (final match in rule.pattern.allMatches(body)) {
        if (ruleCount >= limits.maxMatchesPerRule) {
          truncated = true;
          skipped.add('secret.ruleMatchLimit');
          break;
        }
        if (matches.length >= limits.maxMatches) {
          truncated = true;
          skipped.add('secret.matchLimit');
          break;
        }
        final value = rule.valueGroup == 0
            ? match.group(0)
            : match.group(rule.valueGroup);
        if (value == null || value.trim().isEmpty) continue;
        final normalized = value.trim();
        final valueHash =
            sha256.convert(utf8.encode(normalized)).toString().substring(0, 16);
        final dedupeKey = '${rule.id}|$valueHash';
        if (!seen.add(dedupeKey)) continue;

        ruleCount++;
        matches.add(
          SecretMatch(
            id: FindingFingerprint.of(
              ruleId: rule.id,
              platform: 'any',
              artifactPath: location,
              location: '${match.start}',
              value: normalized,
            ),
            ruleId: rule.id,
            kind: rule.kind,
            confidence: rule.confidence,
            redactedValue: SecretRedactor.redact(normalized),
            valueSha256: valueHash,
            location: location,
            contextRedacted: _context(
                body, match.start, match.end, normalized, limits.contextRadius),
            extractorId: extractorId,
          ),
        );
      }
      if (matches.length >= limits.maxMatches) break;
    }

    matches.sort((a, b) {
      final kind = a.kind.index.compareTo(b.kind.index);
      if (kind != 0) return kind;
      return a.location.compareTo(b.location);
    });

    return SecretScanOutcome(
      matches: List.unmodifiable(matches),
      scannedBytes: truncated ? limits.maxBytes : bytes.length,
      truncated: truncated,
      skippedCodes: skipped.toList()..sort(),
    );
  }

  static String _context(
    String text,
    int start,
    int end,
    String value,
    int radius,
  ) {
    final from = start - radius < 0 ? 0 : start - radius;
    final to = end + radius > text.length ? text.length : end + radius;
    var window = text.substring(from, to).replaceAll(RegExp(r'\s+'), ' ');
    // 窗口里出现的完整值要替换掉：上下文同样不能带明文。
    if (value.length >= 4) {
      window = window.replaceAll(value, SecretRedactor.redact(value));
    }
    if (window.length > 160) {
      window = '${window.substring(0, 157)}…';
    }
    return window.trim();
  }
}
