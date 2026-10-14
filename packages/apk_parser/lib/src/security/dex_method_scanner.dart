import 'package:analysis_model/analysis_model.dart';

import '../dex/dex_method_bodies.dart';
import '../dex/dex_method_table.dart';
import '../dex/dex_structure.dart';
import 'code_markers.dart';
import 'dex_clue_scanner.dart' show DexBytes;

/// 一个在**代码引用**里命中的标记。
///
/// 与 [CodeClue]（字符串线索）刻意分开：字符串常量可以随便写，
/// `method_ids` 的条目来自字节码的 invoke 指令、方法签名或方法句柄。
class CodeReference {
  /// 标记 id，与 [codeMarkers] 一一对应。
  final String markerId;

  final SecurityCategory category;

  /// 命中标记的说明（面向最终用户）。
  final String description;

  /// 证据原文：`Lcom/foo/Bar;.method(proto)` 形式的方法引用（去重、限量）。
  ///
  /// 来自 `method_ids` —— 它证明**引用存在**，但引用可能来自方法签名而不
  /// 是调用指令。
  final List<String> samples;

  /// 出现在哪些 DEX 里。
  final List<String> dexNames;

  /// 该标记出现在**调用指令**上的位置，形如
  /// `Lcom/foo/Bar;.baz()V @ NetProbe.open +0x10`（去重、限量）。
  ///
  /// 与 [samples] 的区别很重要：`method_ids` 里有条目只说明「引用存在」，
  /// 而这里来自 `code_item` 的 `invoke-*` 指令 —— 是**真的有一条调用指令**。
  /// 仍然不等于「运行时会执行到」，但已经能回答「在哪个方法的哪个位置」。
  final List<String> callSiteSamples;

  /// 该标记在调用指令上出现的次数。
  final int callSiteCount;

  const CodeReference({
    required this.markerId,
    required this.category,
    required this.description,
    required this.samples,
    required this.dexNames,
    this.callSiteSamples = const [],
    this.callSiteCount = 0,
  });

  /// 是否至少有一条真实的调用指令（而不只是引用）。
  bool get hasCallSite => callSiteCount > 0;
}

/// 同一个方法体内出现了多个标记。
///
/// 这是调用点分析带来的**新信息**：字符串同现只能说明「两个词都出现在这个
/// 包里」，而这里能说明「这两条调用指令位于同一个方法体内」。
///
/// **仍然不等于数据流**：同一个方法里既调用了识别、又调用了上传，不代表识别
/// 结果被送进了上传请求 —— 那要看寄存器与参数传递，属于数据流分析。
class CodeCoOccurrence {
  /// 调用者的完整描述（类 + 方法 + 原型）。
  final String callerDisplayName;

  /// 该方法体内出现的标记 id（已排序）。
  final List<String> markerIds;

  final List<String> dexNames;

  const CodeCoOccurrence({
    required this.callerDisplayName,
    required this.markerIds,
    required this.dexNames,
  });

  bool containsAll(Iterable<String> ids) =>
      ids.every((id) => markerIds.contains(id));

  @override
  String toString() => 'CodeCoOccurrence($callerDisplayName: $markerIds)';
}

/// DEX 方法引用的扫描结果。
class DexMethodScanResult {
  /// 在代码引用里命中的标记（按类别、id 稳定排序）。
  final List<CodeReference> references;

  /// 实际做了方法引用分析的 DEX 数。
  final int scannedDexCount;

  /// 实际做了指令遍历的 DEX 数。
  final int walkedDexCount;

  /// 结构不可遍历、因此**没有**做分析的 DEX 名。
  final List<String> notTraversable;

  /// 遍历被预算截断的 DEX 名。
  final List<String> truncatedForBudget;

  /// 指令遍历**没有正好走到 `insns_size` 末尾**的方法体。
  ///
  /// 非空说明宽度表或解析有偏差，此时读到的调用点不可信 ——
  /// 必须出现在报告的覆盖范围说明里。
  final List<String> desyncedBodies;

  /// 解析不出来的 `method_ids` 条目总数。
  final int skippedEntries;

  /// 遍历到的 `invoke-*` 指令总数。
  final int callSiteCount;

