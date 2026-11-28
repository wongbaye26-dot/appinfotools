import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/analysis_run.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/pages/history_page.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:apk_info_tool/utils/analysis_run_repository.dart';

void main() {
  testWidgets('历史页展示真实 run，并给出删除入口', (tester) async {
    final run = AnalysisRun(
      id: 'analysis_1_abcdef12',
      toolVersion: '2.11.0',
      appName: 'SUN',
      platform: PackagePlatform.ios,
      packagePath: '/tmp/sun_signed.ipa',
      packageSha256: 'abc123',
      startedAt: DateTime.utc(2026, 11, 27, 12),
      completedAt: DateTime.utc(2026, 11, 27, 12, 0, 2),
      status: AnalysisRunStatus.success,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildV4Theme(
              seed: V4Colors.violet,
              brightness: Brightness.dark,
            ),
            home: HistoryPage(
                loader: () async => [AnalysisRunSummary.fromRun(run)]),
          ),
        ),
      ),
    );
    // 第一次 pump 启动 Future；第二次让 FutureBuilder 拿到结果。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('SUN'), findsOneWidget);
    expect(find.text('SUCCESS'), findsOneWidget);
    expect(find.text('/tmp/sun_signed.ipa'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    // 没有快照的 run：存档按钮存在但禁用。
    final archived = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.description_outlined),
    );
    expect(archived.onPressed, isNull);
  });

  testWidgets('有存档快照时展示只读报告，不重新解析', (tester) async {
    final snapshot = <String, dynamic>{
      'reportSchemaVersion': 12,
      'generatedAt': '2026-11-27T12:00:02.000Z',
      'findings': [
        {'id': 'a'},
        {'id': 'b'},
      ],
      'application': {
        'permissionDetails': [
          {'name': 'android.permission.INTERNET'},
        ],
      },
      'libraries': {'identifiedSdkCount': 3},
    };
    final run = AnalysisRun(
      id: 'analysis_2_abcdef34',
      toolVersion: '2.11.1',
      appName: 'Demo',
      platform: PackagePlatform.android,
      packagePath: '/tmp/demo.apk',
      startedAt: DateTime.utc(2026, 11, 27, 12),
      completedAt: DateTime.utc(2026, 11, 27, 12, 0, 2),
      status: AnalysisRunStatus.success,
      snapshot: snapshot,
    );
    final repo = _FakeRunRepository(run);

    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildV4Theme(
              seed: V4Colors.violet,
              brightness: Brightness.dark,
            ),
            home: HistoryPage(repository: repo),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final archived = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.description_outlined),
    );
    expect(archived.onPressed, isNotNull);

    await tester
        .tap(find.widgetWithIcon(IconButton, Icons.description_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(t.history.snapshot_title), findsOneWidget);
    expect(find.text(t.history.snapshot_hint), findsOneWidget);
    // 摘要事实来自快照本身：schema 11 / 2 findings / 1 permission / 3 SDKs。
    expect(
      find.textContaining('schema v12 · 2026-11-27T12:00:02.000Z'),
      findsOneWidget,
    );
    expect(find.textContaining('2 findings'), findsOneWidget);
    expect(find.textContaining('1 permissions'), findsOneWidget);
    expect(find.textContaining('3 SDKs'), findsOneWidget);
    // 原始 JSON 可见。
    expect(find.textContaining('"reportSchemaVersion": 12'), findsOneWidget);
  });
}

/// 只读内存替身，避免 widget 测试里在 fake-async 区做真实文件 IO。
class _FakeRunRepository extends AnalysisRunRepository {
  final AnalysisRun run;

  _FakeRunRepository(this.run) : super(Directory.systemTemp);

  @override
  Future<List<AnalysisRunSummary>> list({int limit = 50}) async =>
      [AnalysisRunSummary.fromRun(run)];

  @override
  Future<AnalysisRun?> read(String id) async => id == run.id ? run : null;
}
