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

import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ios_codesign_step.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/diff/diff_page.dart';
import 'package:apk_info_tool/utils/diff_report.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/ios_icon_decoder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_directory.dart';

/// 样本目录扫描结果 —— 与 `real_samples_test.dart` 共用同一份发现逻辑。
final SampleDirectory _samples = SampleDirectory.fromEnvironment();

/// 取该类型的第一个样本；没有时返回 `null`（调用方据此**跳过**，而不是崩）。
File? _firstSample(SampleKind kind) {
  final list = _samples.samplesOf(kind);
  return list.isEmpty ? null : list.first;
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
  // 视口用**真实桌面尺寸**（1200×800），不再靠「把视口拉到 8000/40000 高」
  // 让整列卡片一次性进入布局范围。
  //
  // 那种做法的前提是「视口够高 ⇒ 所有卡片都被构建」，而详情页的滚动结构是
  // `DetailTabView._buildTestView` 里的 `ListView` —— **懒构建**，视口外的东西
  // 根本不会进 widget 树。视口一加高，卡片也变长（真实样本有 27 个 Framework、
  // 截断到 24 条），阈值迟早再次失效，而且失效方式是「断言莫名其妙找不到文本」。
  //
  // 改为：视口固定成真实尺寸，需要深层的断言用 `_scrollToFindText` 真的滚过去。
  // 这样测试依赖的是「内容存在且可滚动到」，而不是某个魔法像素高度。
  tester.view.physicalSize = const Size(1200, 800);
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

/// 取详情页最外层的纵向滚动位置。
///
/// 找不到就 `fail`（构建层失败），而不是返回 `null` 让调用方自己去猜 ——
/// 「页面没构建出来」与「滚不到目标」是两件事，失败信息必须能分开。
ScrollableState _outerScrollable(WidgetTester tester) {
  final scrollables = find.byType(Scrollable);
  if (scrollables.evaluate().isEmpty) {
    fail('详情页里找不到任何 Scrollable：页面可能没有构建成功（构建层失败）');
  }
  return tester.state<ScrollableState>(scrollables.first);
}

/// 把列表往下推一步；返回**是否真的动了**。
///
/// 用 `jumpTo` 直接驱动 `ScrollPosition`，**刻意不用 `tester.drag`**。
///
/// 原因（实测，不是推测）：`tester.drag` 模拟的是**触摸**指针，而详情页里
/// 每一个字段值都是 `SelectableText`（`TitleValueLayout` 就是这么渲染的）。
/// 触摸拖拽落在可选中的文本上时，文本选择的手势识别器赢得手势竞技场 ——
/// 列表**一动不动**。同一页面上实测：
///
/// | 拖拽起点落在 | 列表位移 |
/// |---|---|
/// | `RenderEditable`（`SelectableText` 内部） | **0** |
/// | `RenderScrollSemantics` 或别处 | 200 |
///
/// 也就是说「能不能滚到目标」取决于拖拽点恰好压在哪个控件上 —— 而内容一滚，
/// 压在什么上就变了。这不是「测试写得不够稳」，是**方法本身不成立**：
/// 拿触摸拖拽去驱动一个满是可选文本的页面，等于掷骰子。真实样本上的表现就是
/// 「滚到 MD5 卡住、后面的 SHA-1 / SHA-256 永远看不到」，而两张卡其实一直在树里。
///
/// `jumpTo` 仍然是真的滚动（懒构建的卡片照常进入 widget 树），只是绕开了
/// 手势竞技场。`maxScrollExtent` 会随着卡片被构建而变大，因此**每一步都重新读**，
/// 不能缓存。
bool _scrollStep(ScrollableState state, double step) {
  final position = state.position;
  if (!position.hasContentDimensions) return false;
  final before = position.pixels;
  final max = position.maxScrollExtent;
  final target = before + step > max ? max : before + step;
  if (target <= before) return false;
  position.jumpTo(target);
  return true;
}

/// 向下滚动详情页，直到可见文本里出现 [needle]；返回滚过之后的可见文本。
///
/// 详情页最外层是 `DetailTabView._buildTestView` 里的 `ListView` —— 懒构建，
/// 所以**必须**滚动才能让深层卡片进入 widget 树。这里不假设任何视口高度。
Future<String> _scrollToFindText(
  WidgetTester tester,
  String needle, {
  int maxScrolls = 120,
  double step = 320,
}) async {
  final state = _outerScrollable(tester);

  var text = _visibleText(tester);
  if (text.contains(needle)) return text;

  for (var i = 0; i < maxScrolls; i++) {
    // 推不动了 = 已经到底，再滚也是白费。
    if (!_scrollStep(state, step)) break;
    await tester.pump();
    text = _visibleText(tester);
    if (text.contains(needle)) return text;
  }
  return text;
}

/// 从头滚到底，把**沿途**所有可见文本拼起来。
///
/// 用于「页面上确实有这几项」这类断言：这些字段分散在列表不同位置，
/// 而 `_visibleText` 只看当前视口，不滚就只看得到首屏。
///
/// 与旧做法的区别：旧做法把视口拉到 8000 高，指望一次建完；这里是真的滚过去，
/// 不依赖任何像素阈值。滚动本身用 `_scrollStep`（`jumpTo`，不是拖拽）——
/// 理由见那里的注释。
Future<String> _scrollThroughAllText(
  WidgetTester tester, {
  int maxScrolls = 120,
  double step = 320,
}) async {
  final state = _outerScrollable(tester);
  final buffer = StringBuffer()..writeln(_visibleText(tester));

  for (var i = 0; i < maxScrolls; i++) {
    if (!_scrollStep(state, step)) break;
    await tester.pump();
    buffer.writeln(_visibleText(tester));
  }
  return buffer.toString();
}

/// 断言「滚到出现为止」能找到 [needle]，失败时把三种原因分开说清楚。
///
/// - [dataPresent] 为 false → **数据层缺失**，先去查解析 / 审计，不是渲染问题；
/// - 找不到 `Scrollable` → **构建层失败**（在 `_scrollToFindText` 里抛）；
/// - 能滚但滚到底也没出现 → **滚动定位 / 渲染失败**，并把实际可见文本长度报出来。
///
/// 返回滚过之后的可见文本，便于调用方继续做别的断言。
Future<String> _expectTextAfterScroll(
  WidgetTester tester,
  String needle, {
  required bool dataPresent,
  required String dataDescription,
}) async {
  if (!dataPresent) {
    fail('数据层就缺：$dataDescription —— 这不是渲染问题，先查解析/审计');
  }
  final text = await _scrollToFindText(tester, needle);
  if (!text.contains(needle)) {
    fail('页面已构建且可滚动，但滚到底也没出现「$needle」。'
        '数据已确认存在（$dataDescription），因此这是滚动定位或卡片渲染失败。'
        '滚动后可见文本长度=${text.length}');
  }
  return text;
}

void main() {
  // 先把「这次扫到了什么」打进日志，便于辨别跑了什么 / 跳过了什么。
  // ignore: avoid_print
  print('[samples] ${_samples.summary}');

  group('真实 APK 的详情页', () {
    final sample = _firstSample(SampleKind.android);
    late FileState state;

    setUpAll(() async {
      // `sample` 为 null 时这一组已被 skip 拦掉，不会走到这里；
      // 仍然用 `!` 是为了让「skip 条件写错」立刻炸出来，而不是静默跳过。
      state = await _parseApk(sample!.path);
    });

    testWidgets('解析完成后界面显示真实字段，而不是空值', (tester) async {
      await _pumpInfoPage(tester, state);

      final analysis = state.analysis!;
      expect(analysis.appName.hasValue, isTrue);
      expect(analysis.packageId.hasValue, isTrue);
      expect(analysis.sha256.hasValue, isTrue);

      // 哈希卡片排在列表靠后位置，必须真的滚过去才在 widget 树里。
      final text = await _scrollThroughAllText(tester);
      expect(text, contains(analysis.packageId.value!));
      expect(text, contains(analysis.appName.value!));
      expect(text, contains(analysis.sha256.value!));
    });

    testWidgets('加固线索连同证据一起出现在界面上', (tester) async {
      await _pumpInfoPage(tester, state);

      final hints = state.analysis!.android!.hardeningHints;
      expect(hints, isNotEmpty, reason: '这份样本应当报出加固线索');

      final text = await _scrollThroughAllText(tester);
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

      final text = await _scrollThroughAllText(tester);
      expect(text, contains(t.file_info.computing_hash));
    });
  }, skip: _samples.skipReasonFor(SampleKind.android));

  group('真实 IPA 的详情页', () {
    final sample = _firstSample(SampleKind.ios);
    late FileState state;

    setUpAll(() async {
      state = await _parseIpa(sample!.path);
    });

    testWidgets('解析完成后界面显示 iOS 专属字段', (tester) async {
      await _pumpInfoPage(tester, state);

      final ios = state.analysis!.ios!;
      final text = await _scrollThroughAllText(tester);

      // 平台标识：用户第一眼要能确认这是个 iOS 包。
      // 两页的版式一致，这一行是唯一的分辨依据。
      expect(text, contains(t.file_info.platform_ios));
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

      // 验收条件：`codesign verification` 必须能在**滚动到对应位置后**被找到。
      // 不依赖任何固定视口高度。
      await _expectTextAfterScroll(
        tester,
        t.ios_info.codesign_section,
        dataPresent: codeSign.toolExecuted,
        dataDescription: 'codesign 已执行（status=${codeSign.status.name}）',
      );

      // 同一张卡片里的结论文案与原始输出首行也应当在滚动过程中出现。
      final text = await _scrollThroughAllText(tester);
      expect(
        text,
        contains(codeSign.status == SignatureStatus.verificationFailed
            ? t.signature.status_failed
            : t.signature.status_verified),
      );

      // 原始输出的首行：**只在「不是 verified」时**才要求它出现。
      //
      // `DetailRenderer._iosCodeSign` 判据是 `status != verified` —— 验证通过时
      // 刻意不展示原始输出，因为那几行里带着**解包用的临时目录路径**
      // （`/var/folders/.../appinfo_ipa_XXXX/Runner.app: valid on disk`），
      // 每次运行都不同，对用户也没有排查价值。
      //
      // 这条断言把两个方向都钉住：未通过时具体原因必须能看到，通过时不泄漏临时路径。
      // 断言用**工具输出的首行**而不是写死的措辞：codesign 的文案会随系统版本变化。
      final firstLine = codeSign.stderr.trim().split('\n').first.trim();
      if (firstLine.isNotEmpty) {
        if (codeSign.status == SignatureStatus.verified) {
          expect(text, isNot(contains(firstLine)),
              reason: '验证通过时不该把原始输出（含临时解包路径）呈现出来');
        } else {
          expect(text, contains(firstLine), reason: '验证未通过时，具体原因只出现在原始输出里');
        }
      }
    });

    testWidgets('真实 IPA 的图标能真的解码出来（Apple 的 CgBI 变体）', (tester) async {
      final icon = state.analysis!.ios!.icon;
      expect(icon, isNotNull);
      expect(icon!.candidates, isNotEmpty,
          reason: '这份样本的 AppIcon*.png 就在 bundle 顶层，必须能定位到');

      final best = icon.best!;
      // CgBI 的 IHDR 前面还有 CgBI 块，写死偏移 12 会把尺寸读成 null。
      expect(best.pixelWidth, isNotNull, reason: '尺寸读不出来就说明 IHDR 的定位又写死偏移了');
      expect(best.pixelHeight, isNotNull);

      // 解码走的是引擎的真实异步，必须在 runAsync 里给它真实时间。
      late IosIconDecodeResult decoded;
      await tester.runAsync(() async {
        decoded = await IosIconDecoder.decode(best);
      });

      expect(decoded.hasImage, isTrue,
          reason: '图标是 CgBI，不做规范化就解不出来：${decoded.failure}');
      expect(decoded.image!.width, best.pixelWidth);
      expect(decoded.image!.height, best.pixelHeight);
      decoded.image!.dispose();
    });

    testWidgets('未解析的图标说明原因，而不是留空白', (tester) async {
      await _pumpInfoPage(tester, state);

      final ios = state.analysis!.ios!;
      expect(ios.icon!.unresolved, isNotEmpty,
          reason: '这份样本的图标在 Assets.car 里，应当有未解析项');

      final text = await _scrollThroughAllText(tester);
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

      // 验收条件：截断说明必须能在**滚动到对应位置后**被找到。
      await _expectTextAfterScroll(
        tester,
        'ios.nested.truncated',
        dataPresent: state.analysis!.diagnostics
            .any((d) => d.code == 'ios.nested.truncated'),
        dataDescription: '诊断里确有 ios.nested.truncated',
      );
    });
  }, skip: _samples.skipReasonFor(SampleKind.ios));

  // 版本对比（阶段 5）在**真实**结构上的端到端冒烟。
  //
  // 样本目录里只有一个真实 APK，**没有两个真实版本可比** —— 这一点如实说明，
  // 不拿构造数据假装。因此这一组比的是「同一个真实包的两条路径」：
  //
  // - 它能验证适配层 + 差异模型 + 报告在**真实结构**上不炸：22 个组件、
  //   40 条权限、真实的加固线索与安全结果、真实的资源表与 ABI；
  // - 「没有差异」这条结论必须成立（除文件名外）；
  // - 它**不能**验证「两个真实版本之间确实有差异」——那需要两份真实样本，
  //   属于样本目录的缺口，不是代码的缺口。
  group('真实 APK 的版本对比', () {
    final sample = _firstSample(SampleKind.android);
    late FileState state;

    setUpAll(() async {
      state = await _parseApk(sample!.path);
    });

    test('同一个真实包与自己比：没有任何实质差异', () {
      final analysis = state.analysis!;
      final diff = diffOf(analysis, analysis);

      expect(diff.hasChanges, isFalse);
      // 真实数据下这几个维度必须真的读到了值 —— 否则「没差异」是假的，
      // 只是两边都没读到而已。
      for (final id in [
        'android.permissions',
        'android.components',
        'android.locales',
        'android.nativeCodes',
      ]) {
        final set = diff.sets.firstWhere((s) => s.id == id);
        expect(set.comparable, isTrue, reason: '$id 应当可比');
        expect(set.common, isNotEmpty, reason: '$id 在真实样本上应当读到成员');
      }
      // 40 条权限、22 个组件是这份样本的实际规模（解析日志可核对）。
      expect(
        diff.sets
            .firstWhere((s) => s.id == 'android.permissions')
            .common
            .length,
        greaterThanOrEqualTo(30),
      );
    });

    test('真实结构下两份报告都能生成，且条目与模型逐项一致', () {
      final analysis = state.analysis!;
      final diff = diffOf(analysis, analysis);
      final at = DateTime.utc(2026, 10, 16);

      final md = DiffReport.render(analysis, analysis, t, generatedAt: at);
      expect(md, startsWith('# ${t.diff.report_title}'));
      expect(md, contains(sample!.path.split('/').last));
      // 没有差异时不该出现「字段差异」小节。
      expect(md, isNot(contains('## ${t.diff.section_fields}')));

      final map = jsonDecode(
        DiffReport.renderJson(analysis, analysis, generatedAt: at),
      ) as Map<String, dynamic>;
      expect(map['diffReportSchemaVersion'], DiffReport.schemaVersion);
      final sets = (map['sets'] as List).cast<Map<String, dynamic>>();
      expect(
        sets.map((s) => s['id']).toList(),
        diff.sets.map((s) => s.id).toList(),
      );
      // 真实权限清单真的进了 JSON（不是空数组）。
      expect(
        (sets.firstWhere((s) => s['id'] == 'android.permissions')['common']
                as List)
            .length,
        greaterThanOrEqualTo(30),
      );
    });

    testWidgets('差异页能渲染真实数据，并允许导出', (tester) async {
      // 同一个真实包挂两条路径：缓存按 path 索引，这样页面才会进入「两侧都选好」
      // 的状态。差异因此只有文件名一条 —— 这正是我们要断言的真实行为。
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: const MaterialApp(home: Scaffold(body: DiffPage())),
          ),
        ),
      );
      await tester.pump();

      final notifier = container.read(currentFileStateProvider.notifier);
      notifier.update(state.copyWith(filePath: '/tmp/samples/hardened-v1.apk'));
      await tester.pump();
      notifier.update(state);
      await tester.pump();

      final buffer = StringBuffer();
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        buffer.writeln(w.data ?? '');
      }
      for (final w in tester.widgetList<SelectableText>(
        find.byType(SelectableText),
      )) {
        buffer.writeln(w.data ?? '');
      }
      final text = buffer.toString();

      // 真实文件名出现在两侧槽位里。
      expect(text, contains('hardened.apk'));
      expect(text, contains('hardened-v1.apk'));

      // 两侧是**同一个包**，因此唯一的变化是文件名。
      expect(text, contains(t.diff.fields.file_fileName));
      expect(text, contains(t.diff.kind_changed));
      // 集合层面没有任何变化 → 不出现「集合差异」区。这条同时钉住
      // 「页面只列变化的集合」这条口径在真实数据上成立（40 条权限、
      // 22 个组件都读到了，但一条都不显示 —— 它们没变）。
      expect(
        text,
        isNot(contains(t.diff.section_sets)),
        reason: '真实权限 / 组件都读到了，但两侧相同，不该出现在差异区里',
      );
      // 「没查签名」必须出现在「无法比较」区，而不是被算成差异。
      expect(text, contains(t.diff.section_unknown));
      expect(text, contains(t.diff.kind_unknown));

      // 导出按钮可点：两侧同平台、都有解析结果。
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, t.diff.export_action),
      );
      expect(button.onPressed, isNotNull);
    });
  }, skip: _samples.skipReasonFor(SampleKind.android));

  // 这一组是「跳过原因本身」的断言：把五种情况分别钉住，避免以后有人把
  // 「目录里没有 IPA」又压回成「未配置」。
  group('样本目录状态与跳过原因', () {
    testWidgets('未配置时两类都报告「未执行」', (tester) async {
      final scan = SampleDirectory.scan(path: null);
      expect(scan.status, SampleDirStatus.notConfigured);
      for (final kind in SampleKind.values) {
        expect(scan.skipReasonFor(kind), contains('未执行'));
      }
    });

    testWidgets('本次实际扫描到的状态与跳过原因自洽', (tester) async {
      final reason = _samples.skipReasonFor(SampleKind.ios);
      if (_samples.samplesOf(SampleKind.ios).isEmpty) {
        expect(reason, isNotNull);
        expect(reason, isNotEmpty);
      } else {
        expect(reason, isNull);
      }
      expect(_samples.summary, contains('样本目录['));
    });
  });
}
