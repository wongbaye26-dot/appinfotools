import 'dart:typed_data';

import '../macho.dart';

/// 一个选择子在代码里的**调用点**归属。
class IosSelectorCallSite {
  /// 选择子名（`__objc_methname` 里的字符串），例如 `viewDidLoad`。
  final String selector;

  /// 命中的指令条数。
  final int callSites;

  /// 归属到的函数起始地址（去重、升序）。空集表示「有引用但没归属上」。
  final Set<int> functions;

  /// 证据样例，形如 `0x100004a10 +0x1c`（函数起点 + 指令相对偏移）。
  final List<String> samples;

  const IosSelectorCallSite({
    required this.selector,
    required this.callSites,
    required this.functions,
    required this.samples,
  });

  int get functionCount => functions.length;
}

/// 一次调用点扫描的结果。
///
/// ## 这份数据能回答什么、不能回答什么
///
/// **能**：某个选择子在代码里被 `ADRP+ADD/LDR` 引用了几次，这些指令分别落在
/// 哪个函数里。这是 iOS 侧最接近「调用点」的静态证据 —— 比「字符串出现在
/// 二进制里」强一档。
///
/// **不能**：
/// - 「真的被调用」：`ADRP+ADD` 只是**取地址**（准备一个 `SEL`），
///   取到之后传给谁、会不会走到，静态分析看不到；
/// - 跨多条指令的引用：只认**相邻两条**（`ADRP` 紧跟 `ADD`/`LDR`），
///   中间夹了别的指令就漏 —— 编译器偶尔会这样排，但很少；
/// - `objc_msgSend` 的**接收者**与参数：那要数据流分析。
class IosCallSiteReport {
  /// `__objc_selrefs` 的槽位总数（分母）。
  final int selectorSlots;

  /// 至少被一条指令引用过的槽位数。
  final int referencedSlots;

  /// 命中了已知选择子、但**未必**归属到函数的指令总数。
  ///
  /// 它是覆盖率的分母：`attributedCallSites / totalReferences` 回答
  /// 「扫到的引用里有多少能说清在哪个函数」。
  final int totalReferences;

  /// 成功归属到函数的指令总数。
  final int attributedCallSites;

  /// 扫描了多少字节的 `__text`。
  final int scannedBytes;

  /// `__text` 是否因为体积上限被截断。
  final bool truncated;

  /// 选择子 → 调用点。只含**至少被引用一次**的选择子。
  final Map<String, IosSelectorCallSite> bySelector;

  /// 读不出时的原因；`null` 表示扫描跑通了。
  final String? failure;

  const IosCallSiteReport({
    this.selectorSlots = 0,
    this.referencedSlots = 0,
    this.totalReferences = 0,
    this.attributedCallSites = 0,
    this.scannedBytes = 0,
    this.truncated = false,
    this.bySelector = const {},
    this.failure,
  });

  bool get ok => failure == null;

  /// 有没有任何一条指令被归属到函数。
  bool get hasAttribution => attributedCallSites > 0;
}

