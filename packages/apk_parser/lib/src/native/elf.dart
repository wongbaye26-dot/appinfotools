import 'dart:convert';
import 'dart:typed_data';

/// ELF 的类别（位宽）。
enum ElfClass {
  elf32,
  elf64;

  /// 头部里的 `EI_CLASS` 取值。
  static ElfClass? fromIdent(int value) => switch (value) {
        1 => ElfClass.elf32,
        2 => ElfClass.elf64,
        _ => null,
      };

  /// 该类别下 `Elf32_Sym` / `Elf64_Sym` 的字节数。
  int get symbolEntrySize => this == ElfClass.elf64 ? 24 : 16;

  /// 该类别下节头（`Elf32_Shdr` / `Elf64_Shdr`）的字节数。
  int get sectionHeaderSize => this == ElfClass.elf64 ? 64 : 40;

  /// 该类别下 ELF 头本身的字节数。
  int get headerSize => this == ElfClass.elf64 ? 64 : 52;
}

/// ELF 的数据编码。
enum ElfEndianness {
  little,
  big;

  Endian get endian =>
      this == ElfEndianness.little ? Endian.little : Endian.big;

  /// 头部里的 `EI_DATA` 取值。
  static ElfEndianness? fromIdent(int value) => switch (value) {
        1 => ElfEndianness.little,
        2 => ElfEndianness.big,
        _ => null,
      };
}

/// 一条 ELF 结构异常。
class ElfAnomaly {
  final String code;
  final String message;

  /// 该异常是否**阻断**后续的节表 / 符号表解析。
  final bool blocking;

  const ElfAnomaly(this.code, this.message, {this.blocking = false});

  @override
  String toString() => '$code: $message';
}

/// 一个 ELF 节头。
class ElfSection {
  /// 节名（从 `.shstrtab` 解出）；解不出来时为空串。
  final String name;

  /// `sh_type`，例如 2 = `SHT_SYMTAB`、11 = `SHT_DYNSYM`、3 = `SHT_STRTAB`。
  final int type;

  /// 节内容在文件里的偏移。
  final int offset;

  /// 节内容的字节数。
  final int size;

  /// 每个条目的字节数（符号表用得到）。
  final int entrySize;

  /// `sh_link`：符号表指向它的字符串表节索引。
  final int link;

  /// 节索引。
  final int index;

  const ElfSection({
    required this.name,
    required this.type,
    required this.offset,
    required this.size,
    required this.entrySize,
    required this.link,
    required this.index,
  });

  /// 节内容是否完整落在 `[0, fileSize)` 之内。
  bool fitsWithin(int fileSize) {
    if (offset < 0 || size < 0) return false;
    if (offset > fileSize) return false;
    return size <= fileSize - offset;
  }

  /// 该节声明的条目数（`entrySize` 为 0 时返回 0）。
  int get entryCount => entrySize == 0 ? 0 : size ~/ entrySize;

  @override
  String toString() => 'ElfSection($index, $name, type=$type, '
      'off=$offset, size=$size, ent=$entrySize, link=$link)';
}

/// 一个 ELF 符号。
class ElfSymbol {
  /// 符号名（从字符串表解出，已去掉 `@版本` 后缀）。
  final String name;

  /// `st_value`（64 位文件里是 64 位，32 位文件里是 32 位）。
  final int value;

  /// `st_size`。
  final int size;

  /// `st_info`：高 4 位是绑定属性，低 4 位是类型。
  final int info;

  /// `st_shndx`：0（`SHN_UNDEF`）表示**未定义**，也就是从这个库外面导入的。
  final int sectionIndex;

  const ElfSymbol({
    required this.name,
    required this.value,
    required this.size,
    required this.info,
    required this.sectionIndex,
  });

  /// 绑定属性：0 = LOCAL、1 = GLOBAL、2 = WEAK。
  int get bind => (info >> 4) & 0xf;

