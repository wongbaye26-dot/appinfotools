// Finding 稳定指纹（V3 F06 误报处置 / 跨 run 差异的前提）。
//
// 现在 `SecurityFinding` 只有数组下标可用：重扫一次、规则顺序变一次，
// 「同一条问题」就对不上，用户也就无法把「已忽略」带到下一次分析。
//
// 设计取舍：
// - 指纹只包含「能定位到同一处问题」的字段：规则、平台、文件、位置、值；
//   不含分析 id、时间戳、数组下标 —— 它们每次都会变。
// - 位置里的 `+0x…` 偏移与行号被去掉：重编译、重新压缩都会变，
//   保留它们会让同一条问题每次都算「新增」。
// - 值先做 sha256 再截断：指纹会进历史与报告，不应直接暴露密钥原文。

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Finding 指纹。
///
/// 规范串：`v<version>|<platform>|<ruleId>|<artifactPath>|<location>|<valueHash>`。
/// 输出：`v<version>:<sha256 前 32 位十六进制>`。
class FindingFingerprint {
  const FindingFingerprint._();

  /// 算法版本。调整规范化规则必须 +1，并保留旧版本的可读性。
  static const int version = 1;

  /// 十六进制偏移与 `@ 0x…` 地址：构建/解压后必然变化。
  static final RegExp _hexOffset = RegExp(r'(?:\+|\bat\b|\b0x)\s*0x?[0-9a-f]+');

  /// 行号 / 列号后缀：换一行代码就会变。
  static final RegExp _lineColumn = RegExp(r':\d+(?::\d+)?$');

  static final RegExp _whitespace = RegExp(r'\s+');

  /// 生成指纹；`ruleId` 与 `platform` 必填，因为「同一文件同一位置」
  /// 在不同规则下是不同的可处置问题。
  static String of({
    required String ruleId,
    required String platform,
    String? artifactPath,
    String? location,
    String? value,
  }) {
    final canonical = [
      'v$version',
      platform.trim().toLowerCase(),
      ruleId.trim(),
      normalizeArtifactPath(artifactPath) ?? '',
      normalizeLocation(location) ?? '',
      _valueHash(value),
    ].join('|');
    final digest = sha256.convert(utf8.encode(canonical)).toString();
    return 'v$version:${digest.substring(0, 32)}';
  }

  /// 包内路径规范化：统一分隔符、去掉前导 `./` 与 `/`、合并重复分隔符、转小写。
  static String? normalizeArtifactPath(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return null;
    var path = raw.replaceAll('\\', '/');
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    path = path.replaceAll(RegExp(r'/+'), '/');
    final out = path.trim().toLowerCase();
    return out.isEmpty ? null : out;
  }

  /// 位置规范化：去偏移/行号、合并空白、转小写。
  ///
  /// 只做「会因为构建而变」的裁剪；类名、方法签名原样保留（仅小写），
  /// 这样同一处问题在不同构建里仍能对上。
  static String? normalizeLocation(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return null;
    var location = raw.replaceAll('\\', '/');
    location = location.replaceAll(_hexOffset, '');
    location = location.replaceAll(_lineColumn, '');
    location = location.replaceAll(_whitespace, ' ').trim();
    final out = location.toLowerCase();
    return out.isEmpty ? null : out;
  }

  /// 值只参与哈希，不返回明文 —— 指纹会进历史与导出。
  static String _valueHash(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) return '';
    final normalized = raw.replaceAll(_whitespace, ' ').toLowerCase();
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 16);
  }
}
