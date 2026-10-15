// 版本差异页（阶段 5.2）的验收测试。
//
// 验收条件（`docs/plans/V2.4.0_PROGRESS.md` §17.2）：
// - 能从两个已解析的包进入差异页；
// - 三态各自呈现（新增 / 删除 / 变更）；
// - **`absent` 与「新增」必须区分** —— 左边「文件里没有」是新增，
//   左边「我们没读到」是「说不清」，两者绝不能渲染成同一个标签。
//
// 最后一条是本页存在的意义所在，因此单独一条测试钉住。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/providers/parsed_file_cache.dart';
import 'package:apk_info_tool/ui/diff/diff_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart' show IpaContainer;

/// 页面上所有可见文本（`Text` + `SelectableText`）。
String visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(w.data ?? '');
  }
  for (final w in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    buffer.writeln(w.data ?? '');
  }
  return buffer.toString();
}

ApkInfo android({
  String packageName = 'com.example',
  String? versionName = '1.0',
  int? versionCode = 1,
  int? minSdk,
  int? targetSdk,
  int? maxSdk,
  bool? debuggable,
  List<String> permissions = const [],
  FieldSource source = FieldSource.builtinParser,
}) =>
    ApkInfo()
      ..packageName = packageName
      ..label = 'Demo'
      ..versionName = versionName
      ..versionCode = versionCode
      ..sdkVersion = minSdk
      ..targetSdkVersion = targetSdk
      ..maxSdkVersion = maxSdk
      ..applicationDebuggable = debuggable
      ..usesPermissions = permissions
      ..manifestSource = source;

FileState androidState(String path, int size, ApkInfo info) =>
    FileState(filePath: path, fileSize: size, apkInfo: info);

FileState iosState(String path, int size) => FileState(
      filePath: path,
      fileSize: size,
      ipaAnalysis: IpaAnalysis(container: const IpaContainer()),
    );

/// 把差异页挂起来，并按顺序「解析」给定的文件。
///
/// **顺序很重要**：缓存靠监听累积，必须先让页面把 provider 建起来
/// （否则监听还没注册），再逐个投喂解析结果。
Future<void> pumpDiff(
  WidgetTester tester,
  List<FileState> files, {
  Size viewSize = const Size(1400, 2600),
}) async {
  tester.view.physicalSize = viewSize;
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

  for (final f in files) {
    container.read(currentFileStateProvider.notifier).update(f);
    await tester.pump();
  }
}

