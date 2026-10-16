// 「最近文件」列表要显示**真实应用图标**与**平台信息**。
//
// 背景：列表此前只有一个 16px 的通用平台图标（Android 小绿人 / iOS 苹果），
// 平台是靠认图标猜的。现在每个包显示各自的真实图标，平台就必须用文字写出来
// —— 只靠颜色或图标形状区分，在色觉障碍下等于没有区分。
//
// 这里钉三件事：
// 1. 条目里的图标缓存字段能**持久化并往返**，旧数据（没有这个字段）不炸；
// 2. 缓存文件名由「路径 + 体积」派生，被替换过的同名文件不会拿到旧图标；
// 3. 列表行真的渲染出平台标签，并在没有缓存时退回平台通用图标。

import 'dart:convert';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
import 'package:apk_info_tool/utils/recent_icon_cache.dart';
import 'package:apk_info_tool/ui/overview/overview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _epoch = DateTime.utc(2023, 11, 14);

const _entries = [
  {
    'path': '/tmp/samples/example-application.ipa',
    'size': 42465437,
    'analyzedAt': 1700000000000,
    'platform': 'ios',
    'iconFile': 'aaa.png',
  },
  {
    'path': '/tmp/samples/demo.apk',
    'size': 1024,
    'analyzedAt': 1700000000000,
    'platform': 'android',
    'iconFile': 'bbb.png',
  },
  {
    // 旧记录：没有 platform / iconFile（V2.5.0 之前写下的数据）。
    'path': '/tmp/samples/legacy.apk',
    'size': 2048,
    'analyzedAt': 1700000000000,
  },
];

Future<void> _pump(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'recent_files': jsonEncode(_entries),
  });
  await Config.init();
  await Config.loadConfig();

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: const MaterialApp(home: Scaffold(body: OverviewPage())),
      ),
    ),
  );
  await tester.pump();
  await Config.flushAll();
}

void main() {
  group('最近文件条目的图标字段', () {
    test('往返持久化保留 iconFile', () {
      final entry = RecentFileEntry(
        path: '/tmp/a.apk',
        size: 1,
        analyzedAt: _epoch,
        platform: 'android',
        iconFile: 'deadbeef.png',
      );
      final restored = RecentFileEntry.fromJson(entry.toJson());
      expect(restored.iconFile, 'deadbeef.png');
      expect(restored.platform, 'android');
    });

    test('旧数据（没有 iconFile）解析成 null，而不是抛错', () {
      final restored = RecentFileEntry.fromJson(const {
        'path': '/tmp/a.apk',
        'size': 1,
        'analyzedAt': 1700000000000,
      });
      expect(restored.iconFile, isNull);
      expect(restored.platform, isNull);
    });

    test('iconFile 为 null 时序列化里不出现这个键', () {
      final entry = RecentFileEntry(
        path: '/tmp/a.apk',
        size: 1,
        analyzedAt: _epoch,
      );
      expect(entry.toJson().containsKey('iconFile'), isFalse);
    });
  });

  group('图标缓存文件名', () {
    test('同一路径同一体积稳定；换体积会换名字', () {
      final a = RecentIconCache.fileNameFor('/tmp/a.apk', 100);
      final b = RecentIconCache.fileNameFor('/tmp/a.apk', 100);
      final c = RecentIconCache.fileNameFor('/tmp/a.apk', 200);
      expect(a, b, reason: '同输入必须同输出，否则缓存永远命中不了');
      expect(a, isNot(c), reason: '被替换过的同名文件必须拿到新图标');
      expect(a, endsWith('.png'));
      // 不能把路径原样拼进文件名（有分隔符就不是文件名了）。
      expect(a.contains('/'), isFalse);
    });

    test('带分隔符的文件名被拒绝，防目录穿越', () async {
      expect(await RecentIconCache.fileFor('../../etc/passwd'), isNull);
      expect(await RecentIconCache.fileFor('a/b.png'), isNull);
      expect(await RecentIconCache.fileFor(null), isNull);
      expect(await RecentIconCache.fileFor(''), isNull);
    });
  });

  group('列表行渲染', () {
    testWidgets('平台用文字标出，Android / iOS 都在', (tester) async {
      await _pump(tester, const Size(1040, 800));

      expect(find.text('Android'), findsWidgets);
      expect(find.text('iOS'), findsWidgets);
      // 旧记录没有平台 —— 用「—」而不是猜一个。
      expect(find.text('—'), findsWidgets);
    });

    testWidgets('没有缓存图标时退回平台通用图标，且不报错', (tester) async {
      await _pump(tester, const Size(1040, 800));

      // 测试环境没有 path_provider，缓存取不到 → 三行都走通用图标。
      expect(find.byIcon(Icons.android), findsWidgets);
      expect(find.byIcon(Icons.apple), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('最小窗口下也不溢出', (tester) async {
      await _pump(tester, const Size(660, 600));
      expect(tester.takeException(), isNull);
    });
  });
}
