// 真实样本的**界面**端到端测试（交付要求 7 的 UI 部分）。
//
// 覆盖的是「**状态 → 渲染**」这一段：把真实样本解析出来的 `FileState` 注入
// provider，然后断言用户真的能在详情页上看到那些值。
//
// 覆盖不到的是「文件 → 状态」那一段（`loadApkInfo` 的编排）：解析跑在 worker
// isolate 与真实文件 IO 上，而 widget 测试把整个测试体包在 fake-async 区里，
// isolate 的完成回调等不到真实事件循环 —— 实测会直接挂住（不是失败，是卡死）。
// 那一段由 `real_samples_test.dart` 用普通 `test()`（真实事件循环）覆盖。
// 两者合起来是一条完整的链，**但没有一个测试同时覆盖两端**，这里如实说明。
//
// 样本不进版本库，因此未设置 `APPINFOTOOL_SAMPLES` 时整体跳过：
//
// ```sh
// APPINFOTOOL_SAMPLES=/path/to/samples flutter test test/real_samples_ui_test.dart
// ```

import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ios_codesign_step.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _samplesDir = Platform.environment['APPINFOTOOL_SAMPLES'];

File? _firstSample(String extension) {
  final dir = _samplesDir;
  if (dir == null || dir.isEmpty) return null;
  final directory = Directory(dir);
  if (!directory.existsSync()) return null;
  final matches = directory
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith(extension))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return matches.isEmpty ? null : matches.first;
}

/// 用与界面相同的代码路径把真实 APK 解析成一个 [FileState]。
Future<FileState> _parseApk(String path) async {
  final info = await getApkInfo(path);
  final hashes = await computeFileHashes(path);
  return FileState(
    filePath: path,
    fileSize: File(path).lengthSync(),
    apkInfo: info,
    md5Hash: hashes.md5,
    sha1Hash: hashes.sha1,
    sha256Hash: hashes.sha256,
  );
}

/// 同上，针对 IPA。
Future<FileState> _parseIpa(String path) async {
  final task = await IpaParseTask.start(path);
  final events = await task.events.toList();
  final analysis = events.whereType<IpaParseSucceeded>().first.analysis;

  IosCodeSignResult? codeSign;
  if (analysis.mainApp != null) {
    codeSign = await IosCodeSignStep.run(path, analysis.mainApp!);
  }

  final hashes = await computeFileHashes(path);
  return FileState(
    filePath: path,
    fileSize: File(path).lengthSync(),
    ipaAnalysis: analysis,
    iosCodeSign: codeSign,
    md5Hash: hashes.md5,
    sha1Hash: hashes.sha1,
    sha256Hash: hashes.sha256,
  );
}