/// iOS 侧的**调用点级**证据：把 `__objc_selrefs` 里的选择子归属到函数。
///
/// ## 为什么需要它
///
/// Android 侧能回答「`NetProbe.open` 的调用指令在 `Lcom/foo/Bar;.baz()V` 的
/// `+0x10` 处」—— 因为 DEX 有 `code_item`，指令是结构化的。iOS 侧此前只到
/// 「这个选择子被引用了」，拿不到位置，于是同样标 `suspected` 的规则，iOS
/// 那侧的底牌比 Android 软一档。
///
/// ## 做法（三步，都不需要完整反汇编）
///
/// 1. **解析 `__objc_selrefs`**：它是一张 8 字节指针表，每项指向
///    `__objc_methname` 里的选择子字符串。指针在文件里是「重定位前」的形态，
///    因此要按几种可能的编码各试一次，**以「落进 `__objc_methname` 范围」为判据**
///    挑出正确的那个 —— 这个范围本身就是校验和，比猜版本可靠。
/// 2. **扫 `__text` 找 `ADRP` + `ADD`/`LDR` 指令对**：ARM64 访问数据段只有
///    这一种形态。算出目标地址，落在 `__objc_selrefs` 范围内就记一笔。
/// 3. **用 `LC_FUNCTION_STARTS` 把指令地址映射到函数**（二分查找）。
///
/// ## 已知边界
///
/// - **只扫 `__text`，不扫 `__objc_stubs`。** 现代二进制里很多选择子是通过
///   stub 访问的（`__objc_stubs` 里每个选择子一个桩，`ADRP+LDR+BR`），那些
///   引用不在 `__text` 里。实测 2,815 个槽位只有约 1/3 在 `__text` 里被直接
///   引用 —— 这是当前召回率的主要上限；
/// - `ADRP` 只回溯 [_maxAdrpDistance]（64 字节），更远的模式会漏；
/// - `ADRP` 只对 4 KB 页对齐，超出 ±4 GB 的寻址不适用（iOS 上不会）；
/// - `__objc_selrefs` 缺失（strip 过、或纯 Swift 二进制）时直接返回 `failure`；
/// - **不判断「会不会执行」**：取地址 ≠ 调用。
class IosCallSiteScanner {
  IosCallSiteScanner._();

  /// `__text` 的扫描上限（64 MiB）。
  ///
  /// 真实 App 的 `__text` 通常 10–60 MB。超过这个量级说明是超大二进制，
  /// 截断并如实标记 —— 「只扫了一半」必须能看见。
  static const int maxTextBytes = 64 * 1024 * 1024;

  /// 每个选择子最多保留几条证据样例。
  static const int maxSamplesPerSelector = 3;

  /// 扫描一个 Mach-O 镜像。
  ///
  /// [file] 是整个文件字节，[image] 是其中的一个切片。
  /// 两张表：`__objc_selrefs` → `__objc_methname`（选择子），
  /// `__objc_classrefs` → `__objc_classname`（类名，要多解两层 `class_t`）。
  ///
  /// **两张都要扫**：安全规则里的线索大多是**类名**（`AVCaptureDevice`、
  /// `CNContactStore`），只扫选择子的话，算出来的调用点没有消费者。
  static const String selectorRefsSection = '__objc_selrefs';
  static const String selectorNamesSection = '__objc_methname';
  static const String classRefsSection = '__objc_classrefs';
  static const String classNamesSection = '__objc_classname';

