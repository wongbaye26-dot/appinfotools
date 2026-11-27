// 覆盖说明 / 局限说明的**注册守卫**。
//
// 背景（2026-11-09 审计 P1-2 / P1-3）：引擎产出的 code 只要在呈现层的
// switch 里没有 case，就会回退到英文原文 —— 中文界面上出现英文句子，而
// 既有测试全绿。`android.dex.dynamic_loading`（「运行时加载的 DEX 不在
// 本次分析范围」）就这样在 6 种语言里全是英文；Android 的 4 条 Unicode
// 覆盖说明同样漏接。
//
// 做法：从引擎源码提取全部 code，用哨兵字符串构造 note，断言呈现层没有
// 回退到哨兵。新增 code 却忘了补文案时会红，且不需要手工同步清单 ——
// 手写清单正是上一轮漏检的原因。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/coverage_code_guard.dart';

/// 认不出 code 时呈现层会返回这段原文；取到它就说明没命中本地化表。
const _sentinel = '\u0000not-localized';

/// 覆盖说明的占位符实参。
///
/// 呈现层在**缺参**时会返回 null 并回退英文（例如 `count == null`），所以这里
/// 给一份「所有键都在」的超集。每个模板只读自己需要的键，多余的键不影响结果。
const _args = <String, Object>{
  'count': 2,
  'total': 3,
  'reason': 'because',
  'functions': 1,
  'attributed': 1,
  'name': 'libfoo.so',
  'names': ['libfoo.so'],
  'bytes': 1024,
  'limit': 2048,
  'limitMiB': 8,
  'scannedBytes': 512,
  'totalBytes': 1024,
  'percent': '50%',
  'dexCount': 2,
  'code': 'bad',
  'message': 'malformed',
  'anomaly': 'detail',
  'samples': ['assets/x'],
  'largest': 'assets/x',
  'element': 'application',
  'standard': 4,
  'truncated': 1,
  'failed': 1,
  'path': 'assets/x',
  'size': 64,
  'cryptid': 1,
  'probed': 2,
  'nodes': 3,
  'edges': 4,
  'covered': 2,
  'audited': 2,
};

Future<void> _use(String locale) => LocaleSettings.setLocaleRaw(locale);

void main() {
  group('覆盖说明', () {
    final codes = engineCoverageNoteCodes();

    test('提取器能取到引擎的说明 code', () {
      // 正则失效会提取到 0 个 code，下面的循环一次都不跑、测试照样「通过」。
      expect(codes.length, greaterThan(30),
          reason: '从引擎源码提取到的说明 code 太少，提取器可能已失效');
      expect(codes, contains('android.dex.unicode_strings.scope'));
    });

    test('每一条在四个维护中的语言包里都有模板，且不留占位符', () async {
      addTearDown(() => _use('en'));
      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await _use(locale);
        for (final code in codes) {
          final entry = CoverageEntry(
            id: 'guard',
            status: CoverageStatus.partial,
            note: _sentinel,
            noteCode: code,
            noteArgs: _args,
          );
          final text = AnalysisReport.coverageNote(entry, t);
          expect(text, isNot(_sentinel),
              reason: '$locale 下 $code 没有本地化模板，回退成了英文原文');
          expect(text, isNot(contains('{')), reason: '$locale / $code：$text');
          expect(text, isNot(contains('}')), reason: '$locale / $code：$text');
        }
      }
    });

    test('中文语言包不是英文原文的复制', () async {
      addTearDown(() => _use('en'));
      await _use('en');
      final english = {
        for (final code in codes)
          code: AnalysisReport.coverageNote(
            CoverageEntry(
              id: 'guard',
              status: CoverageStatus.partial,
              note: _sentinel,
              noteCode: code,
              noteArgs: _args,
            ),
            t,
          ),
      };
      await _use('zh-CN');
      for (final code in codes) {
        final text = AnalysisReport.coverageNote(
          CoverageEntry(
            id: 'guard',
            status: CoverageStatus.partial,
            note: _sentinel,
            noteCode: code,
            noteArgs: _args,
          ),
          t,
        );
        expect(text, isNot(english[code]),
            reason: '$code 在 zh-CN 下与英文完全相同，可能只是复制了原文');
      }
    });
  });

  group('局限说明', () {
    final codes = engineAnalysisNoteCodes();

    test('提取器能取到引擎的局限 code', () {
      expect(codes.length, greaterThan(20),
          reason: '从引擎源码提取到的局限 code 太少，提取器可能已失效');
      expect(codes, contains('android.dex.dynamic_loading'));
    });

    test('每一条在四个维护中的语言包里都有模板，且不留占位符', () async {
      addTearDown(() => _use('en'));
      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await _use(locale);
        for (final code in codes) {
          final text = AnalysisReport.limitationNoteText(
              AnalysisNote(code, _sentinel, _args), t);
          expect(text, isNot(_sentinel),
              reason: '$locale 下 $code 没有本地化模板，回退成了英文原文');
          expect(text, isNot(contains('{')), reason: '$locale / $code：$text');
          expect(text, isNot(contains('}')), reason: '$locale / $code：$text');
        }
      }
    });

    test('中文语言包不是英文原文的复制', () async {
      addTearDown(() => _use('en'));
      await _use('en');
      final english = {
        for (final code in codes)
          code: AnalysisReport.limitationNoteText(
              AnalysisNote(code, _sentinel, _args), t),
      };
      await _use('zh-CN');
      for (final code in codes) {
        final text = AnalysisReport.limitationNoteText(
            AnalysisNote(code, _sentinel, _args), t);
        expect(text, isNot(english[code]),
            reason: '$code 在 zh-CN 下与英文完全相同，可能只是复制了原文');
      }
    });
  });
}
