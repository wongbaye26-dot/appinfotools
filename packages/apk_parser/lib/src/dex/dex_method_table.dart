import 'dart:typed_data';

import 'dex_structure.dart';
import 'dex_tables.dart';

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
    final tables = DexTables(bytes, structure);
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
      final resolved = tables.methodReference(i);
      if (resolved == null) {
        skipped++;
        continue;
      }

      onReference(DexMethodReference(
        classDescriptor: resolved.$1,
        name: resolved.$2,
        protoDescriptor: resolved.$3,
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
    final tables = DexTables(bytes, structure);
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
