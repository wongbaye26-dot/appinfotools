import 'dart:typed_data';

/// 从 Mach-O 的加载命令里读 `LC_ENCRYPTION_INFO(_64)` 的 `cryptid`。
///
/// ## 为什么需要它
///
/// `codesign` 说「签名无效」时，最常见的原因是**砸壳**（从设备里 dump 出解密后
/// 的二进制）。砸壳会把 `cryptid` 从 1 改成 0 并解密代码段 —— 原始签名覆盖的是
/// 加密态的字节，一改就必然对不上。
///
/// 但「签名无效」这句话本身分不出「砸壳」和「有人打了补丁」。把 `cryptid` 一起
/// 读出来，报告就能从「可能是砸壳」变成「这个二进制已解密（cryptid=0），
/// 签名失效是必然」——**结论有证据，不是猜**。
///
/// ## 输入只要头部 + 加载命令
///
/// 主可执行文件常有几百 MB，整读进内存只为读一个 u32 不值得。调用方按
/// `headerSize + sizeofcmds` 读一小段即可；本函数不会越过给定缓冲区。
///
/// ## 返回 `null` 的含义
///
/// - 不是 Mach-O（fat 二进制、被加密的外壳、根本不是可执行文件）；
/// - 没有这条加载命令（动态库通常没有）；
/// - 缓冲区不完整。
///
/// **`null` 一律表示「没查出来」，不能当成 `cryptid == 0`。**
int? readMachOCryptId(Uint8List bytes) {
  if (bytes.length < 28) return null;
  final data = ByteData.sublistView(bytes);

  // magic 用 little-endian 读，四种取值覆盖 32/64 位与两种字节序。
  final magic = data.getUint32(0, Endian.little);
  final bool is64;
  final Endian order;
  switch (magic) {
    case 0xFEEDFACF:
      is64 = true;
      order = Endian.little;
    case 0xCFFAEDFE:
      is64 = true;
      order = Endian.big;
    case 0xFEEDFACE:
      is64 = false;
      order = Endian.little;
    case 0xCEFAEDFE:
      is64 = false;
      order = Endian.big;
    default:
      // 0xCAFEBABE（fat）等：本函数只处理**单个切片**。
      return null;
  }

  final headerSize = is64 ? 32 : 28;
  if (bytes.length < headerSize) return null;

  // `mach_header(_64)`：ncmds @16、sizeofcmds @20，两者对 32/64 位相同。
  final ncmds = data.getUint32(16, order);
  final sizeofcmds = data.getUint32(20, order);
  if (ncmds == 0 || sizeofcmds == 0) return null;

  // 只信「实际给了多少字节」，不信 sizeofcmds —— 它是文件里的数，
  // 可以被写成任意大。
  final limit = bytes.length;
  var offset = headerSize;
  for (var i = 0; i < ncmds; i++) {
    if (offset + 8 > limit) return null;
    final cmd = data.getUint32(offset, order);
    final cmdsize = data.getUint32(offset + 4, order);
    // cmdsize 必须至少包含 cmd/cmdsize 自身，且不能越界。
    if (cmdsize < 8 || offset + cmdsize > limit) return null;
    // LC_ENCRYPTION_INFO = 0x21，LC_ENCRYPTION_INFO_64 = 0x2C。
    // 两者布局相同：cmd、cmdsize、cryptoff、cryptsize、cryptid。
    if (cmd == 0x21 || cmd == 0x2C) {
      if (cmdsize < 20) return null;
      return data.getUint32(offset + 16, order);
    }
    offset += cmdsize;
  }
  return null;
}
