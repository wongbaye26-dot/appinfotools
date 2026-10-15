/// 一条覆盖维度的状态。
///
/// **四态必须分开渲染**：把「部分覆盖」显示成「已覆盖」会让读者以为结论是
/// 完整的；把「本次不适用」显示成「未覆盖」则会让报告凭空多出一堆假缺口。
enum CoverageStatus {
  /// 完整覆盖。
  covered,

  /// **部分**覆盖：有预算截断，或只覆盖了一部分文件 / 字节。
  partial,

  /// **完全没覆盖**：读不到、不支持，或本次未执行。
  ///
  /// 与 [partial] 分开是因为补救方式不同：部分覆盖要「扩大预算」，
  /// 完全没覆盖要「先让这一步跑起来」。
  notCovered,

  /// 本次**不适用**（例如 Android 报告里的 iOS 维度）。
  ///
  /// 不计入缺口 —— 它不是「没查到」，是「这件事在这个平台上不存在」。
  notApplicable;

  String get label => switch (this) {
        CoverageStatus.covered => 'covered',
        CoverageStatus.partial => 'partially covered',
        CoverageStatus.notCovered => 'not covered',
        CoverageStatus.notApplicable => 'not applicable',
      };
}

/// 一条覆盖说明的三件套：稳定 code / 英文回退文本 / 占位符实参。
///
/// 命名规则：`<平台>.<维度>.<原因>`，全小写下划线；把 `.` 换成 `_`
/// 就是语言包里的键名。
typedef CoverageNote = (String, String, Map<String, Object>);

/// 一条覆盖维度。
///
/// 存在的意义是把覆盖率从「散落各处的说明文本」收敛成**结构化数据**：
/// 之前「覆盖了什么」分散在 `limitations` 的句子、各扫描器的 `truncated`
/// 标志、以及个别发现项里，UI 与报告只能各自去猜。
class CoverageEntry {
  /// 稳定标识，例如 `android.dex.strings`。
  ///
  /// UI 用它映射到本地化文案；**不要**用 [note] 做判断 —— 那是给人看的说明，
  /// 措辞会变。
  final String id;

  final CoverageStatus status;

  /// 实际覆盖的量（字节 / 条目数 / 文件数）。
  ///
  /// 不适用或无法量化时为 `null` —— 不编一个 0 出来，0 会被读成「一个都没覆盖」。
  final int? covered;

  /// 覆盖上限；没有上限时为 `null`。
  final int? limit;

  /// 说明：截断原因、读不到的原因。
  ///
  /// 完整覆盖时通常为 `null`。**这是机器语言（英文）的自由文本**，用于日志与
  /// JSON；界面与报告应当优先用 [noteCode] 走本地化（见 [AnalysisReport]）。
  ///
  /// 之所以留一个自由文本字段：`noteCode` 认不出来时（新引擎 + 旧界面）
  /// 至少要能显示**某句话**，而不是一片空白 —— 那会让「没覆盖」看起来像
  /// 「没什么可说的」。
  final String? note;

  /// 说明的**稳定标识**，例如 `android.dex.strings_not_fully_scanned`。
  ///
  /// 引擎层（`apk_parser` / `ipa_parser`）不依赖 slang，产不出本地化文案，
  /// 因此这里给的是**可映射的 id**：呈现层按它取本地化文案。
  ///
  /// 命名规则：`<平台>.<维度>.<原因>`，全小写下划线；把 `.` 换成 `_`
  /// 就是语言包里的键名。为 `null` 时呈现层回退到 [note]。
  final String? noteCode;

  /// [noteCode] 的占位符实参，例如 `{'count': 3}`。
  ///
  /// 值用 `Object` 而不是 `String`：数量这类东西在 JSON 里应当是数字，
  /// 由呈现层决定怎么显示。
  final Map<String, Object> noteArgs;

