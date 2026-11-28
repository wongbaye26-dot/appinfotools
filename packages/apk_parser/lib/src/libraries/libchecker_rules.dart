/// LibChecker 规则集：`portable-v5` 数据在 Dart 侧的只读视图。
///
/// 规则来自 <https://github.com/LibChecker/LibChecker-Rules>（Apache-2.0），
/// 由 `tool/sync_libchecker_rules.py` 转成紧凑 bundle 后随应用分发。这里**不**
/// 联网、也不改规则：更新是换掉整个 `assets/libchecker/libchecker_v5.zip`。
///
/// 匹配语义必须与上游一致（否则会「看着有库却没识别出来」）：
/// 1. 先按 `name` 精确匹配 —— **包括**正则规则的 `name` 字面值；
/// 2. 找不到再按 `(priority, id)` 升序逐条试正则；
/// 3. 名字里含换行/段落分隔符时**跳过正则**：上游的正则按整串匹配，而这类
///    字符在 Android 组件名里不可能出现，放行只会浪费编译与匹配时间。
library;

/// 规则类型编号（与上游 `LibChecker-Rules` 的 `type` 一致）。
class LibCheckerRuleType {
  static const native = 0;
  static const service = 1;
  static const activity = 2;
  static const receiver = 3;
  static const provider = 4;
  static const dex = 5;

  /// `static` 规则：上游保留但当前 runner 不使用（数据里仍有 14 条）。
  static const staticRule = 6;
  static const permission = 7;
  static const metadata = 8;

  /// intent-filter 的 action 名（组件匹配的兜底路径）。
  static const action = 9;

  /// 本工具参与匹配的类型。`permission` / `metadata` / `static` 不参与 ——
  /// 参考实现也没有用它们，凭空接入只会多出一批无法解释的命中。
  static const supported = {
    native,
    service,
    activity,
    receiver,
    provider,
    dex,
    action,
  };
}

class LibCheckerRule {
  const LibCheckerRule({
    required this.id,
    required this.name,
    required this.label,
    required this.type,
    required this.iconId,
    required this.simpleColorIcon,
    required this.isRegex,
    required this.detailIndex,
    required this.priority,
  });

  final int id;

  /// 匹配串：原生库是 `.so` 文件名，组件是完整类名，DEX 是包名前缀，
  /// 正则规则时是正则**源码**（不是符号名 —— 上游 `regexName` 只是键）。
  final String name;
  final String label;
  final int type;
  final String? iconId;
  final bool simpleColorIcon;
  final bool isRegex;

  /// 详情下标（`-1` 表示这条规则没有详情）。
  final int detailIndex;

  /// 排序权重。当前数据里 `priority == id`，仍然单独保留：上游若将来改掉，
  /// 匹配顺序要跟着变，而不是悄悄退化成按 id 排。
  final int priority;
}

/// 一条规则的详情文案（按语言）。
class LibCheckerDetail {
  const LibCheckerDetail({
    required this.label,
    required this.developer,
    required this.description,
    required this.sourceLink,
    required this.contributors,
  });

  final String? label;
  final String? developer;
  final String? description;
  final String? sourceLink;
  final List<String> contributors;
}

class _TypeIndex {
  final Map<String, LibCheckerRule> exact = {};
  final List<(RegExp, LibCheckerRule)> regex = [];
}

/// 规则集：按类型分索引，正则只编译一次。
class LibCheckerRules {
  LibCheckerRules._({
    required this.dataVersion,
    required this.sourceRevision,
    required this.rules,
    required List<Map<String, LibCheckerDetail>> details,
    required Map<int, _TypeIndex> index,
    required this.regexCompileFailures,
  })  : _details = details,
        _index = index;

  final int dataVersion;
  final String? sourceRevision;
  final List<LibCheckerRule> rules;

  /// 编译失败的正则 id（正常数据为空；留着是为了让「规则数据坏了」可见，
  /// 而不是静默少匹配几条）。
  final List<String> regexCompileFailures;

  final List<Map<String, LibCheckerDetail>> _details;
  final Map<int, _TypeIndex> _index;

  /// 参与匹配的规则数（去掉 `static` 之类不参与的类型）。
  int get usableRuleCount => rules.length;

