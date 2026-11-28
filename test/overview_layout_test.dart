// 概览页的版式约束（V4 · Paper & Signal）。
//
// 这一页对齐 `docs/prototypes/ui-redesign-v4/renders/02-overview-active.png`。
// 原型是一屏 scrollable 的版式，因此这里钉的是：
// 1. 三个真实尺寸下都**不得溢出**（应用最小窗口 900×600 也要能看）；
// 2. 空态有引导卡 / 拖放区 / 引擎表 / 环境 / 流水线，而不是一片空白；
// 3. 有文件时 Hero + POSTURE + 四张证据卡 + 最近分析 + 会话日志都在；
// 4. 「没读到」渲染成 `—`，不渲染成 0（0 会被读成「一个都没有」）。

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ComponentType;
import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/overview/overview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _minWindow = Size(660, 600);
const _defaultWindow = Size(1040, 800);
const _wideWindow = Size(1440, 900);

/// 「解析中、哈希已到」：没有任何 Android 解析结果。
FileState _state() => const FileState(
      filePath: '/tmp/samples/example-application.ipa',
      fileSize: 42465437,
      sha256Hash:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );

/// 字段齐全：包名 / 版本 / minSdk / targetSdk / 权限 / 组件。
FileState _fullState() => FileState(
      filePath: '/tmp/samples/demo-1.2.3.apk',
      fileSize: 42465437,
      sha256Hash:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      apkInfo: ApkInfo()
        ..packageName = 'com.example.demo'
        ..label = 'Demo'
        ..versionName = '1.2.3'
        ..versionCode = 45
        ..sdkVersion = 24
        ..targetSdkVersion = 34
        ..nativeCodes = ['arm64-v8a', 'armeabi-v7a']
        ..usesPermissions = [
          for (var i = 0; i < 12; i++) 'android.permission.P$i'
        ]
        ..components = [
          for (var i = 0; i < 3; i++)
            AndroidComponent(
              type: ComponentType.activity,
              name: 'com.example.demo.Screen$i',
              exported: true,
              hasIntentFilter: true,
            ),
        ],
    );

Future<void> _pump(WidgetTester tester, Size size, {FileState? state}) async {
  SharedPreferences.setMockInitialValues(
      <String, Object>{'recent_files': '[]'});
  await Config.init();
  await Config.loadConfig();

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  final effective = state ?? _state();
  container.read(currentFileStateProvider.notifier).update(effective);
  // 概览页的应用名 / 版本读的是独立的 `currentApkInfoProvider`。
  container.read(currentApkInfoProvider.notifier).update(effective.apkInfo);

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
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.writeln(widget.text.toPlainText());
  }
  return buffer.toString();
}

void main() {
  group('三个真实尺寸下都不得溢出', () {
    for (final entry in {
      '最小窗口': _minWindow,
      '默认窗口': _defaultWindow,
      '宽窗口': _wideWindow,
    }.entries) {
      testWidgets(entry.key, (tester) async {
        await _pump(tester, entry.value, state: _fullState());
        expect(tester.takeException(), isNull);
      });

      testWidgets('${entry.key}（空态）', (tester) async {
        await _pump(tester, entry.value, state: const FileState());
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('空态：引导 + 引擎 + 环境 + 流水线', () {
    testWidgets('引导文案、拖放区与引擎表都在', (tester) async {
      await _pump(tester, _defaultWindow, state: const FileState());

      final text = _visibleText(tester);
      expect(text, contains(t.overview.hero_headline));
      expect(text, contains(t.overview.choose_file));
      expect(text, contains(t.overview.drop_open));
      expect(text, contains(t.overview.engine));
      expect(text, contains(t.overview.engine_builtin));
      expect(text, contains(t.overview.network_off));
    });

    testWidgets('右栏有环境与流水线，最近分析是空态', (tester) async {
      await _pump(tester, _defaultWindow, state: const FileState());

      final text = _visibleText(tester);
      expect(text, contains(t.overview.environment));
      expect(text, contains(t.overview.env_parser));
      expect(text, contains(t.overview.pipeline));
      expect(text, contains(t.overview.pipeline_drop));
      expect(text, contains(t.overview.no_recent_files));
    });
  });

  group('有文件：Hero / 证据卡 / 日志', () {
    testWidgets('应用名、包名、版本与六格元数据都在', (tester) async {
      await _pump(tester, _defaultWindow, state: _fullState());

      final text = _visibleText(tester);
      expect(text, contains('Demo'));
      expect(text, contains('com.example.demo'));
      expect(text, contains('1.2.3'));
      expect(text, contains('PACKAGE'));
      expect(text, contains('VERSION'));
      expect(text, contains('SIGNATURE'));
      expect(text, contains('TARGET SDK'));
      expect(text, contains('COMPONENTS'));
      expect(text, contains('ENTRY POINTS'));
    });

    testWidgets('四张证据卡：权限 / 组件 / DEX / 原生库', (tester) async {
      await _pump(tester, _wideWindow, state: _fullState());

      final text = _visibleText(tester);
      expect(text, contains(t.overview.stat_permissions));
      expect(text, contains(t.overview.stat_components));
      expect(text, contains(t.overview.stat_dex_files));
      expect(text, contains(t.overview.stat_native_libs));
    });

    testWidgets('POSTURE 卡与会话日志都在', (tester) async {
      await _pump(tester, _wideWindow, state: _fullState());

      final text = _visibleText(tester);
      expect(text, contains('POSTURE / STATIC'));
      expect(text, contains(t.overview.session_log));
      expect(text, contains(t.overview.session_local));
    });
  });

  group('诚实计数', () {
    testWidgets('权限没读到时不渲染成 0', (tester) async {
      await _pump(tester, _wideWindow, state: _state());

      final text = _visibleText(tester);
      expect(text, isNot(contains('0\n${t.overview.stat_permissions}')));
    });
  });
}
