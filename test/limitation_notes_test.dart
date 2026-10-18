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

import 'dart:convert';
import 'dart:io';

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

    test('所有语言包里的每一条：没有 Markdown 标记，也没有代码标识符', () {
      // 界面是纯 `Text`，`**` 会原样显示成星号；`includesRuntimeEvidence`
      // 这类是模型字段名，不该出现在给用户看的句子里。
      //
      // 直接读 JSON 而不是渲染：模板里有占位符，渲染需要构造 args，而这一条
      // 要覆盖**全部** 36 条 × 6 个语言包。
      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW', 'ja', 'ko']) {
        final file = File('assets/i18n/$locale.json');
        expect(file.existsSync(), isTrue, reason: '缺少语言包 $locale');
        final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final notes =
            (map['security'] as Map<String, dynamic>)['limitation_notes']
                as Map<String, dynamic>;
        expect(notes, isNotEmpty, reason: '$locale 没有 limitation_notes');
        notes.forEach((key, value) {
          final text = value as String;
          expect(
            text,
            isNot(contains('**')),
            reason: '$locale / $key 里有 Markdown 标记，界面上会显示星号',
          );
          expect(
            text,
            isNot(contains('includesRuntimeEvidence')),
            reason: '$locale / $key 漏了代码标识符',
          );
        });
      }
    });

    test('加固/清单结构异常的证据也是中文（V2.4.11）', () async {
      // 这 5 条此前是「中文前缀 + 英文正文」，用户两次点名看不懂。
      // 现在各自带 code + 参数，走同一条本地化链路。
      const notes = [
        AnalysisNote(
          'android.container.decoy_entries',
          'f',
          {'count': 159, 'samples': 'AndroidManifest.xml/..xml'},
        ),
        AnalysisNote(
          'android.manifest.attribute_start_nonstandard',
          'f',
          {
            'count': 21,
            'largest': 343,
            'element': 'application',
            'standard': 20
          },
        ),
        AnalysisNote(
          'android.manifest.attribute_size_nonstandard',
          'f',
          {'count': 88, 'largest': 26, 'standard': 20},
        ),
        AnalysisNote(
          'android.manifest.namespace_chunk_nonstandard',
          'f',
          {'count': 1, 'largest': 1476, 'standard': 24},
        ),
        AnalysisNote(
          'android.manifest.unknown_chunk',
          'f',
          {'count': 1, 'chunks': '0x0200 x1'},
        ),
      ];

      for (final note in notes) {
        final text = await _render(note);
        expect(
          text,
          isNot(note.fallback),
          reason: '${note.code} 没有命中本地化模板',
        );
        expect(RegExp(r'[\u4e00-\u9fa5]').hasMatch(text), isTrue,
            reason: '${note.code} 不是中文：$text');
        expect(text, isNot(contains('{')), reason: note.code);
        // 参数确实填进去了（不是把模板原样吐出来）。
        expect(text, isNot(contains('elements declare')), reason: text);
      }
    });

    test('加固证据缺参数时整条回退英文，不渲染半截模板', () async {
      const note = AnalysisNote(
        'android.manifest.attribute_start_nonstandard',
        'fallback text',
        {'count': 21},
      );
      expect(await _render(note), 'fallback text');
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
