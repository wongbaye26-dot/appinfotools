/// 两个安装包之间的**结构化差异**（V2.4.0 阶段 5.1）。
///
/// 刻意做成**平台中立 + 零依赖**：本包不认识 `ApkInfo`、不认识 `IpaInfoPlist`，
/// 也不认识应用层的 `PackageAnalysisResult`。它只认「字段 id → 带状态的字段值」
/// 与「集合 id → 成员」这两种输入，由调用方（应用层）负责把两份解析结果
/// 适配成 [DiffSubject]。
///
/// 这样分的理由与 `FieldValue` 当初单独成包是同一条：差异逻辑一旦依赖某一侧
/// 的模型，另一侧就要被迫依赖对方。
///
/// ## 口径（开工前定下的四条，见 `docs/plans/V2.4.0_PROGRESS.md` §17.4）
///
/// 1. **状态本身参与比较**。`FieldValue` 有六种状态，两份包组合起来状态对很多，
///    因此 [FieldDiff.kind] 只在**两侧状态都明确**时才给出 `added` / `removed` /
///    `changed`；任一侧是「我们没读到」（`failed` / `unsupported` / `wrongType` /
///    `hardenedUnknown` / `notRequested`）时一律记 [DiffKind.unknown]。
///    这与本项目一贯的口径一致：**「没查到」不能读成「没有」**。
///    两侧的原始 [FieldValue] 都带在结果里，界面因此能显示「左边：没读到」。
library;

import 'field_value.dart';

/// 一个字段在两份包之间的差异类型。
enum DiffKind {
  /// 左边没有（`absent`）、右边有值 —— 文件里**确实新增**了这个字段。
  added,

  /// 左边有值、右边没有（`absent`）—— 文件里**确实去掉**了这个字段。
  removed,

  /// 两侧都有值但不同。
  changed,

  /// 两侧都有值且相同。
  same,

  /// **无法比较**：至少一侧是「我们没读到」，或者一侧是 `absent` 而另一侧也不是
  /// 明确的 `extracted`。这不是「没有差异」，是「这次说不清」。
  unknown,
}

/// 一个字段的差异。
///
/// [left] / [right] 是**原始**的 [FieldValue]，不是渲染好的字符串 ——
/// 界面要能显示「左边：`unsupported`（aapt2 不报这个字段）」，那需要状态与诊断，
/// 而渲染成字符串就把它们丢了。
class FieldDiff {
  /// 稳定字段 id（`android.minSdkVersion` 这类）。与 `CoverageEntry.id` 同一套命名。
  final String id;

  final FieldValue<Object?> left;
  final FieldValue<Object?> right;
  final DiffKind kind;

  const FieldDiff({
    required this.id,
    required this.left,
    required this.right,
    required this.kind,
  });

  /// 两侧是否都给出了可比较的值。
  bool get isComparable => kind != DiffKind.unknown;

  @override
  String toString() => 'FieldDiff($id, ${kind.name}: ${left.value} → '
      '${right.value})';
}

/// 一个集合的差异（权限、组件、原生符号、域名、原生库…）。
///
/// 三个列表都**按传入顺序稳定输出**：调用方给出的成员顺序即输出顺序，
/// 且 [common] 也按该顺序过滤。差异报告要能两份对照，顺序不稳就做不到 ——
/// 这一点在 §17.4-2 里定过：排序键由调用方决定，本层只保证「不额外打乱」。
class SetDiff {
  final String id;

  /// 右边有、左边没有。
  final List<String> added;

  /// 左边有、右边没有。
  final List<String> removed;

  /// 两边都有。
  final List<String> common;

  const SetDiff({
    required this.id,
    required this.added,
    required this.removed,
    required this.common,
  });

  /// 两侧是否完全一致。
  bool get isSame => added.isEmpty && removed.isEmpty;

  @override
  String toString() => 'SetDiff($id, +${added.length} -${removed.length} '
      '=${common.length})';
}

/// 一份**待比较的包**：字段 id → 带状态的值，集合 id → 成员。
///
/// 用有序列表而不是 `Map` 表达字段：**输出顺序 = 输入顺序**，
/// 不依赖「Dart 的 Map 恰好保序」这种隐式性质。
class DiffSubject {
  /// 有序字段清单。顺序即 [PackageDiff.fields] 的输出顺序。
  final List<({String id, FieldValue<Object?> value})> fields;

  /// 集合 id → 成员（成员顺序即 [SetDiff] 里各列表的顺序）。
  final Map<String, List<String>> sets;

  const DiffSubject({this.fields = const [], this.sets = const {}});
}

