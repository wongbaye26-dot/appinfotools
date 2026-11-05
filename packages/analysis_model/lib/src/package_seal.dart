import 'dart:typed_data';

/// 内容摘要函数：返回小写 hex；`null` = 该算法不可用；**不得抛异常**。
///
/// 由应用层注入（用根项目的 `package:crypto` 实现）。两个 parser 包**不新增**
/// `crypto` 依赖；测试可注入假实现。
typedef ContentDigestFn = String? Function(String algorithm, Uint8List bytes);

/// 单个密封条目的状态。
enum SealState {
  /// 实际摘要与密封记录一致。
  verified,

  /// 实际摘要与记录不一致（或记录/文件不对应）。
  mismatch,

  /// 密封清单里有，归档里没有。
  entryMissing,

  /// 没有找到密封清单。
  unsealed,

  /// 没有摘要函数，未计算。
  notChecked,

  /// 清单解析失败 / 无法判断。
  unknown,
}

/// 一条密封校验。
class SealEntryCheck {
  /// 归档内路径（相对包根）。
  final String path;

  final SealState state;

  /// `sha256` / `sha1` / `md5`。
  final String algorithm;

  /// 期望摘要的前 16 个 hex；不可得时为 `null`。
  final String? expectedDigestPrefix;

  /// 实际摘要的前 16 个 hex；不可得时为 `null`。
  final String? actualDigestPrefix;

  const SealEntryCheck({
    required this.path,
    required this.state,
    required this.algorithm,
    this.expectedDigestPrefix,
    this.actualDigestPrefix,
  });
}

/// 一次密封校验的汇总。
class SealCheck {
  /// `apk.v1.manifest` / `apk.v2.content` / `ipa.codeResources.v1` /
  /// `ipa.codeResources.v2`.
  final String scheme;

  final SealState state;

  final int entriesChecked;
  final int entriesTotal;

  /// 最多 64 条；mismatch 优先。
  final List<SealEntryCheck> checks;

  /// 本版本不验签；恒 `false`。
  final bool signatureVerified;

  /// 稳定 code：`seal.digest_unavailable` / `seal.entry_limit` /
  /// `seal.not_parsed` 等。
  final List<String> noteCodes;

  const SealCheck({
    required this.scheme,
    required this.state,
    this.entriesChecked = 0,
    this.entriesTotal = 0,
    this.checks = const [],
    this.signatureVerified = false,
    this.noteCodes = const [],
  });
}
