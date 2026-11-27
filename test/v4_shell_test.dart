import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/ui/shell/app_shell.dart';
import 'package:apk_info_tool/ui/shell/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildV4Theme(
            seed: V4Colors.violet,
            brightness: Brightness.light,
          ),
          home: const AppShell(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('V4 shell', () {
    testWidgets('桌面尺寸下 shell 正常布局', (tester) async {
      await _pumpShell(tester, const Size(1440, 900));

      expect(tester.takeException(), isNull);
      expect(find.byType(AppSidebar), findsOneWidget);
      expect(find.text(t.nav.overview), findsWidgets);
    });

    testWidgets('顶栏搜索打开页面跳转面板', (tester) async {
      await _pumpShell(tester, const Size(1280, 800));

      await tester.tap(find.text(t.shell.search_hint).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(t.shell.command_title), findsOneWidget);
      expect(find.text(t.nav.settings), findsWidgets);

      await tester.tap(find.text(t.nav.settings).last);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('最小窗口宽度下不溢出', (tester) async {
      await _pumpShell(tester, const Size(900, 600));

      expect(tester.takeException(), isNull);
      expect(find.byType(AppSidebar), findsOneWidget);
    });
  });
}
