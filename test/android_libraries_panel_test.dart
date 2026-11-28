// 「库识别」面板的端到端链路：真 ZIP → ApkReader → DEX 扫描 → 规则匹配 → UI。
//
// 单测里 DexLibraryScanner / LibraryDetector 各自都测过，但「面板自己从包里
// 读 DEX」这一段没测过 —— 路径拼接、条目过滤、缓存键都只在这层。这里用
// 一个只有 `classes.dex` 与 `lib/x86/libflutter.so` 的最小 APK 验证它。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/widgets/android_libraries_panel.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String apkPath;

  setUpAll(() async {
    await AndroidMetadata.instance.ensureLoaded();
    tempDir = await Directory.systemTemp.createTemp('lib-panel-test');
    // 真实 DEX：包含 com.example.fixture 的类定义。
    final dex = await File('packages/apk_parser/test/fixtures/loader-api.dex')
        .readAsBytes();
    final archive = Archive()
      ..addFile(ArchiveFile('classes.dex', dex.length, Uint8List.fromList(dex)))
      ..addFile(ArchiveFile(
        'lib/x86/libflutter.so',
        4,
        Uint8List.fromList(const [0x7f, 0x45, 0x4c, 0x46]),
      ))
      ..addFile(ArchiveFile(
        'AndroidManifest.xml',
        1,
        Uint8List.fromList(const [0]),
      ));
    final bytes = ZipEncoder().encode(archive);
    apkPath = '${tempDir.path}/minimal.apk';
    await File(apkPath).writeAsBytes(bytes);
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  testWidgets('从真实 ZIP 识别出 Flutter 原生库', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: AndroidLibrariesSection(
                    apkPath: apkPath,
                    packageName: 'com.example.fixture',
                    components: const [],
                    structure: const ContainerStructure(
                      fileEntryCount: 3,
                      dexFiles: [DexEntry(name: 'classes.dex', size: 0)],
                      nativeLibraries: [
                        NativeLibraryEntry(
                          name: 'libflutter.so',
                          path: 'lib/x86/libflutter.so',
                          abi: 'x86',
                          size: 4,
                        ),
                      ],
                      abis: ['x86'],
                      totalUncompressedBytes: 0,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // 扫描含真实文件 IO，必须让事件循环跑起来；进度圈是无限动画，
      // 所以不能用 pumpAndSettle（它会一直等动画停）。
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find.text('Flutter').evaluate().isNotEmpty) break;
      }
    });

    expect(find.text('Flutter'), findsOneWidget);
    expect(find.text('Native libraries'), findsOneWidget);
    // 每个 SDK 只算一次：libflutter.so 来自原生库，没有其他命中。
    expect(find.text('Identified 1 SDKs'), findsOneWidget);
    expect(find.textContaining('classes in 1 DEX files'), findsOneWidget);
  });
}
