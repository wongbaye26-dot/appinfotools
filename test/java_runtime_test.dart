import 'dart:io';

import 'package:apk_info_tool/utils/java_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Java 运行时探测。
///
/// 判据全部落在文件系统上，**不执行 `java -version`** —— 除了「版本号没用」
/// 之外还有一条硬约束：`Process.start` 会在 widget 测试的 fake-async 区里留下
/// 一个永不完成的 Timer，直接撞上 `!timersPending` 断言。
void main() {
  final javaName = Platform.isWindows ? 'java.exe' : 'java';

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

  group('JavaRuntime.candidates', () {
    test('JAVA_HOME 排在最前（用户显式配置优先于 PATH）', () {
      final home = p.join('/opt', 'jdk17');
      final candidates =
          JavaRuntime.candidates(environment: {'JAVA_HOME': home});

      expect(candidates.first, p.join(home, 'bin', javaName));
    });

    test('JDK_HOME 也能用（部分发行版只设这个）', () {
      final home = p.join('/opt', 'jdk21');
      final candidates =
          JavaRuntime.candidates(environment: {'JDK_HOME': home});

      expect(candidates, contains(p.join(home, 'bin', javaName)));
    });

    test('我们下载的 JRE 在候选里', () {
      final candidates = JavaRuntime.candidates(environment: const {});

      // 「下载依赖」装出来的 java 必须能被探测到，否则那个下载项等于白装。
      expect(
        candidates.any((path) => path.contains(p.join('jre', 'bin'))),
        isTrue,
        reason: '候选里没有 <下载目录>/jre/bin/$javaName',
      );
    });

    test('平台常见安装目录的**模式**覆盖了各家的默认根', () {
      // 断言的是「模式」而不是展开后的路径：目录不存在时展开结果为空，
      // 直接断言展开结果在没装 JDK 的 CI 上必然失败。
      final patterns = JavaRuntime.platformJavaPatterns({
        'ProgramFiles': r'C:\Program Files',
        'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
        'HOME': '/home/u',
      }, javaName);

      // 「装了 JDK 但没配环境变量」只能靠这一档救回来，所以它必须在。
      if (Platform.isWindows) {
        expect(patterns.any((p) => p.contains('Android Studio')), isTrue);
        expect(patterns.any((p) => p.contains('Eclipse Adoptium')), isTrue);
        expect(patterns.any((p) => p.contains('Microsoft')), isTrue);
      } else if (Platform.isMacOS) {
        expect(patterns.any((p) => p.contains('JavaVirtualMachines')), isTrue);
      } else {
        expect(patterns.any((p) => p.contains('/usr/lib/jvm')), isTrue);
      }
    });

    test('每个模式都以 java 可执行文件名结尾', () {
      final patterns = JavaRuntime.platformJavaPatterns(const {}, javaName);
      expect(patterns, isNotEmpty);
      for (final pattern in patterns) {
        expect(pattern, endsWith(javaName));
      }
    });

    test('不重复列出同一个路径', () {
      final home = p.join('/opt', 'jdk17');
      final candidates =
          JavaRuntime.candidates(environment: {'JAVA_HOME': home});

      expect(candidates.where((c) => c == p.join(home, 'bin', javaName)).length,
          1);
    });
  });

  group('JavaRuntime.childEnvironment', () {
    test('把 java 的 bin 前置到 PATH，并设好 JAVA_HOME', () {
      final home = p.join('/opt', 'jdk17');
      final exe = p.join(home, 'bin', javaName);
      final env = JavaRuntime.childEnvironment(javaPath: exe);

      // apksigner 是 java 的壳：脚本内部执行的是裸命令 `java`，
      // 不前置 PATH 的话「探测到了」也没用。
      expect(env['JAVA_HOME'], home);
      expect(env['PATH'], startsWith(p.join(home, 'bin')));
    });

    test('没找到 java 时返回空 map（不覆盖父进程环境）', () {
      expect(JavaRuntime.childEnvironment(javaPath: ''), isEmpty);
    });

    if (Platform.isMacOS) {
      test('macOS 的 java 桩不参与注入', () {
        // 桩指向 /usr/bin/java，JAVA_HOME 会变成 /usr —— 那是错的。
        expect(
          JavaRuntime.childEnvironment(javaPath: JavaRuntime.macShimPath),
          isEmpty,
        );
      });
    }
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
