import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:crypto/crypto.dart';

/// 应用层的 [ContentDigestFn] 实现。
///
/// parser 包不依赖 `crypto`；摘要实现放在应用层，通过参数注入。
/// 返回小写 hex；未知算法/空输入返回 `null`，**不抛异常**。
String? contentDigest(String algorithm, Uint8List bytes) {
  final data = bytes.isEmpty ? Uint8List(0) : bytes;
  switch (algorithm.toLowerCase()) {
    case 'sha256':
      return sha256.convert(data).toString();
    case 'sha1':
      return sha1.convert(data).toString();
    case 'sha512':
      return sha512.convert(data).toString();
    case 'md5':
      return md5.convert(data).toString();
    default:
      return null;
  }
}
