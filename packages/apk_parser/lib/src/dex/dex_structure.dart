import 'dart:typed_data';

/// DEX 文件头的固定长度（`header_size` 的规范值）。
const int kDexHeaderSize = 112;

/// DEX 规范里 `endian_tag` 的标准取值（小端）。
const int kDexEndianConstant = 0x12345678;

/// `endian_tag` 取该值表示**反向字节序**（`dx --reverse` 的产物）。
///
/// 不当作畸形 —— 它是一种合法的、只是极少见的编码。但本项目不支持它，
/// 因此记为「不支持」并拒绝遍历，而不是硬按小端去读（那会读出一堆垃圾）。
const int kDexReverseEndianConstant = 0x78563412;

/// 超过这个大小就跳过校验和计算。
///
/// adler32 是 O(n) 的；正常 `classes.dex` 在 1–12 MiB，48 MiB 已远超。
/// 跳过时 [DexStructure.checksumVerified] 会是 `false` —— 上层**不得**把
/// 「没报校验和异常」读成「校验和正确」。
const int kDexMaxChecksumBytes = 48 * 1024 * 1024;

/// 一条 DEX 结构异常。
///
/// [code] 是稳定的机器可读标识，便于测试断言与后续做筛选；
/// [message] 是面向人的说明，直接进覆盖不足说明与日志。
class DexAnomaly {
  final String code;
  final String message;

  /// 该异常是否**阻断**后续的段级解析。
  ///
  /// 阻断的意思是：结构已经不可信，任何「没发现线索」的结论都不成立。
  /// 不阻断的（例如版本号不在已知集合里）只作提示，解析照常进行。
  final bool blocking;

  const DexAnomaly(this.code, this.message, {this.blocking = false});

  @override
  String toString() => '$code: $message';
}

/// DEX 头里的一个 id 段（`*_ids`）：条目数与起始偏移。
///
/// 六个 id 段的结构完全一样（size + off），因此共用一个类型。
class DexSection {
  /// 段名，例如 `string_ids`。同时是异常说明里的定位信息。
  final String name;

  /// 条目数（头部声明的）。
  final int size;

  /// 起始偏移（头部声明的）。
  final int offset;

  /// 单个条目的字节数。
  final int itemSize;

  const DexSection({
    required this.name,
    required this.size,
    required this.offset,
    required this.itemSize,
  });

  /// 段末尾（不含）。仅在 [fitsWithin] 为 true 时有意义。
  int get end => offset + size * itemSize;

  /// 该段是否完整落在 `[0, fileSize)` 之内。
  ///
  /// `size == 0` 时只要求 `offset == 0`（DEX 规范如此，`dexdump` 也会据此
  /// 报错）—— 一条都没有的段不该指向某个位置。
  ///
  /// 判定写成 `size <= (fileSize - offset) ~/ itemSize` 而不是
  /// `offset + size * itemSize <= fileSize`：`size` 是头部声明的任意 u32，
  /// 乘法形式的结果**不依赖平台整数宽度**才成立，而除法形式在任何宽度下都
  /// 等价且一眼能看出是「装得下吗」。
  bool fitsWithin(int fileSize) {
    if (size == 0) return offset == 0;
    if (offset < 0 || offset >= fileSize) return false;
    return size <= (fileSize - offset) ~/ itemSize;
  }

  /// 该段是否与 `[0, headerSize)` 重叠（id 段不该压在头部上）。
  bool overlapsHeader(int headerSize) => size > 0 && offset < headerSize;

  @override
  String toString() =>
      'DexSection($name: size=$size, off=$offset, item=$itemSize)';
}

/// DEX 结构解析结果。
///
/// 只解析**头部与段表**，不遍历段内容 —— 段内容的遍历由上层按需进行。
/// 因此即使 DEX 有几百 MB，这一步的开销也是常数。
///
/// **不抛异常**：畸形部分停下来记 [anomalies]，保留已读到的数据。与项目里
/// 其它解析器一致 —— 「读不出来」不是崩溃，是要如实说明的事实。
class DexStructure {
  /// 归档内文件名（如 `classes.dex`），同时是证据位置。
  final String name;

  /// 实际字节数。
  final int byteLength;

  /// DEX 版本号（`magic` 里的三位数字），读不出来时为 `null`。
  final int? version;

  /// 头部声明的 `file_size`；头不可读时为 `null`。
  final int? declaredFileSize;

  /// 头部声明的 `header_size`。
  final int? declaredHeaderSize;

  /// `endian_tag`。
  final int? endianTag;

  /// 六个 id 段，按头部里的出现顺序。头不可读时为空。
  final List<DexSection> sections;

  /// 结构异常。**空的含义是「没发现问题」，不是「没检查」** ——
  /// 头读不出来时一定会有一条 `blocking` 的异常。
  final List<DexAnomaly> anomalies;

