import 'dart:typed_data';

/// 从二进制里提取 UTF-16 字符串（主要覆盖 iOS Mach-O 的宽字符字面量）。
///
/// 与 [AsciiStrings] 分开：ASCII 扫描只认 0x20–0x7E；中文/宽字符话术在
/// UTF-16 里是成对的 code unit，ASCII 扫描会把它们拆成一堆单字符。
///
/// 这是**启发式**：二进制里任意字节都可能凑出合法 code unit，因此：
/// - 只在可打印区间内收集；
/// - 至少 [minLength] 个字符；
/// - 超长串只留头尾；
/// - 调用方仍需把它写进“覆盖范围”，不能声称看到了全部字符串。
///
/// 字节序与起始对齐都可由调用方指定：整文件只能假定小端偶对齐，而
/// `__TEXT,__ustring` 这类节里两种端序、两种起始位置都出现过。
/// [extractAll] 把四种组合一次扫完并去重。
class Utf16Strings {
  Utf16Strings._();

  /// 可打印 code unit（粗略但覆盖常见文字）。
  static bool _printable(int unit) {
    if (unit >= 0x20 && unit < 0x7F) return true;
    if (unit == 0x09 || unit == 0x0A || unit == 0x0D) return true;
    if (unit == 0xA0) return true;
    if (unit >= 0x00A1 && unit <= 0x024F) return true; // Latin extended
    if (unit >= 0x0370 && unit <= 0x04FF) return true; // Greek/Cyrillic
    if (unit >= 0x0590 && unit <= 0x05FF) return true; // Hebrew
    if (unit >= 0x0600 && unit <= 0x06FF) return true; // Arabic
    if (unit >= 0x0900 && unit <= 0x0DFF) return true; // Indic
    if (unit >= 0x1E00 && unit <= 0x1EFF) return true; // Latin extended
    if (unit >= 0x3000 && unit <= 0x9FFF) return true; // CJK
    if (unit >= 0xAC00 && unit <= 0xD7AF) return true; // Hangul
    if (unit >= 0xFF00 && unit <= 0xFFEF) return true; // fullwidth
    if (unit >= 0x2000 && unit <= 0x206F) return true; // punctuation
    return false;
  }

  /// 提取 UTF-16 字符串；[bigEndian] 切换端序，[alignment] 是起始字节偏移。
  static Iterable<String> extract(
    Uint8List bytes, {
    int? limit,
    int minLength = 4,
    int maxKeep = 200,
    int alignment = 0,
    bool bigEndian = false,
    bool requireWide = false,
  }) sync* {
    final end = limit == null || limit > bytes.length ? bytes.length : limit;
    if (requireWide) {
      yield* _extractWide(
        bytes,
        end: end,
        minLength: minLength,
        maxKeep: maxKeep,
        alignment: alignment,
        bigEndian: bigEndian,
      );
      return;
    }
    var start = -1;
    var units = <int>[];
    var hasWide = false;
    for (var i = alignment; i + 1 < end; i += 2) {
      final unit = bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : bytes[i] | (bytes[i + 1] << 8);
      if (_printable(unit)) {
        if (start < 0) start = i;
        if (units.length < maxKeep + 1) units.add(unit);
        if (_isWide(unit)) hasWide = true;
        continue;
      }
      if (start >= 0) {
        if (units.length >= minLength && (!requireWide || hasWide)) {
          yield _clip(String.fromCharCodes(units), maxKeep);
        }
        start = -1;
        units = <int>[];
        hasWide = false;
      }
    }
    if (start >= 0 && units.length >= minLength && (!requireWide || hasWide)) {
      yield _clip(String.fromCharCodes(units), maxKeep);
    }
  }

  /// 只产出含宽字符的串：不为每条 ASCII 噪声串建 `List<int>`。
  static Iterable<String> _extractWide(
    Uint8List bytes, {
    required int end,
    required int minLength,
    required int maxKeep,
    required int alignment,
    required bool bigEndian,
  }) sync* {
    var start = -1;
    var length = 0;
    var hasWide = false;
    for (var i = alignment; i + 1 < end; i += 2) {
      final unit = bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : bytes[i] | (bytes[i + 1] << 8);
      if (_printable(unit)) {
        if (start < 0) start = i;
        length++;
        if (_isWide(unit)) hasWide = true;
        continue;
      }
      if (start >= 0) {
        if (length >= minLength && hasWide) {
          yield _decodeRange(bytes, start, i, maxKeep, bigEndian);
        }
        start = -1;
        length = 0;
        hasWide = false;
      }
    }
    if (start >= 0 && length >= minLength && hasWide) {
      yield _decodeRange(bytes, start, end, maxKeep, bigEndian);
    }
  }

  static String _decodeRange(
    Uint8List bytes,
    int start,
    int end,
    int maxKeep,
    bool bigEndian,
  ) {
    final units = <int>[];
    for (var i = start; i + 1 < end; i += 2) {
      units.add(bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : bytes[i] | (bytes[i + 1] << 8));
      if (units.length >= maxKeep + 1) break;
    }
    return _clip(String.fromCharCodes(units), maxKeep);
  }

  /// 是否属于「宽字符」文字（CJK / Hangul / 全角）。
  static bool _isWide(int unit) =>
      (unit >= 0x2E80 && unit <= 0x9FFF) ||
      (unit >= 0xAC00 && unit <= 0xD7AF) ||
      (unit >= 0xFF00 && unit <= 0xFFEF);

  /// 去重集合的上限：噪声字节可能产出海量互不相同垃圾串，不能让它跟着
  /// 输入大小涨。超过上限后仍继续产出（下游收集器自己有样本上限），只是
  /// 不再做去重。
  static const int maxDedupEntries = 4096;

  /// 一次扫完「小端/大端 × 偶/奇对齐」四种组合，产出时去重。
  ///
  /// 只给**节内字节**用：整文件扫四遍会把一个几十 MiB 的主二进制读四遍，
  /// 而 `__TEXT,__ustring` 通常只有几十 KB。整文件仍走 [extract] 的
  /// 小端偶对齐单次遍历。
  static Iterable<String> extractAll(
    Uint8List bytes, {
    int? limit,
    int minLength = 4,
    int maxKeep = 200,
  }) sync* {
    final seen = <String>{};
    for (final bigEndian in const [false, true]) {
      for (final alignment in const [0, 1]) {
        for (final value in extract(
          bytes,
          limit: limit,
          minLength: minLength,
          maxKeep: maxKeep,
          alignment: alignment,
          bigEndian: bigEndian,
        )) {
          if (seen.length >= maxDedupEntries || seen.add(value)) yield value;
        }
      }
    }
  }

  static String _clip(String value, int maxKeep) {
    if (value.length <= maxKeep) return value;
    final half = maxKeep ~/ 2;
    return '${value.substring(0, half)}…${value.substring(value.length - half)}';
  }
}