void main() {
  group('差异页', () {
    testWidgets('两个已解析的包进来就能看到差异：新增 / 删除 / 变更三态齐现', (tester) async {
      // 左侧：没声明 minSdk、有 maxSdk / debuggable、targetSdk 33
      // 右侧：声明了 minSdk 21、去掉 maxSdk / debuggable、targetSdk 34
      await pumpDiff(tester, [
        androidState(
          '/tmp/demo-1.0.apk',
          1024,
          android(targetSdk: 33, maxSdk: 35, debuggable: true),
        ),
        androidState(
          '/tmp/demo-2.0.apk',
          2048,
          android(targetSdk: 34, minSdk: 21),
        ),
      ]);

      final text = visibleText(tester);

      expect(text, contains(t.diff.kind_changed), reason: 'targetSdk 33 → 34');
      expect(text, contains(t.diff.kind_added), reason: 'minSdk 由无到有');
      expect(text, contains(t.diff.kind_removed),
          reason: 'maxSdk / debuggable 由有到无');

      // 字段名走本地化，不是机器 id。
      expect(text, contains(t.diff.fields.android_targetSdkVersion));
      expect(text, isNot(contains('android.targetSdkVersion')));

      // 两个值都显示出来，中间是箭头 —— 「改成了什么」要看得到。
      expect(text, contains('33'));
      expect(text, contains('34'));
    });

    testWidgets('集合差异分开列新增与删除的成员', (tester) async {
      await pumpDiff(tester, [
        androidState(
          '/tmp/demo-1.0.apk',
          1024,
          android(permissions: ['A', 'B']),
        ),
        androidState(
          '/tmp/demo-2.0.apk',
          2048,
          android(permissions: ['B', 'C']),
        ),
      ]);

      final text = visibleText(tester);
      expect(text, contains(t.diff.sets.android_permissions));
      expect(text, contains(t.diff.added_count(count: 1)));
      expect(text, contains(t.diff.removed_count(count: 1)));
      // 成员本身要列出来 —— 只说「删了 1 项」等于没说。
      expect(text, contains('C'));
      expect(text, contains('A'));
    });

    testWidgets('左侧「没读到」不算新增：显示为无法比较并带原因', (tester) async {
      // `aapt2` 来源**不报** maxSdkVersion。左侧走 aapt2、右侧走内置解析器，
      // 于是 maxSdkVersion 是「左边没读到、右边读到了」——
      // 这**不是**「新增了一项」，而是「这次说不清」。
      final left = androidState(
        '/tmp/demo-1.0.apk',
        1024,
        android(permissions: ['A'], source: FieldSource.aapt2),
      );
      final right = androidState(
        '/tmp/demo-2.0.apk',
        2048,
        android(permissions: ['A'], maxSdk: 35),
      );
      await pumpDiff(tester, [left, right]);

      final text = visibleText(tester);

      expect(
        text,
        contains(t.diff.section_unknown),
        reason: '「我们没读到」的字段必须单独成区',
      );
      expect(text, contains(t.diff.kind_unknown));
      expect(
        text,
        contains('[unsupported]'),
        reason: '要把状态与原因显示出来，而不是留白',
      );

      // 条数用**同一个模型**算出来对照（三端同源：UI 与报告读同一份
      // `PackageDiff`），而不是在测试里另写一套口径。
      final diff = diffSubjects(
        diffSubjectOf(left.analysis!),
        diffSubjectOf(right.analysis!),
      );
      expect(
        text,
        contains(t.diff.summary_unknown(count: diff.unknownFieldCount)),
        reason: '「无法比较」的条数必须单独报出来，不能并进「没有差异」',
      );

      // 本条的关键：整页**不能**出现「新增」。
      // 两侧权限相同、其余集合两侧都是 absent，因此任何「新增」都只可能
      // 来自字段标签 —— 它一旦出现就说明「没读到」被说成了「新增」。
      expect(
        text.contains(t.diff.kind_added),
        isFalse,
        reason: '左边「没读到」被渲染成了「新增」—— 这正是本页要挡的事',
      );
    });

    testWidgets('跨平台比较被拦住，并说明原因', (tester) async {
      await pumpDiff(tester, [
        androidState('/tmp/demo.apk', 1024, android()),
        iosState('/tmp/demo.ipa', 2048),
      ]);

      final text = visibleText(tester);
      expect(text, contains(t.diff.platform_mismatch));
      // 拦住之后不再给出差异结论 —— 免得用户把噪音当差异读。
      expect(text, isNot(contains(t.diff.section_fields)));
    });

    testWidgets('不足两个已解析的包时给出引导与前往分析的入口', (tester) async {
      await pumpDiff(tester, const []);

      final text = visibleText(tester);
      expect(text, contains(t.diff.pick_empty));
      expect(text, contains(t.diff.need_two));
      expect(text, contains(t.diff.pick_hint));
      expect(find.widgetWithText(FilledButton, t.diff.go_analysis),
          findsOneWidget);
    });

    testWidgets('只有一个包时仍然停在引导态，不会拿它和自己比', (tester) async {
      await pumpDiff(tester, [
        androidState('/tmp/demo.apk', 1024, android()),
      ]);

      final text = visibleText(tester);
      expect(text, contains(t.diff.need_two));
      expect(text, isNot(contains(t.diff.section_fields)));
    });
  });

  group('已解析文件缓存', () {
    test('按路径累积；没解析出结构的文件不缓存', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 先读一次把监听唤醒（真实树里由 `AppShell.initState` 做）。
      container.read(parsedFileCacheProvider);
      final notifier = container.read(currentFileStateProvider.notifier);

      // 只打开了文件、还没解析出结构 —— 缓存下来会让差异页列出一个空壳。
      notifier.update(const FileState(filePath: '/tmp/a.apk'));
      expect(container.read(parsedFileCacheProvider), isEmpty);

      notifier.update(androidState('/tmp/a.apk', 1, android()));
      expect(
        container.read(parsedFileCacheProvider).keys,
        ['/tmp/a.apk'],
        reason: '解析出结构之后才进缓存',
      );

      notifier.update(androidState('/tmp/b.apk', 2, android()));
      expect(
        container.read(parsedFileCacheProvider).keys,
        ['/tmp/a.apk', '/tmp/b.apk'],
        reason: '第二个包不能把第一个挤掉 —— 差异页要同时拿到两份',
      );

      // 重新解析同一个路径 → 覆盖那一项，不新增。
      notifier.update(androidState('/tmp/a.apk', 3, android(targetSdk: 34)));
      final cache = container.read(parsedFileCacheProvider);
      expect(cache.keys, ['/tmp/a.apk', '/tmp/b.apk']);
      expect(cache['/tmp/a.apk']!.fileSize, 3);
    });
  });
}