  /// 本次是否**真的验证过**校验和。
  ///
  /// 为 `false`（文件超过 [kDexMaxChecksumBytes]）时，`anomalies` 里没有
  /// `dex.checksum_mismatch` **不能**读成「校验和正确」—— 那是「没验」。
  /// 上层必须把这一项写进覆盖范围说明。
  final bool checksumVerified;

  const DexStructure({
    required this.name,
    required this.byteLength,
    this.version,
    this.declaredFileSize,
    this.declaredHeaderSize,
    this.endianTag,
    this.sections = const [],
    this.anomalies = const [],
    this.checksumVerified = true,
  });

  /// 结构是否足以支撑段级解析（遍历 `method_ids` / `class_defs` 等）。
  ///
  /// 为 `false` 时上层**不得**声称「没发现线索」—— 那是「没查到」，
  /// 与「没有」的结论完全相反。
  bool get isTraversable =>
      sections.isNotEmpty && !anomalies.any((a) => a.blocking);

  /// 边界合法、可以安全遍历的段。
  List<DexSection> get usableSections {
    final size = declaredFileSize;
    if (size == null) return const [];
    return [
      for (final s in sections)
        if (s.fitsWithin(byteLength)) s
    ];
  }

  /// 按名字取段；不存在时返回 `null`。
  DexSection? section(String sectionName) {
    for (final s in sections) {
      if (s.name == sectionName) return s;
    }
    return null;
  }

