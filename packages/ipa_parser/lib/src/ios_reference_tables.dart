// iOS 的「结构化引用表」：`__objc_selrefs` 与 `__objc_classrefs`。
//
// ## 为什么需要它
//
// 此前 iOS 侧只有**裸字符串扫描**：`PHPhotoLibrary` 出现在任何字符串里都算命中
// （注释、日志、资源名都可能）。Android 侧早就有三级证据（字符串 → method_ids
// → 调用点），iOS 一直缺中间那一级。
//
// `__objc_selrefs` / `__objc_classrefs` 是**引用表**：每个 8 字节槽位是一个
// 指针，指向 `__objc_methname` / `__objc_classname` 里的字符串。这些槽位存在
// 就说明代码里有 `objc_msgSend` 真的用了那个选择子 / 类 —— 这比「字符串里
// 出现过」强一档，而且不需要反汇编。
//
// ## 指针怎么解
//
// 现代 Mach-O（iOS 13+）用 **chained fixups**：指针里编码的不是地址，而是
// `rebase.target`（36 位）。格式由 `dyld_chained_starts_in_segment.pointer_format`
// 决定：
// - `PTR_64`（2）：`target` 就是 vmaddr；
// - `PTR_64_OFFSET`（6）：`target` 是相对**镜像基址**的偏移。
//
// 其余格式（ARM64E 带 PAC 的几种）这一版**不解**，如实返回 unsupported ——
// 猜错会产出看起来像真的垃圾，那比不解析更糟。

import 'dart:typed_data';

import 'macho.dart';

/// 从 `__objc_selrefs` / `__objc_classrefs` 解出来的引用集合。
class IosReferenceTables {
  /// 代码引用到的选择子（方法名），例如 `requestTrackingAuthorization...`。
  final Set<String> selectors;

  /// 代码引用到的类名，例如 `CLLocationManager`。
  final Set<String> classes;

  /// 解出来的指针总数（两个表合计）。
  final int decodedPointers;

  /// 解不出来 / 被跳过的槽位数。
  final int skippedPointers;

  /// 解不了的原因（`null` 表示正常解析）。非空时两个集合都为空。
  final String? failure;

  const IosReferenceTables({
    this.selectors = const {},
    this.classes = const {},
    this.decodedPointers = 0,
    this.skippedPointers = 0,
    this.failure,
  });

  bool get isEmpty => selectors.isEmpty && classes.isEmpty;

  /// 解析一个镜像的引用表。
  static IosReferenceTables resolve(Uint8List file, MachOImage image) {
    final selrefs = _section(file, image, '__DATA', '__objc_selrefs') ??
        _section(file, image, '__DATA_CONST', '__objc_selrefs');
    final classrefs = _section(file, image, '__DATA', '__objc_classrefs') ??
        _section(file, image, '__DATA_CONST', '__objc_classrefs');
    if (selrefs == null && classrefs == null) {
      return const IosReferenceTables(
        failure: 'no __objc_selrefs / __objc_classrefs section',
      );
    }

    final fixups = image.chainedFixups;
    if (fixups == null) {
      return const IosReferenceTables(
        failure: 'no LC_DYLD_CHAINED_FIXUPS (pre-iOS 13 binary)',
      );
    }

    final decode = _PointerDecoder(file, image, fixups);
    if (decode.format == null) {
      return IosReferenceTables(failure: decode.unsupportedReason);
    }

    final selectors = <String>{};
    final classes = <String>{};
    var decoded = 0;
    var skipped = 0;

    void collect(MachOSection section, Set<String> into) {
      final base = image.offset + section.fileOffset;
      for (var i = 0; i < section.fileSize ~/ 8; i++) {
        final slot = base + i * 8;
        if (slot + 8 > file.length) break;
        // 绑定槽位（外部符号）走 imports 表：那里给的是符号名，例如
        // `_OBJC_CLASS_$_PHPhotoLibrary`。**这才是类引用的正解** ——
        // `__objc_classrefs` 的槽位几乎全是绑定，不是 rebase。
        final imported = decode.importNameAt(slot);
        if (imported != null) {
          final name = _symbolToName(imported);
          if (name != null) {
            into.add(name);
            decoded++;
          } else {
            skipped++;
          }
          continue;
        }
        final vmaddr = decode.targetAt(slot);
        if (vmaddr == null) {
          skipped++;
          continue;
        }
        final text = _cStringAtVmaddr(file, image, vmaddr);
        if (text == null || !_looksLikeName(text)) {
          skipped++;
          continue;
        }
        into.add(text);
        decoded++;
      }
    }

    if (selrefs != null) collect(selrefs, selectors);
    if (classrefs != null) collect(classrefs, classes);

    return IosReferenceTables(
      selectors: selectors,
      classes: classes,
      decodedPointers: decoded,
      skippedPointers: skipped,
    );
  }

