// 概览页「安全分析」为空 —— 回归测试。
//
// 事故现场：Android 的安全审计结果挂在 `ApkInfo.securityResult` 上（worker
// 直接把模型字段填好），而 `FileState.securityResult` 只有 iOS 会写。于是
// 概览页统一读 `FileState.securityResult`，在 Android 上永远拿到 null，把
// 「做了安全检测、有 3 条发现」渲染成了「— / 未做安全分析」。
//
// 这里钉两层：
// 1. 模型层：`FileState.effectiveSecurityResult` 两个平台的来源都认；
// 2. 界面层：带 Android 安全结论的状态下，POSTURE 卡显示真实条数而不是 `—`。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/overview/overview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

SecurityFinding _finding(SecuritySeverity severity, String ruleId) =>
    SecurityFinding(
      ruleId: ruleId,
      platform: SecurityPlatform.android,
      category: SecurityCategory.backgroundTask,
      severity: severity,
      confidence: SecurityConfidence.confirmed,
      finding: 'finding $ruleId',
      evidence: const [],
      recommendation: 'review',
    );

SecurityAnalysisResult _security() => SecurityAnalysisResult(
      engineVersion: 'android-security-test',
      rulesVersion: 'android-rules-test',
      findings: [
        _finding(SecuritySeverity.p0, 'ANDROID-TEST-A'),
        _finding(SecuritySeverity.p2, 'ANDROID-TEST-B'),
        _finding(SecuritySeverity.p3, 'ANDROID-TEST-C'),
      ],
      limitations: const [AnalysisNote('test.limitation', 'test limitation')],
    );

ApkInfo _apk({SecurityAnalysisResult? security}) => ApkInfo()
  ..packageName = 'com.example.demo'
  ..label = 'Demo'
  ..versionName = '1.2.3'
  ..versionCode = 45
  ..sdkVersion = 24
  ..targetSdkVersion = 34
  ..manifestSource = FieldSource.builtinParser
  ..securityResult = security;

Future<void> _pump(WidgetTester tester, FileState state) async {
  SharedPreferences.setMockInitialValues(
      <String, Object>{'recent_files': '[]'});
  await Config.init();
  await Config.loadConfig();
  addTearDown(Config.flushAll);

  tester.view.physicalSize = const Size(1040, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentFileStateProvider.notifier).update(state);
  container.read(currentApkInfoProvider.notifier).update(state.apkInfo);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: const MaterialApp(home: Scaffold(body: OverviewPage())),
      ),
    ),
  );
  await tester.pump();
}

String _visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(widget.data ?? '');
  }
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.writeln(widget.text.toPlainText());
  }
  return buffer.toString();
}

void main() {
  group('FileState.effectiveSecurityResult', () {
    test('Android：结论写在 ApkInfo 上，也必须读得到', () {
      final security = _security();
      final state = FileState(apkInfo: _apk(security: security));

      expect(state.securityResult, isNull, reason: 'Android 不再单独写这份');
      expect(state.effectiveSecurityResult, same(security));
    });

    test('iOS 与 Android 同时存在时以 FileState 上的为准（解析事件显式写入）', () {
      final onState = _security();
      final onApk = _security();
      final state = FileState(
        apkInfo: _apk(security: onApk),
        securityResult: onState,
      );

      expect(state.effectiveSecurityResult, same(onState));
    });

    test('两边都没有时是 null：未做检测不能伪造一个空结果', () {
      final state = FileState(apkInfo: _apk());
      expect(state.effectiveSecurityResult, isNull);
    });

    test('FileState.analysis 与 effectiveSecurityResult 结论一致', () {
      final security = _security();
      final state = FileState(apkInfo: _apk(security: security));

      expect(state.analysis?.security, same(security));
      expect(state.effectiveSecurityResult?.findings.length,
          state.analysis!.security!.findings.length);
    });
  });

  group('概览页 POSTURE 卡', () {
    testWidgets('Android 有安全结论时显示发现条数与 HIGH 分组，而不是 —', (tester) async {
      await _pump(
        tester,
        FileState(
          filePath: '/tmp/samples/demo-1.2.3.apk',
          fileSize: 42465437,
          apkInfo: _apk(security: _security()),
        ),
      );

      final text = _visibleText(tester);
      expect(text, contains('POSTURE / STATIC'));
      expect(text, contains(t.overview.stat_findings));
      // 3 条发现：HIGH 1 / REVIEW 1 / INFO 1。
      expect(text, contains('3'));
      expect(text, contains('HIGH'));
      expect(text, contains('REVIEW'));
      expect(text, contains('INFO'));
    });

    testWidgets('未做安全检测时仍显示 —（不能把「没查」说成「0 条」）', (tester) async {
      await _pump(
        tester,
        FileState(
          filePath: '/tmp/samples/demo-1.2.3.apk',
          fileSize: 42465437,
          apkInfo: _apk(),
        ),
      );

      final text = _visibleText(tester);
      expect(text, contains('POSTURE / STATIC'));
      expect(text, contains('—'));
    });
  });
}
