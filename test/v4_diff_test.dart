// V4 版式的差异页验收：结构、分段筛选、折叠、右栏卡片。
//
// 与 `test/diff_page_test.dart` 分工不同：
// - `diff_page_test.dart` 钉**逻辑**（三态、「没读到」≠「新增」、导出入口），
//   用的是默认 Material 主题，与版式无关；
// - 本文件钉 **V4 版式**（`docs/prototypes/ui-redesign-v4/screens/05-diff.html`）：
//   眉标、OLD/NEW 标、摘要条、四列字段表、右栏四张卡、折叠页脚。
//
// 最后一条 `V4 差异页渲染（1440×1024）` 只是抓图给人看，不做断言 ——
// 与 `test/_diff_snapshot.dart` 同类，但它跑的是**真实 V4 主题**，
// 因此可以直接和原型 render 叠着看。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/ui/diff/diff_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 中日韩字符（含全角标点）—— 英文界面里不该出现。
final RegExp _cjk = RegExp(
  r'[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef]',
);

/// 页面上所有可见文本（`Text` + `SelectableText`）。
String _visibleText(WidgetTester tester) {
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

/// 「还有 N 个字段变化未展开」—— N 由数据决定，按模板逐个对，不写死数字。
String? _hiddenFieldLine(WidgetTester tester) {
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    final data = w.data;
    if (data == null) continue;
    for (var n = 0; n <= 64; n++) {
      if (data == t.diff.fields_hidden(count: n)) return data;
    }
  }
  return null;
}

ApkInfo _apk({
  String packageName = 'com.aurora.notes',
  String label = 'Aurora Notes',
  String? versionName = '2.9.0',
  int? versionCode = 290,
  int? minSdk,
  int? targetSdk,
  int? maxSdk,
  bool? debuggable,
  List<String> permissions = const [],
  List<String> nativeCodes = const [],
  SecurityAnalysisResult? security,
}) =>
    ApkInfo()
      ..packageName = packageName
      ..label = label
      ..versionName = versionName
      ..versionCode = versionCode
      ..sdkVersion = minSdk
      ..targetSdkVersion = targetSdk
      ..maxSdkVersion = maxSdk
      ..applicationDebuggable = debuggable
      ..usesPermissions = permissions
      ..nativeCodes = nativeCodes
      ..manifestSource = FieldSource.builtinParser
      ..securityResult = security;

SecurityFinding _finding(String ruleId, String text) => SecurityFinding(
      ruleId: ruleId,
      platform: SecurityPlatform.android,
      category: SecurityCategory.backgroundTask,
      severity: SecuritySeverity.p2,
      confidence: SecurityConfidence.confirmed,
      finding: text,
      evidence: const [],
      recommendation: 'review',
    );

SecurityAnalysisResult _security(List<SecurityFinding> findings) =>
    SecurityAnalysisResult(
      engineVersion: 'e',
      rulesVersion: 'r',
      findings: findings,
    );

FileState _state(String path, int size, ApkInfo info) =>
    FileState(filePath: path, fileSize: size, apkInfo: info);

/// 原型同款的两个版本：2.9.0 → 3.20.0。
///
/// 与原型 render 的差别只有 DEX 数（容器结构不好在单测里造）——
/// 少了这一段就少一行 `新增 DEX`，不影响版式判断。
List<FileState> _prototypePair() => [
      _state(
        '/tmp/aurora-2.9.0.apk',
        16882073,
        _apk(
          permissions: const [
            'android.permission.INTERNET',
            'android.permission.CAMERA',
            'android.permission.WAKE_LOCK',
          ],
          nativeCodes: const ['arm64-v8a'],
          targetSdk: 34,
          security: _security([
            _finding('ANDROID-DEBUGGABLE', 'Debug build is allowed'),
          ]),
        ),
      ),
      _state(
        '/tmp/aurora-3.20.0.apk',
        19293798,
        _apk(
          versionName: '3.20.0',
          versionCode: 320,
          targetSdk: 36,
          permissions: const [
            'android.permission.INTERNET',
            'android.permission.CAMERA',
            'android.permission.WAKE_LOCK',
            'android.permission.POST_NOTIFICATIONS',
            'android.permission.ACCESS_FINE_LOCATION',
          ],
          nativeCodes: const ['arm64-v8a', 'armeabi-v7a'],
          security: _security([
            _finding('ANDROID-DEBUGGABLE', 'Debug build is allowed'),
            _finding('ANDROID-ALLOW-BACKUP', 'Backup is allowed'),
          ]),
        ),
      ),
    ];