  /// 这个字符串像不像类名 / 选择子。
  ///
  /// 不是所有槽位都是「指向字符串的指针」：混进来的其他 rebase 会解出
  /// 二进制垃圾（实测出现过 `¨`、`è`）。与其把它们塞进「类清单」让读者
  /// 怀疑整张表，不如直接丢掉 —— 但**跳过数要如实记**。
  static bool _looksLikeName(String value) {
    if (value.length < 2 || value.length > 200) return false;
    for (final code in value.codeUnits) {
      final ok = (code >= 0x30 && code <= 0x39) || // 0-9
          (code >= 0x41 && code <= 0x5A) || // A-Z
          (code >= 0x61 && code <= 0x7A) || // a-z
          code == 0x5F || // _
          code == 0x24 || // $
          code == 0x3A || // :（选择子）
          code == 0x2E; // .（Swift 类型名）
      if (!ok) return false;
    }
    return true;
  }

  /// `_OBJC_CLASS_$_PHPhotoLibrary` → `PHPhotoLibrary`；
  /// `_OBJC_METACLASS_$_X` → `X`；普通 C 符号返回去掉前导下划线的名字。
  static String? _symbolToName(String symbol) {
    const classPrefix = r'_OBJC_CLASS_$_';
    const metaPrefix = r'_OBJC_METACLASS_$_';
    if (symbol.startsWith(classPrefix)) {
      return symbol.substring(classPrefix.length);
    }
    if (symbol.startsWith(metaPrefix)) {
      return symbol.substring(metaPrefix.length);
    }
    if (symbol.startsWith('_')) return symbol.substring(1);
    return symbol.isEmpty ? null : symbol;
  }

  static MachOSection? _section(
    Uint8List file,
    MachOImage image,
    String segment,
    String section,
  ) {
    for (final seg in image.segments) {
      if (seg.name != segment) continue;
      final found = seg.section(section);
      if (found != null && found.fileSize > 0) return found;
    }
    return null;
  }

  /// vmaddr → 文件偏移 → 读 NUL 结尾的字符串。
  static String? _cStringAtVmaddr(
    Uint8List file,
    MachOImage image,
    int vmaddr,
  ) {
    for (final seg in image.segments) {
      if (seg.vmSize == 0) continue;
      if (vmaddr < seg.vmAddress || vmaddr >= seg.vmAddress + seg.vmSize) {
        continue;
      }
      final offset = image.offset + seg.fileOffset + (vmaddr - seg.vmAddress);
      if (offset < 0 || offset >= file.length) return null;
      // 选择子/类名都是短 ASCII，128 字节足够，也避免被畸形文件拖住。
      final end = offset + 128 > file.length ? file.length : offset + 128;
      final nul = file.indexOf(0, offset);
      final stop = (nul < 0 || nul > end) ? end : nul;
      if (stop <= offset) return null;
      return String.fromCharCodes(file.sublist(offset, stop));
    }
    return null;
  }
}

/// `LC_DYLD_CHAINED_FIXUPS` 的最小解码器：只回答「这个槽位指向哪个 vmaddr」。
class _PointerDecoder {
  final Uint8List _file;
  final MachOImage _image;
  final int _dataoff;
  final int _datasize;

  /// 指针格式；`null` 表示不支持。
  final int? format;

  final String unsupportedReason;

  _PointerDecoder(this._file, MachOImage image, ChainedFixups fixups)
      : _image = image,
        _dataoff = image.offset + fixups.dataOffset,
        _datasize = fixups.dataSize,
        format = _readFormat(_file, image, fixups),
        unsupportedReason = _reason(_file, image, fixups);

  static String _reason(Uint8List file, MachOImage image, ChainedFixups f) {
    final fmt = _readFormat(file, image, f);
    if (fmt == null) return 'chained fixups header is unreadable';
    if (fmt != 2 && fmt != 6) {
      return 'pointer format $fmt (ARM64E / 32-bit) is not supported';
    }
    return '';
  }

