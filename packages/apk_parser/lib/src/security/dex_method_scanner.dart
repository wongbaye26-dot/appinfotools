import 'package:analysis_model/analysis_model.dart';

import '../dex/dex_method_table.dart';
import '../dex/dex_structure.dart';
import 'code_markers.dart';
import 'dex_clue_scanner.dart' show DexBytes;

/// 一个在**代码引用**里命中的标记。
///
/// 与 [CodeClue]（字符串线索）刻意分开：字符串常量可以随便写，
/// `method_ids` 的条目来自字节码的 invoke 指令、方法签名或方法句柄。
/// 但**仍然不等于「调用了」** —— 那要遍历 `code_item` 里的指令。
class CodeReference {
  /// 标记 id，与 [codeMarkers] 一一对应。
  final String markerId;

  final SecurityCategory category;

  /// 命中标记的说明（面向最终用户）。
  final String description;

  /// 证据原文：`Lcom/foo/Bar;.method(proto)` 形式的方法引用（去重、限量）。
  final List<String> samples;

  /// 出现在哪些 DEX 里。
  final List<String> dexNames;

  const CodeReference({
    required this.markerId,
    required this.category,
    required this.description,
    required this.samples,
    required this.dexNames,
  });
}

/// DEX 方法引用的扫描结果。
class DexMethodScanResult {
  /// 在代码引用里命中的标记（按类别、id 稳定排序）。
  final List<CodeReference> references;

  /// 实际做了方法引用分析的 DEX 数。
  final int scannedDexCount;

  /// 结构不可遍历、因此**没有**做分析的 DEX 名。
  ///
  /// 必须出现在报告的未覆盖范围里：这些文件上的「没发现代码引用」是
  /// 「没查到」，不是「没有」。
  final List<String> notTraversable;

  /// 遍历被预算截断的 DEX 名。
  final List<String> truncatedForBudget;

  /// 解析不出来的 `method_ids` 条目总数（索引越界、字符串读不出来）。
  ///
  /// 单独计数而不是静默跳过：这些条目里的引用我们**没看到**。
  final int skippedEntries;

  const DexMethodScanResult({
    this.references = const [],
    this.scannedDexCount = 0,
    this.notTraversable = const [],
    this.truncatedForBudget = const [],
    this.skippedEntries = 0,
  });

  bool hasReference(String markerId) =>
      references.any((r) => r.markerId == markerId);

  /// 某个标记的代码引用；没有时返回 `null`。
  CodeReference? reference(String markerId) {
    for (final reference in references) {
      if (reference.markerId == markerId) return reference;
    }
    return null;
  }
}

/// DEX 方法引用的扫描器（安全分析的**第二层**）。
///
/// 第一层是 [DexClueScanner] 的字符串扫描：它把 DEX 当字节流，对「代码引用了
/// 某个类」与「某个字符串里提到了这个词」一视同仁。这一层回答后半个问题 ——
/// `method_ids` 里的条目**只可能**来自字节码的 invoke 指令、方法签名或方法
/// 句柄，不会来自字符串字面量。
///
/// **只做匹配，不解释**：命中不等于调用，也不等于有风险。定级交给规则引擎。
///
/// 匹配范围是「方法所属类的描述符 + 方法名」，**不含参数与返回类型** ——
/// 否则「某个无关方法的参数类型恰好是 HttpURLConnection」也会被记成
/// 「代码引用了 HttpURLConnection」，而那是另一种事实（类型出现了，但没调它）。
class DexMethodScanner {
  DexMethodScanner._();

  static const String scannerVersion = 'dex-method-refs-2026.10.15';

  /// 每个标记最多保留多少条不同样本。
  static const int maxSamplesPerMarker = 5;

  static DexMethodScanResult scan(List<DexBytes> entries) {
    final samples = <String, Set<String>>{};
    final dexes = <String, Set<String>>{};
    final notTraversable = <String>[];
    final truncated = <String>[];
    var scannedDexCount = 0;
    var skippedEntries = 0;

    for (final entry in entries) {
      final structure = DexStructure.read(entry.name, entry.bytes);
      if (!structure.isTraversable) {
        // 结构读不出来就不做引用分析 —— 段边界不合法时读到的条目没有意义。
        notTraversable.add(entry.name);
        continue;
      }

      scannedDexCount++;
      final result = DexMethodTable.forEachReference(
        entry.bytes,
        structure,
        onReference: (reference) {
          // 匹配「类描述符 + 方法名」。`matchCodeMarkers` 会把 `/` 归一成 `.`，
          // 因此 `Lcom/google/mlkit/…` 能命中 `com.google.mlkit`。
          final text = '${reference.classDescriptor}.${reference.name}';
          for (final marker in matchCodeMarkers(text)) {
            (samples[marker.id] ??= <String>{}).add(reference.displayName);
            (dexes[marker.id] ??= <String>{}).add(entry.name);
          }
        },
      );
      skippedEntries += result.skippedCount;
      if (result.truncated) truncated.add(entry.name);
    }

    final references = <CodeReference>[];
    for (final marker in codeMarkers) {
      final markerSamples = samples[marker.id];
      if (markerSamples == null || markerSamples.isEmpty) continue;
      references.add(CodeReference(
        markerId: marker.id,
        category: marker.category,
        description: marker.description,
        samples: markerSamples.take(maxSamplesPerMarker).toList(),
        dexNames: dexes[marker.id]!.toList()..sort(),
      ));
    }
    // 稳定排序：先按类别、再按 id，报告输出才可复现（与字符串线索一致）。
    references.sort((a, b) {
      final byCategory = a.category.name.compareTo(b.category.name);
      return byCategory != 0 ? byCategory : a.markerId.compareTo(b.markerId);
    });

    return DexMethodScanResult(
      references: references,
      scannedDexCount: scannedDexCount,
      notTraversable: notTraversable,
      truncatedForBudget: truncated,
      skippedEntries: skippedEntries,
    );
  }
}
