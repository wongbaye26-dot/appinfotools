// 应用图标的尺寸规则，以及「换文件后图标不该消失」。
//
// 两条都来自 V2.4.8 的用户报告：
// 1. 分析页「概览 → 应用信息」的图标比概览页 Hero 小一圈 —— 三处各写各的
//    数字（92 / 72 / 48），圆角也是两处按比例、一处固定 16px；
// 2. 版本对比**左侧**槽位没有图标，右侧有。左侧是先解析的那个包。

import 'dart:ui' as ui;

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/providers/parsed_file_cache.dart';
import 'package:apk_info_tool/ui/shell/app_shell.dart';
import 'package:apk_info_tool/widgets/android_detail_widgets.dart';
import 'package:apk_info_tool/widgets/ios_detail_widgets.dart';
import 'package:apk_info_tool/widgets/package_icon_metrics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 造一张 8×8 的真位图。
///
/// 必须借 `runAsync`：`Picture.toImage` 要真实事件循环，而 `testWidgets` 的
/// 测试体跑在 fake-async 区里。
Future<ui.Image> _makeImage(WidgetTester tester) async {
  late ui.Image image;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 8, 8),
      Paint()..color = const Color(0xFF1E88E5),
    );
    image = await recorder.endRecording().toImage(8, 8);
  });
  return image;
}

void main() {
  group('图标尺寸规则', () {
    test('圆角跟着边长走，不是固定像素', () {
      // 22.37% 是 iOS 图标的圆角比例。
      expect(
        PackageIconMetrics.radiusOf(PackageIconMetrics.heroSide),
        closeTo(20.58, 0.01),
      );
      expect(
        PackageIconMetrics.radiusOf(PackageIconMetrics.slotSide),
        closeTo(10.74, 0.01),
      );
      // 两个尺寸的圆角**比例相同** —— 固定 16px 时这条会失败。
      final heroRatio =
          PackageIconMetrics.radiusOf(PackageIconMetrics.heroSide) /
              PackageIconMetrics.heroSide;
      final slotRatio =
          PackageIconMetrics.radiusOf(PackageIconMetrics.slotSide) /
              PackageIconMetrics.slotSide;
      expect(heroRatio, closeTo(slotRatio, 1e-9));
    });

    testWidgets('分析页 Android Hero 卡片用的是 Hero 尺寸（不是 72）', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: AndroidHeroCard(
                appName: 'Demo',
                packageName: 'com.example.demo',
                versionName: '1.0',
                versionCode: '1',
              ),
            ),
          ),
        ),
      );

      final size = tester.getSize(
        find.byKey(const ValueKey('package_icon_box')),
      );
      expect(size.width, PackageIconMetrics.heroSide);
      expect(size.height, PackageIconMetrics.heroSide);
      expect(size.width, 92, reason: '与概览页 Hero 同一尺寸');
    });

    testWidgets('分析页 iOS Hero 卡片同样是 Hero 尺寸', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: IosHeroCard(
                appName: 'Demo',
                bundleId: 'com.example.demo',
                version: '1.0',
                buildNumber: '1',
              ),
            ),
          ),
        ),
      );

      final size = tester.getSize(
        find.byKey(const ValueKey('package_icon_box')),
      );
      expect(size.width, PackageIconMetrics.heroSide);
    });
  });

  group('图标副本：换文件后先解析的包仍有图标', () {
    testWidgets('ApkInfo 被 dispose 之后，副本仍然可用', (tester) async {
      final image = await _makeImage(tester);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 先让 provider 建起来并注册监听 —— 否则这次更新它收不到。
      container.read(parsedFileIconsProvider);

      // 还原真实结构：`mainIconImage` 指向某个候选的 `renderedImage`，
      // `ApkInfo.dispose()` 会把候选图一起释放。
      final candidate = IconCandidate(
        path: 'res/mipmap-xxxhdpi/ic_launcher.png',
        type: IconCandidateType.bitmap,
      )..renderedImage = image;
      final info = ApkInfo()
        ..packageName = 'com.example.demo'
        ..mainIconImage = image
        ..iconCandidates = [candidate];

      container.read(currentFileStateProvider.notifier).update(
            FileState(filePath: '/tmp/a.apk', fileSize: 1, apkInfo: info),
          );
      container.read(currentApkInfoProvider.notifier).update(info);

      final icons = container.read(parsedFileIconsProvider);
      expect(icons['/tmp/a.apk'], isNotNull, reason: '解析完成时就该留一份副本');

      // 换文件：分析页会 dispose 上一个 ApkInfo —— 原图随之失效。
      info.dispose();
      expect(info.mainIconImage, isNull);

      // 副本仍然能读尺寸（已释放的 `ui.Image` 在 debug 下会断言失败）。
      final copy = icons['/tmp/a.apk']!;
      expect(copy.width, 8);
      expect(copy.height, 8);
    });

    testWidgets('AppShell 启动时就把副本 provider 建起来', (tester) async {
      // **这一条守的是一行代码。** `ParsedFileIcons` 靠监听累积，而它只在
      // 「差异页真的画出槽位」时才被读到 —— 那时两个包的 `ApkInfo` 早被
      // dispose 了。`AppShell.initState` 里必须显式 `ref.read` 一次。
      //
      // 因此这里**故意不先读** `parsedFileIconsProvider`：先读就等于替
      // AppShell 把它建起来了，测不出「忘了写那一行」。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await Config.init();
      await Config.loadConfig();

      final image = await _makeImage(tester);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: const MaterialApp(home: AppShell()),
          ),
        ),
      );
      await tester.pump();

      final candidate = IconCandidate(
        path: 'res/mipmap-xxxhdpi/ic_launcher.png',
        type: IconCandidateType.bitmap,
      )..renderedImage = image;
      final info = ApkInfo()
        ..packageName = 'com.example.demo'
        ..mainIconImage = image
        ..iconCandidates = [candidate];

      container.read(currentFileStateProvider.notifier).update(
            FileState(filePath: '/tmp/c.apk', fileSize: 1, apkInfo: info),
          );
      await tester.pump();

      expect(
        container.read(parsedFileIconsProvider)['/tmp/c.apk'],
        isNotNull,
        reason: 'AppShell 必须在启动时建好这个 provider，否则进差异页时图标已经没了',
      );
    });

    testWidgets('没有图标的包不会往副本表里塞空值', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(parsedFileIconsProvider);

      final info = ApkInfo()..packageName = 'com.example.demo';
      container.read(currentFileStateProvider.notifier).update(
            FileState(filePath: '/tmp/b.apk', fileSize: 1, apkInfo: info),
          );
      container.read(currentApkInfoProvider.notifier).update(info);

      expect(container.read(parsedFileIconsProvider), isEmpty);
    });
  });
}
