// 界面渲染快照 —— 手动运行，用于**目视检查**，不做断言、不进 CI 门禁。
//
// 用法：
//   flutter test test/_snapshot_render.dart
//
// 产物：build/snapshots/*.png
//
// **⚠️ 本机跑不了**：`RepaintBoundary.toImage()` 会让整个测试进程被 SIGKILL
// （退出码 137，无任何输出；关掉工具沙箱也一样）。可用的替代做法是
// web 构建 + 无头 Chrome，步骤与实测症状见 `docs/notes/ui-snapshot.md`。
// 保留这个文件是因为在别的机器上它可能是好的。
//
// 为什么要有这个：读代码看不出「图标有没有真的画出来」「英文长文案会不会
// 被截断」「顶栏和侧边栏的颜色是不是同一块」。渲成 PNG 一眼就看到了。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/ui/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 加载系统字体。
///
/// Flutter 测试环境默认用 Ahem —— 所有字形都是实心方块。不换成真实字体，
/// 快照上就只有一堆黑框，看不出文案长短、换行位置与截断。
Future<void> _loadFonts() async {
  final candidates = [
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    '/System/Library/Fonts/Supplemental/Arial.ttf',
  ];
  final loader = FontLoader('SnapshotFont');
  var loaded = false;
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      loader.addFont(
        Future.value(ByteData.sublistView(file.readAsBytesSync())),
      );
      loaded = true;
    }
  }
  if (loaded) await loader.load();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  final image = await boundary.toImage(pixelRatio: 1.5);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory('build/snapshots')..createSync(recursive: true);
  final file = File('${dir.path}/$name.png');
  file.writeAsBytesSync(data!.buffer.asUint8List());
  // ignore: avoid_print
  print('saved: ${file.path} (${file.lengthSync()}B)');
}

Future<void> _pumpShell(WidgetTester tester, String locale) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // 语言包是 deferred（懒加载）的：必须 await 异步版本。
  // `setLocaleRawSync` 会抛「Deferred library l_zh_CN was not loaded」，
  // 不 await 则渲染出来的还是 base locale —— 中英文快照会长得一模一样。
  await LocaleSettings.setLocaleRaw(locale);

  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'SnapshotFont'),
          home: const RepaintBoundary(child: AppShell()),
        ),
      ),
    ),
  );
  // 不用 `pumpAndSettle`：页面里有持续动画，它会一直等到超时。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    packageInfo = PackageInfo(
      appName: 'AppInfoTool',
      packageName: 'to.feng.app.apkinfotool.apkInfoTool',
      version: '2.0.0',
      buildNumber: '2.0.0',
    );
  });

  setUpAll(_loadFonts);

  testWidgets('概览页（英文）', (tester) async {
    await _pumpShell(tester, 'en');
    await _capture(tester, 'overview_en');
  });

  testWidgets('概览页（中文）', (tester) async {
    await _pumpShell(tester, 'zh-CN');
    await _capture(tester, 'overview_zh');
  });
}
