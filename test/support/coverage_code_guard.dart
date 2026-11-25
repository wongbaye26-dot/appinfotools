// 覆盖维度 / 覆盖说明的**源码提取器**，供守卫测试使用。
//
// 为什么读源码而不是维护一份手写清单：2.9.0 的守卫把维度清单写死成 16 个，
// 而引擎实际产出 23 个。于是 `android.dex.unicodeStrings` 一直没有本地化名
// （界面与 Markdown 直接显示机器 id），守卫却全绿。手写清单等于把「记得同步」
// 这个人类动作当成门禁，而它已经失败过一次。
//
// 提取规则只认审计引擎里的两种字面量：
//   - 覆盖维度：`CoverageEntry.noted(id: 'android.dex.strings', ...)`
//   - 覆盖说明：`note:` 位置上的 `('android.dex.no_content', 'English…', {...})`
//   - 局限说明：`AnalysisNote('android.dex.dynamic_loading', 'English…')`
//
// 说明用的元组与 `AnalysisNote(...)` 在语法上都是「括号 + 字符串 + 逗号 +
// 字符串」，因此 `coverage` = 前者减去后者。

import 'dart:io';

/// 产出覆盖维度与说明的两个审计引擎。
const _engineSources = <String>[
  'packages/apk_parser/lib/src/security/android_security_audit.dart',
  'packages/ipa_parser/lib/src/security/ios_privacy_audit.dart',
];

/// 匹配 `id: 'android.xxx'`。
final _dimensionPattern = RegExp(r"id:\s*'((?:android|ios)\.[A-Za-z0-9_.]+)'");

/// 匹配「括号 + code + 逗号 + 英文正文」—— 覆盖说明元组与 `AnalysisNote` 都命中。
final _tuplePattern =
    RegExp(r"\(\s*'((?:android|ios)\.[A-Za-z0-9_.]+)'\s*,\s*'");

/// 匹配 `AnalysisNote('code', ...)`。
final _analysisNotePattern = RegExp(r"AnalysisNote\(\s*'([^']+)'");

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    // 相对路径依赖 `flutter test` 的工作目录是仓库根。路径变了要立刻报错，
    // 否则守卫会「提取到 0 个 code」然后静默通过。
    throw StateError('找不到引擎源码 $path（工作目录应为仓库根）');
  }
  return file.readAsStringSync();
}

/// 引擎实际产出的全部覆盖维度 id。
Set<String> engineCoverageDimensionIds() {
  final ids = <String>{};
  for (final path in _engineSources) {
    for (final match in _dimensionPattern.allMatches(_read(path))) {
      ids.add(match.group(1)!);
    }
  }
  return ids;
}

/// 引擎产出的全部**覆盖说明** code（`CoverageEntry.noteCode`）。
Set<String> engineCoverageNoteCodes() {
  final tuples = <String>{};
  final analysisNotes = <String>{};
  for (final path in _engineSources) {
    final source = _read(path);
    for (final match in _tuplePattern.allMatches(source)) {
      tuples.add(match.group(1)!);
    }
    for (final match in _analysisNotePattern.allMatches(source)) {
      analysisNotes.add(match.group(1)!);
    }
  }
  return tuples.difference(analysisNotes);
}

/// 引擎产出的全部**局限说明** code（`AnalysisNote.code`）。
Set<String> engineAnalysisNoteCodes() {
  final codes = <String>{};
  for (final path in _engineSources) {
    for (final match in _analysisNotePattern.allMatches(_read(path))) {
      codes.add(match.group(1)!);
    }
  }
  return codes;
}
