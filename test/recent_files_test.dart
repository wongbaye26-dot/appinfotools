// 最近文件（概览页的「统计」与「最近文件」两块都读它）。
//
// 这个文件此前**完全没有测试**，于是下面这条缺陷活到了用户手里：
//
//   `load()` 在空列表时返回 `const []`，而 `add()` 紧接着对它
//   `removeWhere` 去重 —— `const []` 是不可变的，抛 `UnsupportedError`。
//   调用方写的是 `unawaited(...)`，异常被静默吞掉。
//
// 净效果：**全新安装后第一次分析成功就抛错**，记录永远进不了列表，
// 概览页的统计恒为 0、最近文件恒为空，而日志里什么都没有。
//
// 因此这里既钉住「空集合必须是可变的」，也钉住整条链路（add → 持久化 →
// provider state），免得只在某一层修好、另一层又把异常吞掉。

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/overview/overview_page.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 每个用例都从「全新安装」开始。
///
/// **必须显式写入 `recent_files` 这个键**：`ConfigItem.loadValue()` 在存储里
/// 读不到键时会保留**内存里的旧值**（`?? _value`），而 `Config` 的静态项在
/// 同一个测试进程里是共享的 —— 不写键，上一个用例的记录就会漏到下一个用例，
/// 测试之间就不再独立。
Future<void> _freshInstall() async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'recent_files': '[]',
  });
  await Config.init();
  await Config.loadConfig();
}

/// 取消防抖定时器并立即落盘。
///
/// `ConfigItem.updateValue` 会挂一个 100ms 的 `Timer`；widget 测试跑在
/// fake-async 区里，测试结束时定时器仍挂起会直接判失败。
Future<void> _flushConfig() => Config.flushAll();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(_flushConfig);

  group('RecentFilesManager', () {
    test('空列表必须是可变列表', () async {
      await _freshInstall();

      final entries = RecentFilesManager.load();
      expect(entries, isEmpty);
      // 这一条就是缺陷本体：不可变列表会在 add() 的去重步骤炸掉。
      expect(
        () => entries.removeWhere((e) => false),
        returnsNormally,
        reason: '空集合是正常状态，不能返回 const []',
      );
    });

    test('全新安装后第一次 add 必须成功（统计不再是 0）', () async {
      await _freshInstall();

      await RecentFilesManager.add('/tmp/a.apk', 123, platform: 'android');

      final entries = RecentFilesManager.load();
      expect(entries, hasLength(1));
      expect(entries.single.path, '/tmp/a.apk');
      expect(entries.single.size, 123);
      expect(entries.single.platform, 'android');
    });

    test('重复路径去重并移到头部', () async {
      await _freshInstall();

      await RecentFilesManager.add('/tmp/a.apk', 1, platform: 'android');
      await RecentFilesManager.add('/tmp/b.apk', 2, platform: 'android');
      await RecentFilesManager.add('/tmp/a.apk', 3, platform: 'android');

      final entries = RecentFilesManager.load();
      expect(entries, hasLength(2), reason: '同路径只能有一条');
      expect(entries.first.path, '/tmp/a.apk');
      expect(entries.first.size, 3, reason: '重复添加要更新为新的大小');
    });

    test('最多保留 10 条', () async {
      await _freshInstall();

      for (var i = 0; i < 14; i++) {
        await RecentFilesManager.add('/tmp/$i.apk', i, platform: 'android');
      }

      final entries = RecentFilesManager.load();
      expect(entries, hasLength(10));
      expect(entries.first.path, '/tmp/13.apk', reason: '最新的在最前面');
    });

    test('clear 之后再 add 仍然可用', () async {
      await _freshInstall();

      await RecentFilesManager.add('/tmp/a.apk', 1, platform: 'android');
      await RecentFilesManager.clear();
      expect(RecentFilesManager.load(), isEmpty);

      // 清空后走的是同一条「空列表」分支，必须还能加回来。
      await RecentFilesManager.add('/tmp/b.apk', 2, platform: 'ios');
      expect(RecentFilesManager.load().single.path, '/tmp/b.apk');
    });

    test('记录会落盘，重启后还在', () async {
      await _freshInstall();
      await RecentFilesManager.add('/tmp/a.apk', 7, platform: 'ios');

      // `updateValue` 有 100ms 防抖，等它过去。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(Config.gPrefs.getString('recent_files'), contains('/tmp/a.apk'));

      // 模拟重启：从存储重新读进内存。
      Config.recentFiles.loadValue();
      expect(RecentFilesManager.load().single.size, 7);
    });
  });

  group('recentFilesProvider', () {
    test('add 之后 provider state 立即反映新记录', () async {
      await _freshInstall();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(recentFilesProvider), isEmpty);

      await container
          .read(recentFilesProvider.notifier)
          .add('/tmp/a.apk', 5, platform: 'android');

      expect(
        container.read(recentFilesProvider),
        hasLength(1),
        reason: '概览页 watch 的就是这个 state；它不变，界面就不会刷新',
      );
    });

    test('clear 之后 state 清空且仍是可变列表', () async {
      await _freshInstall();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(recentFilesProvider.notifier)
          .add('/tmp/a.apk', 5, platform: 'android');
      await container.read(recentFilesProvider.notifier).clear();

      final state = container.read(recentFilesProvider);
      expect(state, isEmpty);
      expect(() => state.removeWhere((e) => false), returnsNormally);
    });
  });

  group('概览页', () {
    testWidgets('统计与最近文件真的渲染出来，而不是 0 与空态', (tester) async {
      await _freshInstall();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(recentFilesProvider.notifier)
          .add('/tmp/sun_signed.ipa', 42465437, platform: 'ios');
      await container
          .read(recentFilesProvider.notifier)
          .add('/tmp/hardened.apk', 60608714, platform: 'android');
      // 落盘定时器属于 fake-async 区，测试结束前必须消掉。
      await _flushConfig();

      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            // 与真实树一致：概览页在 AppShell 的 Scaffold 里。
            child: const MaterialApp(home: Scaffold(body: OverviewPage())),
          ),
        ),
      );
      await tester.pump();

      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .join('\n');

      expect(text, contains('2'), reason: '统计总数应当是 2，而不是 0');
      expect(text, contains('hardened.apk'), reason: '最近文件列表要有内容');
      expect(text, contains('sun_signed.ipa'));
      expect(
        text.contains(t.overview.no_recent_files),
        isFalse,
        reason: '有记录时不能还显示空态',
      );
    });
  });
}
