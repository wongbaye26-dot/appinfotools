// 解析诊断的本地化（`AnalysisDiagnosticText`）。
//
// 背景：`AnalysisDiagnostic.message` 是硬编码英文，会显示在详情页的
// 「解析诊断」卡片与 Markdown 报告里。更糟的是 **4 条 android.* 的 message
// 原本写的是中文**，方向反了 —— 英文 / 日文 / 韩文报告里混进中文。
//
// 本轮迁移了 **14 个 code**（模板唯一、实参逐条读过源码的）。剩下的
// 43 个还没迁，**退回英文原文**，不会出现半吊子状态。

import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_diagnostic_text.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _use(String locale) => LocaleSettings.setLocaleRaw(locale);

/// 已迁移的 code —— **手工维护的清单**，理由见文件末尾那条测试。
const migrated = <String>{
  'android.manifest_unparsed',
  'android.resource_reference_cycle',
  'android.resource_reference_cycle_truncated',
  'android.split_sampling_truncated',
  'ios.container.no_payload',
  'ios.container.no_main_app',
  'ios.container.multiple_main_apps',
  'ios.info_plist.missing',
  'ios.info_plist.vanished',
  'ios.info_plist.too_large',
  'ios.info_plist.size_lie',
  'ios.info_plist.unparsable',
  'ios.info_plist.not_a_dict',
  'ios.info_plist.parsed',
};

AnalysisDiagnostic _diag(
  String code, {
  Map<String, Object> args = const {},
  String message = 'ENGLISH FALLBACK',
}) =>
    AnalysisDiagnostic.warning(code, message, messageArgs: args);

