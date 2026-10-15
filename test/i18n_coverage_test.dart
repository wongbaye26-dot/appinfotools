// 界面文案必须真的随语言切换。
//
// 背景：概览页曾经整页都是硬编码英文 —— 中文界面下照样显示英文，而当时
// 没有任何测试覆盖到它。分析页的 Tab 名、导出对话框、安全卡片的置信度
// 标签同理。
//
// 注意语言包是 **deferred（懒加载）** 的：只能用异步的 `setLocaleRaw` 并
// await。`setLocaleRawSync` 会直接抛「Deferred library l_zh_CN was not
// loaded」，不 await 则拿到的还是上一个语言 —— 两种情况都会让这类断言
// 变成假通过或假失败。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _use(String locale) => LocaleSettings.setLocaleRaw(locale);

void main() {
  group('文案随语言切换', () {
    test('概览页', () async {
      await _use('en');
      expect(t.overview.statistics, 'Statistics');
      expect(t.overview.quick_actions, 'Quick Actions');
      expect(t.overview.release_to_analyze, 'Release to Analyze');

      await _use('zh-CN');
      expect(t.overview.statistics, '统计');
      expect(t.overview.quick_actions, '快捷操作');
      expect(t.overview.release_to_analyze, '松开以分析');

      await _use('ja');
      expect(t.overview.statistics, '統計');
    });

    test('详情页 Tab 名', () async {
      await _use('en');
      expect(t.detail_tab.overview, 'Overview');
      expect(t.detail_tab.security, 'Security');

      await _use('zh-CN');
      expect(t.detail_tab.overview, '概览');
      expect(t.detail_tab.security, '安全');
    });

    test('导出对话框', () async {
      await _use('en');
      expect(t.report.full_report, 'Full Report');
      expect(t.report.security_only, 'Security Only');

      await _use('zh-CN');
      expect(t.report.full_report, '完整报告');
      expect(t.report.security_only, '仅安全检测');
    });

    test('安全发现项的置信度标签', () async {
      await _use('en');
      expect(t.security.confidence_capability, 'Capability only');

      await _use('zh-CN');
      expect(t.security.confidence_capability, '仅具备能力');
    });

    test('报告里的「未执行安全检测」与图标导出错误', () async {
      await _use('en');
      expect(
        t.report.limitation_security,
        'Security audit was not performed for this package.',
      );
      expect(t.icon.error_svg_conversion, 'SVG conversion failed');

      await _use('zh-CN');
      expect(t.report.limitation_security, '未对该应用包执行安全检测。');
      expect(t.icon.error_svg_conversion, 'SVG 转换失败');
    });

    test('设置页的标题宽度示例文案', () async {
      await _use('en');
      expect(t.settings.title_width_sample, contains('sample'));

      await _use('zh-CN');
      expect(t.settings.title_width_sample, contains('示例'));
    });

    test('带占位符的文案两种语言都能取到', () async {
      await _use('en');
      expect(
        t.overview.last_analyzed(name: 'demo.apk'),
        'Last analyzed: demo.apk',
      );

      await _use('zh-CN');
      expect(
        t.overview.last_analyzed(name: 'demo.apk'),
        '最近分析：demo.apk',
      );
    });
  });

  // 覆盖维度名（阶段 1.3 / 阶段 3.3 的验收条件）。
  //
  // 引擎产出的是**机器 id**（`android.dex.strings` 这类，JSON 里保留它给程序读），
  // 但 UI 与 Markdown 必须显示可读文案。两个引擎合计 15 个维度。
  group('覆盖维度名', () {
    /// 引擎产出的全部维度 id。新增维度时**必须**同步这里 ——
    /// 这条测试的意义正是「新增了维度却忘了补文案」会红。
    const ids = [
      'android.manifest',
      'android.permissions',
      'android.dex.structure',
      'android.dex.strings',
      'android.dex.methodReferences',
      'android.dex.callSites',
      'android.nativeSymbols',
      'android.arsc',
      'ios.infoPlist',
      'ios.usageDescriptions',
      'ios.executables',
      'ios.macho.strings',
      'ios.nativeSymbols',
      'ios.signature',
      'ios.privacyManifest',
    ];

    test('每个维度在四个维护中的语言包里都有名字，且不留占位符', () async {
      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await _use(locale);
        for (final id in ids) {
          final label = AnalysisReport.coverageDimensionLabel(id, t);
          expect(
            label,
            isNot(id),
            reason: '$locale 下 $id 没有本地化名字，回退成了机器 id',
          );
          expect(label, isNot(contains('{')), reason: '$locale / $id');
          expect(label.trim(), isNotEmpty, reason: '$locale / $id');
        }
      }
      await _use('en');
    });

    test('中文语言包里是中文，英文语言包里没有中文', () async {
      const cjk = r'[\u4e00-\u9fff]';

      await _use('zh-CN');
      final zhLabels = ids
          .map((id) => AnalysisReport.coverageDimensionLabel(id, t))
          .toList();
      // **允许**个别维度不翻译：`ios.infoPlist` 的名字就是 `Info.plist`，
      // 那是文件名而不是术语，硬翻反而对不上原文。
      final zhChinese = zhLabels.where((l) => RegExp(cjk).hasMatch(l)).length;
      expect(
        zhChinese,
        greaterThanOrEqualTo(ids.length - 1),
        reason: 'zh-CN 下只有 $zhChinese/${ids.length} 个维度是中文：'
            '${zhLabels.join(' / ')}',
      );

      await _use('en');
      for (final id in ids) {
        final label = AnalysisReport.coverageDimensionLabel(id, t);
        expect(
          RegExp(cjk).hasMatch(label),
          isFalse,
          reason: 'en 下 $id 混进了中文：$label',
        );
      }
    });

    test('认不出的维度 id 原样返回，不显示空白', () {
      expect(
        AnalysisReport.coverageDimensionLabel('future.dimension', t),
        'future.dimension',
      );
    });
  });
}
