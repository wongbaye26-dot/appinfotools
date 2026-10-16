// 字段值的**唯一**呈现实现（`FieldValueText`）。
//
// 背景：在此之前「无值怎么显示」在四处各写了一遍（详情页 Android 卡片、
// 详情页 iOS 卡片、Markdown 报告的「说明」列、差异页），其中三处直接取
// `value.diagnostic` —— 那是硬编码英文，中文界面上就混进了英文句子。
//
// 这一组里有两条**约定守卫**，它们才是这个文件存在的意义：
// 1. 生产代码里出现的每个 `diagnosticCode` 都必须有本地化文案
//    （加了 code 忘了补文案 → 红）；
// 2. 四个渲染点不得再直接读 `value.diagnostic`（又抄一份实现 → 红）。

import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/field_value_text.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _use(String locale) => LocaleSettings.setLocaleRaw(locale);

/// 扫描生产代码里用到的全部 `diagnosticCode`。
///
/// **只看 `lib/` 与 `packages/*/lib/`** —— 测试里也有同名字面量，
/// 把它们算进来会让「生产代码漏了文案」被测试自己的字面量掩盖。
Set<String> _productionCodes() {
  final pattern = RegExp(r"diagnosticCode:\s*'([^']+)'");
  final codes = <String>{};
  final roots = <Directory>[
    Directory('lib'),
    for (final p in Directory('packages').listSync())
      if (p is Directory) Directory('${p.path}/lib'),
  ];
  for (final root in roots) {
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final m in pattern.allMatches(entity.readAsStringSync())) {
        codes.add(m.group(1)!);
      }
    }
  }
  return codes;
}

