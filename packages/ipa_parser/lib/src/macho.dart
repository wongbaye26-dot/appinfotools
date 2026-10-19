import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

/// Mach-O 的字节序。
enum MachOByteOrder { little, big }

/// 容器形式：单个镜像，或含多个架构的 fat / universal。
enum MachOContainer { thin, fat }

/// Mach-O 文件类型（`filetype` 字段）。
enum MachOFileType {
  object,
  execute,
  fvmlib,
  core,
  preload,
  dylib,
  dylinker,
  bundle,
  dylibStub,
  dsym,
  kextBundle,
  fileset,
  unknown;

  static MachOFileType fromRaw(int raw) => switch (raw) {
        0x1 => MachOFileType.object,
        0x2 => MachOFileType.execute,
        0x3 => MachOFileType.fvmlib,
        0x4 => MachOFileType.core,
        0x5 => MachOFileType.preload,
        0x6 => MachOFileType.dylib,
        0x7 => MachOFileType.dylinker,
        0x8 => MachOFileType.bundle,
        0x9 => MachOFileType.dylibStub,
        0xA => MachOFileType.dsym,
        0xB => MachOFileType.kextBundle,
        0xC => MachOFileType.fileset,
        _ => MachOFileType.unknown,
      };
}

/// 一个 Mach-O 节（`section` / `section_64`）。
///
/// **为什么需要节而不是只要段**：`__TEXT` 段里既有代码也有好几张字符串表，
/// 只看段等于把它们混成一锅。`__objc_methname`（选择子表）是「这个二进制
/// 引用了哪些方法」的结构化证据，比在整文件里搜字符串精确得多。
class MachOSection {
  /// 节名，例如 `__objc_methname`。
  final String name;

  /// 所属段名，例如 `__TEXT`。
  final String segment;

  /// 节在**文件**中的偏移（fat 二进制里是相对切片起点的偏移）。
  final int fileOffset;

  /// 节的字节数。零填充节（`__bss`）为 0。
  final int fileSize;

  const MachOSection({
    required this.name,
    required this.segment,
    required this.fileOffset,
    required this.fileSize,
  });

  /// `__TEXT,__objc_methname` 这种「段,节」写法 —— 证据里直接用这个。
  String get qualifiedName => '$segment,$name';

  @override
  String toString() => 'MachOSection($qualifiedName, $fileOffset+$fileSize)';
}

/// 一个 Mach-O 段（`LC_SEGMENT` / `LC_SEGMENT_64`）。
class MachOSegment {
  final String name;

  /// 段在文件中的偏移与字节数。`__PAGEZERO` 等段 `fileSize` 为 0。
  final int fileOffset;
  final int fileSize;

  /// 段在内存中的大小。
  final int vmSize;

  /// 段内声明的节数。
  final int sectionCount;

  /// 段内的节。数量与 [sectionCount] 一致（命令被截断时可能少几条）。
  final List<MachOSection> sections;

  const MachOSegment({
    required this.name,
    required this.fileOffset,
    required this.fileSize,
    required this.vmSize,
    required this.sectionCount,
    this.sections = const [],
  });

  /// 按节名取（同一段内节名唯一）。
  MachOSection? section(String name) {
    for (final s in sections) {
      if (s.name == name) return s;
    }
    return null;
  }

  @override
  String toString() =>
      'MachOSegment($name, file: $fileOffset+$fileSize, vm: $vmSize, '
      '$sectionCount sections)';
}

/// 一个 Mach-O 符号（`nlist` / `nlist_64`）。
///
/// 名字是**原样**的符号名（C 符号带前导下划线，如 `_system`）。
/// 用 [cName] 取去掉前导下划线后的名字 —— 标记匹配要用它。
class MachOSymbol {
  /// 原样符号名，例如 `_system`、`_exported_helper`。
  final String name;

  /// `n_type`。
  final int type;

  /// `n_sect`。
  final int sectionIndex;

  /// `n_value`。
  final int value;

  const MachOSymbol({
    required this.name,
    required this.type,
    required this.sectionIndex,
    required this.value,
  });

  /// 调试符号（`N_STAB` 位）。它们不是链接符号，不计入导入/导出。
  bool get isDebug => (type & 0xe0) != 0;

  /// 外部符号（`N_EXT` 位）。
  bool get isExternal => (type & 0x01) != 0;

  /// `n_type` 的类型字段（`N_TYPE` 掩码 0x0e）。
  int get typeField => type & 0x0e;

  /// **未定义**（导入）：`N_UNDF | N_EXT`。
  bool get isUndefined => typeField == 0x0 && isExternal;

  /// **定义的**外部符号（导出）：`N_SECT | N_EXT`。
  bool get isDefinedExternal => typeField == 0xe && isExternal;

  /// 去掉 Mach-O 的 C 符号前导下划线（`_system` → `system`）。
  ///
  /// **只去一个**：`___cxa_atexit` 是 C++ 运行时的 `__cxa_atexit`，
  /// 去掉两个就认不出来了。
  String get cName => name.startsWith('_') ? name.substring(1) : name;

