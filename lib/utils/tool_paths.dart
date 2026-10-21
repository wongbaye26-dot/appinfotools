import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

final _log = Logger('ToolPaths');

class ToolPaths {
  static String get appDir => File(Platform.resolvedExecutable).parent.path;
  static String? _appSupportDir;

  static const _appDirName = 'to.feng.app.apkinfotool';

  static Future<void> init() async {
    if (_appSupportDir != null) return;
    await _migrateDataDir();
    final dir = await getApplicationSupportDirectory();
    _appSupportDir = dir.path;
  }

  /// Windows 数据目录迁移：将旧目录结构迁移到新的扁平结构
  /// 旧结构: AppData/Roaming/{companyName}/apk_info_tool/
  /// 新结构: AppData/Roaming/to.feng.app.apkinfotool/
  static Future<void> _migrateDataDir() async {
    if (!Platform.isWindows) return;

    final roamingDir = Platform.environment['APPDATA'];
    if (roamingDir == null) return;

    final newDir = Directory(path.join(roamingDir, _appDirName));

    // 旧包名结构: com.fengware.app.apkinfotool/apk_info_tool -> to.feng.app.apkinfotool
    final oldDir = Directory(
        path.join(roamingDir, 'com.fengware.app.apkinfotool', 'apk_info_tool'));
    if (!oldDir.existsSync()) return;

    try {
      if (!newDir.existsSync()) {
        // 新目录不存在，直接重命名
        await newDir.parent.create(recursive: true);
        await oldDir.rename(newDir.path);
      } else {
        // 新目录已存在，将旧目录内容逐个移入
        for (final entity in oldDir.listSync()) {
          final targetPath = path.join(newDir.path, path.basename(entity.path));
          if (!File(targetPath).existsSync() &&
              !Directory(targetPath).existsSync()) {
            await entity.rename(targetPath);
          }
        }
        // 删除已空的旧子目录
        if (oldDir.listSync().isEmpty) {
          await oldDir.delete();
        }
      }
      _log.info('已迁移数据目录: ${oldDir.path} -> ${newDir.path}');

      // 清理空的旧父目录
      final oldParent = oldDir.parent;
      if (oldParent.existsSync() && oldParent.listSync().isEmpty) {
        await oldParent.delete();
        _log.info('已删除空的旧目录: ${oldParent.path}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('数据目录迁移失败: $e');
      }
    }
  }

  static String get appSupportDir => _appSupportDir ?? appDir;

  static String get installBinDir {
    return path.join(appSupportDir, 'bin');
  }

  static String get repositoryMirrorFilePath =>
      path.join(installBinDir, 'repository_mirrors.txt');

  static String resolveDownloadDir(String? value) {
    if (value == null || value.isEmpty) {
      return installBinDir;
    }
    if (path.isAbsolute(value)) {
      return value;
    }
    return path.normalize(path.join(appSupportDir, value));
  }

  static String toRelativeDownloadDir(String absolutePath) {
    final relative = path.relative(absolutePath, from: appSupportDir);
    return relative.isEmpty ? '.' : relative;
  }

  static List<String> loadExtraRepositoryUrls() {
    final file = File(repositoryMirrorFilePath);
    if (!file.existsSync()) {
      return [];
    }
    return file
        .readAsLinesSync()
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
  }

  static String? findInPath(String command) {
    final rawPath = Platform.environment['PATH'] ?? '';
    if (rawPath.isEmpty) {
      return null;
    }
    final separator = Platform.isWindows ? ';' : ':';
    final dirs = rawPath
        .split(separator)
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);
    final hasExtension = path.extension(command).isNotEmpty;
    final extensions = Platform.isWindows
        ? (Platform.environment['PATHEXT'] ?? '.EXE;.BAT;.CMD')
            .split(';')
            .where((value) => value.trim().isNotEmpty)
        : const [''];
    for (final dir in dirs) {
      if (Platform.isWindows && hasExtension) {
        final candidate = path.join(dir, command);
        if (File(candidate).existsSync()) {
          return candidate;
        }
        continue;
      }
      for (final ext in extensions) {
        final suffix = Platform.isWindows ? ext.toLowerCase() : '';
        final candidate = path.join(dir, '$command$suffix');
        if (File(candidate).existsSync()) {
          return candidate;
        }
      }
    }
    return null;
  }