  /// 从 bundle JSON 构建。`rules` 的每一项是 7 元组：
  /// `[id, name, label, type, iconId, isSimpleColorIcon, detailIndex]`。
  factory LibCheckerRules.fromBundle(Map<String, dynamic> bundle) {
    final meta =
        (bundle['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final regexIds = {
      for (final id in (bundle['regexIds'] as List? ?? const [])) id as int,
    };
    final rawRules = (bundle['rules'] as List).cast<List<dynamic>>();

    final rules = <LibCheckerRule>[];
    for (final row in rawRules) {
      final type = row[3] as int;
      if (!LibCheckerRuleType.supported.contains(type)) continue;
      rules.add(LibCheckerRule(
        id: row[0] as int,
        name: row[1] as String,
        label: row[2] as String,
        type: type,
        iconId: row[4] as String?,
        simpleColorIcon: (row[5] as int? ?? 0) != 0,
        isRegex: regexIds.contains(row[0] as int),
        detailIndex: (row[6] as int?) ?? -1,
        priority: row.length > 7 ? row[7] as int : row[0] as int,
      ));
    }
    rules.sort((a, b) {
      final byPriority = a.priority.compareTo(b.priority);
      return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
    });

    final index = <int, _TypeIndex>{};
    final failures = <String>[];
    for (final rule in rules) {
      final bucket = index.putIfAbsent(rule.type, _TypeIndex.new);
      // 精确表收**所有**规则（含正则规则的字面名），与上游一致。
      bucket.exact.putIfAbsent(rule.name, () => rule);
      if (!rule.isRegex) continue;
      try {
        final pattern = '^(?:${_normalizeDigitClass(rule.name)})\$';
        bucket.regex.add((RegExp(pattern, unicode: true), rule));
      } on FormatException catch (e) {
        failures.add('${rule.id}: ${e.message}');
      }
    }

    final details = <Map<String, LibCheckerDetail>>[
      for (final entry in (bundle['details'] as List? ?? const []))
        _decodeDetail((entry as Map).cast<String, dynamic>()),
    ];

    return LibCheckerRules._(
      dataVersion: (meta['dataVersion'] as int?) ?? 0,
      sourceRevision: meta['sourceRevision']?.toString(),
      rules: rules,
      details: details,
      index: index,
      regexCompileFailures: failures,
    );
  }

  /// 精确 → 正则的查找。`useRegex=false` 时只走精确表（组件 action、DEX
  /// 包前缀的上级包查找都要求这种「只认全等」的语义）。
  LibCheckerRule? find(int type, String name, {bool useRegex = true}) {
    final bucket = _index[type];
    if (bucket == null) return null;
    final exact = bucket.exact[name];
    if (exact != null) return exact;
    if (!useRegex) return null;
    for (final terminator in _lineTerminators) {
      if (name.contains(terminator)) return null;
    }
    for (final (regex, rule) in bucket.regex) {
      if (regex.hasMatch(name)) return rule;
    }
    return null;
  }

  /// 规则详情。`locale` 传 `zh-Hans` / `en`；缺失时依次退回 `en` 与第一项。
  ///
  /// 注意详情里的 `label` 与规则表里的 `label` **不保证相同**（上游有 179 条
  /// 不一致）：列表以规则表为准，详情页可显示详情里的本地化标签。
  LibCheckerDetail? detailFor(LibCheckerRule rule, String locale) {
    if (rule.detailIndex < 0 || rule.detailIndex >= _details.length) {
      return null;
    }
    final entry = _details[rule.detailIndex];
    return entry[locale] ?? entry['en'] ?? (entry.isEmpty ? null : entry.values.first);
  }

  /// 按类型统计（测试与「规则版本」提示用）。
  Map<int, int> countByType() {
    final counts = <int, int>{};
    for (final rule in rules) {
      counts[rule.type] = (counts[rule.type] ?? 0) + 1;
    }
    return counts;
  }

  static Map<String, LibCheckerDetail> _decodeDetail(Map<String, dynamic> entry) {
    final decoded = <String, LibCheckerDetail>{};
    for (final locale in entry.keys) {
      final values = entry[locale];
      if (values is! List) continue;
      decoded[locale] = LibCheckerDetail(
        label: _stringAt(values, 0),
        developer: _stringAt(values, 1),
        description: _stringAt(values, 2),
        sourceLink: _stringAt(values, 3),
        contributors: [
          for (final item in (values.length > 4 ? values[4] as List? : null) ??
              const [])
            if (item is String) item,
        ],
      );
    }
    return decoded;
  }

  static String? _stringAt(List values, int index) {
    if (index >= values.length) return null;
    final value = values[index];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// 上游对 `\d` 做词法归一：正则按 Unicode 模式编译，而 Dart 的 `\d`
  /// 只匹配 ASCII —— 数据里的 `\d` 恰好都想要「数字」，统一换成显式区间，
  /// 避免「同一份规则在不同运行时匹配出不同结果」。
  ///
  /// 转义、字符类的处理逐字符进行：`\\d` 是字面反斜杠 + d，不能改；字符类
  /// 里要塞 `0-9` 而不是 `[0-9]`；`[` 出现在字符类内部要转义。
  static String _normalizeDigitClass(String pattern) {
    final out = StringBuffer();
    var inClass = false;
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == r'\') {
        if (i + 1 < pattern.length) {
          final next = pattern[i + 1];
          i++;
          if (next == 'd') {
            out.write(inClass ? '0-9' : '[0-9]');
          } else {
            out
              ..write(r'\')
              ..write(next);
          }
        } else {
          out.write(r'\');
        }
      } else if (c == '[' && inClass) {
        out.write(r'\[');
      } else if (c == '[') {
        inClass = true;
        out.write('[');
        if (i + 1 < pattern.length && pattern[i + 1] == '^') {
          out.write('^');
          i++;
        }
      } else if (c == ']' && inClass) {
        inClass = false;
        out.write(']');
      } else if (inClass &&
          (c == '&' || c == '-' || c == '~') &&
          i + 1 < pattern.length &&
          pattern[i + 1] == c) {
        out
          ..write(r'\')
          ..write(c);
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  /// 名字里出现这些字符就跳过正则：上游用整串匹配，而它们会把一条正则的
  /// 匹配范围扩到多行 —— Android 组件名/包名不可能含这些字符。
  static const _lineTerminators = ['\n', '\r', '\u0085', '\u2028', '\u2029'];
}