  /// 符号类型：1 = OBJECT、2 = FUNC、3 = SECTION、4 = FILE。
  int get type => info & 0xf;

  /// 是否是**未定义**符号，即这个库**导入**了它。
  bool get isUndefined => sectionIndex == 0;

  /// 是否是符号表第 0 项那个占位符号。
  ///
  /// 按规范它永远是「空名 + 全零 + `SHN_UNDEF`」。它**不是**一个真实的导入，
  /// 把它算进「导入了什么」会凭空多出一条空名字。
  bool get isNullSymbol =>
      name.isEmpty && value == 0 && size == 0 && sectionIndex == 0;

  bool get isFunction => type == 2;

  bool get isObject => type == 1;

  @override
  String toString() => 'ElfSymbol($name, value=0x${value.toRadixString(16)}, '
      '${isUndefined ? 'UND' : 'shndx=$sectionIndex'})';
}

/// ELF 结构解析结果。
///
/// 只解析**头部与节表**，不遍历节内容 —— 因此开销与文件大小无关。
///
/// **不抛异常**：畸形部分停下来记 [anomalies]，保留已读到的数据。
class ElfStructure {
  /// 归档内文件名（如 `lib/arm64-v8a/libnative.so`），同时是证据位置。
  final String name;

  final int byteLength;

  final ElfClass? elfClass;
  final ElfEndianness? endianness;

  /// `e_type`：1 = REL、2 = EXEC、3 = DYN、4 = CORE。
  final int? type;

  /// `e_machine`：183 = AArch64、40 = ARM、62 = x86-64、3 = x86。
  final int? machine;

  /// `e_shoff` / `e_shentsize` / `e_shnum` / `e_shstrndx`。
  final int sectionHeaderOffset;
  final int sectionHeaderEntrySize;
  final int sectionHeaderCount;
  final int sectionNameIndex;

  /// 节表（按索引顺序）。
  final List<ElfSection> sections;

  final List<ElfAnomaly> anomalies;

  const ElfStructure({
    required this.name,
    required this.byteLength,
    this.elfClass,
    this.endianness,
    this.type,
    this.machine,
    this.sectionHeaderOffset = 0,
    this.sectionHeaderEntrySize = 0,
    this.sectionHeaderCount = 0,
    this.sectionNameIndex = 0,
    this.sections = const [],
    this.anomalies = const [],
  });

  /// 结构是否足以支撑符号表解析。
  bool get isTraversable =>
      sections.isNotEmpty && !anomalies.any((a) => a.blocking);

  /// 按名字取节；不存在时返回 `null`。
  ElfSection? section(String sectionName) {
    for (final section in sections) {
      if (section.name == sectionName) return section;
    }
    return null;
  }

  /// `e_machine` 对应的 ABI 名（用于展示）。
  String? get machineName => switch (machine) {
        3 => 'x86',
        40 => 'arm',
        62 => 'x86-64',
        183 => 'aarch64',
        _ => null,
      };

  /// `e_type` 对应的类型名。
  String? get typeName => switch (type) {
        1 => 'REL',
        2 => 'EXEC',
        3 => 'DYN',
        4 => 'CORE',
        _ => null,
      };