  static IosCallSiteReport scan(
    Uint8List file,
    MachOImage image, {
    String refsSection = selectorRefsSection,
    String namesSection = selectorNamesSection,
  }) {
    final selrefs = _section(image, refsSection);
    final methname = _section(image, namesSection);
    final text = _section(image, '__text');

    if (selrefs == null) {
      return IosCallSiteReport(
        failure: 'no $refsSection section (stripped or Swift-only binary)',
      );
    }
    if (methname == null) {
      return IosCallSiteReport(failure: 'no $namesSection section');
    }
    if (text == null) {
      return const IosCallSiteReport(failure: 'no __text section');
    }

    final selrefsBytes = _bytes(file, image, selrefs);
    final methnameBytes = _bytes(file, image, methname);
    final textBytes = _bytes(file, image, text);
    if (selrefsBytes == null || methnameBytes == null || textBytes == null) {
      return const IosCallSiteReport(
        failure: 'a required section lies outside the file slice',
      );
    }

    // ---- 1. 槽位 → 选择子 ----
    final slotCount = selrefsBytes.length ~/ 8;
    final selectorOfSlot = <int, String>{};
    final isClassTable = refsSection == classRefsSection;
    for (var i = 0; i < slotCount; i++) {
      final selector = isClassTable
          ? _resolveClassName(
              file,
              selrefsBytes,
              i,
              methnameBytes,
              methname.address,
              image,
            )
          : _resolveSelector(
              selrefsBytes,
              i,
              methnameBytes,
              methname.address,
              image,
            );
      if (selector != null) selectorOfSlot[i] = selector;
    }

    // ---- 2. 扫 __text ----
    final scanLength =
        textBytes.length > maxTextBytes ? maxTextBytes : textBytes.length;
    final truncated = textBytes.length > scanLength;
    final base = selrefs.address;
    final end = base + selrefsBytes.length;

    // 槽位 → 命中的指令地址
    //
    // **按寄存器记住最近一次 `ADRP`，而不是要求它紧跟 `ADD`/`LDR`。**
    // 优化过的代码经常把两个 `ADRP` 排在一起再分别使用：
    //
    //     ADRP x8, page1
    //     ADRP x9, page2
    //     LDR  x0, [x8, #off1]     <- 距 ADRP 两条指令
    //     LDR  x1, [x9, #off2]
    //
    // 只认相邻两条时，实测只有 **29%** 的 selrefs 槽位能被引用到；改成
    // 「按寄存器回溯」后覆盖率显著上升，而且仍然是线性扫描、不需要反汇编。
    // 按**名字**聚合（不是按槽位）：同一张表里槽位唯一，但 stub 那条路
    // 拿到的也是名字，两边要合并。
    final hits = <String, List<int>>{};
    final adrpOffset = List<int>.filled(32, -1);
    for (var offset = 0; offset + 4 <= scanLength; offset += 4) {
      final insn = _u32(textBytes, offset);
      if (insn == null) break;

      // ADRP：记下该寄存器的页基址（用指令偏移当「时间戳」）。
      if ((insn & 0x9F000000) == 0x90000000) {
        final rd = insn & 0x1F;
        adrpOffset[rd] = offset;
        continue;
      }

      final rn = (insn >> 5) & 0x1F;
      final baseOffset = adrpOffset[rn];
      if (baseOffset < 0) continue;
      // 只回溯有限距离：太远的 `ADRP` 早就被别处覆盖，用它算出来的是错地址。
      if (offset - baseOffset > _maxAdrpDistance) continue;

      final page = _adrpPage(textBytes, baseOffset, text.address + baseOffset);
      if (page == null) continue;
      final target = _addOrLoadTarget(insn, page, rn);
      if (target == null) continue;
      if (target < base || target >= end) continue;
      final slot = (target - base) ~/ 8;
      final name = selectorOfSlot[slot];
      if (name == null) continue;
      (hits[name] ??= <int>[]).add(text.address + offset);
    }

    // ---- 2b. `__objc_stubs`：试过，不划算 ----
    //
    // 理论很顺：桩内 `ADRP+LDR` 取选择子、`BR x16` 跳 `objc_msgSend`，
    // 扫 `__text` 的 `BL <stub>` 就能归属到调用者。**实测不成立**：
    // 在 33-v8.5.5 上只多出 1 条引用（8795 → 8796），却因为要再扫一遍
    // `__text` 找 `BL`，把整个审计从 25 ms 拖到 392 ms（15 倍）。
    //
    // 说明这个二进制的框架类调用不是走 `__objc_stubs` 的（更可能是
    // `objc_msgSend` 直接调用 + `NSClassFromString`），所以不保留这条路径。
    // 真要提召回率，得先确认目标二进制确实用了 stubs，再考虑把 `BL` 检查
    // 融进主循环（避免二次扫描）。

    // ---- 3. 归属到函数 ----
    var totalReferences = 0;
    for (final list in hits.values) {
      totalReferences += list.length;
    }
    final starts = image.functionStarts;
    final bySelector = <String, IosSelectorCallSite>{};
    var attributed = 0;
    final perSelector = <String, List<int>>{};
    for (final entry in hits.entries) {
      for (final address in entry.value) {
        final function = _functionOf(starts, address);
        if (function == null) continue;
        attributed++;
        (perSelector[entry.key] ??= <int>[]).add(address);
      }
    }

    for (final entry in perSelector.entries) {
      final addresses = entry.value..sort();
      final functions = <int>{};
      final samples = <String>[];
      for (final address in addresses) {
        final function = _functionOf(starts, address);
        if (function == null) continue;
        functions.add(function);
        if (samples.length < maxSamplesPerSelector) {
          samples.add(
            '0x${function.toRadixString(16)} '
            '+0x${(address - function).toRadixString(16)}',
          );
        }
      }
      bySelector[entry.key] = IosSelectorCallSite(
        selector: entry.key,
        callSites: addresses.length,
        functions: functions,
        samples: samples,
      );
    }

    // **不截断。** 早先按命中次数截到 200 条，结果把 `requestAccessForMediaType:`
    // 这类只有一两个调用点的选择子全裁掉了 —— 而它们正是安全规则要用的那批
    // （高频的都是 `init`、`isKindOfClass:` 这种）。几千个条目占不了多少内存，
    // 需要「前 N 个」的展示层自己排。
    return IosCallSiteReport(
      selectorSlots: slotCount,
      referencedSlots: hits.length,
      totalReferences: totalReferences,
      attributedCallSites: attributed,
      scannedBytes: scanLength,
      truncated: truncated,
      bySelector: bySelector,
    );
  }

