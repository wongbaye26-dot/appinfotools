// 组件面板：按类型分组、导出状态与访问限制。
//
// 这次改动的直接动机是「组件卡片太矮、下面空一大片」：旧实现把整份组件清单
// 塞进一个 `TitleValueLayout`，并用 `maxLines` 截断，组件一多就只画前几行。
// 因此测试重点不是某一行文案，而是：
// 1. 所有组件都真实渲染出来（不再被截断）；
// 2. 导出 / 访问限制被区分开（显式导出、默认导出、带 permission 的导出）；
// 3. 按类型分组成卡。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/android_components_panel.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, List<AndroidComponent> components) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 800,
                  child: AndroidComponentsPanel(components: components),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('组件多时不再截断', (tester) async {
    final components = [
      for (var i = 0; i < 40; i++)
        AndroidComponent(
          type: ComponentType.activity,
          name: 'com.example.feature.Screen$i',
          exported: false,
        ),
    ];

    await pump(tester, components);

    expect(find.text('40 components · 0 exported'), findsOneWidget);
    // 首尾都要在：旧实现只渲染前 8 行。
    expect(find.text('com.example.feature.Screen0'), findsOneWidget);
    expect(find.text('com.example.feature.Screen39'), findsOneWidget);
  });

  testWidgets('按类型分组并统计导出', (tester) async {
    await pump(tester, [
      AndroidComponent(
        type: ComponentType.activity,
        name: 'com.example.MainActivity',
        exported: true,
        intentFilters: const [
          IntentFilterInfo(
            actions: ['android.intent.action.MAIN'],
            categories: ['android.intent.category.LAUNCHER'],
          ),
        ],
      ),
      AndroidComponent(
        type: ComponentType.service,
        name: 'com.example.SyncService',
        exported: false,
        permission: 'com.example.permission.SYNC',
      ),
      AndroidComponent(
        type: ComponentType.provider,
        name: 'com.example.DataProvider',
        authorities: 'com.example.data',
        readPermission: 'com.example.permission.READ',
        writePermission: 'com.example.permission.WRITE',
        grantUriPermissions: true,
      ),
      AndroidComponent(
        type: ComponentType.receiver,
        name: 'com.example.BootReceiver',
        hasIntentFilter: true,
      ),
    ]);

    expect(find.text('4 components · 2 exported'), findsOneWidget);
    // 四种类型各一张卡。
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Service'), findsOneWidget);
    expect(find.text('Broadcast receiver'), findsOneWidget);
    expect(find.text('Content provider'), findsOneWidget);

    // 显式导出、带权限的导出、默认导出必须能区分。
    expect(find.text('exported'), findsOneWidget);
    expect(find.text('exported by default'), findsOneWidget);
    expect(find.text('permission=com.example.permission.SYNC'), findsOneWidget);
    expect(
      find.text('authorities=com.example.data'),
      findsOneWidget,
    );
    // “半开”的 provider：读写分别受保护，都要标出来。
    expect(find.text('read=com.example.permission.READ'), findsOneWidget);
    expect(find.text('write=com.example.permission.WRITE'), findsOneWidget);
    expect(find.text('grantUriPermissions'), findsOneWidget);
    expect(
      find.textContaining('android.intent.action.MAIN'),
      findsOneWidget,
    );
  });

  testWidgets('空列表给出“暂无数据”而不是隐藏', (tester) async {
    await pump(tester, const []);
    expect(find.text('Components'), findsOneWidget);
    expect(find.text('No data'), findsOneWidget);
  });
}
