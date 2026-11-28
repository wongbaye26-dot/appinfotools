// 权限面板：分组、官方说明与保护级别。
//
// 断言用的是「风险策略 + 平台数据」组合后的可见结果，而不是像素：语言切
// 换、字体度量都会变，但「READ_SMS 归到高风险」「自定义权限说明它不是框架
// 权限」这两条不会。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/widgets/android_permissions_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AndroidMetadata.instance.ensureLoaded();
  });

  Future<void> pump(WidgetTester tester, List<String> permissions) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 800,
                  child: AndroidPermissionsPanel(permissions: permissions),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按风险分组并给出官方说明', (tester) async {
    await pump(tester, const [
      'android.permission.READ_SMS',
      'android.permission.CAMERA',
      'android.permission.ACCESS_NETWORK_STATE',
      'com.example.permission.INTERNAL',
    ]);

    expect(find.text('4 permissions'), findsOneWidget);
    // 高危、敏感、普通、未知各一组。
    expect(find.text('High risk (1)'), findsOneWidget);
    expect(find.text('Sensitive (1)'), findsOneWidget);
    expect(find.text('Normal (1)'), findsOneWidget);
    expect(find.text('Unknown (1)'), findsOneWidget);

    // 框架权限的说明来自平台表；自定义权限明确说明不是框架权限。
    expect(find.text('Not an Android framework permission'), findsOneWidget);
    expect(
      find.textContaining('This app can read all SMS'),
      findsOneWidget,
    );
  });

  testWidgets('保护级别用 tooltip 说明原始位掩码', (tester) async {
    await pump(tester, const ['android.permission.READ_SMS']);

    final chip = find.byWidgetPredicate((widget) =>
        widget is Tooltip &&
        (widget.message ?? '').startsWith('Protection level: Dangerous'));
    expect(chip, findsOneWidget);
    // tooltip 的第二段是原始值与标志位，界面上不直接铺开。
    final tooltip = tester.widget<Tooltip>(chip).message!;
    expect(tooltip, contains('0x1'));
  });

  testWidgets('标志位跟着界面语言翻译，不留英文标识符', (tester) async {
    // CAMERA 的原始值是 0x1001：dangerous 位 + instant 标志位。
    await pump(tester, const ['android.permission.CAMERA']);

    final chip = find.byWidgetPredicate((widget) =>
        widget is Tooltip &&
        (widget.message ?? '').startsWith('Protection level: Dangerous'));
    expect(chip, findsOneWidget);
    final tooltip = tester.widget<Tooltip>(chip).message!;
    expect(tooltip, contains('0x1001'));
    expect(tooltip, contains('Instant'));
    expect(tooltip, isNot(contains('instant,')));
  });

  testWidgets('空清单明确说没有，而不是留白', (tester) async {
    await pump(tester, const []);
    expect(find.text('-'), findsOneWidget);
  });
}
