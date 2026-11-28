import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/package_browser_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实文件 IO 在 widget test 的 fake-async 里会互相等死，统一在 runAsync 里跑，
/// 并轮询到目标出现（进度圈会一直转，pumpAndSettle 会超时）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int attempts = 80,
}) async {
  for (var i = 0; i < attempts; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

void main() {
  testWidgets('文件浏览：树、搜索与图片预览', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: PackageBrowserPanel(
                    packagePath: 'test/fixtures/apk/icon-png.apk',
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await _pumpUntil(
          tester, () => find.text('AndroidManifest.xml').evaluate().isNotEmpty);
      expect(find.text('AndroidManifest.xml'), findsOneWidget);
      expect(find.text('resources.arsc'), findsOneWidget);
      // 顶层目录默认展开一层：res 已展开，但 res/mipmap-hdpi-v4 还是折叠的。
      expect(find.textContaining('mipmap-hdpi-v4'), findsWidgets);
      expect(find.textContaining('ic_launcher.png'), findsNothing);

      // 展开二级目录，图标文件出现在树里。
      await tester.tap(find.textContaining('mipmap-hdpi-v4').first);
      await tester.pump();
      expect(find.textContaining('ic_launcher.png'), findsWidgets);

      // 搜索：只留命中路径。
      await tester.enterText(find.byType(TextField), 'launcher');
      await tester.pump();
      expect(find.text('AndroidManifest.xml'), findsNothing);
      expect(find.textContaining('ic_launcher.png'), findsWidgets);

      // 点开图片 → 预览对话框里出现 Image。
      await tester.tap(find.textContaining('ic_launcher.png').first);
      await _pumpUntil(
        tester,
        () => find.byType(Image).evaluate().isNotEmpty,
      );
      expect(find.byType(Image), findsWidgets);
      expect(find.text(t.browser.title), findsWidgets);
    });
  });
}
