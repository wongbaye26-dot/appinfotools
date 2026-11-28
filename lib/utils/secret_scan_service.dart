// 敏感信息扫描（V3 F01）：把包里的文本与 DEX 字符串喂给 `SecretScanner`。
//
// 三条硬约束：
// - 只返回 `SecretMatch`（脱敏值 + 哈希 + 指纹），**不把明文带出这一层**；
// - 所有读取走预算（单条 2 MiB、全包 12 MiB、条目上限 400），超了记 code；
// - 结果只在内存里，不写日志、不进报告 JSON 的明文位置（报告只写脱敏值）。

import 'dart:convert';
import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:apk_info_tool/utils/package_archive_tree.dart';

/// 一次敏感信息扫描的产物。
class SecretScanReport {
  final List<SecretMatch> matches;
  final int scannedEntries;
  final int scannedDexFiles;

  /// 是否有任意预算被截断（条目数、字节、命中数）。
  final bool truncated;
  final List<String> skippedCodes;

  const SecretScanReport({
    required this.matches,
    required this.scannedEntries,
    required this.scannedDexFiles,
    required this.truncated,
    required this.skippedCodes,
  });

  bool get isEmpty => matches.isEmpty;

  int countOf(SecretKind kind) =>
      matches.where((match) => match.kind == kind).length;
}

class SecretScanService {
  /// 显式查看明文：重新读条目、用同一规则再扫一遍，只返回哈希对得上的那一个值。
  ///
  /// 为什么不在扫描时缓存明文：缓存就等于「明文常驻内存直到会话结束」，
  /// 一旦崩溃转储或把对象打日志就泄露了。这里按需重扫，代价是用户点开时
  /// 多一次读条目，收益是明文只在对话框存活的那几秒里存在。
  ///
  /// 返回 null 表示「读不到」或「重扫结果对不上」，调用方不能自己拼值。
  static Future<String?> revealPlaintext(
    String packagePath,
    SecretMatch match, {
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    final (tree, _) = await PackageArchiveTree.open(packagePath);
    if (tree == null) return null;
    try {
      final read = tree.readEntry(match.location, maxBytes: maxBytes);
      final bytes = read.bytes;
      if (bytes == null) return null;
      final text = utf8.decode(bytes, allowMalformed: true);
      for (final rule in secretRules) {
        if (rule.id != match.ruleId) continue;
        for (final candidate in rule.pattern.allMatches(text)) {
          final raw = rule.valueGroup == 0
              ? candidate.group(0)
              : candidate.group(rule.valueGroup);
          if (raw == null || raw.trim().isEmpty) continue;
          if (SecretScanner.valueHashOf(raw) == match.valueSha256) {
            return raw;
          }
        }
      }
      return null;
    } finally {
      tree.close();
    }
  }

  /// 文本类条目的扩展名白名单：只扫「可能放配置/密钥」的文件，
  /// 不扫 res/ 里的二进制资源与图片。
  static const Set<String> textExtensions = {
    '.json',
    '.xml',
    '.properties',
    '.txt',
    '.pem',
    '.key',
    '.crt',
    '.yaml',
    '.yml',
    '.cfg',
    '.conf',
    '.env',
    '.js',
    '.plist',
    '.pro',
    '.md',
    '.gradle',
    '.ini',
    '.toml',
  };

  static const int maxTextEntries = 400;
  static const int maxEntryBytes = 2 * 1024 * 1024;
  static const int maxTotalTextBytes = 12 * 1024 * 1024;
  static const int maxDexFiles = 8;
  static const int maxDexBytes = 8 * 1024 * 1024;

  /// 扫描 [path]。失败（不是 zip、打不开）返回 null；预算截断不算失败。
  static Future<SecretScanReport?> scan(String path) async {
    final reader = ApkReader();
    final opened = await reader.open(path);
    if (!opened.isOk) return null;

    final matches = <SecretMatch>[];
    final skipped = <String>[];
    var truncated = false;
    var scannedEntries = 0;
    var scannedDexFiles = 0;
    var totalBytes = 0;
    final seen = <String>{};

    void addAll(SecretScanOutcome outcome) {
      for (final match in outcome.matches) {
        if (seen.add(match.id)) matches.add(match);
      }
      if (outcome.truncated) truncated = true;
      for (final code in outcome.skippedCodes) {
        if (!skipped.contains(code)) skipped.add(code);
      }
    }

    final names = reader.listFiles();

    // 1) 文本类条目
    for (final name in names) {
      if (scannedEntries >= maxTextEntries) {
        truncated = true;
        if (!skipped.contains('secret.entryLimit')) {
          skipped.add('secret.entryLimit');
        }
        break;
      }
      if (!_isTextEntry(name)) continue;
      final bytes = reader.readFilePrefix(name, maxBytes: maxEntryBytes);
      if (bytes == null) {
        if (!skipped.contains('secret.entryUnreadable')) {
          skipped.add('secret.entryUnreadable');
        }
        continue;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      addAll(
        SecretScanner.scanText(
          text,
          location: name,
          limits: const SecretScanLimits(maxBytes: maxEntryBytes),
        ),
      );
      scannedEntries++;
      totalBytes += bytes.length;
      if (totalBytes >= maxTotalTextBytes) {
        truncated = true;
        skipped.add('secret.totalByteLimit');
        break;
      }
    }

    // 2) DEX 字符串（先提取再扫：`SecretScanner` 吃文本，不吃二进制）
    for (final name in names) {
      if (scannedDexFiles >= maxDexFiles) {
        truncated = true;
        skipped.add('secret.dexLimit');
        break;
      }
      if (!_isDex(name)) continue;
      final bytes = reader.readFilePrefix(name, maxBytes: maxDexBytes);
      if (bytes == null) continue;
      final strings = AsciiStrings.extract(
        bytes,
        limit: maxDexBytes,
        minLength: 12,
      ).join('\n');
      addAll(
        SecretScanner.scanText(
          strings,
          location: name,
          limits: const SecretScanLimits(maxBytes: 4 * 1024 * 1024),
        ),
      );
      scannedDexFiles++;
    }

    reader.close();
    matches.sort((a, b) {
      final byKind = a.kind.index.compareTo(b.kind.index);
      return byKind != 0 ? byKind : a.location.compareTo(b.location);
    });
    return SecretScanReport(
      matches: List.unmodifiable(matches),
      scannedEntries: scannedEntries,
      scannedDexFiles: scannedDexFiles,
      truncated: truncated,
      skippedCodes: List.unmodifiable(skipped),
    );
  }

  static bool _isTextEntry(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = name.substring(dot).toLowerCase();
    return textExtensions.contains(ext);
  }

  static bool _isDex(String name) =>
      RegExp(r'^classes\d*\.dex$').hasMatch(name);
}
