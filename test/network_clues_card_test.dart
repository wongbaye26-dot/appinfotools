import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/network_clues_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) =>
    TranslationProvider(child: MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('展示线索计数与静态提取边界', (tester) async {
    await tester.pumpWidget(_wrap(const NetworkCluesCard(
      network: NetworkFacts(
        domains: ['api.example.com'],
        ips: ['10.0.0.7'],
        clues: [
          NetworkClue(
            id: 'nc_1',
            type: NetworkClueType.url,
            value: 'https://api.example.com/v1',
            sourcePath: 'classes.dex',
          ),
          NetworkClue(
            id: 'nc_2',
            type: NetworkClueType.ipv4,
            value: '10.0.0.7',
            sourcePath: 'classes.dex',
          ),
          NetworkClue(
            id: 'nc_3',
            type: NetworkClueType.websocket,
            value: 'wss://socket.example.org/ws',
            sourcePath: 'libfoo.so',
          ),
        ],
      ),
    )));
    expect(find.text(t.security.network_clues_title(count: 3)), findsOneWidget);
    expect(find.text('url 1'), findsOneWidget);
    expect(find.text('ipv4 1'), findsOneWidget);
    expect(find.text('websocket 1'), findsOneWidget);
    expect(find.text(t.security.network_clues_limitation), findsOneWidget);
  });

  testWidgets('全部线索弹层显示完整值与来源', (tester) async {
    await tester.pumpWidget(_wrap(const NetworkCluesCard(
      network: NetworkFacts(
        clues: [
          NetworkClue(
            id: 'nc_1',
            type: NetworkClueType.domain,
            value: 'api.example.com',
            sourcePath: 'classes.dex',
          ),
        ],
      ),
    )));
    await tester.tap(find.text(t.security.network_clues_view_all));
    await tester.pumpAndSettle();
    expect(find.text('api.example.com'), findsOneWidget);
    expect(find.text('classes.dex'), findsOneWidget);
    expect(find.text('DOMAIN'), findsOneWidget);
  });

  testWidgets('没有线索时不渲染空卡', (tester) async {
    await tester
        .pumpWidget(_wrap(const NetworkCluesCard(network: NetworkFacts())));
    expect(find.byType(Card), findsNothing);
  });
}