  static MachOSection? _section(MachOImage image, String name) {
    for (final segment in image.segments) {
      for (final section in segment.sections) {
        if (section.name == name) return section;
      }
    }
    return null;
  }

  static Uint8List? _bytes(
    Uint8List file,
    MachOImage image,
    MachOSection section,
  ) {
    if (section.fileSize <= 0) return null;
    final start = image.offset + section.fileOffset;
    final end = start + section.fileSize;
    if (start < 0 || end > file.length || end <= start) return null;
    return Uint8List.sublistView(file, start, end);
  }

  /// 把第 [index] 个槽位解析成选择子名。
  ///
  /// 指针在文件里是**重定位前**的形态，编码随链接器版本与指针格式而变。
  /// 这里不去解析 `LC_DYLD_CHAINED_FIXUPS` 的头部（那要额外几百行，且格式
  /// 有好几种），而是**把几种可能的解读都试一遍，以「落进 `__objc_methname`
  /// 范围」为判据** —— 那个范围本身就是一道很强的校验：错误的解读几乎不可能
  /// 恰好落在一个几十 KB 的区间里。
  static String? _resolveSelector(
    Uint8List selrefs,
    int index,
    Uint8List methname,
    int methnameAddress,
    MachOImage image,
  ) {
    final offset = index * 8;
    if (offset + 8 > selrefs.length) return null;
    final raw = ByteData.sublistView(selrefs, offset, offset + 8)
        .getUint64(0, Endian.little);

    for (final address in _pointerCandidates(raw, image)) {
      if (address < methnameAddress) continue;
      final delta = address - methnameAddress;
      if (delta >= methname.length) continue;
      final selector = _cString(methname, delta);
      if (selector == null) continue;
      // 选择子必须是可打印 ASCII 且长度合理 —— 排除「恰好落进范围但内容是
      // 垃圾」的情况。
      if (selector.length > 200) continue;
      if (!selector.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) continue;
      return selector;
    }
    return null;
  }