  @override
  String toString() => 'MachOSymbol($name, type=0x${type.toRadixString(16)}, '
      'sect=$sectionIndex, value=0x${value.toRadixString(16)})';
}

/// `LC_SYMTAB` 的内容。
///
/// **两个偏移都是相对「本切片起始」的**，不是相对整个文件 —— fat 二进制里
/// 每个切片都是一份完整的 Mach-O，链接器写进去的是切片内偏移。
/// 实测：`libnative-fixture-arm64.dylib` 与 fat 里的 arm64 切片都报
/// `symoff 33112`，而后者在文件里的起点是 4096 之后。
class MachOSymtab {
  final int symbolOffset;
  final int symbolCount;
  final int stringOffset;
  final int stringSize;

  const MachOSymtab({
    required this.symbolOffset,
    required this.symbolCount,
    required this.stringOffset,
    required this.stringSize,
  });

  @override
  String toString() => 'MachOSymtab(symoff=$symbolOffset, nsyms=$symbolCount, '
      'stroff=$stringOffset, strsize=$stringSize)';
}

/// 一个 Mach-O 镜像：fat 里的一个切片，或整个 thin 文件。
class MachOImage {
  /// 该切片在所属文件中的起始偏移（thin 文件为 0）。
  final int offset;

  /// 切片的字节数。
  final int size;

  final MachOByteOrder byteOrder;
  final bool is64Bit;

  final int cpuType;
  final int cpuSubtype;
  final MachOFileType fileType;

  final int loadCommandCount;
  final int loadCommandsSize;
  final int flags;

  /// `LC_UUID`，格式化为大写带连字符的标准写法。
  final String? uuid;

  /// `LC_BUILD_VERSION` 的 platform（1 = macOS，2 = iOS，3 = tvOS，
  /// 4 = watchOS，6 = macCatalyst）。
  final int? platform;

  /// 最低系统版本与 SDK 版本（原始编码，用 [minimumOsVersionText] 取可读形式）。
  final int? minimumOsVersionRaw;
  final int? sdkVersionRaw;

  /// `LC_ID_DYLIB` 的安装名。
  final String? installName;

  /// 链接的动态库（`LC_LOAD_DYLIB` 及其 weak / reexport / upward 变体）。
  final List<String> linkedLibraries;

  /// `LC_RPATH` 的运行时搜索路径。
  final List<String> rpaths;

  final List<MachOSegment> segments;

  /// `LC_MAIN` 的入口偏移（可执行文件才有）。
  final int? entryOffset;

  /// `LC_SYMTAB`；没有该命令时为 `null`。
  final MachOSymtab? symtab;

  /// 从 `LC_SYMTAB` 读出的符号（已过滤调试符号）。
  ///
  /// 为空有两种可能，**必须分开**：没有 `LC_SYMTAB`（[symtab] 为 `null`），
  /// 或符号表存在但读不出条目（见 `MachOFile.diagnostics`）。
  final List<MachOSymbol> symbols;

  /// 本次是否**真的读取**过符号表。
  ///
  /// 为 `false` 时，「没有导入符号」不能读成「没有能力」—— 那是「没查」。
  final bool symbolsRead;

  const MachOImage({
    required this.offset,
    required this.size,
    required this.byteOrder,
    required this.is64Bit,
    required this.cpuType,
    required this.cpuSubtype,
    required this.fileType,
    this.loadCommandCount = 0,
    this.loadCommandsSize = 0,
    this.flags = 0,
    this.uuid,
    this.platform,
    this.minimumOsVersionRaw,
    this.sdkVersionRaw,
    this.installName,
    this.linkedLibraries = const [],
    this.rpaths = const [],
    this.segments = const [],
    this.entryOffset,
    this.symtab,
    this.symbols = const [],
    this.symbolsRead = false,
  });

  /// **导入**的符号（`N_UNDF | N_EXT`）：这个镜像从外部拿到的能力。
  List<MachOSymbol> get importedSymbols => [
        for (final s in symbols)
          if (s.isUndefined) s
      ];

  /// **导出**的符号（`N_SECT | N_EXT`）：这个镜像对外提供的接口。
  List<MachOSymbol> get exportedSymbols => [
        for (final s in symbols)
          if (s.isDefinedExternal) s
      ];

  /// 架构名，例如 `arm64`、`x86_64`。
  String get cpuTypeName => machOCpuTypeName(cpuType);

  /// 面向展示的架构描述，含位数。
  ///
  /// 位数来自**魔数**（`MH_MAGIC_64` 系列），不是从 cputype 猜的 ——
  /// 同一个 cputype 在不同魔数下含义不同。
  String get architectureName =>
      is64Bit ? '$cpuTypeName (64-bit)' : '$cpuTypeName (32-bit)';

  /// 可读的最低系统版本，例如 `27.0`。
  String? get minimumOsVersionText => formatMachOVersion(minimumOsVersionRaw);

