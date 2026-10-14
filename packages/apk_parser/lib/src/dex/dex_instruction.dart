import 'dart:typed_data';

/// DEX 指令的宽度表与载荷识别。
///
/// **这张表是整个第三层的地基**：指令长度不固定（1–5 个 16 位代码单元），
/// 不按宽度走就会在指令中间错位，把别的指令的操作数当成方法索引 ——
/// 那是比漏报更糟的误报，而且看起来完全正常。
///
/// 表按 DEX 规范的**指令格式**分组定义（`instruction-formats`），不写 256 个
/// 字面量：区间形式既短又能直接对照规范，写错一个边界也能被
/// `test/dex_instruction_test.dart` 的「真实 DEX 偏移逐个对照 dexdump」抓住。
class DexInstructionTable {
  DexInstructionTable._();

  /// `(起始 opcode, 结束 opcode, 宽度)`，闭区间，宽度单位是 16 位代码单元。
  static const List<(int, int, int)> _formatRanges = [
    // ---- 1 个代码单元 ----
    (0x00, 0x01, 1), // nop(10x) / move(12x)
    (0x04, 0x04, 1), // move-wide(12x)
    (0x07, 0x07, 1), // move-object(12x)
    (
      0x0a,
      0x0e,
      1
    ), // move-result*(11x) / move-exception(11x) / return-void(10x)
    (0x0f, 0x12, 1), // return*(11x) / const/4(11n)
    (0x1d, 0x1e, 1), // monitor-enter/exit(11x)
    (0x21, 0x21, 1), // array-length(12x)
    (0x27, 0x28, 1), // throw(11x) / goto(10t)
    (0x3e, 0x43, 1), // 未使用（保留为 1，避免错位放大）
    (0x73, 0x73, 1), // 未使用
    (0x79, 0x7a, 1), // 未使用
    (0x7b, 0x8f, 1), // 一元运算与类型转换(12x)
    (0xb0, 0xcf, 1), // 各类 `…/2addr`(12x)
    (0xe3, 0xf9, 1), // 未使用
    // ---- 2 个代码单元 ----
    (0x02, 0x02, 2), // move/from16(22x)
    (0x05, 0x05, 2), // move-wide/from16(22x)
    (0x08, 0x08, 2), // move-object/from16(22x)
    (0x13, 0x13, 2), // const/16(21s)
    (0x15, 0x16, 2), // const/high16(21h) / const-wide/16(21s)
    (0x19, 0x1a, 2), // const-wide/high16(21h) / const-string(21c)
    (0x1c, 0x1c, 2), // const-class(21c)
    (0x1f, 0x20, 2), // check-cast(21c) / instance-of(22c)
    (0x22, 0x23, 2), // new-instance(21c) / new-array(22c)
    (0x29, 0x29, 2), // goto/16(20t)
    (0x2d, 0x3d, 2), // cmp*(23x) / if-*(22t) / if-*z(21t)
    (0x44, 0x6d, 2), // aget/aput(23x) / iget/iput(22c) / sget/sput(21c)
    (0x90, 0xaf, 2), // 二元运算(23x)
    (0xd0, 0xe2, 2), // `…-int/lit16`(22s) 与 `…-int/lit8`(22b)
    (0xfe, 0xff, 2), // const-method-handle / const-method-type(21c)
    // ---- 3 个代码单元 ----
    (0x03, 0x03, 3), // move/16(32x)
    (0x06, 0x06, 3), // move-wide/16(32x)
    (0x09, 0x09, 3), // move-object/16(32x)
    (0x14, 0x14, 3), // const(31i)
    (0x17, 0x17, 3), // const-wide/32(31i)
    (0x1b, 0x1b, 3), // const-string/jumbo(31c)
    (
      0x24,
      0x26,
      3
    ), // filled-new-array(35c) / …/range(3rc) / fill-array-data(31t)
    (0x2a, 0x2c, 3), // goto/32(30t) / packed-switch(31t) / sparse-switch(31t)
    (0x6e, 0x72, 3), // invoke-virtual/super/direct/static/interface(35c)
    (0x74, 0x78, 3), // 同上的 /range 形式(3rc)
    (0xfc, 0xfd, 3), // invoke-custom(35c) / …/range(3rc)
    // ---- 4 个代码单元 ----
    (0xfa, 0xfb, 4), // invoke-polymorphic(45cc) / …/range(4rcc)
    // ---- 5 个代码单元 ----
    (0x18, 0x18, 5), // const-wide(51l)
  ];