/// 挂起差异页并投喂已解析结果（顺序与 `diff_page_test.dart` 一致：
/// 先让页面把 provider 建起来，再逐个更新缓存）。
Future<void> _pump(
  WidgetTester tester,
  List<FileState> files, {
  Size viewSize = const Size(1400, 2600),
  String locale = 'zh-CN',
  String? fontFamily,
  bool v4Theme = false,
}) async {
  tester.view.physicalSize = viewSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // 语言包是 deferred 的，而 `testWidgets` 的测试体跑在 fake-async 区里 ——
  // `loadLibrary()` 的回调等不到真实事件循环，必须放进 `runAsync`。
  await tester.runAsync(() => LocaleSettings.setLocaleRaw(locale));

  final container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: v4Theme
              ? buildV4Theme(
                  seed: V4Colors.violet,
                  brightness: Brightness.light,
                  fontFamily: fontFamily,
                )
              : ThemeData(fontFamily: fontFamily),
          home: const Scaffold(body: RepaintBoundary(child: DiffPage())),
        ),
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
  testWidgets('V4 页头：眉标 + 重新选择 + 导出对比', (tester) async {
    await _pump(tester, _prototypePair());

    // 眉标两半都走语言包：根词与外壳顶栏同源（`工作区 / 对比`）。
    expect(find.text(t.diff.kicker_root), findsOneWidget);
    expect(find.text(t.diff.kicker_leaf), findsOneWidget);
    expect(find.text(t.diff.title), findsOneWidget);
    expect(find.text(t.diff.subtitle), findsOneWidget);
    expect(find.text(t.diff.reselect), findsOneWidget);
    // 导出动作沿用语言包的完整键名（原型里是更短的「导出对比」）。
    expect(find.text(t.diff.export_action), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('V4 槽位：应用名 · 版本 + OLD/NEW 标 + 元信息', (tester) async {
    await _pump(tester, _prototypePair());

    expect(find.text('${t.diff.slot_old_tag} APK'), findsOneWidget);
    expect(find.text('${t.diff.slot_new_tag} APK'), findsOneWidget);
    expect(find.text('Aurora Notes · 2.9.0'), findsOneWidget);
    expect(find.text('Aurora Notes · 3.20.0'), findsOneWidget);

    final text = _visibleText(tester);
    // 副标题：包标识 · 大小 · 权限数（DEX 数缺结构就整段不写，不写 0）。
    expect(text, contains('com.aurora.notes'));
    expect(text, contains('16.1 MB'));
    expect(
      text,
      contains('3 ${t.diff.sets.android_permissions}'),
      reason: '左侧 3 条权限',
    );
  });

  testWidgets('V4 摘要条：三段计数 + 分段筛选真的能筛', (tester) async {
    await _pump(tester, _prototypePair());

    expect(find.text(t.diff.stat_field_changes), findsOneWidget);
    expect(find.text(t.diff.stat_set_changes), findsOneWidget);
    expect(find.text(t.diff.tab_all), findsOneWidget);
    expect(find.byKey(const Key('diff.tab.fields')), findsOneWidget);
    expect(find.byKey(const Key('diff.tab.sets')), findsOneWidget);
    expect(find.byKey(const Key('diff.tab.unknown')), findsOneWidget);

    // 默认「全部」：字段表与集合卡都在。
    expect(find.text(t.diff.section_fields), findsOneWidget);
    expect(find.text(t.diff.section_sets), findsOneWidget);

    await tester.tap(find.byKey(const Key('diff.tab.fields')));
    await tester.pumpAndSettle();
    expect(find.text(t.diff.section_fields), findsOneWidget);
    expect(find.text(t.diff.section_sets), findsNothing);

    await tester.tap(find.byKey(const Key('diff.tab.sets')));
    await tester.pumpAndSettle();
    expect(find.text(t.diff.section_sets), findsOneWidget);
    expect(find.text(t.diff.section_fields), findsNothing);

    // 回到「全部」，别把筛选状态留给后面的断言。
    await tester.tap(find.byKey(const Key('diff.tab.all')));
    await tester.pumpAndSettle();
    expect(find.text(t.diff.section_fields), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('V4 字段表：四列列头 + 本地化字段名 + 机器 id 在下面', (tester) async {
    await _pump(tester, _prototypePair());

    expect(find.text(t.diff.col_field), findsOneWidget);
    expect(find.text(t.diff.col_change), findsOneWidget);
    expect(find.text('2.9.0 / ${t.diff.col_old}'), findsOneWidget);
    expect(find.text('3.20.0 / ${t.diff.col_new}'), findsOneWidget);
    expect(find.text(t.diff.sorted_by_impact), findsOneWidget);

    final text = _visibleText(tester);
    expect(text, contains(t.diff.fields.android_targetSdkVersion));
    // 机器 id 只留短尾（原型是 `manifest.targetSdk` 那种风格）。
    expect(text, contains('targetSdkVersion'));
    expect(text, isNot(contains('android.targetSdkVersion')));
    expect(text, contains('34'));
    expect(text, contains('36'));
  });

  testWidgets('V4 右栏：SUMMARY / 无法比较 / REVIEW CHECKLIST / DIFF POLICY',
      (tester) async {
    final files = _prototypePair();
    await _pump(tester, files);
    // 条数与模型同源（UI 与报告读同一份 `PackageDiff`），不写死原型里的 2。
    final diff = diffSubjects(
      diffSubjectOf(files[0].analysis!),
      diffSubjectOf(files[1].analysis!),
    );
    final unknownCount =
        diff.fields.where((f) => f.kind == DiffKind.unknown).length +
            diff.sets.where((s) => !s.comparable).length;

    expect(find.text(t.diff.rail_summary), findsOneWidget);
    expect(find.text(t.diff.rail_read_only), findsOneWidget);
    expect(find.text(t.diff.rail_checklist), findsOneWidget);
    expect(find.text(t.diff.rail_policy), findsOneWidget);
    // 清单每行末尾的 OPEN（3 条里至少 2 条：权限、ABI）。
    expect(find.text(t.diff.rail_open), findsWidgets);

    final text = _visibleText(tester);
    expect(
      text,
      contains(t.diff.unknown_title(count: unknownCount)),
      reason: '未同时读取的条目单独计数',
    );
    expect(text, contains(t.diff.unknown_field_hint));
    expect(text, contains(t.diff.policy_line_3), reason: '口径必须写在页面上');
    expect(text, contains(t.diff.narrative_pkg_same));
  });

  testWidgets('V4 字段表超过 8 行时折叠，页脚按钮可展开', (tester) async {
    await _pump(tester, [
      _state(
        '/tmp/demo-1.0.apk',
        1024,
        _apk(
          packageName: 'com.a',
          label: 'A',
          versionName: '1.0',
          versionCode: 1,
          minSdk: 21,
          targetSdk: 33,
          maxSdk: 35,
          debuggable: true,
          permissions: const ['P1'],
          nativeCodes: const ['arm64-v8a'],
        ),
      ),
      _state(
        '/tmp/demo-2.0.apk',
        2048,
        _apk(
          packageName: 'com.b',
          label: 'B',
          versionName: '2.0',
          versionCode: 2,
          minSdk: 24,
          targetSdk: 34,
          permissions: const ['P2'],
          nativeCodes: const ['x86_64'],
        ),
      ),
    ]);

    expect(_hiddenFieldLine(tester), isNotNull);
    final expand = find.textContaining(t.diff.show_all);
    expect(expand, findsOneWidget);

    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.text(t.diff.show_less), findsOneWidget);
    expect(_hiddenFieldLine(tester), isNull);
  });

  testWidgets('英文 locale：原型短标签走语言包，页面上不再出现中文', (tester) async {
    await _pump(tester, _prototypePair(), locale: 'en');

    // 语言包确实切到了英文（`t` 是当前译文）。
    expect(t.diff.reselect, 'Reselect');
    expect(find.text('Reselect'), findsOneWidget);
    expect(find.text('Field changes'), findsOneWidget);
    expect(find.text('Collection changes'), findsOneWidget);
    // 等宽「仪表盘」字样在英文下仍是 V4 的英文外观。
    expect(find.text('FIELD'), findsOneWidget);
    expect(find.text('SORTED BY IMPACT'), findsOneWidget);
    expect(find.text('SUMMARY'), findsOneWidget);
    expect(find.text('REVIEW CHECKLIST'), findsOneWidget);

    // 整页零中日韩字符 —— 这些位置之前印的是「重新选择」「字段变化」「还有 N 个…」。
    final text = _visibleText(tester);
    expect(_cjk.firstMatch(text), isNull, reason: '英文界面混入了中文：\n$text');
    expect(text, contains('Both versions share the same package name'));
    expect(tester.takeException(), isNull);
  });
}