  /// `invoke-custom` 的数量（引用 `call_site_ids`，不产出调用点）。
  final int invokeCustomCount;

  /// 同一方法体内出现多个标记的位置（按调用者稳定排序）。
  final List<CodeCoOccurrence> coOccurrences;

  const DexMethodScanResult({
    this.references = const [],
    this.scannedDexCount = 0,
    this.walkedDexCount = 0,
    this.notTraversable = const [],
    this.truncatedForBudget = const [],
    this.desyncedBodies = const [],
    this.skippedEntries = 0,
    this.callSiteCount = 0,
    this.invokeCustomCount = 0,
    this.coOccurrences = const [],
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

  /// 是否所有给到的标记都出现在**同一个方法体**里。
  bool coOccurInSameMethod(Iterable<String> markerIds) =>
      coOccurrences.any((c) => c.containsAll(markerIds));

  /// 找到同时包含全部 [markerIds] 的方法；没有时返回 `null`。
  CodeCoOccurrence? firstCoOccurrence(Iterable<String> markerIds) {
    for (final occurrence in coOccurrences) {
      if (occurrence.containsAll(markerIds)) return occurrence;
    }
    return null;
  }

  /// 找到同时包含「[groupA] 里至少一个」与「[groupB] 里至少一个」的方法。
  ///
  /// 规则引擎要问的是「识别与上传有没有出现在同一个方法里」，而不是
  /// 「某个具体标记有没有出现」—— 一个包里可能有多个 OCR 标记（ML Kit、
  /// Tesseract），要求全部命中等于永远匹配不上。
  CodeCoOccurrence? firstCoOccurrenceAcross(
    Iterable<String> groupA,
    Iterable<String> groupB,
  ) {
    final a = groupA.toSet();
    final b = groupB.toSet();
    if (a.isEmpty || b.isEmpty) return null;
    for (final occurrence in coOccurrences) {
      final hasA = occurrence.markerIds.any(a.contains);
      final hasB = occurrence.markerIds.any(b.contains);
      if (hasA && hasB) return occurrence;
    }
    return null;
  }
}

/// DEX 方法引用与调用点的扫描器（安全分析的**第二、三层**）。
///
/// 两层各回答一个问题：
/// - **第二层**（`method_ids`）：代码**引用**了哪些方法。比字符串命中强，
///   但引用可能来自方法签名而不是调用指令。
/// - **第三层**（`code_item` 的 `invoke-*`）：这些引用里，哪些**真的有调用
///   指令**，在哪个方法的哪个偏移上。并且能回答「哪几个标记出现在同一个
///   方法体内」。
///
/// **都只做匹配，不解释**：命中不等于调用发生，更不等于有风险。
class DexMethodScanner {
  DexMethodScanner._();

  static const String scannerVersion = 'dex-method-refs-2026.10.15';

  /// 每个标记最多保留多少条不同样本。
  static const int maxSamplesPerMarker = 5;

  /// 最多跟踪多少个「有标记命中的调用者方法」。
  ///
  /// 只跟踪**有命中的**调用者，因此正常包里这个数量很小。上限是为了兜住
  /// 畸形文件 —— 一个每个方法都命中标记的包不能让内存失控。
  static const int maxTrackedCallers = 2000;

  /// 最多保留多少条同现记录。
  static const int maxCoOccurrences = 20;

  static DexMethodScanResult scan(List<DexBytes> entries) {
    final samples = <String, Set<String>>{};
    final dexes = <String, Set<String>>{};
    final callSiteSamples = <String, Set<String>>{};
    final callSiteCounts = <String, int>{};
    // 调用者 → 该方法体内命中的标记。
    final callerMarkers = <String, Set<String>>{};
    final callerDexNames = <String, Set<String>>{};

    final notTraversable = <String>[];
    final truncated = <String>[];
    final desynced = <String>[];
    var scannedDexCount = 0;
    var walkedDexCount = 0;
    var skippedEntries = 0;
    var callSiteCount = 0;
    var invokeCustomCount = 0;

    for (final entry in entries) {
      final structure = DexStructure.read(entry.name, entry.bytes);
      if (!structure.isTraversable) {
        // 结构读不出来就不做引用分析 —— 段边界不合法时读到的条目没有意义。
        notTraversable.add(entry.name);
        continue;
      }
      scannedDexCount++;

      // ---- 第二层：method_ids ----
      final referenceResult = DexMethodTable.forEachReference(
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
      skippedEntries += referenceResult.skippedCount;
      if (referenceResult.truncated) truncated.add(entry.name);

      // ---- 第三层：code_item 的指令 ----
      final bodyResult = DexMethodBodies.walk(
        entry.bytes,
        structure,
        onCallSite: (site) {
          callSiteCount++;
          final text = '${site.target.classDescriptor}.${site.target.name}';
          final markers = matchCodeMarkers(text);
          if (markers.isEmpty) return;

          for (final marker in markers) {
            (callSiteSamples[marker.id] ??= <String>{}).add(
              '${site.target.displayName} @ ${site.callerDisplayName} '
              '+0x${site.instructionOffset.toRadixString(16)}',
            );
            callSiteCounts[marker.id] = (callSiteCounts[marker.id] ?? 0) + 1;
            (dexes[marker.id] ??= <String>{}).add(entry.name);
          }

          // 同现只在「调用者已跟踪」或「还没到上限」时记录。
          final caller = site.callerDisplayName;
          if (callerMarkers.containsKey(caller) ||
              callerMarkers.length < maxTrackedCallers) {
            (callerMarkers[caller] ??= <String>{})
                .addAll(markers.map((m) => m.id));
            (callerDexNames[caller] ??= <String>{}).add(entry.name);
          }
        },
      );
      if (bodyResult.methodBodyCount > 0) walkedDexCount++;
      invokeCustomCount += bodyResult.invokeCustomCount;
      if (bodyResult.truncated) {
        if (!truncated.contains(entry.name)) truncated.add(entry.name);
      }
      for (final body in bodyResult.desyncedBodies) {
        desynced.add('${entry.name}:$body');
      }
    }

    final references = <CodeReference>[];
    for (final marker in codeMarkers) {
      final markerSamples = samples[marker.id];
      final markerCallSites = callSiteSamples[marker.id];
      if ((markerSamples == null || markerSamples.isEmpty) &&
          (markerCallSites == null || markerCallSites.isEmpty)) {
        continue;
      }
      references.add(CodeReference(
        markerId: marker.id,
        category: marker.category,
        description: marker.description,
        samples: (markerSamples ?? const <String>{})
            .take(maxSamplesPerMarker)
            .toList(),
        dexNames: (dexes[marker.id] ?? const <String>{}).toList()..sort(),
        callSiteSamples: (markerCallSites ?? const <String>{})
            .take(maxSamplesPerMarker)
            .toList(),
        callSiteCount: callSiteCounts[marker.id] ?? 0,
      ));
    }
    // 稳定排序：先按类别、再按 id，报告输出才可复现（与字符串线索一致）。
    references.sort((a, b) {
      final byCategory = a.category.name.compareTo(b.category.name);
      return byCategory != 0 ? byCategory : a.markerId.compareTo(b.markerId);
    });

    // 同现：只保留命中 **2 个以上**不同标记的方法。
    final coOccurrences = <CodeCoOccurrence>[];
    final callers = callerMarkers.keys.toList()..sort();
    for (final caller in callers) {
      final ids = callerMarkers[caller]!;
      if (ids.length < 2) continue;
      coOccurrences.add(CodeCoOccurrence(
        callerDisplayName: caller,
        markerIds: ids.toList()..sort(),
        dexNames: (callerDexNames[caller] ?? const <String>{}).toList()..sort(),
      ));
      if (coOccurrences.length >= maxCoOccurrences) break;
    }

    return DexMethodScanResult(
      references: references,
      scannedDexCount: scannedDexCount,
      walkedDexCount: walkedDexCount,
      notTraversable: notTraversable,
      truncatedForBudget: truncated,
      desyncedBodies: desynced,
      skippedEntries: skippedEntries,
      callSiteCount: callSiteCount,
      invokeCustomCount: invokeCustomCount,
      coOccurrences: coOccurrences,
    );
  }
}
