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

  /// 为定位 EOCD 需要从**文件尾部**读取的最大字节数。
  ///
  /// 等于 [eocdLength] + [maxCommentLength]。读尾部这么多字节足以覆盖任何
  /// 合法归档 —— 不需要把整个文件读进内存（大 APK 有几百 MB）。
  static const int maxTailBytes = eocdLength + maxCommentLength;

  /// 从尾部读取 EOCD，返回它声明的总条目数。
  ///
  /// 读不到时返回 `null` —— **读不到不算异常**：调用方可能在处理非标准
  /// ZIP，把「找不到 EOCD」当异常会产生误报。
  ///
  /// 传进来的 [bytes] 必须是归档的**尾部**（且包含完整的注释），否则注释
  /// 长度自洽校验会失败，方法会返回 `null`。用 [maxTailBytes] 取尾部即可。
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

      // EOCD 各字段的偏移：4 本磁盘号、6 中央目录所在磁盘号、8 本磁盘条目数、
      // **10 总条目数**、12 中央目录大小、16 中央目录偏移、20 注释长度。
      //
      // 校验「注释长度恰好把 EOCD 顶到缓冲区末尾」再认它：压缩数据里偶然
      // 出现 `PK\x05\x06` 这四个字节是可能的，而只有真正的 EOCD 才能让长度
      // 自洽。自洽校验失败时**继续向前找**而不是直接放弃 —— 前面可能还有
      // 真正的 EOCD。
      final commentLength = bytes[i + 20] | (bytes[i + 21] << 8);
      if (i + eocdLength + commentLength != bytes.length) continue;

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