  /// 可读的 SDK 版本。
  String? get sdkVersionText => formatMachOVersion(sdkVersionRaw);

  /// 平台名（`LC_BUILD_VERSION`）。
  String? get platformName => switch (platform) {
        1 => 'macOS',
        2 => 'iOS',
        3 => 'tvOS',
        4 => 'watchOS',
        5 => 'bridgeOS',
        6 => 'macCatalyst',
        7 => 'iOS Simulator',
        8 => 'tvOS Simulator',
        9 => 'watchOS Simulator',
        10 => 'DriverKit',
        _ => null,
      };

  /// 段在文件中的实际占用（`__LINKEDIT` 等也算在内）。
  int get segmentsFileSize =>
      segments.fold(0, (sum, segment) => sum + segment.fileSize);

  @override
  String toString() => 'MachOImage($architectureName, ${fileType.name}, '
      '${linkedLibraries.length} dylibs, ${segments.length} segments)';
}

/// Mach-O 解析结果。
class MachOFile {
  final MachOContainer? container;

  /// fat 头部自身的字节序；thin 文件为 `null`（用镜像的字节序）。
  final MachOByteOrder? containerByteOrder;

  /// 全部镜像，按 fat 表中的顺序（与 `lipo -info` 一致）。
  final List<MachOImage> images;

  final List<AnalysisDiagnostic> diagnostics;

  const MachOFile({
    this.container,
    this.containerByteOrder,
    this.images = const [],
    this.diagnostics = const [],
  });

  bool get isFat => container == MachOContainer.fat;

  /// 取某个节的字节（自动加上切片的起始偏移）。
  ///
  /// 只返回**文件里真实存在**的那一段：零填充节（`__bss`）、越界偏移、
  /// 声明长度超过切片末尾，一律返回 `null` —— 调用方据此区分「没有这个节」
  /// 与「节存在但读不到」，不要用空列表糊过去。
  Uint8List? sectionBytes(
    Uint8List file, {
    required String segment,
    required String section,
  }) {
    for (final image in images) {
      for (final seg in image.segments) {
        if (seg.name != segment) continue;
        final sec = seg.section(section);
        if (sec == null || sec.fileSize <= 0) return null;
        final start = image.offset + sec.fileOffset;
        final end = start + sec.fileSize;
        if (start < 0 || end > file.length || end <= start) return null;
        return Uint8List.sublistView(file, start, end);
      }
    }
    return null;
  }

  /// 是否成功解析出至少一个镜像。
  bool get isMachO => images.isNotEmpty;

  MachOImage? get primary => images.isEmpty ? null : images.first;

  /// 全部架构名。
  List<String> get architectureNames =>
      images.map((image) => image.architectureName).toList();

  /// 全部镜像链接到的动态库（去重、排序）。
  List<String> get allLinkedLibraries {
    final set = <String>{};
    for (final image in images) {
      set.addAll(image.linkedLibraries);
    }
    return set.toList()..sort();
  }
}

/// Mach-O 的 CPU 类型名。
String machOCpuTypeName(int cpuType) => switch (cpuType) {
      0x00000007 => 'i386',
      0x01000007 => 'x86_64',
      0x0000000C => 'arm',
      0x0100000C => 'arm64',
      0x0200000C => 'arm64_32',
      0x00000012 => 'ppc',
      0x01000012 => 'ppc64',
      _ => 'cpu(0x${cpuType.toRadixString(16)})',
    };

/// 把 Mach-O 的打包版本号格式化成 `major.minor` 或 `major.minor.patch`。
///
/// 编码是 `xxxx.yy.zz`：高 16 位主版本、次 8 位次版本、低 8 位修订号。
/// `xx.y.0` 这类尾随 0 会被省略，与 `otool` 的输出一致。
String? formatMachOVersion(int? raw) {
  if (raw == null) return null;
  final major = (raw >> 16) & 0xFFFF;
  final minor = (raw >> 8) & 0xFF;
  final patch = raw & 0xFF;
  if (patch != 0) return '$major.$minor.$patch';
  return '$major.$minor';
}

/// Mach-O 解析器。
///
/// 规范 5.4 明确要求：「Mach-O 解析应具备文件边界检查，不允许信任文件内未经
/// 验证的长度和偏移」。这里所有偏移与长度**先验证再使用**：越界一律停止解析
/// 并记诊断，而不是读越界内存或陷入死循环。
///
/// 遇到问题**不抛异常**，而是返回已读到的部分并附诊断 —— 一个文件的第 30 条
/// load command 畸形，不该让前 29 条的信息全部丢失。
class MachOParser {
  MachOParser._();

  // 魔数（按大端读到的 32 位值）
  static const int _magic32 = 0xFEEDFACE; // MH_MAGIC，小端
  static const int _magic64 = 0xFEEDFACF; // MH_MAGIC_64，小端
  static const int _cigam32 = 0xCEFAEDFE; // MH_CIGAM，大端
  static const int _cigam64 = 0xCFFAEDFE; // MH_CIGAM_64，大端
  static const int _fatMagic = 0xCAFEBABE;
  static const int _fatCigam = 0xBEBAFECA;
  static const int _fatMagic64 = 0xCAFEBABF;
  static const int _fatCigam64 = 0xBFBAFECA;

