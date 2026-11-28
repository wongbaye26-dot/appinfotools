import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/utils/privacy_inventory.dart';
import 'package:apk_info_tool/widgets/privacy_summary_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PrivacyInventory _inventory({bool librariesRead = false}) => PrivacyInventory(
      permissionsRead: true,
      totalPermissions: 4,
      riskCounts: const {
        AndroidPermissionRisk.high: 1,
        AndroidPermissionRisk.sensitive: 1,
        AndroidPermissionRisk.normal: 1,
        AndroidPermissionRisk.unknown: 1,
      },
      notable: const [
        PrivacyPermission(
          name: 'android.permission.READ_SMS',
          shortName: 'READ_SMS',
          risk: AndroidPermissionRisk.high,
          label: 'Read your text messages',
        ),
        PrivacyPermission(
          name: 'android.permission.CAMERA',
          shortName: 'CAMERA',
          risk: AndroidPermissionRisk.sensitive,
          label: 'Take pictures and videos',
        ),
      ],
      sdks: librariesRead
          ? const [
              PrivacySdk(label: 'Flutter', kind: 'nativeLibrary', hitCount: 2)
            ]
          : const [],
      librariesRead: librariesRead,
      iosUsageKeys: const [],
    );

Future<void> _pump(WidgetTester tester, PrivacyInventory inventory) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
              child: PrivacySummaryCard(inventory: inventory)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t = AppLocale.en.buildSync();

  testWidgets('隐私卡：风险芯片、高敏条目与 SDK 提示', (tester) async {
    await _pump(tester, _inventory());

    expect(find.text(t.privacy.title), findsOneWidget);
    expect(find.text('High risk · 1'), findsOneWidget);
    expect(find.text('Sensitive · 1'), findsOneWidget);
    expect(find.text('Read your text messages'), findsOneWidget);
    expect(find.text(t.privacy.sdk_hint), findsOneWidget);
  });

  testWidgets('加载了库识别时显示 SDK 数量而不是提示', (tester) async {
    await _pump(tester, _inventory(librariesRead: true));
    expect(find.text(t.privacy.sdk_count(count: '1')), findsOneWidget);
    expect(find.text(t.privacy.sdk_hint), findsNothing);
  });
}
