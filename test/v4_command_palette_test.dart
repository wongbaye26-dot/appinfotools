// 顶栏搜索面板：页面跳转 + 重新打开最近分析的包。
//
// 这里不测「搜包内部字符串」——那是产品明确没做的能力。测的是两件事：
// 过滤是按路径匹配的；选中一行会发出打开请求而不是只关掉弹窗。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/ui/shell/v4_command_palette.dart';
import 'package:apk_info_tool/utils/recent_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRecentFiles extends RecentFiles {
  _FakeRecentFiles(this.entries);

  final List<RecentFileEntry> entries;

  @override
  List<RecentFileEntry> build() => entries;
}

void main() {
  final entries = [
    RecentFileEntry(
      path: '/tmp/samples/bali_6.9.99.ipa',
      size: 4096,
      analyzedAt: DateTime(2026, 11, 28),
      platform: 'ios',
    ),
    RecentFileEntry(
      path: '/tmp/samples/demo.apk',
      size: 1024,
      analyzedAt: DateTime(2026, 11, 27),
      platform: 'android',
    ),
  ];

  Future<void> pumpPalette(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentFilesProvider.overrideWith(() => _FakeRecentFiles(entries)),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => showV4CommandPalette(context, ref),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('列出最近分析，并按路径过滤', (tester) async {
    await pumpPalette(tester);

    expect(find.text('bali_6.9.99.ipa'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'demo');
    await tester.pumpAndSettle();
    expect(find.text('demo.apk'), findsOneWidget);
    expect(find.text('bali_6.9.99.ipa'), findsNothing);
  });

  testWidgets('选中最近文件会发出打开请求并跳到分析页', (tester) async {
    final container = ProviderContainer(overrides: [
      recentFilesProvider.overrideWith(() => _FakeRecentFiles(entries)),
    ]);
    addTearDown(container.dispose);
    // provider 是 autoDispose：没有监听者时状态会在回调结束后被回收，
    // 这里挂一个空监听模拟 AppShell 的常驻监听。
    container.listen(shellNavigationProvider, (_, __) {});

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => showV4CommandPalette(context, ref),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bali_6.9.99.ipa'));
    await tester.pumpAndSettle();

    expect(container.read(pendingOpenRequestProvider),
        '/tmp/samples/bali_6.9.99.ipa');
    expect(container.read(shellNavigationProvider).target, 'analysis');
  });
}