  // Load command
  static const int _lcSymtab = 0x2;
  static const int _lcSegment = 0x1;
  static const int _lcSegment64 = 0x19;
  static const int _lcUuid = 0x1B;
  static const int _lcIdDylib = 0xD;
  static const int _lcLoadDylib = 0xC;
  static const int _lcLoadWeakDylib = 0x80000018;
  static const int _lcReexportDylib = 0x8000001F;
  static const int _lcLoadUpwardDylib = 0x80000023;
  static const int _lcLazyLoadDylib = 0x20;
  static const int _lcRpath = 0x8000001C;
  static const int _lcMain = 0x80000028;
  static const int _lcBuildVersion = 0x32;
  static const int _lcVersionMinMacosx = 0x24;
  static const int _lcVersionMinIphoneos = 0x25;
  static const int _lcVersionMinTvos = 0x2F;
  static const int _lcVersionMinWatchos = 0x30;

  /// `nlist_64` / `nlist` 的字节数。
  static const int _nlist64Size = 16;
  static const int _nlist32Size = 12;

  /// 单个镜像最多读多少条符号。兜住畸形文件，截断时记诊断。
  static const int maxSymbolsPerImage = 200000;

  static const int _headerSize32 = 28;
  static const int _headerSize64 = 32;
  static const int _fatEntrySize32 = 20;
  static const int _fatEntrySize64 = 32;

  static MachOFile parse(Uint8List data) {
    if (data.length < 4) {
      return _failure(
          'file is too short (${data.length} bytes) to be a Mach-O');
    }

    final magic = _be32(data, 0);
    if (magic == null) {
      return _failure('cannot read the magic number');
    }

    // Fat 头部固定大端；小端形式（CIGAM）在现实中几乎不出现，但仍要识别。
    if (magic == _fatMagic || magic == _fatMagic64) {
      return _parseFat(data, MachOByteOrder.big,
          entriesAre64Bit: magic == _fatMagic64);
    }
    if (magic == _fatCigam || magic == _fatCigam64) {
      return _parseFat(data, MachOByteOrder.little,
          entriesAre64Bit: magic == _fatCigam64);
    }

    if (magic == _magic64 ||
        magic == _magic32 ||
        magic == _cigam64 ||
        magic == _cigam32) {
      final is64 = magic == _magic64 || magic == _cigam64;
      // 按大端读魔数：读到 MH_CIGAM 系列说明文件本身是**小端**
      // （小端文件把 MH_MAGIC 存成 CF FA ED FE，大端读出来就是 CIGAM）。
      // 现实中绝大多数 Mach-O 是小端。
      final order = (magic == _magic64 || magic == _magic32)
          ? MachOByteOrder.big
          : MachOByteOrder.little;

      final diagnostics = <AnalysisDiagnostic>[];
      final image = _parseImage(
        data,
        base: 0,
        available: data.length,
        is64Bit: is64,
        order: order,
        diagnostics: diagnostics,
      );
      diagnostics.insert(
        0,
        AnalysisDiagnostic.info(
          'ios.macho.parsed',
          'thin Mach-O (${is64 ? '64' : '32'}-bit, '
              '${machOCpuTypeName(_readUint32(data, 4, order) ?? 0)}), '
              '${image == null ? 0 : 1} image parsed',
        ),
      );
      return MachOFile(
        container: MachOContainer.thin,
        images: image == null ? const [] : [image],
        diagnostics: diagnostics,
      );
    }

    return _failure('not a Mach-O: magic 0x${magic.toRadixString(16)}');
  }

  static MachOFile _failure(String message) => MachOFile(
        diagnostics: [
          AnalysisDiagnostic.error('ios.macho.unrecognised', message),
        ],
      );