/// 两份包的完整差异。
class PackageDiff {
  final List<FieldDiff> fields;
  final List<SetDiff> sets;

  const PackageDiff({this.fields = const [], this.sets = const []});

  /// 是否有任何实质差异（`same` 与 `unknown` 都不算）。
  ///
  /// `unknown` 不算差异，但**也不代表「没差异」** —— 调用方要把它单独呈现，
  /// 否则「这次说不清」会被读成「两边一样」。
  bool get hasChanges =>
      fields.any((f) =>
          f.kind == DiffKind.added ||
          f.kind == DiffKind.removed ||
          f.kind == DiffKind.changed) ||
      sets.any((s) => !s.isSame);

  /// 无法比较的字段数。**必须单独报出来**，不能并进「无差异」。
  int get unknownFieldCount =>
      fields.where((f) => f.kind == DiffKind.unknown).length;
}

/// 比较两份包。
///
/// 纯函数：不改输入，不做 IO，不依赖平台。
///
/// 字段按 [DiffSubject.fields] 的顺序输出；集合按**左侧的键顺序**输出，
/// 右侧多出来的键追加在后面 —— 这样「加了一个集合维度」也表现为一条差异，
/// 而不是被静默丢掉。
PackageDiff diffSubjects(DiffSubject left, DiffSubject right) {
  final rightFields = {
    for (final f in right.fields) f.id: f.value,
  };

  final fields = <FieldDiff>[
    for (final f in left.fields)
      FieldDiff(
        id: f.id,
        left: f.value,
        right: rightFields[f.id] ?? const FieldValue<Object?>.absent(),
        kind: _kindOf(f.value, rightFields[f.id]),
      ),
  ];

  // 右侧独有的字段：左边当「没有」，同样计入差异。
  final leftIds = {for (final f in left.fields) f.id};
  for (final f in right.fields) {
    if (leftIds.contains(f.id)) continue;
    fields.add(FieldDiff(
      id: f.id,
      left: const FieldValue<Object?>.absent(),
      right: f.value,
      kind: _kindOf(const FieldValue<Object?>.absent(), f.value),
    ));
  }

  final sets = <SetDiff>[];
  final seen = <String>{};
  for (final id in [...left.sets.keys, ...right.sets.keys]) {
    if (!seen.add(id)) continue;
    sets.add(
        _diffSet(id, left.sets[id] ?? const [], right.sets[id] ?? const []));
  }

  return PackageDiff(fields: fields, sets: sets);
}

/// 判定一个字段对的差异类型。
///
/// **只有两侧状态都明确时才给出实质结论** —— 见 [DiffKind.unknown] 的说明。
DiffKind _kindOf(FieldValue<Object?> left, FieldValue<Object?>? right) {
  // 右侧根本没有这个字段：当成「文件里没有」，而不是「没读到」。
  // 这个选择是刻意的：差异比较的两侧都是**我们自己解析出来的**结果，
  // 字段清单由同一份代码生成，因此「清单里没有」就是「这份包里没有」。
  final r = right ?? const FieldValue<Object?>.absent();

  final leftKnown =
      left.status == FieldStatus.extracted || left.status == FieldStatus.absent;
  final rightKnown =
      r.status == FieldStatus.extracted || r.status == FieldStatus.absent;
  if (!leftKnown || !rightKnown) return DiffKind.unknown;

  final leftHas = left.status == FieldStatus.extracted;
  final rightHas = r.status == FieldStatus.extracted;

  if (leftHas && rightHas) {
    return left.value == r.value ? DiffKind.same : DiffKind.changed;
  }
  if (!leftHas && rightHas) return DiffKind.added;
  if (leftHas && !rightHas) return DiffKind.removed;
  return DiffKind.same; // 两侧都是 absent：文件里都没有。
}

/// 比较两个集合。
///
/// 顺序：`added` 按右侧顺序、`removed` 按左侧顺序、`common` 按左侧顺序 ——
/// 各自沿用**它自己的来源顺序**，不重排。重排会让「同一个包两次比较」的
/// 输出不一致（例如域名是按扫描到的顺序来的）。
SetDiff _diffSet(String id, List<String> left, List<String> right) {
  final leftSet = left.toSet();
  final rightSet = right.toSet();
  return SetDiff(
    id: id,
    added: [
      for (final m in right)
        if (!leftSet.contains(m)) m
    ],
    removed: [
      for (final m in left)
        if (!rightSet.contains(m)) m
    ],
    common: [
      for (final m in left)
        if (rightSet.contains(m)) m
    ],
  );
}
