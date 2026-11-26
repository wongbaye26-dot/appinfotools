import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';

// 辅助获取命令行路径
class CommandTools {
  static const String adb = "adb";
  static const String aapt2 = "aapt2";
  static const String apksigner = "apksigner";

  /// 解析结果缓存，键由「工具名 + 三个设置项 + 数据目录」组成。
  ///
  /// **为什么必须缓存**：`findInPath` 在 Windows 上要对 `PATH` 的每个目录 ×
  /// `PATHEXT` 的每个扩展名做一次**同步** `File.existsSync()`（40 个目录 ×
  /// 6 个扩展 = 240 次 stat），而 `ApkInfo.renderIcon` 是**为每个图标候选
  /// 调一次** `findAapt2Path()` —— 一个包十来个候选就重复十几次全扫。
  /// macOS 上这些 stat 是微秒级，Windows 上单次就到毫秒级；`PATH` 里只要
  /// 有一条连不通的网络路径（企业环境常见），每次探测都可能卡上数秒。
  ///
  /// 键里带上设置项，用户改设置后自然失效。**文件系统**的变化（下载完
  /// 工具、手工删除）不在键里，那类变化由 [invalidateCache] 显式通知。
  static final Map<String, String?> _cache = <String, String?>{};

  /// 清空解析缓存。下载/删除工具之后必须调用。
  static void invalidateCache() => _cache.clear();

  /// 仅测试用：当前缓存条目数（验证「同一次解析只解析一次」）。
  static int get debugCacheSize => _cache.length;

  static String getAdbPath() =>
      _resolve(adb, Config.adbSource.value, Config.adbPath.value) ?? adb;

  static String? findAdbPath() =>
      _resolve(adb, Config.adbSource.value, Config.adbPath.value);

  static String getAapt2Path() =>
      _resolve(aapt2, Config.aapt2Source.value, Config.aapt2Path.value) ??
      aapt2;

  static String? findAapt2Path() =>
      _resolve(aapt2, Config.aapt2Source.value, Config.aapt2Path.value);

  static String getApkSignerPath() =>
      _resolve(apksigner, Config.apksignerSource.value,
          Config.apksignerPath.value) ??
      apksigner;

  static String? findApkSignerPath() => _resolve(
      apksigner, Config.apksignerSource.value, Config.apksignerPath.value);

  static String? _resolve(String toolName, String source, String manualPath) {
    // `appSupportDir` 在 `ToolPaths.init()` 之前是安装目录、之后是数据目录，
    // 把它放进键里，初始化完成后缓存自然失效 —— 否则第一次解析的结果
    // 会被错误地一直沿用。
    final key = '$toolName|$source|$manualPath|${Config.downloadDir.value}'
        '|${ToolPaths.appSupportDir}';
    if (_cache.containsKey(key)) return _cache[key];
    final value = _compute(toolName, source, manualPath);
    _cache[key] = value;
    return value;
  }

  /// 真正的解析（含文件系统探测）。只在缓存未命中时执行。
  static String? _compute(String toolName, String source, String manualPath) {
    final downloadDir = ToolPaths.resolveDownloadDir(Config.downloadDir.value);
    final String? downloadedPath;
    final String? bundledPath;
    switch (toolName) {
      case adb:
        downloadedPath = ToolPaths.getDownloadedAdbPath(baseDir: downloadDir);
        bundledPath = ToolPaths.getBundledToolPath(
            Platform.isWindows ? 'adb.exe' : 'adb');
      case aapt2:
        downloadedPath = ToolPaths.getDownloadedAapt2Path(baseDir: downloadDir);
        bundledPath = ToolPaths.getBundledToolPath(
            Platform.isWindows ? 'aapt2.exe' : 'aapt2');
      case apksigner:
        downloadedPath =
            ToolPaths.getDownloadedApksignerPath(baseDir: downloadDir);
        bundledPath = ToolPaths.getBundledToolPath(
            Platform.isWindows ? 'apksigner.bat' : 'apksigner');
      default:
        return null;
    }
    return _resolveToolPath(
        toolName, source, manualPath, downloadedPath, bundledPath);
  }

  static String? _resolveToolPath(
    String toolName,
    String source,
    String manualPath,
    String? downloadedPath,
    String? bundledPath,
  ) {
    final builtinPath = downloadedPath ?? bundledPath;

    // 只查 `PATH` 会漏掉「装了 Android Studio 但没配 PATH」的机器 ——
    // `findSystemTool` 会继续在 Android SDK 的 build-tools / platform-tools
    // 里找。设置页用的是同一个入口，两处结论因此始终一致。
    //
    // **`builtin` 且内置工具确实存在时不探测系统环境**：那一档的结论本来就
    // 是内置路径，探测只是白付一次 `PATH` × `PATHEXT` 的 stat 风暴
    // （Windows 上这正是「打开一个包要等很久」的来源之一）。
    final String? envPath;
    if (source == Config.kToolSourceBuiltin && builtinPath != null) {
      envPath = null;
    } else {
      envPath = ToolPaths.findSystemTool(toolName);
    }
    switch (source) {
      case Config.kToolSourceBuiltin:
        return builtinPath ??
            envPath ??
            (manualPath.isNotEmpty ? manualPath : null);
      case Config.kToolSourceCustom:
        return manualPath.isNotEmpty ? manualPath : envPath ?? builtinPath;
      case Config.kToolSourceSystem:
      default:
        return envPath ??
            builtinPath ??
            (manualPath.isNotEmpty ? manualPath : null);
    }
  }
}