  static MachOFile _parseFat(
    Uint8List data,
    MachOByteOrder order, {
    required bool entriesAre64Bit,
  }) {
    final diagnostics = <AnalysisDiagnostic>[];

    final count = _readUint32(data, 4, order);
    if (count == null) {
      return _failure('fat header is truncated');
    }
    if (count <= 0 || count > 64) {
      // 真实产物最多几个架构；声明几十个只可能是畸形或构造的。
      return _failure('implausible fat architecture count: $count');
    }

    final entrySize = entriesAre64Bit ? _fatEntrySize64 : _fatEntrySize32;
    final tableEnd = 8 + count * entrySize;
    if (tableEnd > data.length) {
      return _failure('fat architecture table is truncated');
    }

    final images = <MachOImage>[];
    for (var i = 0; i < count; i++) {
      final entry = 8 + i * entrySize;
      final offset = entriesAre64Bit
          ? _readUint64(data, entry + 8, order)
          : _readUint32(data, entry + 8, order);
      final size = entriesAre64Bit
          ? _readUint64(data, entry + 16, order)
          : _readUint32(data, entry + 12, order);

      if (offset == null || size == null) {
        diagnostics.add(AnalysisDiagnostic.error(
          'ios.macho.fat_entry_truncated',
          'fat entry $i is truncated',
        ));
        continue;
      }
      if (offset < 0 || size < 0 || offset + size > data.length) {
        diagnostics.add(AnalysisDiagnostic.error(
          'ios.macho.fat_entry_out_of_bounds',
          'fat entry $i spans $offset+$size, beyond the ${data.length} byte file',
        ));
        continue;
      }
      if (size < 4) {
        diagnostics.add(AnalysisDiagnostic.error(
          'ios.macho.fat_entry_too_small',
          'fat entry $i is only $size bytes',
        ));
        continue;
      }

      // 切片自身可能又是 fat（嵌套 fat 不允许），交给 _parseImage 判断魔数。
      final image = _parseImage(
        data,
        base: offset,
        available: size,
        is64Bit: null,
        order: null,
        diagnostics: diagnostics,
        sliceIndex: i,
      );
      if (image != null) images.add(image);
    }

    diagnostics.insert(
      0,
      AnalysisDiagnostic.info(
        'ios.macho.parsed',
        'fat Mach-O with $count architecture entr'
            '${count == 1 ? 'y' : 'ies'}, ${images.length} parsed',
      ),
    );

    return MachOFile(
      container: MachOContainer.fat,
      containerByteOrder: order,
      images: images,
      diagnostics: diagnostics,
    );
  }

