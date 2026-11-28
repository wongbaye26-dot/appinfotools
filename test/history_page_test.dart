import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/analysis_run.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/pages/history_page.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