  /// 本机已安装的 Android SDK 根目录候选（按优先级）。
  ///
  /// `aapt2` / `apksigner` / `adb` 通常随 Android Studio 一起装好，但**不会**
  /// 自动进入 `PATH`。只看 `PATH` 的话，用户明明装了 SDK，设置页却显示
  /// 「未找到」—— 这是本机（aapt2 在 `~/Library/Android/sdk/build-tools/`）
  /// 实际遇到的情况。
  ///
  /// 顺序：`ANDROID_HOME` → `ANDROID_SDK_ROOT` → 各平台默认安装位置。
  /// 环境变量优先是因为它代表用户的显式选择。
  ///
  /// [environment] 只为测试注入，生产路径一律读进程环境。`Platform.environment`
  /// 是只读的，没有这个缝就没法验证「变量优先、重复去掉」这两条约定。
  static List<String> androidSdkRoots({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final roots = <String>[];
    void add(String? value) {
      if (value == null) return;
      final trimmed = value.trim();
      if (trimmed.isEmpty || roots.contains(trimmed)) return;
      roots.add(trimmed);
    }

    add(env['ANDROID_HOME']);
    add(env['ANDROID_SDK_ROOT']);

    final home = env['HOME'] ?? env['USERPROFILE'];
    if (Platform.isMacOS) {
      if (home != null) add(path.join(home, 'Library', 'Android', 'sdk'));
    } else if (Platform.isWindows) {
      final localAppData = env['LOCALAPPDATA'];
      if (localAppData != null) add(path.join(localAppData, 'Android', 'Sdk'));
    } else if (Platform.isLinux) {
      if (home != null) {
        add(path.join(home, 'Android', 'Sdk'));
        add(path.join(home, 'android-sdk'));
      }
    }
    return roots;
  }

  /// 在 Android SDK 的 `build-tools/<最新版本>/` 下找可执行文件。
  ///
  /// [roots] 同样只为测试注入。
  static String? findInAndroidBuildTools(String name, {List<String>? roots}) {
    for (final root in roots ?? androidSdkRoots()) {
      final dir = _latestBuildToolsDir(path.join(root, 'build-tools'));
      if (dir == null) continue;
      final candidate = path.join(dir, name);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 在 Android SDK 的 `platform-tools/` 下找可执行文件。
  static String? findInAndroidPlatformTools(String name,
      {List<String>? roots}) {
    for (final root in roots ?? androidSdkRoots()) {
      final candidate = path.join(root, 'platform-tools', name);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 已知 Android 工具在 SDK 里的文件名（Windows 带扩展名）。
  ///
  /// 只认这三个：它们就是本项目实际会执行的外部工具。未知命令返回 `null`，
  /// 免得把任意命令名拼进 SDK 路径去探测。
  static String? androidToolFileName(String command) {
    switch (command) {
      case 'aapt2':
        return Platform.isWindows ? 'aapt2.exe' : 'aapt2';
      case 'apksigner':
        return Platform.isWindows ? 'apksigner.bat' : 'apksigner';
      case 'adb':
        return Platform.isWindows ? 'adb.exe' : 'adb';
    }
    return null;
  }

  /// 在 Android SDK 里找已知工具（`PATH` 之外的常见位置）。
  static String? findInAndroidSdk(String command) {
    final name = androidToolFileName(command);
    if (name == null) return null;
    if (command == 'adb') return findInAndroidPlatformTools(name);
    return findInAndroidBuildTools(name);
  }

  /// 「系统环境」的完整查找顺序：先 `PATH`，再 Android SDK。
  ///
  /// 设置页的「系统环境」选项和 [findInPath] 的调用方都应该走这个入口，
  /// 否则两处结论会不一致（设置页显示找到、实际解析却找不到）。
  static String? findSystemTool(String command) {
    return findInPath(command) ?? findInAndroidSdk(command);
  }

  static String? getDownloadedAdbPath({String? baseDir}) {
    final name = Platform.isWindows ? 'adb.exe' : 'adb';
    final root = baseDir ?? installBinDir;
    final candidate = path.join(root, 'platform-tools', name);
    if (File(candidate).existsSync()) {
      return candidate;
    }
    return getBundledToolPath(name);
  }

  static String? getDownloadedAapt2Path({String? baseDir}) {
    final buildToolsDir = _getLatestBuildToolsDir(baseDir: baseDir);
    if (buildToolsDir == null) {
      return getBundledToolPath(Platform.isWindows ? 'aapt2.exe' : 'aapt2');
    }
    final name = Platform.isWindows ? 'aapt2.exe' : 'aapt2';
    final candidate = path.join(buildToolsDir, name);
    return File(candidate).existsSync() ? candidate : null;
  }

  static String? getDownloadedApksignerPath({String? baseDir}) {
    final buildToolsDir = _getLatestBuildToolsDir(baseDir: baseDir);
    if (buildToolsDir == null) {
      return getBundledToolPath(
          Platform.isWindows ? 'apksigner.bat' : 'apksigner');
    }
    final name = Platform.isWindows ? 'apksigner.bat' : 'apksigner';
    final candidate = path.join(buildToolsDir, name);
    return File(candidate).existsSync() ? candidate : null;
  }

  static String? getBundledToolPath(String name) {
    final candidates = [
      path.join(appDir, 'bin', name),
      path.join(appDir, name),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  static String? _getLatestBuildToolsDir({String? baseDir}) {
    final root = baseDir ?? installBinDir;
    return _latestBuildToolsDir(path.join(root, 'build-tools'));
  }

  /// 在给定的 `build-tools` 目录里挑版本号最大的那个子目录。
  ///
  /// 抽出来是为了让「应用下载的 build-tools」与「系统 Android SDK 的
  /// build-tools」共用同一套版本比较 —— 两处各写一份排序迟早会不一致。
  static String? _latestBuildToolsDir(String buildToolsRoot) {
    final dir = Directory(buildToolsRoot);
    if (!dir.existsSync()) {
      return null;
    }
    final versions = dir
        .listSync()
        .whereType<Directory>()
        .map((entry) => path.basename(entry.path))
        .toList();
    if (versions.isEmpty) {
      return null;
    }
    versions.sort(compareVersionDescending);
    return path.join(buildToolsRoot, versions.first);
  }

  static int compareVersionDescending(String a, String b) {
    return -_compareVersion(a, b);
  }

  static int _compareVersion(String a, String b) {
    final aParts = _parseVersion(a);
    final bParts = _parseVersion(b);
    final maxLength =
        aParts.length > bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < maxLength; i++) {
      final aValue = i < aParts.length ? aParts[i] : 0;
      final bValue = i < bParts.length ? bParts[i] : 0;
      if (aValue != bValue) {
        return aValue.compareTo(bValue);
      }
    }
    return 0;
  }

  static List<int> _parseVersion(String value) {
    return value.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  }
}