  /// 读取 ELF 的头部与节表。
  static ElfStructure read(String name, Uint8List bytes) {
    final anomalies = <ElfAnomaly>[];

    if (bytes.length < 16) {
      return ElfStructure(
        name: name,
        byteLength: bytes.length,
        anomalies: [
          ElfAnomaly(
              'elf.too_short', '文件只有 ${bytes.length} 字节，不足 ELF 标识的 16 字节',
              blocking: true),
        ],
      );
    }

    if (!(bytes[0] == 0x7F &&
        bytes[1] == 0x45 && // E
        bytes[2] == 0x4C && // L
        bytes[3] == 0x46)) {
      // F
      return ElfStructure(
        name: name,
        byteLength: bytes.length,
        anomalies: [
          ElfAnomaly('elf.bad_magic',
              'magic 不是 \\x7fELF（实际 ${_hex(bytes.sublist(0, 4))}）',
              blocking: true),
        ],
      );
    }

    final elfClass = ElfClass.fromIdent(bytes[4]);
    final endianness = ElfEndianness.fromIdent(bytes[5]);
    if (elfClass == null) {
      anomalies.add(ElfAnomaly(
          'elf.unknown_class', 'EI_CLASS=${bytes[4]}，既不是 1（32 位）也不是 2（64 位）',
          blocking: true));
    }
    if (endianness == null) {
      anomalies.add(ElfAnomaly(
          'elf.unknown_endianness', 'EI_DATA=${bytes[5]}，既不是 1（小端）也不是 2（大端）',
          blocking: true));
    }
    if (elfClass == null || endianness == null) {
      return ElfStructure(
        name: name,
        byteLength: bytes.length,
        elfClass: elfClass,
        endianness: endianness,
        anomalies: anomalies,
      );
    }

    if (bytes.length < elfClass.headerSize) {
      anomalies.add(ElfAnomaly(
          'elf.header_truncated',
          '${elfClass.name} 的头部需要 ${elfClass.headerSize} 字节，'
              '实际只有 ${bytes.length} 字节',
          blocking: true));
      return ElfStructure(
        name: name,
        byteLength: bytes.length,
        elfClass: elfClass,
        endianness: endianness,
        anomalies: anomalies,
      );
    }

    final data = ByteData.sublistView(bytes);
    final endian = endianness.endian;

    final type = data.getUint16(0x10, endian);
    final machine = data.getUint16(0x12, endian);

    // e_shoff / e_shentsize / e_shnum / e_shstrndx 在 32/64 位下的偏移不同。
    final is64 = elfClass == ElfClass.elf64;
    final sectionHeaderOffset =
        is64 ? data.getUint64(0x28, endian) : data.getUint32(0x20, endian);
    final sectionHeaderEntrySize = data.getUint16(is64 ? 0x3A : 0x2E, endian);
    final sectionHeaderCount = data.getUint16(is64 ? 0x3C : 0x30, endian);
    final sectionNameIndex = data.getUint16(is64 ? 0x3E : 0x32, endian);

    if (sectionHeaderCount == 0) {
      // 完全剥离节表的库是合法的（运行只需要程序头）。如实说明，不报错。
      return ElfStructure(
        name: name,
        byteLength: bytes.length,
        elfClass: elfClass,
        endianness: endianness,
        type: type,
        machine: machine,
        anomalies: [
          const ElfAnomaly(
              'elf.no_section_headers',
              '节表被剥离（e_shnum=0）：无法读取符号表，'
                  '但文件本身是合法的 —— 运行只需要程序头'),
        ],
      );
    }

    if (sectionHeaderEntrySize < elfClass.sectionHeaderSize) {
      anomalies.add(ElfAnomaly(
          'elf.section_entry_too_small',
          'e_shentsize=$sectionHeaderEntrySize，小于 ${elfClass.name} 的 '
              '${elfClass.sectionHeaderSize} 字节',
          blocking: true));
    }

    // 先验边界：e_shoff 与 e_shnum 都是文件里声明的任意值。
    final tableEnd =
        sectionHeaderOffset + sectionHeaderEntrySize * sectionHeaderCount;
    if (sectionHeaderOffset < 0 ||
        sectionHeaderEntrySize <= 0 ||
        tableEnd > bytes.length) {
      anomalies.add(ElfAnomaly(
        'elf.section_table_out_of_range',
        '节表越界：偏移 $sectionHeaderOffset、$sectionHeaderCount 项 × '
            '$sectionHeaderEntrySize 字节 = 末尾 $tableEnd，'
            '超出文件长度 ${bytes.length}',
        blocking: true,
      ));
      return ElfStructure(
        name: name,
        byteLength: bytes.length,
        elfClass: elfClass,
        endianness: endianness,
        type: type,
        machine: machine,
        sectionHeaderOffset: sectionHeaderOffset,
        sectionHeaderEntrySize: sectionHeaderEntrySize,
        sectionHeaderCount: sectionHeaderCount,
        sectionNameIndex: sectionNameIndex,
        anomalies: anomalies,
      );
    }

    // 先读原始节头（名字还需要 .shstrtab 才能解）。
    final rawSections = <_RawSection>[];
    for (var i = 0; i < sectionHeaderCount; i++) {
      final base = sectionHeaderOffset + i * sectionHeaderEntrySize;
      rawSections.add(_readRawSection(data, base, elfClass, endian));
    }

    // 解节名：先找到 .shstrtab（由 e_shstrndx 指向），再逐个查名字。
    final nameTable = sectionNameIndex < rawSections.length
        ? rawSections[sectionNameIndex]
        : null;
    if (nameTable == null || !nameTable.fitsWithin(bytes.length)) {
      anomalies.add(ElfAnomaly(
        'elf.section_name_table_unavailable',
        'e_shstrndx=$sectionNameIndex 指向的节名表不可用：'
            '节名读不出来，但节的类型与偏移仍然有效',
      ));
    }

    final sections = <ElfSection>[];
    for (var i = 0; i < rawSections.length; i++) {
      final raw = rawSections[i];
      final sectionName = nameTable == null
          ? ''
          : _stringAt(
              bytes,
              nameTable.offset + raw.nameOffset,
              nameTable.offset + nameTable.size,
            );
      sections.add(ElfSection(
        name: sectionName ?? '',
        type: raw.type,
        offset: raw.offset,
        size: raw.size,
        entrySize: raw.entrySize,
        link: raw.link,
        index: i,
      ));
    }

    return ElfStructure(
      name: name,
      byteLength: bytes.length,
      elfClass: elfClass,
      endianness: endianness,
      type: type,
      machine: machine,
      sectionHeaderOffset: sectionHeaderOffset,
      sectionHeaderEntrySize: sectionHeaderEntrySize,
      sectionHeaderCount: sectionHeaderCount,
      sectionNameIndex: sectionNameIndex,
      sections: sections,
      anomalies: anomalies,
    );
  }

