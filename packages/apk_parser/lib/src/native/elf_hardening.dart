// 原生库（`lib/**.so`）的**二进制加固属性**。
//
// ## 读什么，为什么
//
// | 属性 | 判据 | 缺了会怎样 |
// |---|---|---|
// | NX 栈 | 有 `PT_GNU_STACK` 且 `p_flags` 不含 `PF_X` | 栈可执行 —— 栈上数据能当代码跑 |
// | RELRO | 有 `PT_GNU_RELRO` | `.got` 可写 —— GOT 覆写是经典的绕过手法 |
// | BIND_NOW | `DT_FLAGS & DF_BIND_NOW` 或 `DT_FLAGS_1 & DF_1_NOW` | 与 RELRO 合起来才是 Full RELRO |
// | 栈保护 | `.dynsym` 里导入 `__stack_chk_fail` | 有溢出检测（**只能证明「用了」，不能证明「没用」**）|
// | 已 strip | 没有 `.symtab` | 留符号对分析者友好，不是缺陷 |
//
// ## 一个必须先讲清楚的事实
//
// **在真实 APK 上这一维几乎全绿。** 实测 4 个真实包的 121 个 arm64 `.so`：
//
// | 属性 | 不满足的库数 |
// |---|---|
// | 可执行栈 | **0** |
// | 缺 RELRO | **1**（Flutter 的 `libapp.so`，Dart AOT 快照，合法选择） |
// | 缺 BIND_NOW | **1**（同一个） |
// | 未 strip | **0** |
//
// 原因是 NDK 默认就带 `-z relro -z now` 与 NX 栈。所以：
//
// - **逐库报「缺 RELRO」是纯噪声** —— 它会稳定命中所有 Flutter 应用；
// - 只有「可执行栈」是**没有正当理由**的缺陷，值得单独一条；
// - 其余属性作为**聚合数字**呈现，让人看到「121 个库里 120 个是 Full RELRO」，
//   而不是刷出 120 条「已加固」。
//
// 这条约束写在这里，是因为下一个维护者看到「这一维几乎不报东西」时，
// 第一反应会是「是不是解析坏了」。先读上面那张表。

import 'dart:typed_data';

/// `p_type` 常量。
class ElfProgramType {
  ElfProgramType._();

  static const int load = 1;
  static const int dynamic = 2;
  static const int interp = 3;
  static const int gnuStack = 0x6474e551;
  static const int gnuRelro = 0x6474e552;
}

/// `p_flags` 常量。
class ElfProgramFlag {
  ElfProgramFlag._();

  static const int execute = 0x1;
  static const int write = 0x2;
  static const int read = 0x4;
}

/// 一个原生库的加固属性。
///
/// 每个字段都可为 `null`：**`null` 一律表示「读不出来」**，不是「不满足」。
/// 把「读不出」折成「不满足」会让损坏的库被当成加固缺失，那是误报。
class ElfHardening {
  /// 归档内名，例如 `lib/arm64-v8a/libnative.so`。
  final String name;

  /// 栈是否可执行。
  ///
  /// - `false`：有 `PT_GNU_STACK` 且不含 `PF_X` —— NX 生效；
  /// - `true`：有 `PT_GNU_STACK` 且含 `PF_X` —— **栈可执行**；
  /// - `null`：没有 `PT_GNU_STACK`。旧工具链的产物，内核在部分架构上会
  ///   按「可执行」处理，属于**未知**而非「安全」。
  final bool? stackExecutable;

  /// 是否有 `PT_GNU_RELRO`。
  final bool? relro;

  /// 是否启用了立即绑定（`DF_BIND_NOW` / `DF_1_NOW`）。
  final bool? bindNow;

  /// 是否导入了 `__stack_chk_fail`（栈保护的证据）。
  ///
  /// **只能证明「用了」**：没有函数触发 canary 时这个符号不会出现在
  /// `.dynsym` 里，所以 `false` 不等于「没开栈保护」。
  final bool? stackCanary;

  /// 是否已 strip（没有 `.symtab`）。
  final bool? stripped;

  /// 解析失败的原因；`null` 表示读成功。
  final String? failure;

  const ElfHardening({
    required this.name,
    this.stackExecutable,
    this.relro,
    this.bindNow,
    this.stackCanary,
    this.stripped,
    this.failure,
  });

  ElfHardening.unreadable(this.name, String this.failure)
      : stackExecutable = null,
        relro = null,
        bindNow = null,
        stackCanary = null,
        stripped = null;

  bool get parsed => failure == null;

  /// 是否 Full RELRO（RELRO + 立即绑定）。缺一不可。
  bool get fullRelro => relro == true && bindNow == true;

  @override
  String toString() => 'ElfHardening($name, execStack: $stackExecutable, '
      'relro: $relro, bindNow: $bindNow, canary: $stackCanary, '
      'stripped: $stripped, failure: $failure)';
}