  /// 读 `dyld_chained_starts_in_segment.pointer_format`。
  ///
  /// 结构：`dyld_chained_fixups_header`(32) → `starts_in_image` →
  /// `seg_info_offset[seg_count]` → `dyld_chained_starts_in_segment`。
  static int? _readFormat(Uint8List file, MachOImage image, ChainedFixups f) {
    // `dataoff` 相对切片起点，读文件时要加上切片偏移。
    final header = image.offset + f.dataOffset;
    if (header + 32 > file.length) return null;
    final bd = ByteData.sublistView(file);
    final startsOffset = bd.getUint32(header + 4, Endian.little);
    final starts = header + startsOffset;
    if (starts + 4 > file.length) return null;
    final segCount = bd.getUint32(starts, Endian.little);
    // 段序与 load command 里的段序一致；取第一个有 fixups 的段即可 ——
    // 同一个镜像里所有段的 pointer_format 相同。
    for (var i = 0; i < segCount && i < image.segments.length; i++) {
      final entry = starts + 4 + i * 4;
      if (entry + 4 > file.length) return null;
      final segInfoOffset = bd.getUint32(entry, Endian.little);
      if (segInfoOffset == 0) continue; // 该段没有 fixups
      final segInfo = starts + segInfoOffset;
      if (segInfo + 8 > file.length) return null;
      return bd.getUint16(segInfo + 4, Endian.little);
    }
    return null;
  }

  /// 读 `imports` 表里的符号名（绑定槽位用）。
  ///
  /// 返回 `null` 表示这个槽位**不是**绑定、或 imports 表读不出来。
  String? importNameAt(int slotOffset) {
    if (slotOffset + 8 > _file.length) return null;
    final bd = ByteData.sublistView(_file);
    final raw = bd.getUint64(slotOffset, Endian.little);
    if ((raw >> 63) & 1 != 1) return null;
    // `dyld_chained_ptr_64_bind`: ordinal:24 在低位。
    final ordinal = raw & 0xFFFFFF;
    return _importName(ordinal);
  }

  /// `imports[ordinal]` → symbols 池里的字符串。
  String? _importName(int ordinal) {
    final bd = ByteData.sublistView(_file);
    final header = _dataoff;
    if (header + 32 > _file.length) return null;
    final importsOffset = bd.getUint32(header + 8, Endian.little);
    final symbolsOffset = bd.getUint32(header + 12, Endian.little);
    final importsCount = bd.getUint32(header + 16, Endian.little);
    final importsFormat = bd.getUint32(header + 20, Endian.little);
    if (ordinal >= importsCount) return null;
    // 只支持 `DYLD_CHAINED_IMPORT`（4 字节/条）：`lib_ordinal:8 weak:1
    // name_offset:23`。其余格式（24 位序号、64 位条目）这一版不解。
    if (importsFormat != 1) return null;
    final entry = header + importsOffset + ordinal * 4;
    if (entry + 4 > _file.length) return null;
    final value = bd.getUint32(entry, Endian.little);
    final nameOffset = (value >> 9) & 0x7FFFF;
    final start = header + symbolsOffset + nameOffset;
    if (start < 0 || start >= _file.length) return null;
    final nul = _file.indexOf(0, start);
    final stop = nul < 0 ? _file.length : nul;
    if (stop <= start) return null;
    return String.fromCharCodes(_file.sublist(start, stop));
  }

  /// 解某个槽位的目标 vmaddr；`null` 表示这个槽位是绑定（外部符号）或读不出。
  int? targetAt(int slotOffset) {
    if (slotOffset + 8 > _file.length) return null;
    final bd = ByteData.sublistView(_file);
    final raw = bd.getUint64(slotOffset, Endian.little);
    // 最高位是 bind 标志：外部符号（走 imports），不是 rebase。
    if ((raw >> 63) & 1 == 1) return null;
    final target = raw & 0xFFFFFFFFF; // 36 位
    if (target == 0) return null;
    // `PTR_64_OFFSET` 的 target 相对**镜像基址**（mach header 所在段的
    // vmaddr）。`__PAGEZERO` 的 vmaddr 是 0 且 fileSize 为 0，不能拿它当基址。
    var base = 0;
    for (final seg in _image.segments) {
      if (seg.fileOffset == 0 && seg.fileSize > 0) {
        base = seg.vmAddress;
        break;
      }
    }
    return format == 6 ? base + target : target;
  }

  int get dataSize => _datasize;
  int get dataOffset => _dataoff;
}