  @override
  String toString() => 'ElfStructure($name, ${elfClass?.name}, '
      '${machineName ?? machine}, ${typeName ?? type}, '
      '${sections.length} sections, ${anomalies.length} anomalies)';
}

/// 读取 ELF 符号表的结果。
class ElfSymbolReadResult {
  /// 读出来的符号。
  final List<ElfSymbol> symbols;

  /// 读不出来的条目数（名字越界、条目跨出节外）。
  ///
  /// 单独计数而不是静默跳过：这些条目里的符号我们**没看到**。
  final int skipped;

  /// 是否因为预算上限而提前停止。
  final bool truncated;

  final List<ElfAnomaly> anomalies;

  const ElfSymbolReadResult({
    this.symbols = const [],
    this.skipped = 0,
    this.truncated = false,
    this.anomalies = const [],
  });

  /// **导入**的符号（`st_shndx == 0`），即这个库从外面拿到的能力。
  ///
  /// 排除符号表第 0 项那个占位符号（空名、全零）—— 它不是真实导入，
  /// 算进去会凭空多出一条空名字。
  List<ElfSymbol> get imported => [
        for (final s in symbols)
          if (s.isUndefined && !s.isNullSymbol) s,
      ];

  /// **导出**的符号（定义在本库里），同样排除占位符号。
  List<ElfSymbol> get exported => [
        for (final s in symbols)
          if (!s.isUndefined && !s.isNullSymbol) s,
      ];

  bool get isEmpty => symbols.isEmpty;

  @override
  String toString() => 'ElfSymbolReadResult(${symbols.length} symbols, '
      'skipped=$skipped, truncated=$truncated)';
}

