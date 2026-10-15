import 'dart:typed_data';

/// 一个 DER 元素的**位置**描述（不复制内容）。
///
/// 刻意只描述位置：证书链动辄几 KB，把每层内容都切出来会平白多出一堆
/// 临时对象；而调用方真正需要的只有「这个字段在哪、多长」。
class DerElement {
  /// 元素自身的起始偏移（**含头部**）。
  ///
  /// 保留它是为了能切出「这个元素的完整字节」—— 例如从 CMS 的证书集合里
  /// 取出单张证书再交给 X.509 解析。
  final int start;

  /// 首字节（tag）：`class(2) | constructed(1) | number(5)`。
  final int tag;

  /// 内容起始偏移。
  final int contentStart;

  /// 内容字节数。
  final int length;

  /// 整个元素（含头部）的结束偏移。
  final int end;

  const DerElement({
    required this.start,
    required this.tag,
    required this.contentStart,
    required this.length,
    required this.end,
  });

  int get contentEnd => contentStart + length;

  bool get isConstructed => (tag & 0x20) != 0;

  /// 标签类别：0 = universal，1 = application，2 = context-specific，3 = private。
  int get tagClass => (tag >> 6) & 0x03;

  /// 标签编号（低 5 位）。**不处理高标签号形式**（`0x1F` 续字节）——
  /// 证书里用到的上下文标签只有 `[0]`/`[3]` 这类小号。
  int get tagNumber => tag & 0x1F;

  bool get isUniversal => tagClass == 0;

  /// 是否是指定编号的 universal 标签（例如 SEQUENCE = 0x10）。
  bool isUniversalTag(int number) => isUniversal && tagNumber == number;
}

/// DER 里的 universal 标签编号。
class DerTag {
  static const int boolean = 0x01;
  static const int integer = 0x02;
  static const int bitString = 0x03;
  static const int octetString = 0x04;
  static const int nullTag = 0x05;
  static const int oid = 0x06;
  static const int utf8String = 0x0C;
  static const int printableString = 0x13;
  static const int ia5String = 0x16;
  static const int utcTime = 0x17;
  static const int generalizedTime = 0x18;
  static const int sequence = 0x10;
  static const int set = 0x11;
}

/// 极简 DER 读取器：只做「按偏移读一个元素」「枚举子元素」。
///
/// 面向的是**已经过 CMS 外壳定位**的可信边界内的字节，因此：
/// - 每次读取都**先验边界**，越界一律返回 `null`（不抛）；
/// - 递归/循环由调用方用**显式深度上限**控制（本类不做递归）。
///
/// 不做的事：不解析 BER 的不定长形式（证书链里不会出现），不做规范化检查，
/// 不校验内容与算法的一致性。它只回答「这里有没有一个 DER 元素、它多长」。
class DerReader {
  final Uint8List bytes;

  const DerReader(this.bytes);

  /// 读取 [offset] 处的元素头。越界或长度不合法时返回 `null`。
  DerElement? at(int offset) {
    if (offset < 0 || offset >= bytes.length) return null;
    final tag = bytes[offset];
    var cursor = offset + 1;
    if (cursor >= bytes.length) return null;

    var length = bytes[cursor++];
    if (length & 0x80 != 0) {
      final count = length & 0x7F;
      // `0x80` 是不定长（BER），证书里不该出现；>4 字节的长度也不现实。
      if (count == 0 || count > 4) return null;
      if (cursor + count > bytes.length) return null;
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | bytes[cursor++];
      }
    }

    if (length < 0) return null;
    final end = cursor + length;
    if (end > bytes.length) return null;
    return DerElement(
      start: offset,
      tag: tag,
      contentStart: cursor,
      length: length,
      end: end,
    );
  }

  /// 枚举 [parent] 的直接子元素。
  ///
  /// 遇到不合法的子元素就**停下**（返回已读到的部分），而不是抛异常 ——
  /// 畸形证书只应导致「读到一半」，不应让整个解析崩掉。
  List<DerElement> children(DerElement parent, {int max = 512}) {
    final out = <DerElement>[];
    if (!parent.isConstructed) return out;
    var cursor = parent.contentStart;
    while (cursor < parent.contentEnd && out.length < max) {
      final child = at(cursor);
      if (child == null || child.end <= cursor) break;
      out.add(child);
      cursor = child.end;
    }
    return out;
  }

  /// 取 [element] 的内容字节。
  Uint8List content(DerElement element) =>
      Uint8List.sublistView(bytes, element.contentStart, element.contentEnd);

  /// 把内容当 ASCII/Latin-1 文本读。
  String text(DerElement element) {
    final content = this.content(element);
    return String.fromCharCodes(content);
  }

  /// 按 DER 的 OID 编码解出点分形式（`2.5.4.3`）。
  ///
  /// 首字节是 `40 * x + y`，其余每个字节按 7 位分组、最高位是续接标志。
  String? oid(DerElement element) {
    if (element.length == 0) return null;
    final content = this.content(element);
    final parts = <int>[content[0] ~/ 40, content[0] % 40];
    var value = 0;
    var started = false;
    for (var i = 1; i < content.length; i++) {
      final byte = content[i];
      value = (value << 7) | (byte & 0x7F);
      started = true;
      if (byte & 0x80 == 0) {
        parts.add(value);
        value = 0;
        started = false;
      }
      // 单个分量超过 32 位就说明这不是我们认得的 OID，放弃。
      if (value > 0xFFFFFFFF) return null;
    }
    if (started) return null;
    return parts.join('.');
  }
}