void main() {
  group('FieldValueText', () {
    test('有值时走格式化函数，不给就直接 toString', () {
      const v = FieldValue<Object?>.extracted(
        21,
        source: FieldSource.builtinParser,
      );
      expect(FieldValueText.describe(v, t), '21');
      expect(
        FieldValueText.describe(v, t, format: (x) => 'SDK $x'),
        'SDK 21',
      );
    });

    test('absent 渲染成 `-`（文件里确实没有）', () {
      expect(
        FieldValueText.describe(const FieldValue<Object?>.absent(), t),
        '-',
      );
    });

    test('「我们没读到」带状态名与原因，两者都不省', () async {
      const v = FieldValue<Object?>.unsupported(
        diagnostic: 'aapt2 does not report maxSdkVersion',
        diagnosticCode: 'source.not_reported',
        diagnosticArgs: {'source': 'aapt2', 'field': 'maxSdkVersion'},
      );

      await _use('zh-CN');
      final zh = FieldValueText.describe(v, t);
      expect(zh, startsWith('[unsupported] '));
      expect(zh, contains('aapt2'));
      expect(zh, contains('maxSdkVersion'));
      // 中文下句子的**框架**必须是中文 —— 这正是这一轮要修的事。
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(zh), isTrue,
          reason: '中文界面下诊断文案仍是英文：$zh');

      await _use('en');
      expect(FieldValueText.describe(v, t), contains('does not report'));
    });

    test('认不出的 code 退回英文原文，不显示空白', () {
      const v = FieldValue<Object?>.failed(
        diagnostic: 'something went wrong',
        diagnosticCode: 'future.unknown_code',
      );
      expect(FieldValueText.diagnostic(v, t), 'something went wrong');
    });

    test('没有 code 时退回英文原文', () {
      const v = FieldValue<Object?>.failed(diagnostic: 'boom');
      expect(FieldValueText.diagnostic(v, t), 'boom');
    });

    test('两者都没有时返回 null —— 不编一个空串出来', () {
      expect(FieldValueText.diagnostic(const FieldValue<Object?>.absent(), t),
          isNull);
    });
  });

  group('约定守卫：诊断文案必须可本地化', () {
    test('生产代码里的每个 diagnosticCode 都有本地化文案', () async {
      final codes = _productionCodes();
      expect(
        codes.length,
        greaterThanOrEqualTo(15),
        reason: '扫到的 code 太少，扫描逻辑可能失效了：$codes',
      );

      // 哨兵：把 fallback 设成一个绝不可能出现在任何语言包里的串。
      // 认得出 code → 渲染本地化文案（≠ 哨兵）；认不出 → 原样返回哨兵。
      const sentinel = '<<UNLOCALIZED-DIAGNOSTIC>>';
      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await _use(locale);
        for (final code in codes) {
          final text = FieldValueText.diagnostic(
            FieldValue<Object?>.failed(
              diagnostic: sentinel,
              diagnosticCode: code,
            ),
            t,
          );
          expect(
            text,
            isNot(sentinel),
            reason: '$locale 下 code「$code」没有本地化文案，退回了英文原文',
          );
          expect(text, isNot(contains('{')),
              reason: '$locale / $code 有未替换的占位符');
          expect(text!.trim(), isNotEmpty, reason: '$locale / $code 是空文案');
        }
      }
      await _use('en');
    });

    test('中文语言包里是中文，英文语言包里没有中文', () async {
      const cjk = r'[\u4e00-\u9fff]';
      final codes = _productionCodes();
      // 这三个的文案本身就是专有名词/文件名，允许不含中文。
      const untranslated = {'privacy_manifest.too_large'};

      await _use('zh-CN');
      final notChinese = <String>[];
      for (final code in codes) {
        final text = FieldValueText.diagnostic(
          FieldValue<Object?>.failed(diagnostic: 'x', diagnosticCode: code),
          t,
        )!;
        if (!RegExp(cjk).hasMatch(text)) notChinese.add('$code → $text');
      }
      expect(
        notChinese.where((s) => !untranslated.any(s.startsWith)).toList(),
        isEmpty,
        reason: '这些 code 在 zh-CN 下不是中文：${notChinese.join(' / ')}',
      );

      await _use('en');
      for (final code in codes) {
        final text = FieldValueText.diagnostic(
          FieldValue<Object?>.failed(diagnostic: 'x', diagnosticCode: code),
          t,
        )!;
        expect(
          RegExp(cjk).hasMatch(text),
          isFalse,
          reason: 'en 下 code「$code」混进了中文：$text',
        );
      }
    });

    test('四个渲染点不再直接读 value.diagnostic', () {
      // 这四处此前各写了一遍渲染，其中三处直接输出 `value.diagnostic`
      // （硬编码英文）。现在统一走 `FieldValueText`，这条守卫防止有人
      // 又在某一处抄一份出来。
      //
      // **先去掉行注释**：说明「以前这里直接读 `value.diagnostic`」的注释
      // 本身会命中这个串，把注释算进来会得到假红（第一次写这条时就踩了）。
      String code(String path) => File(path)
          .readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');

      const sites = [
        'lib/pages/info_page.dart',
        'lib/utils/analysis_report.dart',
        'lib/utils/diff_labels.dart',
      ];
      // 只查**字段访问** `value.diagnostic`，不查方法调用。两次假红都出在
      // 这条太宽的判据上：`.diagnostics`（复数，`AnalysisDiagnostic` 列表）
      // 含这个子串；`FieldValueText.diagnostic(value, t)` 这个**正确**的调用
      // 也含。收窄到 `\bvalue\.diagnostic\b` 两个问题一起消失。
      final readsDiagnostic = RegExp(r'\bvalue\.diagnostic\b');
      for (final path in sites) {
        expect(
          readsDiagnostic.hasMatch(code(path)),
          isFalse,
          reason: '$path 又直接读了 `value.diagnostic` —— 请改用 FieldValueText',
        );
      }
      // JSON 报告是**唯一**例外：它保留原始字段（含英文回退）给程序读，
      // 与「界面/报告显示本地化名字」并不矛盾。
      expect(
        code('lib/utils/diff_report.dart').contains('value.diagnostic'),
        isTrue,
        reason: 'JSON 报告应当保留原始 diagnostic',
      );
    });
  });
}