/// 符号表读取。
///
/// 两个来源，**语义不同**：
/// - `.dynsym`（`SHT_DYNSYM`）：动态链接需要的符号，**运行时一定在**。
///   导入的 libc 函数（`system` / `dlopen` / `ptrace`…）就在这里。
/// - `.symtab`（`SHT_SYMTAB`）：完整符号表，**发布版本通常被 strip 掉**。
///   有它说明这个库没剥离，能读到内部函数名 —— 这本身就是一条线索。
class ElfSymbolTable {
  ElfSymbolTable._();

  /// 一次读取最多处理多少个符号条目。
  static const int maxSymbols = 200000;

  /// 读动态符号表（`.dynsym`）。
  static ElfSymbolReadResult readDynamic(Uint8List bytes, ElfStructure s) =>
      _read(bytes, s, 'SHT_DYNSYM');

  /// 读完整符号表（`.symtab`）。
  static ElfSymbolReadResult readStatic(Uint8List bytes, ElfStructure s) =>
      _read(bytes, s, 'SHT_SYMTAB');

  static ElfSymbolReadResult _read(
    Uint8List bytes,
    ElfStructure structure,
    String kind,
  ) {
    final anomalies = <ElfAnomaly>[];
    if (!structure.isTraversable) {
      return ElfSymbolReadResult(anomalies: [
        ElfAnomaly('elf.structure_not_traversable',
            '${structure.name} 的结构不可信，未读取 $kind'),
      ]);
    }
    final elfClass = structure.elfClass!;
    final endian = structure.endianness!.endian;

    // 按节类型找符号表：DYNSYM=11、SYMTAB=2。
    final wantedType = kind == 'SHT_DYNSYM' ? 11 : 2;
    ElfSection? symbolSection;
    for (final section in structure.sections) {
      if (section.type == wantedType) {
        symbolSection = section;
        break;
      }
    }
    if (symbolSection == null) {
      // 被 strip 掉的库没有 .symtab，这是**正常**情况，不是异常。
      return ElfSymbolReadResult(anomalies: [
        ElfAnomaly('elf.symbol_table_absent',
            '没有 $kind 节（${kind == 'SHT_SYMTAB' ? '符号表被剥离，发布版本常见' : '文件可能不是动态链接'}）'),
      ]);
    }
    if (!symbolSection.fitsWithin(bytes.length)) {
      return ElfSymbolReadResult(anomalies: [
        ElfAnomaly(
            'elf.symbol_section_out_of_range',
            '$kind 节越界：偏移 ${symbolSection.offset}、'
                '大小 ${symbolSection.size}，超出文件长度 ${bytes.length}',
            blocking: true),
      ]);
    }

    // 字符串表由 sh_link 指向。
    final stringTable = symbolSection.link < structure.sections.length
        ? structure.sections[symbolSection.link]
        : null;
    if (stringTable == null || !stringTable.fitsWithin(bytes.length)) {
      return ElfSymbolReadResult(anomalies: [
        ElfAnomaly(
            'elf.symbol_string_table_unavailable',
            '$kind 的 sh_link=${symbolSection.link} 指向的字符串表不可用：'
                '符号名读不出来，因此不产出符号（不猜名字）',
            blocking: true),
      ]);
    }

    final data = ByteData.sublistView(bytes);
    final entrySize = symbolSection.entrySize > 0
        ? symbolSection.entrySize
        : elfClass.symbolEntrySize;
    final declared = entrySize == 0 ? 0 : symbolSection.size ~/ entrySize;
    final limit = declared < maxSymbols ? declared : maxSymbols;

    final symbols = <ElfSymbol>[];
    var skipped = 0;
    for (var i = 0; i < limit; i++) {
      final base = symbolSection.offset + i * entrySize;
      if (base + elfClass.symbolEntrySize > bytes.length) {
        skipped++;
        continue;
      }
      final symbol = _readSymbol(
        data,
        bytes,
        base,
        elfClass,
        endian,
        stringTable,
      );
      if (symbol == null) {
        skipped++;
        continue;
      }
      symbols.add(symbol);
    }

    return ElfSymbolReadResult(
      symbols: symbols,
      skipped: skipped,
      truncated: limit < declared,
      anomalies: anomalies,
    );
  }

