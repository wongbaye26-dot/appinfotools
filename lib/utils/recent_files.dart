import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// 最近分析文件的单条记录。
class RecentFileEntry {
  final String path;
  final int size;
  final DateTime analyzedAt;
  final String? platform; // 'android' | 'ios' | null

  /// 真实应用图标的缓存文件名（见 [RecentIconCache]）；没有缓存时为 `null`。
  ///
  /// 存**文件名**而不是绝对路径：缓存目录的位置随平台与用户变（macOS 的
  /// 应用支持目录带沙箱/用户路径），存绝对路径的话换台机器或换个账户就
  /// 全部失效。目录由 [RecentIconCache] 负责解析。
  final String? iconFile;

  const RecentFileEntry({
    required this.path,
    required this.size,
    required this.analyzedAt,
    this.platform,
    this.iconFile,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'size': size,
        'analyzedAt': analyzedAt.millisecondsSinceEpoch,
        if (platform != null) 'platform': platform,
        if (iconFile != null) 'iconFile': iconFile,
      };

  factory RecentFileEntry.fromJson(Map<String, dynamic> json) =>
      RecentFileEntry(
        path: json['path'] as String,
        size: json['size'] as int? ?? 0,
        analyzedAt: DateTime.fromMillisecondsSinceEpoch(
          json['analyzedAt'] as int? ?? 0,
        ),
        platform: json['platform'] as String?,
        iconFile: json['iconFile'] as String?,
      );

  /// 文件名（不含路径）。
  String get fileName => path.split(Platform.pathSeparator).last;

  /// 格式化的分析时间（相对时间）。
  String timeAgo() {
    final now = DateTime.now();
    final diff = now.difference(analyzedAt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${analyzedAt.year}-${analyzedAt.month.toString().padLeft(2, '0')}-${analyzedAt.day.toString().padLeft(2, '0')}';
  }
}

/// 最近分析文件管理器。
///
/// 最多保留 10 条记录，新记录插入到头部，重复路径去重。
class RecentFilesManager {
  static const int _maxCount = 10;

  /// 读取当前列表。
  ///
  /// **返回值一定是可变列表。** [add] 会就地对它 `removeWhere` 去重，而
  /// `const []` 是不可变的 —— 早先这里在空列表时返回 `const []`，于是
  /// **全新安装后的第一次分析必然抛 `UnsupportedError`**，调用方又是
  /// `unawaited(...)`，异常被静默吞掉：表现为「最近文件永远是空的、
  /// 统计永远是 0」。空集合在这里是正常状态，不是常量。
  static List<RecentFileEntry> load() {
    try {
      final jsonStr = Config.recentFiles.value;
      if (jsonStr.isEmpty || jsonStr == '[]') return <RecentFileEntry>[];
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => RecentFileEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      log.warning('failed to parse recent files: $e');
      return <RecentFileEntry>[];
    }
  }

  /// 添加一条记录（去重后插入头部，超出 _maxCount 时截断尾部）。
  ///
  /// [iconFile] 是真实应用图标的缓存文件名（见 [RecentIconCache]）。
  /// **覆盖同路径的旧记录时沿用新的那个值** —— 重命名或重新下载之后，
  /// 图标要跟着换，不能把旧图标留在列表里。
  static Future<void> add(
    String path,
    int size, {
    String? platform,
    String? iconFile,
  }) async {
    final entries = load();
    // 去重：移除已存在的同路径记录
    entries.removeWhere((e) => e.path == path);
    // 插入头部
    entries.insert(
      0,
      RecentFileEntry(
        path: path,
        size: size,
        analyzedAt: DateTime.now(),
        platform: platform,
        iconFile: iconFile,
      ),
    );
    // 截断
    final trimmed =
        entries.length > _maxCount ? entries.sublist(0, _maxCount) : entries;
    // 持久化
    final jsonStr = jsonEncode(trimmed.map((e) => e.toJson()).toList());
    await Config.recentFiles.updateValue(jsonStr);
  }

  /// 清空列表。
  static Future<void> clear() async {
    await Config.recentFiles.updateValue('[]');
  }

  /// 格式化文件大小。
  static String formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
}
