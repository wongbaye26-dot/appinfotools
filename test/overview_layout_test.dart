// 概览页 Hero 区的版式约束。
//
// 这一页是**固定一屏、不上下滚动**的：Hero 长高了就必须有东西让位。
// 上一版把详细信息网格加进 Hero 之后，在 900×600（应用允许的最小窗口）
// 下底部被整片裁掉，渲染成一条黄黑警示带 —— 用户看到的是残缺的界面，
// 而不是「内容有点多」。
//
// 因此这里钉三件事：
// 1. 三个真实尺寸下都**不得有溢出**；
// 2. 窗口矮的时候网格按约定收起，而不是把统计与最近文件挤没；
// 3. Hero 区里每个字段都带复制入口，并且复制真的写进剪贴板。

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/overview/overview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 真实的内容区尺寸 = 窗口宽 − 侧栏 240。
const _minWindow = Size(660, 600);
const _defaultWindow = Size(1040, 800);
const _wideWindow = Size(1440, 900);

/// 一个「解析中、哈希已到」的状态：字段够多，能压出版式问题，
/// 又不需要真实样本。
FileState _state() => const FileState(
      filePath: '/tmp/samples/example-application.ipa',
      fileSize: 42465437,
      md5Hash: 'd41d8cd98f00b204e9800998ecf8427e',
      sha1Hash: 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      sha256Hash:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );

Future<void> _pump(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues(
      <String, Object>{'recent_files': '[]'});
  await Config.init();
  await Config.loadConfig();

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentFileStateProvider.notifier).update(_state());

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

String _visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(widget.data ?? '');
  }
  for (final widget
      in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
    buffer.writeln(widget.data ?? '');
  }
  return buffer.toString();
}

/// Hero 里「详细信息」网格那一段。
Finder _detailsGrid() => find.text(t.overview.field_details);

void main() {
  group('Hero 版式：任何尺寸都不得溢出', () {
    for (final entry in {
      '最小窗口': _minWindow,
      '默认窗口': _defaultWindow,
      '宽窗口': _wideWindow,
    }.entries) {
      testWidgets(entry.key, (tester) async {
        await _pump(tester, entry.value);

        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key} 下 Hero 溢出 —— 固定一屏布局里溢出会被直接裁掉',
        );
      });
    }
  });

  group('Hero 版式：窗口矮时网格收起', () {
    testWidgets('最小窗口下网格不显示，但统计与最近文件都还在', (tester) async {
      await _pump(tester, _minWindow);

      expect(_detailsGrid(), findsNothing, reason: '高度不够时网格应整块收起');
      final text = _visibleText(tester);
      expect(text, contains(t.overview.statistics));
      expect(text, contains(t.overview.recent_files));
      expect(text, contains(t.overview.no_recent_files));
      // 收起的是网格，不是整个 Hero —— 状态卡片必须还在。
      expect(text, contains(t.overview.status_platform));
      expect(text, contains(t.overview.status_signature));
    });

    testWidgets('默认窗口下网格显示，并且字段齐全', (tester) async {
      await _pump(tester, _defaultWindow);

      expect(_detailsGrid(), findsOneWidget);
      final text = _visibleText(tester);
      expect(text, contains(t.overview.field_file_name));
      expect(text, contains(t.overview.field_file_path));
      expect(text, contains(t.file_info.sha256));
      expect(text, contains(t.file_info.sha1));
      expect(text, contains(t.file_info.md5));
    });

    testWidgets('网格自身的滚动上限不会把统计挤没', (tester) async {
      await _pump(tester, _defaultWindow);

      // 统计卡片的三项必须真的在树里，而不是被 Hero 顶出去。
      final text = _visibleText(tester);
      expect(text, contains('Android'));
      expect(text, contains('iOS'));
      expect(text, contains(t.overview.stat_analyzed));
    });
  });

  group('Hero 区每个字段都能复制', () {
    testWidgets('复制按钮数量与字段数量一致', (tester) async {
      await _pump(tester, _defaultWindow);

      // 这个状态下有值的字段：应用名（标题行）+ 四个状态卡片 + 网格里的
      // 文件名 / 文件路径 / SHA-256 / SHA-1 / MD5 —— 共 10 个。
      // 标识符与版本没有值（状态里没有解析结果），因此不出现复制入口：
      // 空字段不给复制按钮，正是「取不到就不假装有」的那条约定。
      final copies = find.byIcon(Icons.content_copy).evaluate().length;
      expect(
        copies,
        greaterThanOrEqualTo(10),
        reason: '有值的字段都应有复制入口（实测 $copies 个）',
      );
    });

    testWidgets('点击复制真的写入剪贴板', (tester) async {
      await _pump(tester, _defaultWindow);

      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') calls.add(call);
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      // 点第一个复制按钮（应用名）。
      await tester.tap(find.byIcon(Icons.content_copy).first);
      await tester.pump();

      expect(calls, isNotEmpty, reason: '复制按钮必须真的调用 Clipboard.setData');
      final data = calls.first.arguments as Map;
      expect(data['text'], 'example-application.ipa');
    });
  });
}