  /// 解析一个 Mach-O 镜像。
  ///
  /// [is64Bit] 与 [order] 为 `null` 时从切片自身的魔数推断（fat 的每个切片
  /// 都有自己的头部，不能沿用 fat 表的字节序）。
  static MachOImage? _parseImage(
    Uint8List data, {
    required int base,
    required int available,
    required bool? is64Bit,
    required MachOByteOrder? order,
    required List<AnalysisDiagnostic> diagnostics,
    int? sliceIndex,
  }) {
    final label = sliceIndex == null ? 'image' : 'slice $sliceIndex';
    if (base + 4 > data.length || available < 4) {
      diagnostics.add(AnalysisDiagnostic.error(
        'ios.macho.image_truncated',
        '$label has no room for a header',
      ));
      return null;
    }

    final magic = _be32(data, base);
    if (magic == null) return null;

    var resolvedIs64 = is64Bit;
    var resolvedOrder = order;
    if (magic == _magic64 ||
        magic == _magic32 ||
        magic == _cigam64 ||
        magic == _cigam32) {
      resolvedIs64 = magic == _magic64 || magic == _cigam64;
      resolvedOrder = (magic == _magic64 || magic == _magic32)
          ? MachOByteOrder.big
          : MachOByteOrder.little;
    } else if (resolvedIs64 == null || resolvedOrder == null) {
      diagnostics.add(AnalysisDiagnostic.error(
        'ios.macho.bad_magic',
        '$label has an unrecognised magic 0x${magic.toRadixString(16)}',
      ));
      return null;
    }

    final is64 = resolvedIs64;
    final byteOrder = resolvedOrder;
    final headerSize = is64 ? _headerSize64 : _headerSize32;

    if (headerSize > available) {
      diagnostics.add(AnalysisDiagnostic.error(
        'ios.macho.image_truncated',
        '$label declares a ${is64 ? 64 : 32}-bit header but only $available '
            'bytes are available',
      ));
      return null;
    }

    final cpuType = _readUint32(data, base + 4, byteOrder);
    final cpuSubtype = _readUint32(data, base + 8, byteOrder);
    final fileTypeRaw = _readUint32(data, base + 12, byteOrder);
    final ncmds = _readUint32(data, base + 16, byteOrder);
    final sizeofcmds = _readUint32(data, base + 20, byteOrder);
    final flags = _readUint32(data, base + 24, byteOrder);

    if (cpuType == null ||
        cpuSubtype == null ||
        fileTypeRaw == null ||
        ncmds == null ||
        sizeofcmds == null ||
        flags == null) {
      diagnostics.add(AnalysisDiagnostic.error(
        'ios.macho.header_truncated',
        '$label header is truncated',
      ));
      return null;
    }

    if (ncmds < 0 || sizeofcmds < 0 || headerSize + sizeofcmds > available) {
      diagnostics.add(AnalysisDiagnostic.error(
        'ios.macho.load_commands_out_of_bounds',
        '$label declares $sizeofcmds bytes of load commands, beyond the '
            '$available byte slice',
      ));
      return null;
    }
    // 每条 load command 至少 8 字节（cmd + cmdsize）。
    if (ncmds * 8 > sizeofcmds) {
      diagnostics.add(AnalysisDiagnostic.error(
        'ios.macho.implausible_command_count',
        '$label declares $ncmds commands in $sizeofcmds bytes',
      ));
      return null;
    }

    String? uuidText;
    int? platform;
    int? minimumOs;
    int? sdkVersion;
    String? installName;
    final linkedLibraries = <String>[];
    final rpaths = <String>[];
    final segments = <MachOSegment>[];
    int? entryOffset;
    MachOSymtab? symtab;

    final commandsEnd = base + headerSize + sizeofcmds;
    var cursor = base + headerSize;

    for (var i = 0; i < ncmds; i++) {
      if (cursor + 8 > commandsEnd) {
        diagnostics.add(AnalysisDiagnostic.error(
          'ios.macho.command_truncated',
          '$label ran out of room at command $i',
        ));
        break;
      }
      final cmd = _readUint32(data, cursor, byteOrder);
      final cmdsize = _readUint32(data, cursor + 4, byteOrder);
      if (cmd == null || cmdsize == null) break;

      // cmdsize 必须 >= 8 且让游标前进，否则会死循环。
      if (cmdsize < 8 || cursor + cmdsize > commandsEnd) {
        diagnostics.add(AnalysisDiagnostic.error(
          'ios.macho.command_size_invalid',
          '$label command $i declares size $cmdsize, which is invalid or '
              'exceeds the load-command region',
        ));
        break;
      }

      switch (cmd) {
        case _lcSegment:
        case _lcSegment64:
          final segment = _readSegment(data, cursor, byteOrder,
              is64: cmd == _lcSegment64,
              label: label,
              diagnostics: diagnostics);
          if (segment != null) segments.add(segment);
        case _lcSymtab:
          // symtab_command: cmd + cmdsize + symoff + nsyms + stroff + strsize
          if (cmdsize >= 24) {
            final symoff = _readUint32(data, cursor + 8, byteOrder);
            final nsyms = _readUint32(data, cursor + 12, byteOrder);
            final stroff = _readUint32(data, cursor + 16, byteOrder);
            final strsize = _readUint32(data, cursor + 20, byteOrder);
            if (symoff != null &&
                nsyms != null &&
                stroff != null &&
                strsize != null) {
              symtab = MachOSymtab(
                symbolOffset: symoff,
                symbolCount: nsyms,
                stringOffset: stroff,
                stringSize: strsize,
              );
            }
          }
        case _lcUuid:
          if (cmdsize >= 24) {
            final bytes = data.sublist(cursor + 8, cursor + 24);
            uuidText = _formatUuid(bytes);
          }
        case _lcIdDylib:
          installName = _readDylibName(data, cursor, cmdsize, byteOrder);
        case _lcLoadDylib:
        case _lcLoadWeakDylib:
        case _lcReexportDylib:
        case _lcLoadUpwardDylib:
        case _lcLazyLoadDylib:
          final name = _readDylibName(data, cursor, cmdsize, byteOrder);
          if (name != null) linkedLibraries.add(name);
        case _lcRpath:
          final name = _readDylibName(data, cursor, cmdsize, byteOrder);
          if (name != null) rpaths.add(name);
        case _lcMain:
          if (cmdsize >= 24) {
            entryOffset = _readUint64(data, cursor + 8, byteOrder);
          }
        case _lcBuildVersion:
          if (cmdsize >= 24) {
            platform = _readUint32(data, cursor + 8, byteOrder);
            minimumOs = _readUint32(data, cursor + 12, byteOrder);
            sdkVersion = _readUint32(data, cursor + 16, byteOrder);
          }
        case _lcVersionMinMacosx:
        case _lcVersionMinIphoneos:
        case _lcVersionMinTvos:
        case _lcVersionMinWatchos:
          if (cmdsize >= 16) {
            minimumOs ??= _readUint32(data, cursor + 8, byteOrder);
            sdkVersion ??= _readUint32(data, cursor + 12, byteOrder);
          }
      }

      cursor += cmdsize;
    }

    // 读符号表。**偏移是相对本切片起始的** —— fat 里每个切片都是一份完整的
    // Mach-O，链接器写进去的是切片内偏移，因此要加 base。
    var symbols = const <MachOSymbol>[];
    var symbolsRead = false;
    if (symtab != null) {
      final result = _readSymbols(
        data,
        base: base,
        available: available,
        is64: is64,
        byteOrder: byteOrder,
        symtab: symtab,
        label: label,
        diagnostics: diagnostics,
      );
      symbols = result.symbols;
      symbolsRead = result.read;
    }

    return MachOImage(
      offset: base,
      size: available,
      byteOrder: byteOrder,
      is64Bit: is64,
      cpuType: cpuType,
      cpuSubtype: cpuSubtype,
      fileType: MachOFileType.fromRaw(fileTypeRaw),
      loadCommandCount: ncmds,
      loadCommandsSize: sizeofcmds,
      flags: flags,
      uuid: uuidText,
      platform: platform,
      minimumOsVersionRaw: minimumOs,
      sdkVersionRaw: sdkVersion,
      installName: installName,
      linkedLibraries: linkedLibraries,
      rpaths: rpaths,
      segments: segments,
      entryOffset: entryOffset,
      symtab: symtab,
      symbols: symbols,
      symbolsRead: symbolsRead,
    );
  }

