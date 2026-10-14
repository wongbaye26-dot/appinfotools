import 'dart:typed_data';

/// 可打印 ASCII 字符串提取。
///
/// Android 的 DEX 与 iOS 的 Mach-O 都要做「从二进制里捞字符串」这件事，
/// 而两份各写一遍必然漂移（历史上 `ZipGuard` 与 `ApkReader` 就因为这个
/// 重复实现而踩过坑）。提取规则本身与平台无关，因此放在这里，
/// 由两侧的安全扫描器共用。
///
/// **只提取 ASCII**：MUTF-8 / UTF-16 的中文字面量（中文域名、本地化字符串）
/// 会漏掉。这是已知局限，调用方必须把它写进报告的未覆盖范围，
/// 而不是用宽字符匹配去凑 —— 那样会把二进制噪声变成假域名。
class AsciiStrings {
  AsciiStrings._();

  static const int defaultMinLength = 6;

  /// 超长串只保留头尾的默认长度。域名与标识符不会超长，超长的基本是
  /// base64 / blob，全量保留只会把报告撑爆。
  static const int defaultMaxKeep = 200;

  /// 提取 [bytes] 前 [limit] 字节内长度 ≥ [minLength] 的可打印 ASCII 串。
  ///
  /// [limit] 为 `null` 时扫整个缓冲区；调用方应自行套字节预算
  /// （解析不可信文件的铁律：先定预算再读）。
  static Iterable<String> extract(
    Uint8List bytes, {
    int? limit,
    int minLength = defaultMinLength,
    int maxKeep = defaultMaxKeep,
  }) sync* {
    final end = limit == null || limit > bytes.length ? bytes.length : limit;
    var start = -1;
    for (var i = 0; i < end; i++) {
      final b = bytes[i];
      final printable = b >= 0x20 && b < 0x7F;
      if (printable) {
        if (start < 0) start = i;
        continue;
      }
      if (start >= 0) {
        if (i - start >= minLength) {
          yield _clip(String.fromCharCodes(bytes, start, i), maxKeep);
        }
        start = -1;
      }
    }
    if (start >= 0 && end - start >= minLength) {
      yield _clip(String.fromCharCodes(bytes, start, end), maxKeep);
    }
  }

  /// 超长串只留头尾，中间用省略号标记 —— 保留「这是被截断的」这一事实，
  /// 而不是悄悄给人一个看起来完整的字符串。
  static String _clip(String value, int maxKeep) {
    if (value.length <= maxKeep) return value;
    final half = maxKeep ~/ 2;
    return '${value.substring(0, half)}…${value.substring(value.length - half)}';
  }
}
