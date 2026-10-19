// 引擎产出的 code **必须**在 `AnalysisReport` 对应的 switch 里有分支。
//
// ## 为什么需要这条守卫
//
// `SecurityFinding` 的四段文案（finding / recommendation / relationship /
// limitation）都是「稳定 code + 英文回退」：引擎给 code，呈现层按 code 查
// 本地化模板，**认不出就回退英文原文**。这个设计本身是对的，但漏注册的后果
// 是静默的 —— 编译通过、界面只是显示英文。
//
// 2026-10-19 审计实测：7 个 code 产出但未注册，其中 `IOS-NATIVE-SYMBOLS`
// 是唯一真实 iOS 样本上**必然出现**的发现项，它的 limitation（251 字符）与
// recommendation 在中文报告里是英文。而 `i18n_coverage_test` 只比「语言包
// 键集 ↔ 语言包键集」，看不到这一层。
//
// ## 这条守卫能看见什么、看不见什么
//
// 看见：`messageCode:` / `recommendationCode:` / `limitationCode:` /
// `relationshipCode:` 后面（含换行后的三元分支）的字面量 code。
// 看不见：由助手函数间接返回的 code（例如 `_exportedMessageCode()` 里
// `return 'android.exported_component_weak'`）。这类目前都注册着，但守卫
// 不会替它兜底 —— 新写这类助手时要自己确认。
//
// 断言的是**归属**而不只是「注册过」：`messageCode` 必须出现在
// `findingText` 的 switch 里，`limitationCode` 必须出现在 `limitationText`
// 里。放错 switch 与漏注册同样会渲染成英文。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一个 code 字段名 → 它应该在哪个函数里被处理。
const _fieldToFunction = {
  'messageCode': 'findingText',
  'recommendationCode': 'recommendationText',
  'relationshipCode': 'relationshipText',
  'limitationCode': 'limitationText',
};

/// 从 `analysis_report.dart` 里截出某个函数内 `switch (code)` 的分支区。
String _switchBody(String source, String functionName) {
  final decl = RegExp(
    r'static String\?? ' + functionName + r'\(SecurityFinding',
  ).firstMatch(source);
  if (decl == null) {
    fail('analysis_report.dart 里找不到 $functionName —— 守卫需要同步更新');
  }
  final from = decl.start;
  final sw = source.indexOf('switch (code)', from);
  if (sw < 0) fail('$functionName 里没有 switch (code)');
  final end = source.indexOf('_ =>', sw);
  if (end < 0) fail('$functionName 的 switch 没有兜底分支');
  return source.substring(sw, end);
}

/// 分支里出现的 code 字面量。
Set<String> _registeredCodes(String body) => {
      for (final m in RegExp(r"'([a-z0-9_.]+)'\s*=>").allMatches(body))
        m.group(1)!,
    };

/// 引擎里通过四个字段产出的 code（含换行后的三元分支）。
///
/// 取字段名之后 200 个字符内的 `android.*` / `ios.*` 字面量 —— 足够覆盖
/// `cond\n ? 'a'\n : 'b'` 这种换行写法，又不会误收同文件里别的字符串。
Map<String, Set<String>> _engineCodes() {
  final result = <String, Set<String>>{
    for (final field in _fieldToFunction.keys) field: <String>{},
  };
  final files = [
    ...Directory('packages').listSync(recursive: true).whereType<File>().where(
        (f) =>
            f.path.endsWith('.dart') &&
            f.path.contains('/lib/') &&
            !f.path.contains('/test/')),
    ...Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart')),
  ];

  final pattern = RegExp(
    r'(messageCode|recommendationCode|relationshipCode|limitationCode):',
  );
  final literal = RegExp(r"'(android|ios)\.[a-z0-9_.]+'");
  for (final file in files) {
    final source = file.readAsStringSync();
    for (final m in pattern.allMatches(source)) {
      final field = m.group(1)!;
      // **只取这个字段的值表达式**，到第一个行尾逗号为止。
      //
      // 试过两种边界都不对：固定 200 字符窗口会把紧邻字段的值算进来；
      // 「下一个同缩进字段名」在最后一个字段上找不到边界，反而吞掉下一条
      // 发现项的 messageCode。这四个字段的值只有「字符串 / 三元」两种形状，
      // 内部不会出现「逗号 + 换行」，所以行尾逗号是可靠终点。
      final comma = source.indexOf(',\n', m.end);
      final end = comma < 0 ? (m.end + 200).clamp(0, source.length) : comma;
      final value = source.substring(m.end, end);
      for (final lit in literal.allMatches(value)) {
        result[field]!.add(lit.group(0)!.replaceAll("'", ''));
      }
    }
  }
  return result;
}

void main() {
  test('引擎产出的每个 code 都在对应的 switch 里有分支', () {
    final report = File('lib/utils/analysis_report.dart').readAsStringSync();
    final registered = {
      for (final entry in _fieldToFunction.entries)
        entry.key: _registeredCodes(_switchBody(report, entry.value)),
    };

    final produced = _engineCodes();
    final missing = <String>[];
    for (final field in _fieldToFunction.keys) {
      for (final code in produced[field]!) {
        if (!registered[field]!.contains(code)) {
          missing.add('$field: $code（应在 ${_fieldToFunction[field]} 里）');
        }
      }
    }

    expect(
      missing,
      isEmpty,
      reason: '这些 code 引擎会产出但呈现层认不出，界面与报告会静默显示英文：\n'
          '${missing.join('\n')}',
    );
  });

  test('守卫自身是有效的：至少扫到了三位数的 code', () {
    // 防止「正则写坏了 → 一个都没扫到 → 断言空集恒过」这种假绿。
    final produced = _engineCodes();
    final total = produced.values.fold<int>(0, (sum, s) => sum + s.length);
    expect(total, greaterThan(100), reason: '只扫到 $total 个 code，正则很可能坏了');
    for (final field in _fieldToFunction.keys) {
      expect(produced[field], isNotEmpty, reason: '$field 一个都没扫到');
    }
  });
}