  /// 读 `LC_SYMTAB` 指向的符号表与字符串表。
  ///
  /// 返回的 `read` 表示**是否真的读了**：表越界时为 `false`，此时
  /// 「没有导入符号」不能读成「没有能力」—— 那是「没查」。
  static ({List<MachOSymbol> symbols, bool read}) _readSymbols(
    Uint8List data, {
    required int base,
    required int available,
    required bool is64,
    required MachOByteOrder byteOrder,
    required MachOSymtab symtab,
    required String label,
    required List<AnalysisDiagnostic> diagnostics,
  }) {
    final entrySize = is64 ? _nlist64Size : _nlist32Size;
    final sliceEnd = base + available;

    // 先验边界：symoff / nsyms / stroff / strsize 都是文件里声明的任意值。
    final symbolsStart = base + symtab.symbolOffset;
    final symbolsEnd = symbolsStart + symtab.symbolCount * entrySize;
    final stringsStart = base + symtab.stringOffset;
    final stringsEnd = stringsStart + symtab.stringSize;

    if (symbolsStart < 0 ||
        symbolsStart > sliceEnd ||
        symbolsEnd > sliceEnd ||
        stringsStart < 0 ||
        stringsStart > sliceEnd ||
        stringsEnd > sliceEnd) {
      diagnostics.add(AnalysisDiagnostic.warning(
        'ios.macho.symtab_out_of_bounds',
        '$label declares a symbol table at ${symtab.symbolOffset} '
            '(${symtab.symbolCount} entries) and strings at '
            '${symtab.stringOffset} (${symtab.stringSize} bytes), '
            'beyond the $available byte slice',
      ));
      return (symbols: const <MachOSymbol>[], read: false);
    }

    final limit = symtab.symbolCount < maxSymbolsPerImage
        ? symtab.symbolCount
        : maxSymbolsPerImage;
    if (limit < symtab.symbolCount) {
      diagnostics.add(AnalysisDiagnostic.warning(
        'ios.macho.symtab_truncated',
        '$label has ${symtab.symbolCount} symbols; only the first $limit '
            'were read',
      ));
    }

    final symbols = <MachOSymbol>[];
    var skipped = 0;
    for (var i = 0; i < limit; i++) {
      final entry = symbolsStart + i * entrySize;
      final nameOffset = _readUint32(data, entry, byteOrder);
      if (nameOffset == null) {
        skipped++;
        continue;
      }
      final type = data[entry + 4];
      final sectionIndex = data[entry + 5];
      final value = is64
          ? _readUint64(data, entry + 8, byteOrder)
          : _readUint32(data, entry + 8, byteOrder);
      if (value == null) {
        skipped++;
        continue;
      }

      final name = _stringAt(data, stringsStart + nameOffset, stringsEnd);
      if (name == null) {
        // 名字越界：不猜，跳过并计数。
        skipped++;
        continue;
      }

      symbols.add(MachOSymbol(
        name: name,
        type: type,
        sectionIndex: sectionIndex,
        value: value,
      ));
    }

    if (skipped > 0) {
      diagnostics.add(AnalysisDiagnostic.warning(
        'ios.macho.symtab_entries_skipped',
        '$label: $skipped of ${symtab.symbolCount} symbol entries could not '
            'be read (name out of range or entry truncated); they are not '
            'covered by the result',
      ));
    }

    return (symbols: symbols, read: true);
  }

  /// 从 `[offset, end)` 里读一个 NUL 结尾的字符串；越界返回 `null`。
  static String? _stringAt(Uint8List data, int offset, int end) {
    if (offset < 0 || offset >= end || end > data.length) return null;
    var cursor = offset;
    while (cursor < end && data[cursor] != 0) {
      cursor++;
    }
    if (cursor >= end) return null;
    return _cString(data.sublist(offset, cursor));
  }

  static MachOSegment? _readSegment(
    Uint8List data,
    int cursor,
    MachOByteOrder order, {
    required bool is64,
    required String label,
    required List<AnalysisDiagnostic> diagnostics,
  }) {
    final needed = is64 ? 72 : 56;
    final cmdsize = _readUint32(data, cursor + 4, order);
    if (cmdsize == null || cmdsize < needed) {
      diagnostics.add(AnalysisDiagnostic.error(
        'ios.macho.segment_truncated',
        '$label has a segment command smaller than $needed bytes',
      ));
      return null;
    }

    final nameBytes = data.sublist(cursor + 8, cursor + 24);
    final name = _cString(nameBytes);

    final int? vmSize;
    final int? fileOffset;
    final int? fileSize;
    final int? sectionCount;
    if (is64) {
      vmSize = _readUint64(data, cursor + 32, order);
      fileOffset = _readUint64(data, cursor + 40, order);
      fileSize = _readUint64(data, cursor + 48, order);
      sectionCount = _readUint32(data, cursor + 64, order);
    } else {
      vmSize = _readUint32(data, cursor + 28, order);
      fileOffset = _readUint32(data, cursor + 32, order);
      fileSize = _readUint32(data, cursor + 36, order);
      sectionCount = _readUint32(data, cursor + 48, order);
    }

    if (vmSize == null || fileOffset == null || fileSize == null) return null;

    return MachOSegment(
      name: name,
      fileOffset: fileOffset,
      fileSize: fileSize,
      vmSize: vmSize,
      sectionCount: sectionCount ?? 0,
      sections: _readSections(
        data,
        cursor: cursor,
        cmdsize: cmdsize,
        is64: is64,
        order: order,
        declared: sectionCount ?? 0,
      ),
    );
  }