  /// 读取 DEX 的头部与段表。
  ///
  /// 所有偏移与长度**先验边界再使用**；越界的段不会被遍历，只记异常。
  static DexStructure read(String name, Uint8List bytes) {
    final anomalies = <DexAnomaly>[];

    if (bytes.length < kDexHeaderSize) {
      return DexStructure(
        name: name,
        byteLength: bytes.length,
        anomalies: [
          DexAnomaly(
            'dex.too_short',
            '文件只有 ${bytes.length} 字节，不足 DEX 头部的 '
                '$kDexHeaderSize 字节',
            blocking: true,
          ),
        ],
      );
    }

    final data = ByteData.sublistView(bytes);

    // magic: 'dex\n' + 3 位版本 + '\0'
    if (!(bytes[0] == 0x64 && // d
        bytes[1] == 0x65 && // e
        bytes[2] == 0x78 && // x
        bytes[3] == 0x0A)) {
      return DexStructure(
        name: name,
        byteLength: bytes.length,
        anomalies: [
          DexAnomaly(
            'dex.bad_magic',
            'magic 不是 dex\\n0xx（实际 '
                '${_hex(bytes.sublist(0, 4))}）',
            blocking: true,
          ),
        ],
      );
    }

    final versionText = String.fromCharCodes(bytes.sublist(4, 7));
    final version = int.tryParse(versionText);
    if (version == null) {
      anomalies.add(DexAnomaly(
        'dex.version_unparsable',
        'magic 里的版本号不可解析（实际 ${_escape(versionText)}）',
        blocking: true,
      ));
    }

    final checksum = data.getUint32(8, Endian.little);
    final declaredFileSize = data.getUint32(0x20, Endian.little);
    final declaredHeaderSize = data.getUint32(0x24, Endian.little);
    final endianTag = data.getUint32(0x28, Endian.little);

    if (declaredFileSize != bytes.length) {
      // 「声明尺寸与实际不符」既可能是截断，也可能是拼接 —— 只说事实。
      anomalies.add(DexAnomaly(
        'dex.file_size_mismatch',
        '头部声明 file_size=$declaredFileSize，实际 ${bytes.length} 字节',
        blocking: true,
      ));
    }

    if (declaredHeaderSize != kDexHeaderSize) {
      anomalies.add(DexAnomaly(
        'dex.header_size_not_standard',
        '头部声明 header_size=$declaredHeaderSize，规范值是 $kDexHeaderSize',
        blocking: true,
      ));
    }

    if (endianTag == kDexReverseEndianConstant) {
      anomalies.add(const DexAnomaly(
        'dex.reverse_endian_unsupported',
        '该 DEX 使用反向字节序（endian_tag=0x78563412），本项目不支持解析',
        blocking: true,
      ));
    } else if (endianTag != kDexEndianConstant) {
      anomalies.add(DexAnomaly(
        'dex.endian_tag_invalid',
        'endian_tag=0x${endianTag.toRadixString(16).padLeft(8, '0')}，'
            '既不是 0x12345678 也不是反向序常量',
        blocking: true,
      ));
    }

    final sections = <DexSection>[
      DexSection(
        name: 'string_ids',
        size: data.getUint32(0x38, Endian.little),
        offset: data.getUint32(0x3C, Endian.little),
        itemSize: 4,
      ),
      DexSection(
        name: 'type_ids',
        size: data.getUint32(0x40, Endian.little),
        offset: data.getUint32(0x44, Endian.little),
        itemSize: 4,
      ),
      DexSection(
        name: 'proto_ids',
        size: data.getUint32(0x48, Endian.little),
        offset: data.getUint32(0x4C, Endian.little),
        itemSize: 12,
      ),
      DexSection(
        name: 'field_ids',
        size: data.getUint32(0x50, Endian.little),
        offset: data.getUint32(0x54, Endian.little),
        itemSize: 8,
      ),
      DexSection(
        name: 'method_ids',
        size: data.getUint32(0x58, Endian.little),
        offset: data.getUint32(0x5C, Endian.little),
        itemSize: 8,
      ),
      DexSection(
        name: 'class_defs',
        size: data.getUint32(0x60, Endian.little),
        offset: data.getUint32(0x64, Endian.little),
        itemSize: 32,
      ),
    ];

    for (final section in sections) {
      if (!section.fitsWithin(bytes.length)) {
        anomalies.add(DexAnomaly(
          'dex.section_out_of_range',
          '${section.name} 段越界：声明 ${section.size} 条、偏移 '
              '${section.offset}，按每条 ${section.itemSize} 字节算需要读到 '
              '${section.end}，超出文件长度 ${bytes.length}',
          blocking: true,
        ));
        continue;
      }
      if (section.overlapsHeader(declaredHeaderSize)) {
        anomalies.add(DexAnomaly(
          'dex.section_overlaps_header',
          '${section.name} 段偏移 ${section.offset} 落在头部'
              '（$declaredHeaderSize 字节）之内',
          blocking: true,
        ));
      }
    }

    // 校验和：头部声明的 adler32 是否与实际内容一致。
    //
    // **不当作恶意证据**：有些工具会把它清零或重算，而任何攻击者都能重算。
    // 它只能说明「内容与编译产物不再一致」。因此 severity 是提示性的，
    // 措辞里也说清了这一点。
    //
    // 只算 adler32，**不验 SHA-1 签名**（那需要引入 crypto 依赖），
    // 局限在下面的 message 里写明。
    var checksumVerified = false;
    if (bytes.length <= kDexMaxChecksumBytes) {
      checksumVerified = true;
      final actualChecksum = adler32(bytes, start: 12);
      if (actualChecksum != checksum) {
        anomalies.add(DexAnomaly(
          'dex.checksum_mismatch',
          '头部声明的 adler32 校验和是 0x'
              '${checksum.toRadixString(16).padLeft(8, '0')}，'
              '实际内容是 0x'
              '${actualChecksum.toRadixString(16).padLeft(8, '0')}：'
              '该 DEX 在编译后被改动过，或校验和被工具清零。'
              '这不代表恶意，但说明内容与编译产物不再一致'
              '（本次未验证 SHA-1 签名）',
        ));
      }
    }

    return DexStructure(
      name: name,
      byteLength: bytes.length,
      version: version,
      declaredFileSize: declaredFileSize,
      declaredHeaderSize: declaredHeaderSize,
      endianTag: endianTag,
      sections: sections,
      anomalies: anomalies,
      checksumVerified: checksumVerified,
    );
  }

  @override
  String toString() => 'DexStructure($name, version=$version, '
      '${sections.length} sections, ${anomalies.length} anomalies)';
}

/// 计算 `bytes[start:]` 的 Adler-32。
///
/// DEX 规范定义的校验和就是「文件第 12 字节到末尾」的 adler32。
///
/// 自己实现而不引依赖：这个算法只有十几行且完全确定，而它可以用外部工具
/// 独立核对（见 `test/fixtures/dex/README.md` 里的 Python `zlib.adler32`）。
int adler32(Uint8List bytes, {int start = 0}) {
  const modulus = 65521;
  var a = 1;
  var b = 0;
  for (var i = start; i < bytes.length; i++) {
    a += bytes[i];
    b += a;
    // 每 5552 字节取一次模：这是 zlib 的经典做法，避免在大文件上溢出
    // （5552 是使 255*5552 + 65520 不超过 2^32 的最大块长）。
    if ((i - start + 1) % 5552 == 0) {
      a %= modulus;
      b %= modulus;
    }
  }
  a %= modulus;
  b %= modulus;
  return ((b << 16) | a) & 0xFFFFFFFF;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ');

String _escape(String value) {
  final buffer = StringBuffer();
  for (final unit in value.codeUnits) {
    buffer.write(unit >= 0x20 && unit < 0x7F
        ? String.fromCharCode(unit)
        : '\\x${unit.toRadixString(16).padLeft(2, '0')}');
  }
  return buffer.toString();
}
