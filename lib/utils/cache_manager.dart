import 'dart:io';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一次缓存盘点结果（单位：字节）。
///
/// 只统计**可以安全删掉、删掉后会自动重建**的东西：图标缩略图与轮换的
/// 日志备份。配置、已知设备、最近分析、安装记录、下载的工具都不在其中 ——
/// 那些是用户数据或离线能力，不属于缓存。
class CacheUsage {
  final int iconBytes;
  final int logBytes;

  const CacheUsage({this.iconBytes = 0, this.logBytes = 0});

  int get total => iconBytes + logBytes;

  bool get isEmpty => total == 0;
}

/// 缓存清理。
///
/// 为什么把范围钉死在这两类：
/// - `recent_icons/` 是 `RecentIconCache` 写的缩略图，删了下次渲染会重取；
/// - `debug.log.N` 是日志轮换留下的备份，当前 `debug.log` 还开着，不删。
///
/// 不删 `debug.log` 本身：Windows 上删除打开中的文件会失败，各平台行为也
/// 不一致；「清理缓存」如果要用户先关掉调试日志，那就不叫清理缓存了。
class CacheManager {
  CacheManager._();

  /// 盘点缓存占用。[supportDir] 只给测试注入。
  static Future<CacheUsage> inspect({Directory? supportDir}) async {
    final dir = supportDir ?? await _supportDir();
    if (dir == null) return const CacheUsage();
    final icons = await _dirBytes(Directory(p.join(dir.path, 'recent_icons')));
    final logs = await _logBackupBytes(dir);
    return CacheUsage(iconBytes: icons, logBytes: logs);
  }

  /// 清空缓存，返回清理前的占用（即释放的字节数）。
  ///
  /// 删除失败只记日志、不抛：缓存清理是「尽力而为」的动作，失败时界面
  /// 如实显示还剩多少即可，不该弹一个异常。
  static Future<CacheUsage> clear({Directory? supportDir}) async {
    final dir = supportDir ?? await _supportDir();
    if (dir == null) return const CacheUsage();
    final before = await inspect(supportDir: dir);

    final icons = Directory(p.join(dir.path, 'recent_icons'));
    if (await icons.exists()) {
      await for (final entity in icons.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (e) {
          log.warning('CacheManager: 删除 ${entity.path} 失败: $e');
        }
      }
    }

    for (final file in await _logBackups(dir)) {
      try {
        await file.delete();
      } catch (e) {
        log.warning('CacheManager: 删除 ${file.path} 失败: $e');
      }
    }

    return before;
  }

  /// `12.4 MB` 这类展示文本；0 显示 `0 B`。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  static Future<Directory?> _supportDir() async {
    try {
      return await getApplicationSupportDirectory();
    } catch (e) {
      // 测试环境没有 path_provider 平台实现；取不到目录就是「没有缓存」。
      log.fine('CacheManager: 无法解析应用数据目录: $e');
      return null;
    }
  }

  static Future<int> _dirBytes(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
    } catch (e) {
      log.fine('CacheManager: 统计 ${dir.path} 失败: $e');
    }
    return total;
  }

  /// 轮换备份：`debug.log.1` … `debug.log.N`。
  static Future<List<File>> _logBackups(Directory dir) async {
    final result = <File>[];
    final backup = RegExp(r'^debug\.log\.\d+$');
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && backup.hasMatch(p.basename(entity.path))) {
          result.add(entity);
        }
      }
    } catch (e) {
      log.fine('CacheManager: 枚举日志备份失败: $e');
    }
    return result;
  }

  static Future<int> _logBackupBytes(Directory dir) async {
    var total = 0;
    for (final file in await _logBackups(dir)) {
      try {
        total += await file.length();
      } catch (_) {
        // 文件在枚举与读取之间被轮换掉了，跳过即可。
      }
    }
    return total;
  }
}