void main() {
  group('AnalysisDiagnosticText', () {
    test('认得出的 code 走本地化，实参填进模板', () async {
      await _use('zh-CN');
      expect(
        AnalysisDiagnosticText.text(
          _diag('ios.info_plist.missing',
              args: {'path': 'Payload/A.app/Info.plist'}),
          t,
        ),
        'Payload/A.app/Info.plist 里没有 Info.plist',
      );
    });

    test('没有占位符的 code 也走本地化', () async {
      await _use('zh-CN');
      expect(
        AnalysisDiagnosticText.text(_diag('ios.container.no_payload'), t),
        '容器里没有 Payload/ 目录；这不是一个标准 IPA',
      );
    });

    test('认不出的 code 退回英文原文', () async {
      await _use('zh-CN');
      expect(
        AnalysisDiagnosticText.text(
          _diag('ios.macho.unparsable', message: 'could not be parsed'),
          t,
        ),
        'could not be parsed',
      );
    });

    test('模板有占位符但没给实参 → 也退回，不把 {path} 摆给用户', () async {
      // 这条是「绝不出现半吊子状态」的保证：迁移了一半（有模板没 args）
      // 的条目看起来会像拿了个参数化的空壳，比不迁移更难懂。
      await _use('zh-CN');
      expect(
        AnalysisDiagnosticText.text(_diag('ios.info_plist.parsed'), t),
        'ENGLISH FALLBACK',
        reason: '没给 path / keys 却渲染本地化模板，会剩下裸的 {path}',
      );
    });

    test('line 保留机器 id 与严重度 —— 它是排查入口', () async {
      await _use('zh-CN');
      final line = AnalysisDiagnosticText.line(
        _diag('ios.info_plist.missing', args: {'path': 'P'}),
        t,
      );
      expect(line, startsWith('[warning] ios.info_plist.missing: '));
      expect(line, contains('P 里没有 Info.plist'));
    });

    test('每个已迁移的 code 在四个语言包里都能渲染且没有残留占位符', () async {
      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await _use(locale);
        for (final code in migrated) {
          // 给全占位符的实参（名字与模板一致即可，值无所谓）
          final d = _diag(code, args: {
            for (final k in _placeholdersOf(code)) k: '<$k>',
          });
          final text = AnalysisDiagnosticText.text(d, t);
          expect(text, isNot('ENGLISH FALLBACK'),
              reason: '$locale 下 $code 没有本地化文案');
          expect(text, isNot(contains('{')), reason: '$locale / $code 有未替换占位符');
          expect(text.trim(), isNotEmpty, reason: '$locale / $code 是空文案');
        }
      }
      await _use('en');
    });

    test('中文语言包里是中文，英文语言包里没有中文', () async {
      const cjk = r'[\u4e00-\u9fff]';

      await _use('zh-CN');
      for (final code in migrated) {
        final text = AnalysisDiagnosticText.text(
          _diag(code, args: {for (final k in _placeholdersOf(code)) k: '<$k>'}),
          t,
        );
        expect(RegExp(cjk).hasMatch(text), isTrue,
            reason: 'zh-CN 下 $code 不是中文：$text');
      }

      await _use('en');
      for (final code in migrated) {
        final text = AnalysisDiagnosticText.text(
          _diag(code, args: {for (final k in _placeholdersOf(code)) k: '<$k>'}),
          t,
        );
        expect(RegExp(cjk).hasMatch(text), isFalse,
            reason: 'en 下 $code 混进中文：$text');
      }
    });
  });

  group('约定守卫', () {
    test('四个语言包的 analysis_diagnostic 键集完全一致', () {
      // slang 缺键时**静默回退** base locale —— 「补了 en 忘了 zh-TW」
      // 运行时不报错，只是那一句变成英文。直接读文件比对键集。
      final keys = <String, Set<String>>{};
      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        final map = jsonDecode(
          File('assets/i18n/$locale.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        keys[locale] =
            ((map['analysis_diagnostic'] as Map).keys.cast<String>()).toSet();
      }
      final base = keys['en']!;
      for (final locale in keys.keys) {
        expect(keys[locale], base, reason: '$locale 的键集与 en 不一致');
      }
      // 键数必须与已迁移清单一致：多了说明 i18n 加了但渲染层没接；
      // 少了说明某个 code 其实没迁过去。
      expect(base, migrated.map((c) => c.replaceAll('.', '_')).toSet());
    });

    test('渲染点不再直接读 d.message（JSON 出口除外）', () {
      // 详情页的「解析诊断」卡片与 Markdown 报告的表格此前各写一遍，
      // 都直接输出 `diagnostic.message`。现在统一走 AnalysisDiagnosticText。
      // JSON 出口是**唯一例外**：保留原始字段给程序读。
      String code(String path) => File(path)
          .readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final raw = RegExp(r'\bdiagnostic\.message\b|(?<!Text)\.message\b');

      for (final path in const [
        'lib/utils/detail_renderer.dart',
        'lib/pages/info_page.dart',
      ]) {
        expect(
          raw.hasMatch(code(path)),
          isFalse,
          reason:
              '$path 又直接读了 diagnostic.message —— 请改用 AnalysisDiagnosticText',
        );
      }
      expect(
        code('lib/utils/analysis_report.dart').contains("'message': d.message"),
        isTrue,
        reason: 'JSON 出口应当保留原始 message',
      );
    });
  });
}

/// 每个已迁移 code 的占位符名 —— 与 i18n 模板逐条对应。
///
/// 写成函数而不是从模板反解：测试要能独立判断「模板要几个实参」，
/// 而不是依赖被测代码自己说的数量（那就成了自证）。
List<String> _placeholdersOf(String code) => switch (code) {
      'android.manifest_unparsed' => const ['failure'],
      'android.resource_reference_cycle' => const ['cycle'],
      'android.resource_reference_cycle_truncated' => const ['count'],
      'android.split_sampling_truncated' => const ['checked', 'total'],
      'ios.container.multiple_main_apps' => const ['count', 'paths'],
      'ios.info_plist.missing' => const ['path'],
      'ios.info_plist.vanished' => const ['path'],
      'ios.info_plist.too_large' => const ['path', 'size', 'limit'],
      'ios.info_plist.size_lie' => const ['path', 'size', 'decompressed'],
      'ios.info_plist.unparsable' => const ['path', 'message'],
      'ios.info_plist.not_a_dict' => const ['path', 'actual'],
      'ios.info_plist.parsed' => const ['path', 'keys'],
      _ => const <String>[],
    };
