// 差异页渲染快照 —— 手动运行，用于**目视检查**，不做断言、不进 CI 门禁。
//
// 用法（**一次跑一条**，`--plain-name` 逐个跑；同一测试体内第二次 pumpWidget
// 会挂住）：
//   flutter test test/_diff_snapshot.dart --plain-name '差异页（中文）'
//
// 产物：build/snapshots/*.png

import 'dart:io';
import 'dart:ui' as ui;

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/diff/diff_page.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ComponentType;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
      loader
          .addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
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

ApkInfo _android({
  String? versionName,
  int? versionCode,
  int? minSdk,
  int? targetSdk,
  int? maxSdk,
  bool? debuggable,
  List<String> permissions = const [],
  List<AndroidComponent> components = const [],
}) =>
    ApkInfo()
      ..packageName = 'com.example.demo'
      ..label = '演示应用'
      ..versionName = versionName
      ..versionCode = versionCode
      ..sdkVersion = minSdk
      ..targetSdkVersion = targetSdk
      ..maxSdkVersion = maxSdk
      ..applicationDebuggable = debuggable
      ..usesPermissions = permissions
      ..components = components
      ..manifestSource = FieldSource.builtinParser;

Future<void> _pump(WidgetTester tester, String locale) async {
  tester.view.physicalSize = const Size(1400, 1500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // 语言包是 deferred 的，而 `testWidgets` 的测试体跑在 **fake-async 区**里 ——
  // `loadLibrary()` 的完成回调等不到真实事件循环，直接 `await` 会卡死。
  // 必须放进 `runAsync`（与「真样本解析必须放 setUpAll」是同一类坑）。
  await tester.runAsync(() => LocaleSettings.setLocaleRaw(locale));

  final container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'SnapshotFont'),
          home: const Scaffold(
            body: RepaintBoundary(child: DiffPage()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final notifier = container.read(currentFileStateProvider.notifier);
  notifier.update(FileState(
    filePath: '/tmp/demo-1.0.0.apk',
    fileSize: 1048576,
    apkInfo: _android(
      versionName: '1.0.0',
      versionCode: 1,
      minSdk: 21,
      targetSdk: 33,
      maxSdk: 35,
      permissions: ['android.permission.INTERNET', 'android.permission.CAMERA'],
      components: const [
        AndroidComponent(
          type: ComponentType.activity,
          name: 'com.example.demo.MainActivity',
          exported: true,
        ),
      ],
    ),
  ));
  await tester.pump();
  notifier.update(FileState(
    filePath: '/tmp/demo-2.0.0.apk',
    fileSize: 2097152,
    apkInfo: _android(
      versionName: '2.0.0',
      versionCode: 2,
      minSdk: 24,
      targetSdk: 34,
      permissions: [
        'android.permission.INTERNET',
        'android.permission.ACCESS_FINE_LOCATION',
      ],
      components: const [
        AndroidComponent(
          type: ComponentType.activity,
          name: 'com.example.demo.MainActivity',
          exported: true,
        ),
        AndroidComponent(
          type: ComponentType.service,
          name: 'com.example.demo.SyncService',
        ),
      ],
    ),
  ));
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('差异页（中文）', (tester) async {
    await _pump(tester, 'zh-CN');
    await _capture(tester, 'diff_zh');
  });
}
