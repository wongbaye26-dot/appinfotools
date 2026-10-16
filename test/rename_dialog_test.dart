// 重命名对话框的表单验证。
//
// 此前 `GlobalKey<FormFieldState>()`（缺泛型参数）导致 `currentState`
// 返回 null，因为 Dart 泛型默认不可变：`FormFieldState<String>` is-not
// `FormFieldState<dynamic>`。点击「确定」时 `validate()` 根本不走，
// 用户看到的是「点了没反应」。
//
// V2.4.6 起对话框只有一份实现（`lib/widgets/rename_file_dialog.dart`），
// 概览页的 Hero 与分析页的「文件」行共用它。下面第二组直接驱动这个共用实现 ——
// 此前两页各写一个几乎一样的 `AlertDialog`，改一处不会改到另一处。

import 'dart:async';
import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/file_rename.dart';
import 'package:apk_info_tool/widgets/rename_file_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 挂一个按钮，点它弹出重命名对话框；返回「对话框的 Future」。
///
/// 必须把 Future 本身交出来：对话框关闭后才知道结果，而那时 `tester.tap`
/// 早就返回了。
Future<Future<RenameResult?>> _mountDialog(
  WidgetTester tester,
  String filePath, {
  String displayName = 'Demo',
  String versionName = '1.0',
}) async {
  late Future<RenameResult?> pending;
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                pending = showRenameFileDialog(
                  context,
                  filePath: filePath,
                  displayName: displayName,
                  versionName: versionName,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return pending;
}

void main() {
  group('Rename dialog — formKey 类型', () {
    testWidgets('GlobalKey<FormFieldState<String>> 能正确找到 TextFormField 的 state',
        (tester) async {
      final formKey = GlobalKey<FormFieldState<String>>();
      final controller = TextEditingController(text: 'test.apk');

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: TextFormField(
                key: formKey,
                controller: controller,
                validator: (value) {
                  if (value == null || value.isEmpty) return 'empty';
                  if (!value.endsWith('.apk')) return 'bad suffix';
                  return null;
                },
              ),
            ),
          ),
        ),
      );

      // key 必须能拿到 state，否则就是泛型不匹配的老问题。
      expect(formKey.currentState, isNotNull,
          reason:
              'GlobalKey<FormFieldState<String>> 必须能找到 TextFormField 的 state');

      // 有效值 → validate 返回 true
      expect(formKey.currentState!.validate(), isTrue);

      // 无效值 → validate 返回 false
      controller.text = 'bad';
      await tester.pump();
      expect(formKey.currentState!.validate(), isFalse);
    });
  });

  group('共用重命名对话框', () {
    late Directory dir;
    late String filePath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('rename_dialog');
      filePath = p.join(dir.path, 'original.apk');
      File(filePath).writeAsStringSync('dummy');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    testWidgets('显示改的是哪个文件，默认名按「应用名-版本.后缀」', (tester) async {
      await _mountDialog(tester, filePath);

      expect(find.text(t.rename.rename_file), findsWidgets);
      // 路径是事实，用户要能确认自己没点错行。
      expect(find.text(filePath), findsOneWidget);
      // 默认名进输入框。
      expect(find.text('Demo-1.0.apk'), findsOneWidget);
    });

    testWidgets('三个快捷命名按钮都能改写输入框', (tester) async {
      await _mountDialog(tester, filePath);

      await tester.tap(find.text(t.rename.app_name_only));
      await tester.pump();
      expect(find.text('Demo.apk'), findsOneWidget);

      await tester.tap(find.text(t.rename.name_with_version));
      await tester.pump();
      expect(find.text('Demo-v1.0.apk'), findsOneWidget);

      await tester.tap(find.text(t.rename.default_name));
      await tester.pump();
      expect(find.text('Demo-1.0.apk'), findsOneWidget);
    });

    testWidgets('后缀不合法时拦下，且**不会**动磁盘上的文件', (tester) async {
      final pending = await _mountDialog(tester, filePath);
      var closed = false;
      unawaited(pending.then((_) => closed = true));

      await tester.enterText(find.byType(TextFormField), 'bad.txt');
      await tester.tap(find.text(t.base.confirm));
      await tester.pumpAndSettle();

      expect(find.text(t.rename.must_end_with_apk), findsOneWidget);
      // 对话框还在（没被 pop 掉），文件也没动。
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(File(filePath).existsSync(), isTrue);
      // 校验没过就不该关闭对话框 —— `closed` 是真的在观察 Future 有没有完成。
      expect(closed, isFalse, reason: '校验失败时对话框必须留在原地');
    });

    testWidgets('合法名字真的改名，并返回 renamed + 新路径', (tester) async {
      final pending = await _mountDialog(tester, filePath);
      RenameResult? result;
      unawaited(pending.then((value) => result = value));

      await tester.enterText(find.byType(TextFormField), 'Renamed-2.0.apk');
      await tester.tap(find.text(t.base.confirm));

      // **跨过真实文件 IO 这道坎。**
      //
      // `renameFile` 走的是 dart:io 的异步文件操作，而 `testWidgets` 的测试体
      // 跑在 fake-async 区里：IO 的完成回调落在真实事件循环上，而它的续体排在
      // fake 区的微任务队列里，只有 `pump()` 才会被排空。因此必须**交替**推进
      // 两边 —— 只用 `runAsync(() => pending)` 会死锁（实测挂到测试超时），
      // 只用 `pumpAndSettle()` 则 IO 永远没有机会完成。
      for (var i = 0; i < 50 && result == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }

      // 收进一个不可变局部量：闭包里赋值的变量不会被提升，直接读 `result.path`
      // 是编译错误（「可能为 null」）。
      final renamed = result;
      expect(renamed, isNotNull, reason: '改名应当在若干轮推进内完成');
      expect(renamed!.outcome, RenameOutcome.renamed);
      expect(renamed.path, p.join(dir.path, 'Renamed-2.0.apk'));
      expect(File(filePath).existsSync(), isFalse);
      expect(File(renamed.path!).existsSync(), isTrue);
    });

    testWidgets('取消返回 null，且不动文件', (tester) async {
      final pending = await _mountDialog(tester, filePath);

      await tester.tap(find.text(t.base.cancel));
      await tester.pumpAndSettle();

      expect(await pending, isNull);
      expect(File(filePath).existsSync(), isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('解析不出应用名时，默认名退回原文件名（不编一个出来）', (tester) async {
      await _mountDialog(
        tester,
        filePath,
        displayName: '',
        versionName: '',
      );

      expect(find.text('original.apk'), findsOneWidget);
    });
  });
}
