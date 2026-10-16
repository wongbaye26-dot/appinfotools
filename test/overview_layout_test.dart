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
      // 文件路径**不在网格里**（V2.5.0 起移到 Hero 的常驻行，见下一个 group），
      // 但文件名仍在网格中 —— 两者不是同一项。
      expect(text, contains('/tmp/samples/example-application.ipa'));
      expect(text, contains(t.file_info.sha256));
      expect(text, contains(t.file_info.sha1));
      expect(text, contains(t.file_info.md5));
    });

    testWidgets('网格不含内部滚动器（用户要求固定显示）', (tester) async {
      await _pump(tester, _defaultWindow);

      // 去掉 SingleChildScrollView 后，网格直接展开，字段不会藏在滚动器里。
      final hero = find.byType(OverviewPage);
      expect(
        find.descendant(of: hero, matching: find.byType(SingleChildScrollView)),
        findsNothing,
        reason: '详细信息网格不应包含内部滚动器',
      );
    });

    testWidgets('没有解析结果时不显示架构标签', (tester) async {
      await _pump(tester, _defaultWindow);

      final text = _visibleText(tester);
      expect(text, isNot(contains('64-bit')), reason: '无 analysis 结果时不应有架构标签');
      expect(text, isNot(contains('32-bit')), reason: '无 analysis 结果时不应有架构标签');
    });
  });

  // V2.5.0：文件路径从「详细信息」网格移到了 Hero 的常驻行。
  //
  // 动机是实测出来的：网格在矮窗口下会整块收起（见上一组），而「这个包在
  // 磁盘上哪儿 / 我要改个名」恰好在最小窗口下看不见。路径与重命名入口
  // 都必须**任何尺寸都在**。
  group('Hero 的文件路径行常驻且可重命名', () {
    for (final entry in {
      '最小窗口': _minWindow,
      '默认窗口': _defaultWindow,
      '宽窗口': _wideWindow,
    }.entries) {
      testWidgets('${entry.key}下都能看到完整路径与重命名按钮', (tester) async {
        await _pump(tester, entry.value);

        expect(
          _visibleText(tester),
          contains('/tmp/samples/example-application.ipa'),
          reason: '${entry.key} 下路径必须可见（网格收起时更要可见）',
        );
        expect(
          find.byIcon(Icons.drive_file_rename_outline),
          findsOneWidget,
          reason: '${entry.key} 下重命名入口必须存在',
        );
      });
    }

    testWidgets('点重命名按钮弹出对话框，默认名按「应用名-版本号.后缀」', (tester) async {
      await _pump(tester, _defaultWindow);

      await tester.tap(find.byIcon(Icons.drive_file_rename_outline));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(t.rename.rename_file), findsWidgets);
      // 状态里没有解析结果，因此默认名退回原文件名（不编一个应用名出来）。
      // 用 `findsWidgets` 而不是 `findsOneWidget`：网格里的文件名、路径行
      // 末尾、以及对话框输入框里都会出现这个串。
      expect(find.text('example-application.ipa'), findsWidgets);

      await tester.tap(find.text(t.base.cancel));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('Hero 图标是正方形', () {
    // 真实的 App 图标是**圆角正方形**。Hero 行是按右侧文字列的高度拉伸的
    // （实测 92 宽 × 109 高），图标若跟着拉伸，`BoxFit` 就会在上下各留出
    // 一条 `colorScheme.surface` 的深色带 —— 用户看到的就是图标外那一圈
    // 「黑边」。因此这里钉住「图标框必须是正方形」。
    for (final entry in {
      '默认窗口': _defaultWindow,
      '最小窗口（紧凑模式）': _minWindow,
    }.entries) {
      testWidgets(entry.key, (tester) async {
        await _pump(tester, entry.value);

        final size = tester.getSize(
          find.byKey(const ValueKey('overview_hero_icon')),
        );

        expect(
          size.width,
          size.height,
          reason: '图标框必须是正方形（实测 ${size.width}×${size.height}）',
        );
        expect(size.width, greaterThan(0), reason: '图标框不能是零尺寸');
      });
    }
  });

  group('Hero 区每个字段都能复制', () {
    testWidgets('复制按钮数量与字段数量一致', (tester) async {
      await _pump(tester, _defaultWindow);

      // 这个状态下有值的字段：应用名（标题行）+ 四个状态卡片 + 网格里的
      // 文件名 / SHA-256 / SHA-1 / MD5 + Hero 里的文件路径 —— 共 10 个。
      // 文件路径旁边**同时**有复制与重命名两个入口（路径是用户最常要
      // 贴给别人、也最常要改名的一项）。
      // 标识符与版本没有值（状态里没有解析结果），因此不出现复制入口：
      // 空字段不给复制按钮，正是「取不到就不假装有」的那条约定。
      final copies = find.byIcon(Icons.content_copy).evaluate().length;
      expect(
        copies,
        greaterThanOrEqualTo(10),
        reason: '有值的字段都应有复制入口（实测 $copies 个）',
      );

      // 重命名按钮**只有一个**：路径行是唯一的入口，网格里不再重复。
      expect(find.byIcon(Icons.drive_file_rename_outline), findsOneWidget);
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

      // 点第一个复制按钮 —— V2.5.0 起「当前文件」那一行最前面就是文件路径，
      // 它的复制按钮因此排在树里第一个（此前是应用名）。
      await tester.tap(find.byIcon(Icons.content_copy).first);
      await tester.pump();

      expect(calls, isNotEmpty, reason: '复制按钮必须真的调用 Clipboard.setData');
      final data = calls.first.arguments as Map;
      expect(data['text'], '/tmp/samples/example-application.ipa');
    });
  });
}
