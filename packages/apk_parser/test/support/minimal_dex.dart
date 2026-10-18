// 测试用的**最小 DEX 构造器**。
//
// ## 为什么可以手搓这一个
//
// 项目的铁律是「造夹具用真实产物，不手拼字节」—— 因为手拼的样本会带着与
// 解析器相同的错误假设。这里有一个明确的例外理由：
//
// 1. `SdkInventoryScanner` 只读 DEX 头的**两个字段**（`string_ids_size` /
//    `string_ids_off`）与每个 `string_id_item` 的 4 字节偏移，不碰 class_defs、
//    method_ids、code_item 等任何复杂结构；
// 2. 这个构造器的**正确性本身**由真实样本钉住：
//    `sdk_inventory_scanner_test.dart` 里对 `real-cooccurrence.dex`（javac +
//    d8 的真实产物）跑同一套断言；
// 3. 它的唯一用途是**控制类名条数**（测试 20 条阈值、重复计数、边界），
//    用 javac 造 25 个类既啰嗦又没必要。
//
// 换句话说：真实样本证明「解析对」，这个构造器用来证明「判据对」。
//
// ## 布局（只写到够用为止）
//
// ```
// 0x00  magic "dex\n035\0"
// 0x20  file_size      (u32)
// 0x24  header_size    (u32) = 0x70
// 0x28  endian_tag     (u32) = 0x12345678
// 0x38  string_ids_size (u32)
// 0x3C  string_ids_off  (u32)
// 0x70  string_ids: count × u32（指向各自的 string_data）
//       string_data: uleb128(utf16_size) + MUTF-8 + 0x00
// ```

import 'dart:typed_data';

/// 用给定的字符串列表构造一个最小 DEX。
///
/// 字符串按顺序放进 `string_ids`，索引 0..n-1 —— 与真实 DEX 一致（真实 DEX
/// 的 `string_ids` 也是按字典序排的，但扫描器不依赖顺序）。
Uint8List buildMinimalDex(List<String> strings) {
  const headerSize = 0x70;
  final stringIdsSize = strings.length;
  final stringIdsOff = headerSize;
  final dataStart = stringIdsOff + stringIdsSize * 4;

  // 先算每条 string_data 的字节与偏移。
  final dataBytes = <int>[];
  final offsets = <int>[];
  for (final value in strings) {
    offsets.add(dataStart + dataBytes.length);
    // utf16_size 用单字节 ULEB128（测试里的字符串都远短于 128）。
    final utf16Length = value.length;
    assert(utf16Length < 0x80, '测试字符串请短于 128 个 UTF-16 单元');
    dataBytes.add(utf16Length);
    for (final unit in value.codeUnits) {
      // ASCII 直接写单字节；非 ASCII 用 MUTF-8 的替代形式太绕，测试里不用。
      assert(unit < 0x80, '测试字符串请只用 ASCII');
      dataBytes.add(unit);
    }
    dataBytes.add(0); // 结尾 NUL
  }

  final fileSize = dataStart + dataBytes.length;
  final out = Uint8List(fileSize);
  final data = ByteData.sublistView(out);

  // magic: "dex\n035\0"
  const magic = [0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x35, 0x00];
  for (var i = 0; i < magic.length; i++) {
    out[i] = magic[i];
  }
  data.setUint32(0x20, fileSize, Endian.little);
  data.setUint32(0x24, headerSize, Endian.little);
  data.setUint32(0x28, 0x12345678, Endian.little);
  data.setUint32(0x38, stringIdsSize, Endian.little);
  data.setUint32(0x3C, stringIdsOff, Endian.little);

  for (var i = 0; i < offsets.length; i++) {
    data.setUint32(stringIdsOff + i * 4, offsets[i], Endian.little);
  }
  for (var i = 0; i < dataBytes.length; i++) {
    out[dataStart + i] = dataBytes[i];
  }
  return out;
}

/// 造一份「含 [count] 个 `<prefix>` 包下类名」的 DEX。
///
/// 类名形如 `Lcom/adjust/sdk/C0;`、`Lcom/adjust/sdk/C1;` ……
/// 之所以每条都是独立字符串：扫描器数的是「带该前缀的类名条数」，
/// 一个字符串里出现两次也只算一次（那正是 `SdkHit.occurrences` 的定义）。
Uint8List buildDexWithClassPrefix(String packagePrefix, int count) {
  return buildMinimalDex([
    for (var i = 0; i < count; i++) 'L$packagePrefix/C$i;',
  ]);
}
