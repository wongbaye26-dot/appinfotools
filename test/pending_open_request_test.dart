// 概览页「导入文件」的链路测试。
//
// 这条链路曾经断过：概览页自己写了一份 `FileState` 就导航到分析页，
// 看起来「打开了」，但没有任何解析发生 —— 用户看到的就是「导入后没反应」。
//
// 现在概览页只发一次性请求，解析交给分析页（任务句柄、阶段回调、取消、
// 代际计数都只属于那里）。这里钉住的正是这个约定。

import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('待打开文件请求', () {
    test('request 写入路径，consume 取走后清空', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(pendingOpenRequestProvider.notifier);
      expect(container.read(pendingOpenRequestProvider), isNull);

      notifier.request('/tmp/a.apk');
      expect(container.read(pendingOpenRequestProvider), '/tmp/a.apk');

      expect(notifier.consume(), '/tmp/a.apk');
      expect(
        container.read(pendingOpenRequestProvider),
        isNull,
        reason: '取走后必须清空，否则同一次请求会被重复触发',
      );

      // 再取一次应当是空 —— 不能把同一条请求消费两次。
      expect(notifier.consume(), isNull);
    });

    testWidgets('分析页收到请求后把文件路径落到 FileState 上', (tester) async {
      // 造一个真实存在的文件：`_openFile` 会先判 existsSync，路径不存在时
      // 请求根本发不出来，那样测的就不是这条链路了。
      final dir = Directory.systemTemp.createTempSync('appinfotool_open');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}/sample.apk')
        ..writeAsBytesSync(const [0x50, 0x4B, 0x03, 0x04]);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            // 与真实树一致：分析页在 Scaffold 里。
            child: const MaterialApp(home: Scaffold(body: APKInfoPage())),
          ),
        ),
      );

      expect(
        container.read(currentFileStateProvider).filePath,
        isNull,
        reason: '还没导入任何文件',
      );

      container.read(pendingOpenRequestProvider.notifier).request(file.path);
      await tester.pump();

      expect(
        container.read(currentFileStateProvider).filePath,
        file.path,
        reason: '请求必须被分析页接住并落到 FileState 上，否则就是「没反应」',
      );
      expect(
        container.read(pendingOpenRequestProvider),
        isNull,
        reason: '请求是一次性的，处理完必须清空',
      );
    });
  });
}
