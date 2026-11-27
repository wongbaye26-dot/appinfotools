import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/setting_page.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('V4 设置页宽屏有分区导航且不溢出', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
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
            home: const Scaffold(body: SettingPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(t.settings.environment), findsWidgets);
    expect(find.text(t.settings.about), findsWidgets);

    await tester.tap(find.text(t.settings.appearance).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
