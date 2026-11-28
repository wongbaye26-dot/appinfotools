import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_info_tool/widgets/android_signature_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('本地证书：方案、DN、序列号与三种指纹都渲染出来', (tester) async {
    late List<SignatureCertificate> certificates;
    await tester.runAsync(() async {
      certificates = await SignatureAnalyzer.readLocalCertificates(
        'test/fixtures/apk/signed-v2-v3.apk',
      );
    });
    expect(certificates, isNotEmpty);

    final analysis = SignatureAnalysis(
      status: SignatureStatus.toolUnavailable,
      localCertificates: certificates,
      verifiedSchemes: const {'v2', 'v3'},
    );

    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AndroidSignaturePanel(signature: analysis),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final t = TranslationProvider.of(
      tester.element(find.byType(AndroidSignaturePanel)),
    ).translations;

    // 方案 chip 与状态 chip
    expect(find.text('V2'), findsWidgets);
    expect(find.text('V3'), findsWidgets);
    expect(find.text(t.signature.status_tool_unavailable), findsOneWidget);

    // 证书字段
    expect(find.text('CN=Fixture'), findsWidgets);
    expect(find.text('DF5D287C71A19C67'), findsWidgets);
    // v1 / v2 / v3 各有一张证书卡片，同一张证书因此出现多次。
    expect(find.textContaining('3F:FB:ED:BA:EB:55:83:14'), findsWidgets);
    expect(find.textContaining('F0:33:79:ED:96:88:B5:AA'), findsWidgets);
    expect(find.textContaining('F3:78:A5:7E:06:33:3A:85'), findsWidgets);
    expect(find.textContaining('RSA (2048 bits)'), findsWidgets);
    expect(find.text('SHA256withRSA'), findsWidgets);
  });

  testWidgets('没有签名数据时给出「未找到」而不是空白', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: AndroidSignaturePanel(signature: null)),
          ),
        ),
      ),
    );
    final t = TranslationProvider.of(
      tester.element(find.byType(AndroidSignaturePanel)),
    ).translations;
    expect(find.text(t.signature.no_signature), findsOneWidget);
  });
}