  /// 读取段命令后面的节表。
  ///
  /// 布局：`segment_command(_64)` 之后紧跟 `sectionCount` 条节记录。
  /// - 64 位：`section_64` 每条 80 字节，`sectname` 在 +0、`segname` 在 +16、
  ///   `size`（8 字节）在 +40、`offset`（4 字节）在 +48；
  /// - 32 位：`section` 每条 68 字节，`size`（4 字节）在 +36、`offset` 在 +40。
  ///
  /// **逐条按 `cmdsize` 与文件长度双重限界**：`sectionCount` 来自文件，
  /// 可以被写成任意大的数；用它做循环上限而不校验就等于让文件决定内存分配。
  static List<MachOSection> _readSections(
    Uint8List data, {
    required int cursor,
    required int cmdsize,
    required bool is64,
    required MachOByteOrder order,
    required int declared,
  }) {
    if (declared <= 0) return const [];
    final headerSize = is64 ? 72 : 56;
    final entrySize = is64 ? 80 : 68;
    final available = cmdsize - headerSize;
    if (available < entrySize) return const [];
    // 用「命令里真有多少字节」和「声明了多少条」的较小值当上限。
    final maxBySize = available ~/ entrySize;
    final count = declared < maxBySize ? declared : maxBySize;

    final sections = <MachOSection>[];
    for (var i = 0; i < count; i++) {
      final base = cursor + headerSize + i * entrySize;
      if (base + entrySize > data.length) break;
      final name = _cString(data.sublist(base, base + 16));
      final segment = _cString(data.sublist(base + 16, base + 32));
      if (name.isEmpty) continue;
      final size = is64
          ? _readUint64(data, base + 40, order)
          : _readUint32(data, base + 36, order);
      final offset = is64
          ? _readUint32(data, base + 48, order)
          : _readUint32(data, base + 40, order);
      if (size == null || offset == null) continue;
      sections.add(MachOSection(
        name: name,
        segment: segment,
        fileOffset: offset,
        fileSize: size,
      ));
    }
    return sections;
  }

  /// 读取 `dylib` 结构里的名字。名字偏移是**相对命令起始位置**的。
  static String? _readDylibName(
      Uint8List data, int cursor, int cmdsize, MachOByteOrder order) {
    final nameOffset = _readUint32(data, cursor + 8, order);
    if (nameOffset == null || nameOffset < 24 || nameOffset >= cmdsize) {
      return null;
    }
    final start = cursor + nameOffset;
    final end = cursor + cmdsize;
    if (start >= end || end > data.length) return null;
    return _cString(data.sublist(start, end));
  }

  /// 读 NUL 结尾的字符串。
  static String _cString(List<int> bytes) {
    final nul = bytes.indexOf(0);
    final slice = nul >= 0 ? bytes.sublist(0, nul) : bytes;
    return String.fromCharCodes(slice);
  }

  /// UUID 的 16 字节按 `8-4-4-4-12` 分组、大写十六进制。
  static String _formatUuid(List<int> bytes) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  // ---------------------------------------------------------------------------
  // 有边界检查的读取原语
  // ---------------------------------------------------------------------------

  static int? _be32(Uint8List data, int offset) {
    if (offset < 0 || offset + 4 > data.length) return null;
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }

  static int? _readUint32(Uint8List data, int offset, MachOByteOrder order) {
    if (offset < 0 || offset + 4 > data.length) return null;
    return order == MachOByteOrder.little
        ? data[offset] |
            (data[offset + 1] << 8) |
            (data[offset + 2] << 16) |
            (data[offset + 3] << 24)
        : (data[offset] << 24) |
            (data[offset + 1] << 16) |
            (data[offset + 2] << 8) |
            data[offset + 3];
  }

  /// 读 64 位无符号整数。
  ///
  /// 用 Dart 的 64 位 int 承载；超过 `2^63-1` 会变成负数，调用方必须像对待
  /// 任何越界值一样检查（`< 0` 即拒绝）。
  static int? _readUint64(Uint8List data, int offset, MachOByteOrder order) {
    final low = _readUint32(data, offset, order);
    final high = _readUint32(data, offset + 4, order);
    if (low == null || high == null) return null;
    return order == MachOByteOrder.little
        ? (high << 32) | low
        : (low << 32) | high;
  }
}
