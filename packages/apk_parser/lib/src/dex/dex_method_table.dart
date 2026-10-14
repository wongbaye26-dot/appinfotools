import 'dart:convert';
import 'dart:typed_data';

import 'dex_structure.dart';

/// 一个被 DEX **引用**的方法。
///
/// **「被引用」不等于「被调用」**：`method_ids` 里的条目来自字节码的 invoke
/// 指令、方法签名、方法句柄等。它比字符串同现强得多（字符串常量不会产生
/// `method_ids`），但**没有**回答「在哪个方法里、被调了几次」—— 那要遍历
/// `code_item` 里的指令，是下一层的事。措辞上必须守住这条界线。
class DexMethodReference {
  /// 所属类的描述符，例如 `Ljava/net/HttpURLConnection;`。
  final String classDescriptor;

  /// 方法名，例如 `getInputStream`。
  final String name;

  /// 方法原型描述符，例如 `()Ljava/io/InputStream;`。
  ///
  /// 参数类型取不出来时为 `null`（只影响可读性，不影响匹配）。
  final String? protoDescriptor;

  const DexMethodReference({
    required this.classDescriptor,
    required this.name,
    this.protoDescriptor,
  });

  /// `Ljava/net/HttpURLConnection;.getInputStream()Ljava/io/InputStream;`
  ///
  /// 格式与 `dexdump -d` 的 `invoke-*` 行一致，便于与工具输出逐字对照。
  String get displayName => '$classDescriptor.$name${protoDescriptor ?? ''}';

  /// 类的 Java 风格全名（`java.net.HttpURLConnection`）。
  ///
  /// 存在的理由是**便于与字符串线索比较**：字符串里写的是点号
  /// （`com.google.mlkit`），而 DEX 描述符用斜杠。不归一化就会整类漏掉。
  /// 不是对象类型（基本类型 / 数组）时返回 `null`。
  String? get javaClassName {
    final descriptor = classDescriptor;
    if (descriptor.length < 2) return null;
    if (!descriptor.startsWith('L') || !descriptor.endsWith(';')) return null;
    return descriptor.substring(1, descriptor.length - 1).replaceAll('/', '.');
  }

  @override
  String toString() => 'DexMethodReference($displayName)';
}

/// 遍历 `method_ids` 的结果。
class DexMethodTableResult {
  /// 成功解析并交给回调的条目数。
  final int visitedCount;

  /// 解析不出来的条目数（索引越界、字符串读不出来）。
  ///
  /// 单独计数而不是静默跳过：这些条目里的引用我们**没看到**。
  final int skippedCount;

  /// 是否因为预算上限而提前停止。
  final bool truncated;

  const DexMethodTableResult({
    this.visitedCount = 0,
    this.skippedCount = 0,
    this.truncated = false,
  });

  @override
  String toString() => 'DexMethodTableResult(visited=$visitedCount, '
      'skipped=$skippedCount, truncated=$truncated)';
}

/// `method_ids` 的**流式**遍历。
///
/// 为什么流式：一个 8 MiB 的 DEX 可以有上百万条 `method_ids`，把它们全部
/// materialize 成对象再筛选，内存与耗时都不划算。调用方每拿到一条就当场判断
/// 要不要留 —— 上层只需要关心那几十个标记。
///
/// 因此这个类**不认识任何安全规则**：它只负责把结构读对，匹配交给调用方。
class DexMethodTable {
  DexMethodTable._();

  /// 一次遍历最多处理多少条 `method_ids`。
  ///
  /// 取 200 万是刻意宽松：正常的 `classes.dex` 远低于这个量级（本项目的
  /// 8 MiB 单文件预算下最多约 100 万条）。真正的意义是**兜住畸形文件** ——
  /// 一个声明了 40 亿条目的 DEX 不能让遍历跑不完。截断时如实报告。
  static const int maxReferenceEntries = 2000000;