  /// 每个 opcode 的宽度，下标即 opcode。长度固定 256。
  static final List<int> widths = _buildWidths();

  /// `packed-switch-payload` 的标识。
  static const int packedSwitchPayload = 0x0100;

  /// `sparse-switch-payload` 的标识。
  static const int sparseSwitchPayload = 0x0200;

  /// `fill-array-data-payload` 的标识。
  static const int fillArrayDataPayload = 0x0300;

  /// `invoke-*` 的 opcode（35c 形式，含 `invoke-custom`）。
  ///
  /// `0xfc` 引用的是 `call_site_ids` 而不是 `method_ids`，由调用方区分。
  static const Set<int> invokeOpcodes = {
    0x6e, 0x6f, 0x70, 0x71, 0x72, // 35c
    0x74, 0x75, 0x76, 0x77, 0x78, // 3rc
    0xfa, 0xfb, // 45cc / 4rcc（invoke-polymorphic）
    0xfc, 0xfd, // 35c / 3rc（invoke-custom）
  };

  /// 取 [opcode] 的宽度。
  static int widthOf(int opcode) => widths[opcode & 0xFF];

  static List<int> _buildWidths() {
    final table = List<int>.filled(256, 0);
    for (final (start, end, width) in _formatRanges) {
      for (var opcode = start; opcode <= end; opcode++) {
        table[opcode] = width;
      }
    }
    return table;
  }

  /// 判断 `insns[index]`（一个 16 位单元）是不是某个**载荷**的开头。
  ///
  /// 载荷的首单元是标识（`0x0100` / `0x0200` / `0x0300`），**低字节是 0x00**，
  /// 按 opcode 读会被当成 `nop`（宽度 1）—— 于是遍历会走进载荷数据里，
  /// 把 switch 的跳转目标当成指令。这是真实存在的错位来源，必须单独识别。
  ///
  /// 真正的 `nop` 是 `0x0000`，与三个标识都不相等，因此不会误判。
  static bool isPayloadHeader(int unit) =>
      unit == packedSwitchPayload ||
      unit == sparseSwitchPayload ||
      unit == fillArrayDataPayload;

  /// 载荷从 [index] 起占多少代码单元；不是载荷时返回 `null`。
  ///
  /// 长度是**变长**的：读不出长度（越界、截断）时返回 `null`，
  /// 由调用方记异常而不是硬猜。
  static int? payloadWidth(Uint16List insns, int index) {
    if (index < 0 || index + 1 >= insns.length) return null;
    final ident = insns[index];

    switch (ident) {
      case packedSwitchPayload:
        // ushort ident + ushort size + int targets[size]
        final size = insns[index + 1];
        return 2 + size * 2;
      case sparseSwitchPayload:
        // ushort ident + ushort size + { int key; int target; }[size]
        final size = insns[index + 1];
        return 2 + size * 4;
      case fillArrayDataPayload:
        // ushort ident + ushort element_width + uint size + ubyte data[]
        if (index + 3 >= insns.length) return null;
        final elementWidth = insns[index + 1];
        final size = insns[index + 2] | (insns[index + 3] << 16);
        final bytes = 8 + size * elementWidth;
        return (bytes + 1) ~/ 2;
      default:
        return null;
    }
  }
}
