import 'dart:io';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:path/path.dart' as path;

/// 本机 Java 运行时的探测结果。
class JavaRuntimeInfo {
  const JavaRuntimeInfo({
    this.executablePath,
    this.usable = false,
    this.detail,
  });

  /// `java` 可执行文件路径。`null` 表示 `PATH` 里没有它。
  final String? executablePath;

  /// 这个 `java` 是否真的能跑。
  ///
  /// 与「文件存在」不是一回事：macOS 的 `/usr/bin/java` 是一个**桩**，
  /// 没装 JDK 时它照样存在，一执行就报 `Unable to locate a Java Runtime`。
  final bool usable;

  /// 不能用的原因，仅用于日志与诊断。
  final String? detail;

  /// 供界面直接展示的一行文字。
  String get displayLabel => executablePath ?? '';
}

/// 探测本机的 Java 运行时 —— `apksigner` 的**隐含**运行时依赖。
///
/// ## 为什么项目需要它
///
/// `apksigner` 在 macOS / Linux 上是一段 **shell 脚本**，末尾是
/// `exec java $javaOpts -jar "$jarpath" "$@"`；Windows 的 `apksigner.bat`
/// 同理。也就是说 Java 缺失时 apksigner 根本起不来 —— 而这个事实在界面上
/// 完全看不见（它不属于任何一条「工具路径」设置）。
///
/// ## 为什么不执行 `java -version`
///
/// 两个原因，第二个是硬的：
///
/// 1. 版本号对用户没有用处。设置页要回答的问题是「apksigner 能不能跑」，
///    那只需要知道 java 在不在、是不是那个桩。
/// 2. `Process.start` 在 widget 测试的 fake-async 区里会留下一个**永不完成**
///    的零延迟 Timer（真实子进程的 IO 事件不会在 pump 窗口内回流），于是
///    每个渲染到设置页的测试都会撞上
///    `A Timer is still pending even after the widget tree was disposed`。
///    这条约束是实测出来的，不是推测。
///
/// 因此判据全部落在文件系统上，**不拉任何子进程**。
class JavaRuntime {
  /// macOS 的系统 java 桩。真装了 JDK 时它会转交给真正的 java。
  static const String macShimPath = '/usr/bin/java';

  static JavaRuntimeInfo detect() {
    final executable =
        ToolPaths.findInPath(Platform.isWindows ? 'java.exe' : 'java');
    if (executable == null) {
      log.info('JavaRuntime: PATH 里没有 java');
      return const JavaRuntimeInfo(detail: 'java not found in PATH');
    }

    if (Platform.isMacOS && executable == macShimPath && !hasInstalledJdk()) {
      log.warning('JavaRuntime: 只有 macOS 的 java 桩，没有可用 JDK');
      return const JavaRuntimeInfo(
        executablePath: macShimPath,
        detail: 'macOS stub java without an installed JDK',
      );
    }

    log.info('JavaRuntime: $executable');
    return JavaRuntimeInfo(executablePath: executable, usable: true);
  }

  /// macOS 上是否装了 JDK。
  ///
  /// 判据是 `JAVA_HOME` 或 JDK 的安装目录里有内容。两者都没有时，桩
  /// `/usr/bin/java` 一执行就会报错 —— 这正是 `SignatureAnalyzer` 里
  /// 「退出码 1 + Unable to locate a Java Runtime」那条规则的来源。
  ///
  /// [environment] 只为测试注入。
  static bool hasInstalledJdk({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final javaHome = env['JAVA_HOME'];
    if (javaHome != null &&
        javaHome.trim().isNotEmpty &&
        Directory(javaHome.trim()).existsSync()) {
      return true;
    }

    final candidates = <String>[
      '/Library/Java/JavaVirtualMachines',
    ];
    final home = env['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      candidates.add(path.join(home, 'Library', 'Java', 'JavaVirtualMachines'));
    }
    for (final candidate in candidates) {
      final dir = Directory(candidate);
      if (!dir.existsSync()) continue;
      if (dir.listSync().isNotEmpty) return true;
    }
    return false;
  }
}
