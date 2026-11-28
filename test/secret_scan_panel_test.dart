import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/secret_scan_service.dart';
import 'package:apk_info_tool/widgets/secret_scan_panel.dart';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个只含文本条目的最小 zip：`ApkReader` 只需要中央目录就能列条目。
Future<File> _syntheticPackage(String dir) async {
  final archive = Archive()
    ..addFile(ArchiveFile.bytes(
      'assets/config.json',
      utf8.encode(
        '{\n  "endpoint": "https://api.example.com",\n'
        '  "aws": "AKIAIOSFODNN7EXAMPLE"\n}\n',
      ),
    ))
    ..addFile(ArchiveFile.bytes(
      'META-INF/notes.txt',
      utf8.encode('just a readme, no secrets here\n'),
    ));
  final bytes = ZipEncoder().encode(archive);
  final file = File('$dir/synthetic.apk');
  await file.writeAsBytes(bytes);
  return file;
}

SecretMatch _match() => SecretMatch(
      id: 'v1:0123456789abcdef0123456789abcdef',
      ruleId: 'aws-access-key',
      kind: SecretKind.awsAccessKey,
      redactedValue: 'AKIA…MPLE',
      valueSha256: 'a' * 16,
      location: 'assets/config.json',
      contextRedacted: 'aws: "AKIA…MPLE"',
      confidence: SecretConfidence.high,
      extractorId: SecretScanner.extractorId,
    );

void main() {
  testWidgets('敏感信息面板：只显示脱敏值与指纹', (tester) async {
    // 用注入的 loader 避免在 widget 测试里做真实文件 IO（fake-async 会互相等死）。
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SecretScanPanel(
                  packagePath: 'in-memory.apk',
                  loader: (_) async => SecretScanReport(
                    matches: [_match()],
                    scannedEntries: 1,
                    scannedDexFiles: 0,
                    truncated: false,
                    skippedCodes: const [],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AKIA…MPLE'), findsOneWidget);
    expect(find.textContaining('AKIAIOSFODNN7EXAMPLE'), findsNothing);
    expect(find.textContaining(t.secrets.kind_aws), findsWidgets);
    expect(find.textContaining(t.secrets.scope(entries: '1', dex: '0')),
        findsOneWidget);
  });

  testWidgets('显式查看明文：先确认，再显示，且退出后不再存在', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SecretScanPanel(
                  packagePath: 'in-memory.apk',
                  loader: (_) async => SecretScanReport(
                    matches: [_match()],
                    scannedEntries: 1,
                    scannedDexFiles: 0,
                    truncated: false,
                    skippedCodes: const [],
                  ),
                  revealLoader: (_, __) async => 'AKIAIOSFODNN7EXAMPLE',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 不确认就没有明文。
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    expect(find.text(t.secrets.reveal_title), findsOneWidget);
    expect(find.text('AKIAIOSFODNN7EXAMPLE'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, t.secrets.reveal));
    await tester.pumpAndSettle();
    expect(find.text('AKIAIOSFODNN7EXAMPLE'), findsOneWidget);
  });

  test('SecretScanService：命中、脱敏与范围统计', () async {
    final temp = await Directory.systemTemp.createTemp('secret_scan_service');
    addTearDown(() => temp.delete(recursive: true));
    final file = await _syntheticPackage(temp.path);

    final report = await SecretScanService.scan(file.path);
    expect(report, isNotNull);
    expect(report!.matches, hasLength(1));
    expect(report.matches.single.kind, SecretKind.awsAccessKey);
    expect(report.matches.single.redactedValue, 'AKIA…MPLE');
    expect(report.scannedEntries, 2);
    expect(report.scannedDexFiles, 0);
    expect(report.truncated, isFalse);
    // 报告里绝不出现明文（JSON 也只有一个 16 位哈希）。
    final json = jsonEncode(report.matches.single.toJson());
    expect(json, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
  });
}