  /// 一个 8 字节槽位的**候选解读**。
  ///
  /// 文件里的指针是「重定位前」的形态，编码随链接器版本与指针格式而变。
  /// 与其解析 `LC_DYLD_CHAINED_FIXUPS` 头部（格式有好几种，几百行），不如把
  /// 四种可能的解读都列出来，**由调用方用「目标落进已知区间」筛掉错的** ——
  /// 一个几十 KB 的节范围本身就是很强的校验。
  static List<int> _pointerCandidates(int raw, MachOImage image) {
    return <int>[
      // 1. 经典（无 chained fixups）：文件里直接是绝对 vmaddr。
      raw,
      // 2. `DYLD_CHAINED_PTR_64_OFFSET`：target 是相对 image base 的偏移。
      (raw & 0xFFFFFFFFF) + _imageBase(image),
      // 3. `DYLD_CHAINED_PTR_64`：target 是绝对 vmaddr（36 位）。
      raw & 0xFFFFFFFFF,
      // 4. arm64e 变体：高位 8 位参与地址。
      ((raw >> 36) & 0xFF) << 56 | (raw & 0xFFFFFFFFF),
    ];
  }

  /// 虚拟地址 → 文件偏移（跨段映射）。落不进任何有文件内容的段时返回 `null`。
  static int? _fileOffsetOf(MachOImage image, int vmaddr) {
    if (vmaddr <= 0) return null;
    for (final segment in image.segments) {
      if (segment.vmSize <= 0) continue;
      if (vmaddr < segment.vmAddress) continue;
      final delta = vmaddr - segment.vmAddress;
      if (delta >= segment.vmSize) continue;
      // 零填充部分（`__bss`）没有文件内容。
      if (delta >= segment.fileSize) return null;
      return image.offset + segment.fileOffset + delta;
    }
    return null;
  }

  /// 从文件 [offset] 处读一个 8 字节指针。
  static int? _readPointer(Uint8List file, int offset) {
    if (offset < 0 || offset + 8 > file.length) return null;
    return ByteData.sublistView(file, offset, offset + 8)
        .getUint64(0, Endian.little);
  }

  /// 把第 [index] 个 `__objc_classrefs` 槽位解析成**类名**。
  ///
  /// 与选择子表不同：`__objc_classrefs` 的槽位指向 **class 对象**
  /// （`__objc_data` 里的 `class_t`），不是名字字符串。要拿到名字得走三层：
  ///
  /// ```c
  /// struct objc_class {          // 64 位，40 字节
  ///   isa, superclass;           // +0, +8
  ///   cache_t cache;             // +16（16 字节）
  ///   uintptr_t data;            // +32 -> class_ro_t*（低 3 位是标志）
  /// };
  /// struct class_ro_t {
  ///   uint32_t flags, instanceStart, instanceSize, reserved;  // +0..+12
  ///   const uint8_t *ivarLayout;                              // +16
  ///   const char *name;                                       // +24
  /// };
  /// ```
  ///
  /// 每一层的指针都要按 [_pointerCandidates] 试解读，并用「下一跳能落进
  /// 有文件内容的段」筛掉错的 —— 三层串起来，误判几乎不可能。
  static String? _resolveClassName(
    Uint8List file,
    Uint8List classrefs,
    int index,
    Uint8List classname,
    int classnameAddress,
    MachOImage image,
  ) {
    final raw = _readPointer(classrefs, index * 8);
    if (raw == null) return null;

    for (final classAddr in _pointerCandidates(raw, image)) {
      final classOffset = _fileOffsetOf(image, classAddr);
      if (classOffset == null) continue;

      final dataRaw = _readPointer(file, classOffset + 32);
      if (dataRaw == null) continue;

      for (final roRaw in _pointerCandidates(dataRaw, image)) {
        // `class_data_bits_t` 的低 3 位是标志（FAST_IS_SWIFT 等）。
        final roOffset = _fileOffsetOf(image, roRaw & ~7);
        if (roOffset == null) continue;

        final nameRaw = _readPointer(file, roOffset + 24);
        if (nameRaw == null) continue;

        for (final nameAddr in _pointerCandidates(nameRaw, image)) {
          if (nameAddr < classnameAddress) continue;
          final delta = nameAddr - classnameAddress;
          if (delta >= classname.length) continue;
          final name = _cString(classname, delta);
          if (name == null || name.length > 200) continue;
          if (!name.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) continue;
          return name;
        }
      }
    }
    return null;
  }