/// 解析一个 `.so` 的加固属性。
///
/// [bytes] 是该条目的**解压后**字节。读不出来时返回 `failure` 非空的对象。
ElfHardening readElfHardening(String name, Uint8List bytes) {
  if (bytes.length < 16) {
    return ElfHardening.unreadable(name, 'file is only ${bytes.length} bytes');
  }
  if (!(bytes[0] == 0x7F &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4C &&
      bytes[3] == 0x46)) {
    return ElfHardening.unreadable(name, 'not an ELF file');
  }
  final elfClass = bytes[4]; // 1 = 32 位，2 = 64 位
  final endianFlag = bytes[5]; // 1 = 小端，2 = 大端
  if (elfClass != 1 && elfClass != 2) {
    return ElfHardening.unreadable(name, 'EI_CLASS=${bytes[4]} is invalid');
  }
  if (endianFlag != 1 && endianFlag != 2) {
    return ElfHardening.unreadable(name, 'EI_DATA=${bytes[5]} is invalid');
  }
  final is64 = elfClass == 2;
  final endian = endianFlag == 2 ? Endian.big : Endian.little;

  // 头部最小长度：64 位 64 字节、32 位 52 字节。
  if (bytes.length < (is64 ? 64 : 52)) {
    return ElfHardening.unreadable(name, 'ELF header is truncated');
  }
  final data = ByteData.sublistView(bytes);

  // e_phoff / e_phentsize / e_phnum 在 32/64 位下的偏移不同。
  final phoff =
      is64 ? data.getUint64(0x20, endian) : data.getUint32(0x1C, endian);
  final phentsize = data.getUint16(is64 ? 0x36 : 0x2A, endian);
  final phnum = data.getUint16(is64 ? 0x38 : 0x2C, endian);
  // 标准程序头长度：64 位 56、32 位 32。
  final minimumPhentsize = is64 ? 56 : 32;
  if (phnum == 0) {
    return ElfHardening.unreadable(
        name, 'no program headers (e_phnum=0) — nothing to judge');
  }
  if (phentsize < minimumPhentsize) {
    return ElfHardening.unreadable(
        name, 'e_phentsize=$phentsize is below $minimumPhentsize');
  }
  // **先验边界**：e_phoff / e_phnum 都是文件里声明的任意值。
  final tableEnd = phoff + phentsize * phnum;
  if (phoff < 0 || tableEnd > bytes.length) {
    return ElfHardening.unreadable(
        name,
        'program header table is out of range '
        '(offset $phoff, $phnum × $phentsize = end $tableEnd, '
        'file ${bytes.length})');
  }

  bool? stackExecutable;
  bool? relro;
  int? dynamicOffset;
  int? dynamicSize;

  for (var i = 0; i < phnum; i++) {
    final base = phoff + i * phentsize;
    final type = data.getUint32(base, endian);
    // **`p_flags` 的位置在 32/64 位下不同**：64 位在偏移 4（紧跟 p_type），
    // 32 位在偏移 24（排在 p_offset/p_vaddr/p_paddr/p_filesz/p_memsz 之后）。
    // 用错位置读出来的是一个「看起来合理」的地址值 —— 不报错，只是错。
    final flags = is64
        ? data.getUint32(base + 4, endian)
        : data.getUint32(base + 24, endian);
    switch (type) {
      case ElfProgramType.gnuStack:
        stackExecutable = (flags & ElfProgramFlag.execute) != 0;
      case ElfProgramType.gnuRelro:
        relro = true;
      case ElfProgramType.dynamic:
        final offset = is64
            ? data.getUint64(base + 8, endian)
            : data.getUint32(base + 4, endian);
        final fileSize = is64
            ? data.getUint64(base + 32, endian)
            : data.getUint32(base + 16, endian);
        if (offset >= 0 && fileSize > 0 && offset + fileSize <= bytes.length) {
          dynamicOffset = offset;
          dynamicSize = fileSize;
        }
      default:
        break;
    }
  }
  relro ??= false;

  final bindNow = _readBindNow(data, endian, is64, dynamicOffset, dynamicSize);
  final stripped = _isStripped(data, bytes, endian, is64);
  final canary = _importsStackChkFail(data, bytes, endian, is64);

  return ElfHardening(
    name: name,
    stackExecutable: stackExecutable,
    relro: relro,
    bindNow: bindNow,
    stackCanary: canary,
    stripped: stripped,
  );
}