  const CoverageEntry({
    required this.id,
    required this.status,
    this.covered,
    this.limit,
    this.note,
    this.noteCode,
    this.noteArgs = const {},
  });

  /// 从一个「三件套」建条目 —— [note] / [noteCode] / [noteArgs] 同进同退。
  ///
  /// 引擎层（`apk_parser` / `ipa_parser`）不依赖 slang，只能给出稳定 code +
  /// 英文回退 + 参数；用这个工厂把三件事绑在一起，避免「改了一处漏了另一处」
  /// —— 只给 note 会让界面显示英文，只给 code 而语言包缺键会显示空白。
  factory CoverageEntry.noted({
    required String id,
    required CoverageStatus status,
    int? covered,
    int? limit,
    CoverageNote? note,
  }) =>
      CoverageEntry(
        id: id,
        status: status,
        covered: covered,
        limit: limit,
        note: note?.$2,
        noteCode: note?.$1,
        noteArgs: note?.$3 ?? const {},
      );

  /// 该维度是否是**缺口**（部分覆盖或完全没覆盖）。
  bool get isGap =>
      status == CoverageStatus.partial || status == CoverageStatus.notCovered;

  /// 覆盖比例的文本形式；无法量化时为 `null`。
  String? get ratioText {
    if (covered == null || limit == null || limit == 0) return null;
    return '$covered/$limit';
  }

  @override
  String toString() =>
      'CoverageEntry($id, ${status.name}${ratioText == null ? '' : ' $ratioText'})';
}

/// 一次分析的覆盖报告。
class AnalysisCoverage {
  final List<CoverageEntry> entries;

  const AnalysisCoverage({this.entries = const []});

  /// 是否存在缺口（部分覆盖或完全没覆盖）。
  ///
  /// [CoverageStatus.notApplicable] **不算**缺口 —— 它不是「没查到」。
  bool get hasGaps => entries.any((e) => e.isGap);

  /// 本次**适用**的维度（不含 notApplicable）。
  List<CoverageEntry> get applicable => [
        for (final e in entries)
          if (e.status != CoverageStatus.notApplicable) e
      ];

  /// 有缺口的维度。
  List<CoverageEntry> get gaps => [
        for (final e in entries)
          if (e.isGap) e
      ];

  /// 按 id 取条目；没有时返回 `null`。
  CoverageEntry? entry(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  bool get isEmpty => entries.isEmpty;

  /// 合并两份覆盖报告。
  ///
  /// 同一个 id 出现两次时**保留更差的那一条**：覆盖是「木桶」——
  /// 同一维度被两条路径覆盖过，只要有一条没覆盖完，整体就没覆盖完。
  AnalysisCoverage merge(AnalysisCoverage other) {
    final byId = <String, CoverageEntry>{};
    for (final e in entries) {
      byId[e.id] = e;
    }
    for (final e in other.entries) {
      final existing = byId[e.id];
      byId[e.id] = existing == null ? e : _worse(existing, e);
    }
    return AnalysisCoverage(entries: byId.values.toList());
  }

  /// 取状态更差的一条（covered < partial < notCovered；notApplicable 最弱）。
  static CoverageEntry _worse(CoverageEntry a, CoverageEntry b) {
    final rank = <CoverageStatus, int>{
      CoverageStatus.notApplicable: 0,
      CoverageStatus.covered: 1,
      CoverageStatus.partial: 2,
      CoverageStatus.notCovered: 3,
    };
    final ra = rank[a.status]!;
    final rb = rank[b.status]!;
    if (ra != rb) return ra >= rb ? a : b;
    // 状态相同时保留覆盖量更小的那条（同样体现「木桶」）。
    final ca = a.covered ?? 1 << 62;
    final cb = b.covered ?? 1 << 62;
    return ca <= cb ? a : b;
  }

  @override
  String toString() => 'AnalysisCoverage(${entries.length} entries, '
      '${gaps.length} gaps)';
}
