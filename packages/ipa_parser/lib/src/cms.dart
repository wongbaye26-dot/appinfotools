import 'dart:typed_data';

/// CMS/PKCS#7 `SignedData` 载荷定位的结果。
class CmsContentResult {
  /// 定位到的载荷；失败时为 `null`。
  final Uint8List? content;

  /// 失败原因。成功时为 `null`。
  final String? failure;

  const CmsContentResult._(this.content, this.failure);

  const CmsContentResult.success(Uint8List content) : this._(content, null);

  const CmsContentResult.failure(String reason) : this._(null, reason);

  bool get ok => content != null;

  @override
  String toString() =>
      ok ? 'CmsContentResult(${content!.length} bytes)' : 'CmsContentResult($failure)';
}

/// 从 CMS/PKCS#7 `SignedData` 中取出 `encapContentInfo` 的载荷。
///
/// 用途只有一个：`embedded.mobileprovision` 的内容是一段被 CMS 包起来的
/// plist，要读它就得先把这段字节找出来。
///
/// **这里只做结构定位，不做任何密码学验证。** 规范 5.5 明确禁止自行实现签名
/// 算法并宣称权威结论 —— 找出的字节是否可信，由调用方交给 `codesign` 判定，
/// 或者明确标记为「未验证」。因此本类不接触任何签名值、摘要或证书。
///
/// 输入是**不受信任**的：所有长度字段都先验边界，不定长（BER）容器靠扫描
/// 结束标记收尾，嵌套深度有上限。畸形输入一律返回失败，不抛异常、不越界读。
class CmsContentExtractor {
  CmsContentExtractor._();

  /// 输入上限（16 MiB）。真实的描述文件只有几 KB。
  static const int maxInputBytes = 16 * 1024 * 1024;

  /// 载荷上限（8 MiB）。
  static const int maxContentBytes = 8 * 1024 * 1024;

  /// 嵌套深度上限 —— 防止构造出来的深嵌套把栈打穿。
  static const int maxDepth = 32;

  /// `pkcs7-signedData`：1.2.840.113549.1.7.2。
  static const List<int> signedDataOid = [
    0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02, //
  ];

  /// `pkcs7-data`：1.2.840.113549.1.7.1。
  static const List<int> dataOid = [
    0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01, //
  ];

  /// 取出 `SignedData.encapContentInfo.eContent` 的字节。
  static CmsContentResult extract(Uint8List der) {
    if (der.isEmpty) {
      return const CmsContentResult.failure('input is empty');
    }
    if (der.length > maxInputBytes) {
      return CmsContentResult.failure(
        'input is ${der.length} bytes, above the $maxInputBytes byte limit',
      );
    }

    final outer = _read(der, 0, der.length, 0);
    if (outer == null) {
      return const CmsContentResult.failure(
        'the outer ASN.1 element could not be read',
      );
    }
    if (outer.tag != _sequence) {
      return CmsContentResult.failure(
        'the outer element is not a SEQUENCE (tag 0x'
        '${outer.tag.toRadixString(16)})',
      );
    }

    final outerChildren = _children(der, outer, 0);
    if (outerChildren == null || outerChildren.isEmpty) {
      return const CmsContentResult.failure(
        'the outer SEQUENCE has no readable content',
      );
    }

    final contentType = outerChildren.first;
    if (contentType.tag != _oid ||
        !_matches(der, contentType, signedDataOid)) {
      return const CmsContentResult.failure(
        'the content type is not pkcs7-signedData',
      );
    }

    // `[0] EXPLICIT` 里装着 SignedData。OID 之后可能有其他元素，按标签找。
    _Tlv? wrapper;
    for (final child in outerChildren.skip(1)) {
      if (child.tag == _context0) {
        wrapper = child;
        break;
      }
    }
    if (wrapper == null) {
      return const CmsContentResult.failure(
        'the SignedData content wrapper is missing',
      );
    }

    final wrapperChildren = _children(der, wrapper, 0);
    if (wrapperChildren == null || wrapperChildren.isEmpty) {
      return const CmsContentResult.failure(
        'the SignedData content wrapper is empty',
      );
    }
    final signedData = wrapperChildren.first;
    if (signedData.tag != _sequence) {
      return const CmsContentResult.failure('SignedData is not a SEQUENCE');
    }

    final signedDataChildren = _children(der, signedData, 0);
    if (signedDataChildren == null) {
      return const CmsContentResult.failure(
        'SignedData could not be walked',
      );
    }

    // encapContentInfo 在 SignedData 里排第三，但版本差异客观存在，
    // 因此按「内容类型是 pkcs7-data 的那个 SEQUENCE」来找，不数序号。
    for (final child in signedDataChildren) {
      if (child.tag != _sequence) continue;
      final inner = _children(der, child, 0);
      if (inner == null || inner.isEmpty) continue;
      if (inner.first.tag != _oid || !_matches(der, inner.first, dataOid)) {
        continue;
      }

      for (final element in inner.skip(1)) {
        if (element.tag != _context0) continue;
        final bytes = _collectOctets(der, element, 0);
        if (bytes == null) {
          return const CmsContentResult.failure(
            'eContent is not an OCTET STRING',
          );
        }
        if (bytes.isEmpty) {
          return const CmsContentResult.failure('eContent is empty');
        }
        if (bytes.length > maxContentBytes) {
          return CmsContentResult.failure(
            'eContent is ${bytes.length} bytes, above the '
            '$maxContentBytes byte limit',
          );
        }
        return CmsContentResult.success(bytes);
      }
      return const CmsContentResult.failure(
        'encapContentInfo carries no eContent',
      );
    }

    return const CmsContentResult.failure(
      'no encapContentInfo with the pkcs7-data content type was found',
    );
  }

