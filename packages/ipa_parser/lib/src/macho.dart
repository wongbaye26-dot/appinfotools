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

/// 一个 Mach-O 段（`LC_SEGMENT` / `LC_SEGMENT_64`）。
class MachOSegment {
  final String name;

  /// 段在文件中的偏移与字节数。`__PAGEZERO` 等段 `fileSize` 为 0。
  final int fileOffset;
  final int fileSize;

  /// 段在内存中的大小。
  final int vmSize;

  final int sectionCount;

  const MachOSegment({
    required this.name,
    required this.fileOffset,
    required this.fileSize,
    required this.vmSize,
    required this.sectionCount,
  });

  @override
  String toString() =>
      'MachOSegment($name, file: $fileOffset+$fileSize, vm: $vmSize, '
      '$sectionCount sections)';
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
  });

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
    );
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
    );
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