/// 用给定状态渲染详情页。
Future<ProviderContainer> _pumpInfoPage(
  WidgetTester tester,
  FileState state,
) async {
  // 详情页是一个 ListView：默认 800x600 的测试视口只会构建**可见的那几张卡**，
  // 于是哈希、加固线索、诊断这些排在后面的内容根本不会出现在 widget 树里。
  // 断言它们就等于断言一个从没被构建过的东西。
  //
  // 把视口放高，让整列卡片都进入布局范围 —— 比逐个 scrollUntilVisible 简单，
  // 也比「只断言首屏」更不容易漏。
  tester.view.physicalSize = const Size(1200, 8000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentFileStateProvider.notifier).update(state);
  // 详情页的 Android 卡片读的是 `currentApkInfoProvider`（不是 FileState 里的
  // apkInfo）—— `loadApkInfo` 会同时更新两者，测试必须照做，否则渲染出来
  // 是一排只有标题、没有值的空卡片。
  if (state.apkInfo != null) {
    container.read(currentApkInfoProvider.notifier).update(state.apkInfo);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: const MaterialApp(home: APKInfoPage()),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// 把界面上所有可见文本拼起来，便于整体断言。
///
/// 两种都要收：`TitleValueLayout` 用 `Text` 渲染标题、用 **`SelectableText`**
/// 渲染值。只收前者会得到一串「只有标题、没有值」的假象，让人误以为界面
/// 渲染不出来 —— 实际是断言方法本身漏了一半。
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

void main() {
  final dir = _samplesDir;
  // `group` 的 skip 接受字符串（会作为跳过原因展示），而 `testWidgets` 的
  // skip 只接受 bool —— 因此把跳过条件放在 group 上，这样**原因不会被丢掉**。
  final skipReason =
      dir == null || dir.isEmpty ? '未设置 APPINFOTOOL_SAMPLES，界面端到端未执行' : null;

  group('真实 APK 的详情页', () {
    final sample = _firstSample('.apk');
    late FileState state;

    setUpAll(() async {
      state = await _parseApk(sample!.path);
    });

    testWidgets('解析完成后界面显示真实字段，而不是空值', (tester) async {
      await _pumpInfoPage(tester, state);

      final analysis = state.analysis!;
      expect(analysis.appName.hasValue, isTrue);
      expect(analysis.packageId.hasValue, isTrue);
      expect(analysis.sha256.hasValue, isTrue);

      final text = _visibleText(tester);
      expect(text, contains(analysis.packageId.value!));
      expect(text, contains(analysis.appName.value!));
      expect(text, contains(analysis.sha256.value!));
    });

    testWidgets('加固线索连同证据一起出现在界面上', (tester) async {
      await _pumpInfoPage(tester, state);

      final hints = state.analysis!.android!.hardeningHints;
      expect(hints, isNotEmpty, reason: '这份样本应当报出加固线索');

      final text = _visibleText(tester);
      for (final hint in hints) {
        // 线索名与证据都要出现 —— 只说「可能被加固」没有排查价值。
        expect(text, contains(hint.signal.name),
            reason: '界面没有显示线索 ${hint.signal.name}');
        expect(text, contains(hint.evidence),
            reason: '界面没有显示线索证据 ${hint.evidence}');
      }
    });

    testWidgets('未计算完哈希时说明「正在计算」，而不是显示成没有哈希', (tester) async {
      await _pumpInfoPage(tester, state.copyWith(isComputingHash: true));

      final text = _visibleText(tester);
      expect(text, contains(t.file_info.computing_hash));
    });
  }, skip: skipReason);

  group('真实 IPA 的详情页', () {
    final sample = _firstSample('.ipa');
    late FileState state;

    setUpAll(() async {
      state = await _parseIpa(sample!.path);
    });

    testWidgets('解析完成后界面显示 iOS 专属字段', (tester) async {
      await _pumpInfoPage(tester, state);

      final ios = state.analysis!.ios!;
      final text = _visibleText(tester);

      // 平台标识：用户第一眼要能确认这是个 iOS 包。
      expect(text, contains(t.ios_info.platform_badge));
      expect(text, contains(ios.bundleIdentifier.value!));
      expect(text, contains(ios.shortVersion.value!));
      expect(text, contains(ios.minimumOSVersion.value!));
      expect(text, contains(t.ios_info.container_section));
      expect(text, contains(t.ios_info.binary_section));
    });

    testWidgets('签名结论与原始输出都出现在界面上', (tester) async {
      await _pumpInfoPage(tester, state);

      final codeSign = state.iosCodeSign!;
      expect(codeSign.toolExecuted, isTrue, reason: 'macOS 上应当真的执行了 codesign');

      final text = _visibleText(tester);
      expect(text, contains(t.ios_info.codesign_section));

      // 结论文案要与状态一致。
      expect(
        text,
        contains(codeSign.status == SignatureStatus.verificationFailed
            ? t.signature.status_failed
            : t.signature.status_verified),
      );

      // 原始输出的首行必须出现 —— 结论不是「通过」时，具体原因只在那里。
      // 断言用**工具输出的首行**而不是写死的措辞：codesign 的文案会随系统
      // 版本变化，写死会让测试因为无关原因变红。
      final firstLine = codeSign.stderr.trim().split('\n').first.trim();
      if (firstLine.isNotEmpty) {
        expect(text, contains(firstLine));
      }
    });

    testWidgets('未解析的图标说明原因，而不是留空白', (tester) async {
      await _pumpInfoPage(tester, state);

      final ios = state.analysis!.ios!;
      expect(ios.icon!.unresolved, isNotEmpty,
          reason: '这份样本的图标在 Assets.car 里，应当有未解析项');

      final text = _visibleText(tester);
      expect(text, contains(t.ios_info.icon_declared_unresolved));
      expect(text, contains('Assets.car'));
    });

    testWidgets('被截断的嵌套清单在界面上有说明', (tester) async {
      await _pumpInfoPage(tester, state);

      expect(
        state.analysis!.diagnostics.map((d) => d.code),
        contains('ios.nested.truncated'),
        reason: '这份样本有 27 个框架，超过 24 条上限',
      );

      final text = _visibleText(tester);
      expect(text, contains('ios.nested.truncated'));
    });
  }, skip: skipReason);

  testWidgets('未设置样本目录时界面测试整体跳过', (tester) async {
    if (skipReason == null) return;
    expect(skipReason, contains('未执行'));
  });
}
