// 「覆盖不足」面板的文案质量。
//
// 背景（V2.4.9）：用户看着这个面板问「这是什么原因导致的」。逐条查下来发现
// **分析结论没错，是文案本身有问题**：
//
// 1. `android.dex.budget` 只拿到文件名，说不出「扫了多少 / 一共多大 / 几成」；
// 2. 两条说明里带 `**`（Markdown 语法），而界面是纯 `Text` —— 星号原样显示；
// 3. 一条说明里漏出了代码标识符 `includesRuntimeEvidence`。
//
// 这一组钉住：这几条渲染出来**必须是完整的中文句子**，且不含 Markdown 标记
// 与代码标识符。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _render(AnalysisNote note) async {
  await LocaleSettings.setLocaleRaw('zh-CN');
  return AnalysisReport.limitationNoteText(note, t);
}

void main() {
  group('覆盖不足的文案', () {
    test('DEX 扫描预算要说清「扫了多少 / 一共多大 / 几成」', () async {
      // 真实样本的数字：8 MiB 上限 / 17534446 字节。
      const note = AnalysisNote(
        'android.dex.budget',
        'DEX scan budget: classes.dex was only scanned for 8388608 of '
            '17534446 bytes (47%).',
        {
          'name': 'classes.dex',
          'scannedBytes': 8388608,
          'totalBytes': 17534446,
          'percent': 47,
        },
      );

      final text = await _render(note);
      expect(text, contains('classes.dex'));
      expect(text, contains('8388608'));
      expect(text, contains('17534446'));
      expect(text, contains('47'));
      // 不能留占位符，也不能退回英文。
      expect(text, isNot(contains('{')));
      expect(text, contains('扫描预算'));
    });

    test('预算说明缺参数时退回英文，不渲染半截模板', () async {
      // 只给了文件名（V2.4.8 之前的样子）—— 模板要 4 个参数，必须退回。
      const note = AnalysisNote(
        'android.dex.budget',
        'DEX scan budget: classes.dex — partial.',
        {'name': 'classes.dex'},
      );

      final text = await _render(note);
      expect(text, 'DEX scan budget: classes.dex — partial.');
      expect(text, isNot(contains('{')));
    });

    test('界面是纯 Text —— 文案里不能留 Markdown 标记', () async {
      const notes = [
        AnalysisNote('android.dex.method_semantics', ''),
        AnalysisNote('android.native_symbols.semantics', ''),
      ];

      for (final note in notes) {
        final text = await _render(note);
        expect(
          text,
          isNot(contains('**')),
          reason: '${note.code} 的文案里有 Markdown 标记，界面上会原样显示星号',
        );
        expect(text, isNot(contains('__')));
      }
    });

    test('文案里不能漏出代码标识符', () async {
      const note = AnalysisNote('android.offline_static_analysis', '');

      final text = await _render(note);
      expect(text, isNot(contains('includesRuntimeEvidence')));
      expect(text, isNot(contains('bool')));
      expect(text, isNot(contains('false')));
      expect(text, contains('离线静态分析'));
    });

    test('英文界面下不混进中文', () async {
      await LocaleSettings.setLocaleRaw('en');
      const note = AnalysisNote(
        'android.dex.budget',
        'fallback',
        {
          'name': 'classes.dex',
          'scannedBytes': 1,
          'totalBytes': 2,
          'percent': 50,
        },
      );
      final text = AnalysisReport.limitationNoteText(note, t);
      expect(RegExp(r'[\u4e00-\u9fa5]').hasMatch(text), isFalse);
      await LocaleSettings.setLocaleRaw('zh-CN');
    });
  });
}
