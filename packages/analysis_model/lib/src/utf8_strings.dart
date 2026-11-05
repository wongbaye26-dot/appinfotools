import 'dart:typed_data';

/// 从二进制里提取**含非 ASCII 字符**的 UTF-8 字符串。
///
/// [AsciiStrings] 在遇到第一个 ≥ 0x80 的字节就断开，因此 `__TEXT,__cstring`
/// 里的中文界面文案（`@"请输入助记词"` 编译后就是 UTF-8）会被切成碎片，
/// 一个中文词也捞不出来。这个提取器补的就是这一段。
///
/// ## 为什么只产出「含非 ASCII」的串
///
/// 纯 ASCII 串已经由 [AsciiStrings] 在同一份字节上产出过一次。这里再产一次
/// 只会让下游收集器（端点、标记、地址）把同一条串处理两遍，而中文话术匹配
/// 根本用不到它们。少产一半，也少一半误报面。
///
/// ## 这是启发式，不是解码器
///
/// 二进制里随机的字节也可能凑出合法的 UTF-8 序列，所以：
/// - 逐序列严格校验（拒绝超长编码、代理区、> U+10FFFF、非法后续字节）；
/// - 只保留「可打印」的码点区间，控制字节一律断开；
/// - 少于 [minLength] 个码点不产出；超长串只留头尾；
/// - **调用方必须把预算与未覆盖范围写进报告**，不能声称看到了全部字符串。
///
/// 命中原文是否可信，最终由调用方的关键词表决定 —— 这里只提供候选串。
class Utf8Strings {
  Utf8Strings._();

  /// Unicode 话术常常只有 2–4 个字，6 个字符的 ASCII 门槛在这里太高。
  static const int defaultMinLength = 2;

  /// 超长串只留头尾，避免一段 base64/blob 撑爆报告。
  static const int defaultMaxKeep = 200;

  /// 可打印码点（粗略，覆盖常见文字；与 `Utf16Strings` 的区间保持一致）。
  /// CJK / 全角码点。中文话术扫描用它降噪：随机二进制字节凑出两个
  /// 合法 CJK 码点的概率，比凑出两个任意非 ASCII 码点低好几个数量级。
  static bool _isCjk(int cp) =>
      (cp >= 0x3000 && cp <= 0x9FFF) ||
      (cp >= 0xAC00 && cp <= 0xD7AF) ||
      (cp >= 0xFF00 && cp <= 0xFFEF);

  static bool _printable(int cp) {
    if (cp >= 0x20 && cp < 0x7F) return true;
    if (cp >= 0x00A1 && cp <= 0x024F) return true; // Latin extended
    if (cp >= 0x0370 && cp <= 0x06FF) {
      return true; // Greek/Cyrillic/Hebrew/Arabic
    }
    if (cp >= 0x0900 && cp <= 0x0DFF) return true; // Indic
    if (cp >= 0x1E00 && cp <= 0x1EFF) return true; // Latin extended additional
    if (cp >= 0x2000 && cp <= 0x206F) return true; // general punctuation
    if (cp >= 0x3000 && cp <= 0x9FFF) return true; // CJK（含假名/标点）
    if (cp >= 0xAC00 && cp <= 0xD7AF) return true; // Hangul
    if (cp >= 0xFF00 && cp <= 0xFFEF) return true; // fullwidth forms
    return false;
  }