  /// 遍历 `method_ids`，对每个能解析出来的引用调用 [onReference]。
  ///
  /// [structure] 必须已经通过 [DexStructure.isTraversable] 检查 ——
  /// 段边界不合法时读出来的东西没有意义，本方法不做二次校验之外的兜底。
  static DexMethodTableResult forEachReference(
    Uint8List bytes,
    DexStructure structure, {
    required void Function(DexMethodReference reference) onReference,
    int maxEntries = maxReferenceEntries,
  }) {
    final tables = _DexTables(bytes, structure);
    final methodIds = structure.section('method_ids');
    if (methodIds == null || methodIds.size == 0) {
      return const DexMethodTableResult();
    }

    var visited = 0;
    var skipped = 0;
    var truncated = false;

    final limit = methodIds.size < maxEntries ? methodIds.size : maxEntries;
    if (limit < methodIds.size) truncated = true;

    for (var i = 0; i < limit; i++) {
      final base = methodIds.offset + i * methodIds.itemSize;
      // itemSize 是 8：class_idx(u16) + proto_idx(u16) + name_idx(u32)。
      final classIdx = tables.uint16(base);
      final protoIdx = tables.uint16(base + 2);
      final nameIdx = tables.uint32(base + 4);

      final classDescriptor = tables.typeDescriptor(classIdx);
      final name = tables.string(nameIdx);
      if (classDescriptor == null || name == null) {
        skipped++;
        continue;
      }

      onReference(DexMethodReference(
        classDescriptor: classDescriptor,
        name: name,
        protoDescriptor: tables.protoDescriptor(protoIdx),
      ));
      visited++;
    }

    return DexMethodTableResult(
      visitedCount: visited,
      skippedCount: skipped,
      truncated: truncated,
    );
  }

  /// 遍历 `type_ids`，对每个能解析出来的类型描述符调用 [onDescriptor]。
  ///
  /// 用途与 [forEachReference] 不同：`type_ids` 是**所有**出现过的类型
  /// （含字段类型、局部变量类型、类定义本身），覆盖面比 `method_ids` 更广。
  /// 两者结合才能回答「这个类型到底有没有被代码用到」。
  static int forEachType(
    Uint8List bytes,
    DexStructure structure, {
    required void Function(String descriptor) onDescriptor,
  }) {
    final tables = _DexTables(bytes, structure);
    final typeIds = structure.section('type_ids');
    if (typeIds == null) return 0;

    var visited = 0;
    for (var i = 0; i < typeIds.size; i++) {
      final descriptor = tables.typeDescriptor(i);
      if (descriptor == null) continue;
      onDescriptor(descriptor);
      visited++;
    }
    return visited;
  }
}

/// 段读取的边界安全包装与字符串/类型缓存。
///
/// 缓存是必要的：`method_ids` 里的 `class_idx` 高度重复（同一个类的多个方法），
/// 每个都重新解一次字符串会让遍历慢一个量级。
class _DexTables {
  final Uint8List bytes;
  final DexStructure structure;
  final ByteData _data;

  late final List<String?> _stringCache;
  late final List<String?> _typeCache;
  final Map<int, String?> _protoCache = {};

  _DexTables(this.bytes, this.structure) : _data = ByteData.sublistView(bytes) {
    final stringIds = structure.section('string_ids');
    final typeIds = structure.section('type_ids');
    _stringCache = List<String?>.filled(stringIds?.size ?? 0, null);
    _typeCache = List<String?>.filled(typeIds?.size ?? 0, null);
  }

  /// 读 u16；越界返回 0（由调用方的索引校验兜住，不会因此产出错误引用）。
  int uint16(int offset) {
    if (offset < 0 || offset + 2 > bytes.length) return 0;
    return _data.getUint16(offset, Endian.little);
  }

  /// 读 u32；越界返回 0。
  int uint32(int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return _data.getUint32(offset, Endian.little);
  }

