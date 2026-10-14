import 'dart:typed_data';

/// ZIP 结构一致性检查。
///
/// 只做**廉价且几乎不可能误报**的检查：EOCD（中央目录结束记录）声明的
/// 条目数与实际解析出的条目数是否对得上。
///
/// **为什么不做更深的检查**（本地文件头 vs 中央目录逐字段比对）：那需要
/// 自己解析 ZIP 字节，实现出错会把**正常**的包判成异常 —— 误报比漏报更糟，
/// 用户一旦被误报几次就不再信任整个检测。EOCD 这一条足以发现「被裁剪」或
/// 「两个归档拼接」的样本，而正常打包工具产出的归档必然一致。
class ZipStructure {
  ZipStructure._();

  /// EOCD 固定部分长度。
  static const int eocdLength = 22;

  /// ZIP 注释的上限（EOCD 后面最多跟这么多字节）。
  static const int maxCommentLength = 65535;

  /// 从尾部读取 EOCD，返回它声明的总条目数。
  ///
  /// 读不到时返回 `null` —— **读不到不算异常**：`zipAsArchive` 之类的场景
  /// 本就可能不是标准 ZIP，把它当异常会产生误报。
  static int? declaredEntryCount(Uint8List bytes) {
    if (bytes.length < eocdLength) return null;

    // EOCD 后面可能跟着注释，因此从尾部向前搜索签名，最多回溯注释上限。
    final earliest = bytes.length - eocdLength - maxCommentLength;
    final start = earliest < 0 ? 0 : earliest;

    for (var i = bytes.length - eocdLength; i >= start; i--) {
      if (bytes[i] != 0x50 ||
          bytes[i + 1] != 0x4b ||
          bytes[i + 2] != 0x05 ||
          bytes[i + 3] != 0x06) {
        continue;
      }
      // 偏移 10 起是「本磁盘条目数」（2 字节），12 起是「总条目数」。
      return bytes[i + 10] | (bytes[i + 11] << 8);
    }
    return null;
  }

  /// 比对 EOCD 声明的条目数与实际解析出的条目数。
  ///
  /// 返回不一致的说明；一致或读不到 EOCD 时返回 `null`。
  static String? checkEntryCount(Uint8List bytes, int actualCount) {
    final declared = declaredEntryCount(bytes);
    if (declared == null) return null;
    if (declared == actualCount) return null;
    return 'central directory declares $declared entries '
        'but $actualCount were parsed';
  }
}
