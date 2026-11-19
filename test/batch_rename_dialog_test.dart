// 批量重命名对话框：**规模**上的回归。
//
// 用户报告「超过 10 个以上都会失败」，所以这里用 24 条真实存在的路径把
// 对话框渲染出来，断言：列表完整、每行都给出目标名、按钮可用。
//
// 不点「全部重命名」：那一步要真改磁盘文件，跨真实 IO 的 widget 测试在本
// 项目里会卡在 fake-async 与 isolate 之间（见 `real_samples_ui_test.dart`
// 顶部的说明）。改名本身由 `batch_rename_test.dart` 用普通 `test()` 覆盖。

import 'dart:io';

import 'package:apk_info_tool/utils/package_identity.dart';
import 'package:apk_info_tool/widgets/batch_rename_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late List<String> paths;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('batch_dialog');
    paths = [
      for (var i = 0; i < 24; i++)
        (File(p.join(dir.path, 'raw_$i.apk'))..writeAsStringSync('x')).path,
    ];
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<PackageIdentity> fakeReader(String path) async => PackageIdentity(
        appName: 'App ${p.basenameWithoutExtension(path).split('_').last}',
        version: '1.0',
        platform: PackageIdentityPlatform.android,
      );

  testWidgets('24 个文件全部列出且按钮可用', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BatchRenameDialog(paths: paths, identityReader: fakeReader),
      ),
    ));
    // 读取是异步的（每读一条就 setState），推进到读完为止。
    await tester.pumpAndSettle();

    // 列表自身滚动，所以只断言首尾两条 —— 但两条都要存在，说明 24 条都建了。
    expect(find.text('raw_0.apk'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('raw_23.apk'), findsOneWidget);

    // 目标名按「应用名-版本」生成。
    expect(find.text('App 23-1.0.apk'), findsOneWidget);

    final apply = tester.widget<FilledButton>(
      find.byType(FilledButton),
    );
    expect(apply.onPressed, isNotNull);
  });

  testWidgets('读不到应用名时给出提示，并用文件名兜底', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BatchRenameDialog(
          paths: paths.take(2).toList(),
          identityReader: (_) async => const PackageIdentity(
            appName: '',
            version: '',
            platform: PackageIdentityPlatform.unknown,
            failure: 'unreadable',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 兜底名 = 原文件名 → 已是目标名（标题与副标题都是它），
    // 按钮因此置灰（没有可改的）。
    expect(find.text('raw_0.apk'), findsNWidgets(2));
    final apply = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(apply.onPressed, isNull);
  });
}