  /// `string_ids[index]` 指向的字符串。
  String? string(int index) {
    if (index < 0 || index >= _stringCache.length) return null;
    final cached = _stringCache[index];
    if (cached != null) return cached;
    final section = structure.section('string_ids')!;
    final dataOff = uint32(section.offset + index * section.itemSize);
    final value = _stringAt(dataOff);
    // 只有解析成功才写缓存 —— 缓存 null 会让「暂时读不出来」变成永久。
    if (value != null) _stringCache[index] = value;
    return value;
  }

  /// `type_ids[index]` 对应的类型描述符。
  String? typeDescriptor(int index) {
    if (index < 0 || index >= _typeCache.length) return null;
    final cached = _typeCache[index];
    if (cached != null) return cached;
    final section = structure.section('type_ids')!;
    final descriptorIdx = uint32(section.offset + index * section.itemSize);
    final value = string(descriptorIdx);
    if (value != null) _typeCache[index] = value;
    return value;
  }

  /// `proto_ids[index]` 对应的原型描述符，例如 `(Ljava/lang/String;I)V`。
  String? protoDescriptor(int index) {
    if (_protoCache.containsKey(index)) return _protoCache[index];
    final value = _buildProtoDescriptor(index);
    _protoCache[index] = value;
    return value;
  }

  String? _buildProtoDescriptor(int index) {
    final section = structure.section('proto_ids');
    if (section == null) return null;
    if (index < 0 || index >= section.size) return null;

    final base = section.offset + index * section.itemSize;
    // proto_id_item: shorty_idx(u32) + return_type_idx(u32) + parameters_off(u32)
    final returnTypeIdx = uint32(base + 4);
    final parametersOff = uint32(base + 8);

    final returnType = typeDescriptor(returnTypeIdx);
    if (returnType == null) return null;

    final parameters = <String>[];
    if (parametersOff != 0) {
      // type_list: size(u32) + size × type_idx(u16)
      final count = uint32(parametersOff);
      // 先验边界：size 是文件里声明的任意值，乘 2 之前必须确认读得到。
      if (parametersOff + 4 + count * 2 > bytes.length) return null;
      for (var i = 0; i < count; i++) {
        final typeIdx = uint16(parametersOff + 4 + i * 2);
        final parameter = typeDescriptor(typeIdx);
        if (parameter == null) return null;
        parameters.add(parameter);
      }
    }
    return '(${parameters.join()})$returnType';
  }

  /// 读 `string_data_item`：uleb128 的 utf16 长度 + MUTF-8 字节 + NUL。
  String? _stringAt(int offset) {
    if (offset <= 0 || offset >= bytes.length) return null;
    final read = _readUleb128(offset);
    if (read == null) return null;
    final start = read.$2;
    var end = start;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    // 没有终止符说明这个字符串跨到了文件之外 —— 不猜，如实返回 null。
    if (end >= bytes.length) return null;
    return _decodeModifiedUtf8(start, end);
  }

  /// 读一个 ULEB128，返回 `(值, 下一个偏移)`。
  ///
  /// 超过 5 字节视为畸形：DEX 规范里 uleb128 最多 5 字节（32 位）。
  /// 不设这个上限，一段全 `0xFF` 的字节会让循环一直读下去。
  (int, int)? _readUleb128(int offset) {
    var result = 0;
    var shift = 0;
    var i = offset;
    while (i < bytes.length) {
      final byte = bytes[i++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return (result, i);
      shift += 7;
      if (shift > 28) return null;
    }
    return null;
  }

  /// 解码 MUTF-8。
  ///
  /// DEX 用的是「修改过的 UTF-8」：`U+0000` 编成 `0xC0 0x80`，而终止符是
  /// 裸的 `0x00`。因此按 `0x00` 截断是安全的（串内不会出现裸 0）。
  ///
  /// 用 `allowMalformed` 而不是严格解码：描述符与方法名基本是 ASCII，
  /// 真出现畸形字节时，**留着能读的部分**比整条丢掉有用。
  String _decodeModifiedUtf8(int start, int end) {
    final view = Uint8List.sublistView(bytes, start, end);
    return utf8.decode(view, allowMalformed: true);
  }
}
