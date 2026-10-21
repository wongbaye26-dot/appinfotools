import 'dart:ffi' show Abi;

import 'package:apk_info_tool/config.dart';
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

  /// `java` 可执行文件路径。`null` 表示没找到。
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
/// ## 为什么不能只查 PATH
///
/// 这是 Windows 上「装了 JDK 却显示未找到」的真正原因：Oracle / Adoptium /
/// Microsoft 的安装器**默认不把 `bin` 写进 PATH**（只有勾选「Set JAVA_HOME」
/// 才可能写）。本机实测：`java` 在 `C:\Program Files\Java\jdk-17\bin\`，
/// 而 `PATH` 里没有它。
///
/// 因此探测顺序是「用户显式指定 → `JAVA_HOME` → `PATH` → 我们下载的 JRE →
/// 各平台常见安装目录」。最后一档覆盖「装了但没配环境变量」这一大类。
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

  /// 下载 JRE 时用的版本。
  ///
  /// 17 是当前的 LTS，也是 `apksigner` 官方支持的基线。**不要随意抬高**：
  /// 更高的版本对 apksigner 没有额外好处，却会让下载体积变大。
  static const int downloadFeatureVersion = 17;

  static JavaRuntimeInfo? _cached;
  static String? _cacheKey;

  /// 按设置里的「来源」解析 Java。
  ///
  /// 与 [CommandTools._resolveToolPath] 同一套三档语义，顺序上有个刻意的
  /// 差别：**`builtin` 也允许退回系统探测**。理由是我们下载的 JRE 是可选
  /// 项（默认没下），而用户机器上很可能已经有 java —— 让默认值「内置」把
  /// 一个能用的环境说成「未找到」，比什么都不做更糟。
  static JavaRuntimeInfo detect({bool refresh = false}) {
    final source = Config.javaSource.value;
    final manual = Config.javaPath.value.trim();
    final key = '$source|$manual';
    if (!refresh && _cached != null && _cacheKey == key) return _cached!;

    final info = _resolve(source: source, manual: manual);
    _cacheKey = key;
    return _cached = info;
  }

  static JavaRuntimeInfo _resolve({
    required String source,
    required String manual,
  }) {
    switch (source) {
      case Config.kToolSourceCustom:
        if (manual.isEmpty) {
          return const JavaRuntimeInfo(detail: 'custom source without a path');
        }
        // 用户指定了路径就**只认它**：路径写错时说「写错了」，而不是悄悄
        // 换成另一个 java —— 那会让人以为设置生效了。
        return _evaluate(manual, source: 'custom') ??
            JavaRuntimeInfo(
              executablePath: manual,
              detail: 'configured java path does not exist',
            );
      case Config.kToolSourceBuiltin:
        return _fromDownloaded() ?? _probe() ?? _notFound();
      case Config.kToolSourceSystem:
      default:
        return _probe() ?? _fromDownloaded() ?? _notFound();
    }
  }

  static JavaRuntimeInfo _notFound() {
    log.info('JavaRuntime: 没有找到可用的 java');
    return const JavaRuntimeInfo(detail: 'no java runtime found');
  }

  static JavaRuntimeInfo? _fromDownloaded() {
    final downloaded = ToolPaths.getDownloadedJavaPath(baseDir: _downloadDir());
    if (downloaded == null) return null;
    return _evaluate(downloaded, source: 'downloaded');
  }

  static String _downloadDir() =>
      ToolPaths.resolveDownloadDir(Config.downloadDir.value);

  /// 自动探测到的 java（**不含**下载的 JRE、不含自定义路径）。
  ///
  /// 设置页的「系统环境」那一档要显示它 —— 如果这里把下载的 JRE 也算进去，
  /// 用户会看到「系统环境」指向我们自己的目录，看不出机器上到底有没有 java。
  static String? probeSystemPath() => _probe()?.executablePath;

  static JavaRuntimeInfo? _probe() {
    for (final candidate in candidates()) {
      final info = _evaluate(candidate, source: 'probe');
      if (info != null) return info;
    }
    return null;
  }

  /// 清掉缓存（测试用）。
  static void resetCache() {
    _cached = null;
    _cacheKey = null;
  }

  /// 按优先级列出所有候选路径。
  ///
  /// 返回的是**可能不存在**的路径，由 [detect] 逐个验。分开是为了让
  /// 「候选顺序」可以被单元测试钉住 —— 顺序错了（例如把 PATH 排在
  /// `JAVA_HOME` 前面）用户就会用到一个旧版本。
  static List<String> candidates({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final fileName = Platform.isWindows ? 'java.exe' : 'java';
    final result = <String>[];

    void add(String? value) {
      if (value == null) return;
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      if (result.contains(trimmed)) return;
      result.add(trimmed);
    }

    // 1. JAVA_HOME / JDK_HOME —— 用户显式配过的，优先级最高。
    for (final key in const ['JAVA_HOME', 'JDK_HOME']) {
      final home = env[key];
      if (home != null && home.trim().isNotEmpty) {
        add(path.join(home.trim(), 'bin', fileName));
      }
    }

    // 2. PATH。
    final inPath = ToolPaths.findInPath(fileName);
    if (inPath != null) add(inPath);

    // 3. 我们自己下载的 JRE。目录跟随设置里的「下载目录」——
    //    写死 installBinDir 的话，用户改过下载目录后就找不到了。
    //
    // 这里**直接拼路径**而不是用 `getDownloadedJavaPath`：后者在文件不存在
    // 时返回 null，而 [candidates] 的契约是「列出所有可能的位置」，由
    // [detect] 逐个验存在性。混用两种语义会让「下载了但没被探测到」这种
    // 缺陷无处暴露。
    add(path.join(_downloadDir(), 'jre', 'bin', fileName));

    // 4. 各平台常见安装位置 —— 「装了但没配环境变量」的主要来源。
    result.addAll(platformJavaPatterns(env, fileName).expand(_expand));
    return result;
  }

  /// 平台常见安装目录的**模式**（未展开）。
  ///
  /// 用 `*` 表示「展开这一层子目录」，由 [_expand] 处理 —— 因为 JDK 的目录名
  /// 里带版本号（`jdk-17.0.20`、`temurin-17.0.20.1`），写死任何一个都会在
  /// 下次更新后失效。
  ///
  /// 公开是为了让测试能钉住「这一档覆盖了哪些根目录」—— 展开后的结果随机器
  /// 而变（目录不存在就是空），直接断言展开结果在 CI 上必然不稳。
  static List<String> platformJavaPatterns(
    Map<String, String> env,
    String fileName,
  ) {
    final patterns = <String>[];
    if (Platform.isWindows) {
      final programFiles = env['ProgramFiles'] ?? r'C:\Program Files';
      final programFilesX86 = env['ProgramFiles(x86)'];
      final localAppData = env['LOCALAPPDATA'];

      // Oracle / Adoptium / Microsoft / Azul 的默认安装根。
      for (final root in [
        programFiles,
        if (programFilesX86 != null) programFilesX86
      ]) {
        patterns.add(path.join(root, 'Java', '*', 'bin', fileName));
        patterns.add(path.join(root, 'Eclipse Adoptium', '*', 'bin', fileName));
        patterns
            .add(path.join(root, 'Eclipse Foundation', '*', 'bin', fileName));
        patterns.add(path.join(root, 'Microsoft', 'jdk-*', 'bin', fileName));
        patterns.add(path.join(root, 'Zulu', '*', 'bin', fileName));
        patterns
            .add(path.join(root, 'BellSoft', 'LibericaJDK-*', 'bin', fileName));
      }
      if (localAppData != null) {
        patterns.add(path.join(localAppData, 'Programs', 'Eclipse Adoptium',
            '*', 'bin', fileName));
      }
      // Android Studio 自带一个 JBR（JetBrains Runtime）。装了 Studio 的机器
      // 往往**没有**独立 JDK，而 apksigner 只需要能跑 jar —— JBR 完全够用。
      patterns.add(path.join(
          programFiles, 'Android', 'Android Studio', 'jbr', 'bin', fileName));
    } else if (Platform.isMacOS) {
      final home = env['HOME'];
      patterns.add(
          '/Library/Java/JavaVirtualMachines/*/Contents/Home/bin/$fileName');
      if (home != null && home.trim().isNotEmpty) {
        patterns.add(path.join(home, 'Library', 'Java', 'JavaVirtualMachines',
            '*', 'Contents', 'Home', 'bin', fileName));
      }
      patterns.add(
          '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/$fileName');
    } else {
      patterns.add('/usr/lib/jvm/*/bin/$fileName');
      patterns.add('/usr/lib/jvm/*/jre/bin/$fileName');
    }
    return patterns;
  }

  /// 展开路径里的 `*`（只支持单层，够用了）。
  static List<String> _expand(String pattern) {
    if (!pattern.contains('*')) return [pattern];
    final separator = Platform.isWindows ? r'\' : '/';
    final segments = pattern.split(separator);
    var current = <String>[segments.first.isEmpty ? separator : segments.first];

    for (final segment in segments.skip(1)) {
      final next = <String>[];
      if (segment == '*') {
        for (final base in current) {
          final dir = Directory(base);
          if (!dir.existsSync()) continue;
          try {
            for (final entry in dir.listSync()) {
              if (entry is Directory) next.add(entry.path);
            }
          } catch (_) {
            // 没权限的目录直接跳过：探测不该因为某个目录读不了而失败。
          }
        }
      } else {
        for (final base in current) {
          next.add(path.join(base, segment));
        }
      }
      current = next;
      if (current.isEmpty) return const [];
    }
    current.sort();
    return current;
  }

  static JavaRuntimeInfo? _evaluate(String candidate,
      {required String source}) {
    if (!File(candidate).existsSync()) return null;

    if (Platform.isMacOS && candidate == macShimPath && !hasInstalledJdk()) {
      // 桩存在但跑不起来。**不能返回 null 继续找下一个** —— 它是 PATH 里
      // 唯一那个 java，继续找也找不到别的；返回「找到了但不可用」才能让
      // 界面说清楚「装了 java 却没有 JDK」。
      log.warning('JavaRuntime: 只有 macOS 的 java 桩，没有可用 JDK');
      return const JavaRuntimeInfo(
        executablePath: macShimPath,
        detail: 'macOS stub java without an installed JDK',
      );
    }

    log.info('JavaRuntime: $candidate ($source)');
    return JavaRuntimeInfo(executablePath: candidate, usable: true);
  }

  /// 给子进程用的环境变量：把 java 所在目录前置到 `PATH`，并设 `JAVA_HOME`。
  ///
  /// ## 为什么必须有这个
  ///
  /// 仅仅「探测到 java 在哪」是不够的 —— `apksigner` 是脚本，它内部执行的是
  /// 裸命令 `java`（macOS/Linux 的 shell 脚本）或 `%JAVA_HOME%\bin\java.exe`
  /// （Windows 的 .bat）。既然用户的 java 不在 PATH 里，脚本照样找不到它，
  /// 于是设置页显示「已找到」而签名验证仍然失败 —— 那比不显示更糟。
  ///
  /// 返回空 map 表示没找到 java：`Process.start` 的 `includeParentEnvironment`
  /// 默认为 true，空 map 等于不覆盖任何变量。
  static Map<String, String> childEnvironment({String? javaPath}) {
    final resolved = javaPath ?? detect().executablePath;
    if (resolved == null || resolved.isEmpty) return const {};
    if (Platform.isMacOS && resolved == macShimPath) return const {};

    final binDir = path.dirname(resolved);
    final home = path.dirname(binDir);
    final separator = Platform.isWindows ? ';' : ':';
    final current = Platform.environment['PATH'] ?? '';
    return {
      'PATH': current.isEmpty ? binDir : '$binDir$separator$current',
      'JAVA_HOME': home,
    };
  }

  /// 是否支持「一键下载 JRE」。
  ///
  /// **只有 Windows**。Adoptium 给 Windows 的是 `.zip`，能复用现有的
  /// 校验 + `ZipGuard` 解包链路；macOS / Linux 只有 `.tar.gz`，而
  /// `ZipGuard` 是 zip 专用的 —— 为 tar 另写一套路径校验（防穿越、防炸弹）
  /// 是另一个安全面，不该为了一个下载项顺手引入。
  ///
  /// macOS 用户有 Xcode / Homebrew，Linux 有系统包管理器，两条路都比我们
  /// 自带一份 JRE 更合适。
  static bool get supportsDownload => Platform.isWindows;

  /// 当前机器的 Adoptium 架构名。
  static String get adoptiumArchitecture {
    final abi = Abi.current();
    if (abi == Abi.windowsArm64 ||
        abi == Abi.macosArm64 ||
        abi == Abi.linuxArm64) {
      return 'aarch64';
    }
    return 'x64';
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
