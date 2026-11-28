// IPA 安装入口：选中 .ipa 后安装页换成 iOS 设备卡。
//
// 这里不碰真实子进程：注入空工具链，`_refreshIos` 只会做一次同步探测，
// 页面必须老实显示「缺工具 + 安装指引」，而不是一个空设备列表。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/install_page.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/utils/ios_install_service.dart';
import 'package:apk_info_tool/utils/ipa_install_metadata.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme:
            buildV4Theme(seed: V4Colors.violet, brightness: Brightness.light),
        home: Scaffold(
          body: InstallPage(
            iosToolchain: const IosToolchain(),
            // 真实 adb/aapt2 会在 fake-async 区留下 pending Timer，
            // 这里全部注入空实现，只验证 iOS 分支的渲染。
            deviceLoader: () async => const [],
            apkInfoLoader: (_) async => null,
            ipaMetaLoader: (_) async => const IpaInstallMetadata(
              displayName: 'Demo App',
              bundleIdentifier: 'com.example.demo',
              version: '1.2.3',
              buildNumber: '45',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _dropIpa(WidgetTester tester, String path) async {
  final target = tester.widget<DropTarget>(find.byType(DropTarget).first);
  target.onDragDone!(
    DropDoneDetails(
      files: [DropItemFile(path)],
      localPosition: Offset.zero,
      globalPosition: Offset.zero,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('拖入 .ipa 后显示 iOS 设备卡与缺工具指引', (tester) async {
    await _pump(tester);
    await _dropIpa(tester, '/tmp/samples/Demo.ipa');

    expect(find.text(t.install.ios_section), findsOneWidget);
    // 空工具链：chip 显示「工具缺失」，并给出安装命令。
    expect(find.text(t.install.ios_status_missing), findsOneWidget);
    expect(find.text('brew install libimobiledevice ideviceinstaller'),
        findsOneWidget);
    // 不再显示 adb 的设备卡（iOS 链路与 adb 是互斥的两条路）。
    expect(find.text(t.install.device_section), findsNothing);
    expect(find.text(t.install.ios_no_devices), findsNothing);
  });

  testWidgets('拖入 .apk 时仍是 adb 设备卡', (tester) async {
    await _pump(tester);
    await _dropIpa(tester, '/tmp/samples/Demo.apk');

    expect(find.text(t.install.ios_section), findsNothing);
  });

  testWidgets('文件条显示 IPA 的应用名、版本与 Bundle ID', (tester) async {
    await _pump(tester);
    await _dropIpa(tester, '/tmp/samples/Demo.ipa');
    await tester.pump();

    expect(find.text('Demo App · 1.2.3'), findsOneWidget);
    expect(find.textContaining('com.example.demo'), findsWidgets);
  });
}