  // ---------------------------------------------------------------------------
  // BER/DER 最小读取
  // ---------------------------------------------------------------------------

  static const int _sequence = 0x30;
  static const int _oid = 0x06;
  static const int _octetString = 0x04;

  /// 构造形式的 OCTET STRING（`0x04 | 0x20`）。
  ///
  /// BER 允许把长字符串切成多段，外层用构造形式包裹。Apple 的 `security cms`
  /// 产出的正是这种形态，因此必须支持。
  static const int _octetStringConstructed = 0x24;

  /// `[0]` 上下文标签（构造形式）。
  static const int _context0 = 0xA0;

  /// 把 `wrapper` 下的 OCTET STRING 片段拼起来。
  ///
  /// 遇到预期外的标签直接失败 —— 静默跳过意味着可能丢掉一段字节，而调用方
  /// 无从察觉，拿到的会是一段「看起来解析成功」的残缺 plist。
  static Uint8List? _collectOctets(Uint8List data, _Tlv wrapper, int depth) {
    if (depth > maxDepth) return null;
    final children = _children(data, wrapper, depth);
    if (children == null) return null;

    final builder = BytesBuilder(copy: false);
    for (final child in children) {
      if (child.tag == _octetString) {
        builder.add(
          Uint8List.sublistView(data, child.contentStart, child.contentEnd),
        );
      } else if (child.tag == _octetStringConstructed) {
        final nested = _collectOctets(data, child, depth + 1);
        if (nested == null) return null;
        builder.add(nested);
      } else {
        return null;
      }
    }
    return builder.takeBytes();
  }

  /// 读出 `parent` 的子元素。
  static List<_Tlv>? _children(Uint8List data, _Tlv parent, int depth) {
    if (!parent.isConstructed) return null;

    final result = <_Tlv>[];
    var offset = parent.contentStart;
    while (offset < parent.contentEnd) {
      final child = _read(data, offset, parent.contentEnd, depth + 1);
      if (child == null || child.nextOffset <= offset) return null;
      result.add(child);
      offset = child.nextOffset;
    }
    return result;
  }

  /// 读取 `offset` 处的一个 TLV。
  ///
  /// 不定长（`0x80`）只在 BER 里合法，CMS 的描述文件确实在用，因此支持：
  /// 从内容起点逐个跳过子元素，直到遇到结束标记 `00 00`。
  ///
  /// 返回值区分「内容结束」与「本元素结束」：不定长元素的内容结束在结束标记
  /// **之前**，而下一个兄弟元素从结束标记**之后**开始。把两者混为一谈会让
  /// 调用方把结束标记再当成一个元素的起点，从而提前认定父容器已结束 ——
  /// 真实的描述文件里，`eContent` 后面还有证书与签名者信息，一旦提前收尾，
  /// 整个 SignedData 就会被截断。
  static _Tlv? _read(Uint8List data, int offset, int limit, int depth) {
    if (depth > maxDepth) return null;
    // 至少要有标识字节和长度字节。
    if (offset < 0 || offset + 1 >= limit) return null;

    final tag = data[offset];
    // `00` 是结束标记的起始字节，不能当作值的标识。
    if (tag == 0x00) return null;

    final firstLengthByte = data[offset + 1];
    final int contentStart;
    int? definiteLength;

    if (firstLengthByte == 0x80) {
      contentStart = offset + 2;
      definiteLength = null;
    } else if (firstLengthByte < 0x80) {
      contentStart = offset + 2;
      definiteLength = firstLengthByte;
    } else {
      final lengthBytes = firstLengthByte & 0x7F;
      // 0 表示不定长但用了长形式 —— 非法；超过 4 字节的长度在 32 位地址空间里
      // 没有意义，直接拒绝而不是构造一个溢出的整数。
      if (lengthBytes == 0 || lengthBytes > 4) return null;
      if (offset + 2 + lengthBytes > limit) return null;

      var value = 0;
      for (var i = 0; i < lengthBytes; i++) {
        value = (value << 8) | data[offset + 2 + i];
      }
      contentStart = offset + 2 + lengthBytes;
      definiteLength = value;
    }

    if (definiteLength != null) {
      final end = contentStart + definiteLength;
      if (end < contentStart || end > limit) return null;
      return _Tlv(tag, contentStart, end, end);
    }

    // 不定长：扫到结束标记为止。
    var cursor = contentStart;
    while (true) {
      // 结束标记本身要占两个字节。
      if (cursor + 1 >= limit) return null;
      if (data[cursor] == 0x00 && data[cursor + 1] == 0x00) {
        return _Tlv(tag, contentStart, cursor, cursor + 2);
      }
      final child = _read(data, cursor, limit, depth + 1);
      if (child == null || child.nextOffset <= cursor) return null;
      cursor = child.nextOffset;
    }
  }

  /// `tlv` 的内容是否等于 [oid]。
  static bool _matches(Uint8List data, _Tlv tlv, List<int> oid) {
    final length = tlv.contentEnd - tlv.contentStart;
    if (length != oid.length) return false;
    for (var i = 0; i < oid.length; i++) {
      if (data[tlv.contentStart + i] != oid[i]) return false;
    }
    return true;
  }
}

/// 一个已定位的 TLV。
class _Tlv {
  final int tag;

  /// 内容起始偏移。
  final int contentStart;

  /// 内容结束偏移（不含）。
  ///
  /// 不定长元素指向结束标记的**起点**。
  final int contentEnd;

  /// 本元素结束后的偏移，即下一个兄弟元素的起点。
  ///
  /// 定长时等于 [contentEnd]；不定长时跳过两字节的结束标记。
  final int nextOffset;

  const _Tlv(this.tag, this.contentStart, this.contentEnd, this.nextOffset);

  bool get isConstructed => (tag & 0x20) != 0;
}