  /// 提取 [bytes] 前 [limit] 字节内含非 ASCII 字符的 UTF-8 串。
  ///
  /// [limit] 为 `null` 时扫整个缓冲区；调用方仍应先套字节预算
  /// （解析不可信文件的铁律：先定预算再读）。
  ///
  /// [minCjkChars] 要求串里至少有几个 CJK / 全角码点。默认 0（通用提取）；
  /// 中文话术扫描传 2 —— 实测一个 34 MiB 的真实 Mach-O 上，不设门槛会产出
  /// 12 万条「Aé」这类噪声串，设了之后只剩真正的中文文本。
  static Iterable<String> extract(
    Uint8List bytes, {
    int? limit,
    int minLength = defaultMinLength,
    int maxKeep = defaultMaxKeep,
    int minCjkChars = 0,
  }) sync* {
    final end = limit == null || limit > bytes.length ? bytes.length : limit;
    final half = maxKeep < 2 ? 1 : maxKeep ~/ 2;

    // 只留头尾两段：一段 64 MiB 的二进制里可能有一条极长的「伪字符串」，
    // 全量存进 List 会让内存峰值跟着文件大小走。两个 List 复用而不是每次
    // 断开都新建 —— NUL 在二进制里出现几百万次，逐次分配会直接把扫描拖慢。
    final head = <int>[];
    final tail = <int>[];
    var length = 0;
    var hasNonAscii = false;
    var cjkCount = 0;
    // CJK 过滤模式下，纯 ASCII 前缀（机器码 / 标识符）既不入串也不进 List：
    // 34 MiB 的主二进制里绝大多数字节都落在这条分支上。
    var collecting = minCjkChars == 0;

    void add(int cp) {
      length++;
      if (head.length < half) {
        head.add(cp);
      } else {
        tail.add(cp);
        if (tail.length > half) tail.removeAt(0);
      }
      if (cp >= 0x80) hasNonAscii = true;
      if (_isCjk(cp)) cjkCount++;
    }

    String? finish() {
      if (!hasNonAscii || length < minLength || cjkCount < minCjkChars) {
        return null;
      }
      if (length > maxKeep) {
        return '${String.fromCharCodes(head)}…${String.fromCharCodes(tail)}';
      }
      return String.fromCharCodes(<int>[...head, ...tail]);
    }

    void reset() {
      head.clear();
      tail.clear();
      length = 0;
      hasNonAscii = false;
      cjkCount = 0;
      collecting = minCjkChars == 0;
    }

    for (var i = 0; i < end;) {
      final b0 = bytes[i];

      // 可打印 ASCII 是绝大多数：直接走快路径，不再过 `_printable` /
      // `_isCjk` 两道判断，也不做多字节解码。
      if (b0 >= 0x20 && b0 < 0x7F) {
        if (collecting) add(b0);
        i += 1;
        continue;
      }

      var cp = -1;
      var width = 1;
      if (b0 >= 0xC2 && b0 <= 0xF4) {
        // 严格解一条 UTF-8 序列：非法后续字节 / 超长 / 代理区 / 越界一律
        // 当成「断开」，并从下一个字节重新同步。
        final needed = b0 < 0xE0 ? 2 : (b0 < 0xF0 ? 3 : 4);
        if (i + needed <= end) {
          var ok = true;
          // 2/3/4 字节前导分别是 110xxxxx / 1110xxxx / 11110xxx。
          var value = b0 & (0xFF >> (needed + 1));
          for (var k = 1; k < needed; k++) {
            final b = bytes[i + k];
            if (b < 0x80 || b > 0xBF) {
              ok = false;
              break;
            }
            value = (value << 6) | (b & 0x3F);
          }
          const minimum = <int>[0, 0, 0x80, 0x800, 0x10000];
          if (ok &&
              value >= minimum[needed] &&
              value <= 0x10FFFF &&
              (value < 0xD800 || value > 0xDFFF)) {
            cp = value;
            width = needed;
          }
        }
      }

      if (cp < 0 || !_printable(cp)) {
        final text = finish();
        if (text != null) yield text;
        reset();
        // 只前进一个字节：坏序列的第二个字节可能正是下一条串的开头。
        i += 1;
        continue;
      }

      // CJK 模式从**第一个**中文码点开始收：前面的 ASCII 前缀对中文话术
      // 匹配没有意义，跳过它能省掉纯 ASCII 段的所有 List 操作。
      if (!collecting && _isCjk(cp)) collecting = true;
      if (collecting) add(cp);
      i += width;
    }

    final text = finish();
    if (text != null) yield text;
  }
}