  static ElfSymbol? _readSymbol(
    ByteData data,
    Uint8List bytes,
    int base,
    ElfClass elfClass,
    Endian endian,
    ElfSection stringTable,
  ) {
    final is64 = elfClass == ElfClass.elf64;
    final nameOffset = data.getUint32(base, endian);
    final info = data.getUint8(base + (is64 ? 4 : 12));
    final sectionIndex = data.getUint16(base + (is64 ? 6 : 14), endian);
    final value = is64
        ? data.getUint64(base + 8, endian)
        : data.getUint32(base + 4, endian);
    final size = is64
        ? data.getUint64(base + 16, endian)
        : data.getUint32(base + 8, endian);

    // 字符串表里的名字：必须落在该节范围内，否则不猜。
    final rawName = _stringAt(
      bytes,
      stringTable.offset + nameOffset,
      stringTable.offset + stringTable.size,
    );
    if (rawName == null) return null;

    return ElfSymbol(
      name: _stripVersion(rawName),
      value: value,
      size: size,
      info: info,
      sectionIndex: sectionIndex,
    );
  }

  /// 去掉符号名里的 `@版本` 后缀（如 `connect@LIBC` → `connect`）。
  ///
  /// 版本信息实际来自 `.gnu.version` 节，`st_name` 指向的名字通常本来就不带
  /// 后缀；这里只是兜住某些工具把版本写进名字的情况。
  static String _stripVersion(String name) {
    final at = name.indexOf('@');
    return at <= 0 ? name : name.substring(0, at);
  }
}

/// 原始节头（名字还没解）。
class _RawSection {
  final int nameOffset;
  final int type;
  final int offset;
  final int size;
  final int link;
  final int entrySize;

  const _RawSection({
    required this.nameOffset,
    required this.type,
    required this.offset,
    required this.size,
    required this.link,
    required this.entrySize,
  });

  bool fitsWithin(int fileSize) {
    if (offset < 0 || size < 0 || offset > fileSize) return false;
    return size <= fileSize - offset;
  }
}

_RawSection _readRawSection(
  ByteData data,
  int base,
  ElfClass elfClass,
  Endian endian,
) {
  final is64 = elfClass == ElfClass.elf64;
  if (is64) {
    return _RawSection(
      nameOffset: data.getUint32(base, endian),
      type: data.getUint32(base + 4, endian),
      offset: data.getUint64(base + 0x18, endian),
      size: data.getUint64(base + 0x20, endian),
      link: data.getUint32(base + 0x28, endian),
      entrySize: data.getUint64(base + 0x38, endian),
    );
  }
  return _RawSection(
    nameOffset: data.getUint32(base, endian),
    type: data.getUint32(base + 4, endian),
    offset: data.getUint32(base + 0x10, endian),
    size: data.getUint32(base + 0x14, endian),
    link: data.getUint32(base + 0x18, endian),
    entrySize: data.getUint32(base + 0x24, endian),
  );
}

/// 从 `[offset, end)` 里读一个 NUL 结尾的字符串。
///
/// 越界（起点在范围外、或找不到终止符）时返回 `null` —— **不猜**。
String? _stringAt(Uint8List bytes, int offset, int end) {
  if (offset < 0 || offset >= end || end > bytes.length) return null;
  var cursor = offset;
  while (cursor < end && bytes[cursor] != 0) {
    cursor++;
  }
  if (cursor >= end) return null;
  return utf8.decode(
    Uint8List.sublistView(bytes, offset, cursor),
    allowMalformed: true,
  );
}

String _hex(List<int> bytes) =>
    bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ');
