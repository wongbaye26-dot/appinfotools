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
}