/// `DT_FLAGS` / `DT_FLAGS_1` 里的立即绑定标志。
///
/// 两个 tag 都要看：链接器按版本写其中一个，只查一个会漏。
bool? _readBindNow(
  ByteData data,
  Endian endian,
  bool is64,
  int? offset,
  int? size,
) {
  if (offset == null || size == null) return null;
  const dtFlags = 30;
  const dtFlags1 = 0x6ffffffb;
  const dfBindNow = 0x8;
  const df1Now = 0x1;
  final entrySize = is64 ? 16 : 8;
  var found = false;
  var now = false;
  for (var pos = offset; pos + entrySize <= offset + size; pos += entrySize) {
    final tag = is64 ? data.getInt64(pos, endian) : data.getInt32(pos, endian);
    if (tag == 0) break; // DT_NULL 结束
    final value = is64
        ? data.getUint64(pos + 8, endian)
        : data.getUint32(pos + 4, endian);
    if (tag == dtFlags) {
      found = true;
      if ((value & dfBindNow) != 0) now = true;
    } else if (tag == dtFlags1) {
      found = true;
      if ((value & df1Now) != 0) now = true;
    }
  }
  return found ? now : false;
}

/// 有没有 `.symtab`（未 strip 才有）。
///
/// 直接扫节表：`SHT_SYMTAB` = 2。走节名匹配会被混淆/异常的节名表影响，
/// 而节类型是结构事实。
bool? _isStripped(ByteData data, Uint8List bytes, Endian endian, bool is64) {
  final shoff =
      is64 ? data.getUint64(0x28, endian) : data.getUint32(0x20, endian);
  final shentsize = data.getUint16(is64 ? 0x3A : 0x2E, endian);
  final shnum = data.getUint16(is64 ? 0x3C : 0x30, endian);
  final minimumShentsize = is64 ? 64 : 40;
  if (shnum == 0) return true; // 节表被剥离 → 必然没有 .symtab
  if (shentsize < minimumShentsize) return null;
  final tableEnd = shoff + shentsize * shnum;
  if (shoff < 0 || tableEnd > bytes.length) return null;
  for (var i = 0; i < shnum; i++) {
    final base = shoff + i * shentsize;
    if (data.getUint32(base + 4, endian) == 2) return false; // SHT_SYMTAB
  }
  return true;
}

/// `.dynsym` 里是否导入 `__stack_chk_fail`。
///
/// 只查 `.dynsym`（`SHT_DYNSYM` = 11）：`.symtab` 会被 strip 掉，
/// 而动态符号表在运行库上一定存在。
bool? _importsStackChkFail(
  ByteData data,
  Uint8List bytes,
  Endian endian,
  bool is64,
) {
  final shoff =
      is64 ? data.getUint64(0x28, endian) : data.getUint32(0x20, endian);
  final shentsize = data.getUint16(is64 ? 0x3A : 0x2E, endian);
  final shnum = data.getUint16(is64 ? 0x3C : 0x30, endian);
  final minimumShentsize = is64 ? 64 : 40;
  if (shnum == 0 || shentsize < minimumShentsize) return null;
  if (shoff < 0 || shoff + shentsize * shnum > bytes.length) return null;

  for (var i = 0; i < shnum; i++) {
    final base = shoff + i * shentsize;
    if (data.getUint32(base + 4, endian) != 11) continue; // SHT_DYNSYM
    final offset = is64
        ? data.getUint64(base + 24, endian)
        : data.getUint32(base + 16, endian);
    final size = is64
        ? data.getUint64(base + 32, endian)
        : data.getUint32(base + 20, endian);
    final entrySize = is64 ? 24 : 16;
    final strtabIndex = data.getUint32(base + (is64 ? 40 : 24), endian);
    if (strtabIndex >= shnum) return null;
    final strBase = shoff + strtabIndex * shentsize;
    final strOffset = is64
        ? data.getUint64(strBase + 24, endian)
        : data.getUint32(strBase + 16, endian);
    final strSize = is64
        ? data.getUint64(strBase + 32, endian)
        : data.getUint32(strBase + 20, endian);
    if (offset < 0 || size <= 0 || offset + size > bytes.length) return null;
    if (strOffset < 0 || strSize <= 0 || strOffset + strSize > bytes.length) {
      return null;
    }
    for (var pos = offset; pos + entrySize <= offset + size; pos += entrySize) {
      // Elf{32,64}_Sym 的第一个字段 st_name 都是 4 字节。
      final nameOffset = data.getUint32(pos, endian);
      if (nameOffset == 0) continue;
      final absolute = strOffset + nameOffset;
      if (absolute >= strOffset + strSize || absolute >= bytes.length) continue;
      if (_startsWith(
          bytes, absolute, strOffset + strSize, '__stack_chk_fail')) {
        return true;
      }
    }
    return false;
  }
  return null;
}

/// [bytes] 从 [start] 起是否以 [prefix] 开头，且不越过 [limit]。
bool _startsWith(Uint8List bytes, int start, int limit, String prefix) {
  if (start + prefix.length > limit) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[start + i] != prefix.codeUnitAt(i)) return false;
  }
  // 必须以 NUL 结尾，否则 `__stack_chk_fail_local` 之类也会命中。
  if (start + prefix.length < limit &&
      bytes[start + prefix.length] != 0 &&
      bytes[start + prefix.length] != 0x40) {
    return false;
  }
  return true;
}
