import 'dart:io';

import 'package:apk_info_tool/utils/java_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// Java 运行时探测。
///
/// 判据全部落在文件系统上，**不执行 `java -version`** —— 除了「版本号没用」
/// 之外还有一条硬约束：`Process.start` 会在 widget 测试的 fake-async 区里留下
/// 一个永不完成的 Timer，直接撞上 `!timersPending` 断言。
void main() {
  group('JavaRuntime.detect', () {
    test('不抛异常，且结果自洽', () {
      final info = JavaRuntime.detect();

      // 同一台机器上结果稳定：有路径不代表能用（可能是 macOS 的 java 桩）。
      if (info.usable) {
        expect(info.executablePath, isNotNull);
        expect(info.displayLabel, isNotEmpty);
      } else {
        // 不能用时必须给出原因，否则排查时无从下手。
        expect(info.detail, isNotNull);
      }
    });
  });

  group('JavaRuntime.hasInstalledJdk', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jdk_probe_');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('JAVA_HOME 指向真实目录 -> 认为装了 JDK', () {
      expect(
        JavaRuntime.hasInstalledJdk(environment: {'JAVA_HOME': tmp.path}),
        isTrue,
      );
    });

    test('JAVA_HOME 指向不存在的目录 -> 不能据此认为装了 JDK', () {
      final result = JavaRuntime.hasInstalledJdk(environment: {
        'JAVA_HOME': '${tmp.path}/definitely-absent',
        // HOME 指到临时目录，避开本机真实的 ~/Library/Java。
        'HOME': tmp.path,
      });

      // 本机若在 /Library/Java/JavaVirtualMachines 里装了系统级 JDK，这里会
      // 是 true —— 那不是失败，只是说明该判据命中了系统目录。
      final systemJdk = Directory('/Library/Java/JavaVirtualMachines');
      final hasSystem =
          systemJdk.existsSync() && systemJdk.listSync().isNotEmpty;
      expect(result, hasSystem);
    });

    test('JAVA_HOME 为空白字符串时不当作有效路径', () {
      final result = JavaRuntime.hasInstalledJdk(environment: {
        'JAVA_HOME': '   ',
        'HOME': tmp.path,
      });

      final systemJdk = Directory('/Library/Java/JavaVirtualMachines');
      final hasSystem =
          systemJdk.existsSync() && systemJdk.listSync().isNotEmpty;
      expect(result, hasSystem);
    });
  });
}