  /// 镜像的基址（最低的段 vmaddr，通常是 `__TEXT` 的）。
  static int _imageBase(MachOImage image) {
    var base = -1;
    for (final segment in image.segments) {
      if (segment.vmAddress <= 0) continue;
      if (base < 0 || segment.vmAddress < base) base = segment.vmAddress;
    }
    return base < 0 ? 0 : base;
  }

  /// `ADRP` 之后最多回溯多少字节（16 条指令）。
  ///
  /// 编译器把多个 `ADRP` 排在一起时，最远的那个到使用点大约隔几条指令；
  /// 再远就说明该寄存器早被别的 `ADRP` 覆盖了。
  static const int _maxAdrpDistance = 64;

  /// 算出 [offset] 处 `ADRP` 的页基址。
  static int? _adrpPage(Uint8List text, int offset, int pc) {
    final adrp = _u32(text, offset);
    if (adrp == null) return null;
    if ((adrp & 0x9F000000) != 0x90000000) return null;
    final immlo = (adrp >> 29) & 0x3;
    final immhi = (adrp >> 5) & 0x7FFFF;
    var imm = (immhi << 2) | immlo;
    // 21 位符号扩展。
    if ((imm & 0x100000) != 0) imm -= 0x200000;
    return (pc & ~0xFFF) + (imm << 12);
  }

  /// 若 [insn] 是「以 [rn] 为基址」的 `ADD`/`LDR`，返回它的目标地址。
  static int? _addOrLoadTarget(int insn, int page, int rn) {
    // ADD (immediate)：sf 0 0 100010 sh imm12 Rn Rd
    //   64 位 0x91…、32 位 0x11…，掩码 0xFFC00000。
    if ((insn & 0xFFC00000) == 0x91000000 ||
        (insn & 0xFFC00000) == 0x11000000) {
      // 只认 `ADD Rd, Rn, #imm` 且 Rd == Rn（就地加偏移）。
      if ((insn & 0x1F) != rn) return null;
      var imm12 = (insn >> 10) & 0xFFF;
      if (((insn >> 22) & 1) == 1) imm12 <<= 12;
      return page + imm12;
    }

    // LDR (immediate, unsigned offset)：64 位 0xF94…、32 位 0xB94…。
    // imm12 以访问宽度为单位。
    if ((insn & 0xFFC00000) == 0xF9400000 ||
        (insn & 0xFFC00000) == 0xB9400000) {
      final imm12 = (insn >> 10) & 0xFFF;
      final scale = (insn & 0xFFC00000) == 0xF9400000 ? 8 : 4;
      return page + imm12 * scale;
    }

    return null;
  }

  /// 二分查找：地址 [address] 落在哪个函数里（返回函数起始地址）。
  ///
  /// [starts] 必须升序（`LC_FUNCTION_STARTS` 天然如此）。找不到返回 `null`。
  static int? _functionOf(List<int> starts, int address) {
    if (starts.isEmpty) return null;
    var low = 0;
    var high = starts.length - 1;
    if (address < starts[0]) return null;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (starts[mid] <= address) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return starts[low];
  }

  static int? _u32(Uint8List data, int offset) {
    if (offset < 0 || offset + 4 > data.length) return null;
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  /// 读 NUL 结尾的 C 字符串；越界或空串返回 `null`。
  static String? _cString(Uint8List data, int offset) {
    if (offset < 0 || offset >= data.length) return null;
    final limit = offset + 512 > data.length ? data.length : offset + 512;
    final bytes = <int>[];
    for (var i = offset; i < limit; i++) {
      final byte = data[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    if (bytes.isEmpty) return null;
    return String.fromCharCodes(bytes);
  }
}
