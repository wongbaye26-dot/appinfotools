import 'dart:convert';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// 一条安装记录。
///
/// 只存「发生过什么」：装的是哪个包、哪台设备、成功与否、什么时候。**不存
/// 设备连接状态**——那是每次都要重新问 adb 的事实，落盘只会过期。
class InstallRecord {
  /// 展示名：优先应用名，其次是文件名。
  final String fileName;

  /// 人类可读大小（如 `18.4 MB`）。已格式化，避免再依赖原始文件是否还在。
  final String size;
  final String device;
  final String? packageName;
  final bool ok;
  final DateTime at;

  const InstallRecord({
    required this.fileName,
    required this.size,
    required this.device,
    required this.ok,
    required this.at,
    this.packageName,
  });

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'size': size,
        'device': device,
        if (packageName != null) 'package': packageName,
        'ok': ok,
        'at': at.millisecondsSinceEpoch,
      };

  static InstallRecord? fromJson(Map<String, dynamic> json) {
    final name = json['fileName'];
    if (name is! String || name.isEmpty) return null;
    return InstallRecord(
      fileName: name,
      size: json['size'] as String? ?? '',
      device: json['device'] as String? ?? '',
      packageName: json['package'] as String?,
      ok: json['ok'] == true,
      at: DateTime.fromMillisecondsSinceEpoch(
        (json['at'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

/// 最近安装记录（跨启动保留）。
///
/// 为什么落盘而不是只放内存：安装页关闭再打开后，「最近安装」如果清了，
/// 用户会以为自己刚才那次安装失败了。上限 10 条，与「最近分析」一致。
///
/// 为什么复用 [Config]：与 `recent_files` / `known_devices` 同一条存储，
/// 不必新造文件格式，也不会出现「换台机器记录就丢」的路径问题。
class InstallHistoryManager {
  static const int _maxCount = 10;

  /// 读取当前记录。**返回值一定是可变列表**（调用方会就地增删）。
  static List<InstallRecord> load() {
    try {
      final jsonStr = Config.installHistory.value;
      if (jsonStr.isEmpty || jsonStr == '[]') return <InstallRecord>[];
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => InstallRecord.fromJson(e as Map<String, dynamic>))
          .whereType<InstallRecord>()
          .toList();
    } catch (e) {
      log.warning('failed to parse install history: $e');
      return <InstallRecord>[];
    }
  }

  /// 记录一次安装尝试，返回最新列表。
  static Future<List<InstallRecord>> add(InstallRecord record) async {
    final entries = load()
      ..insert(0, record);
    final trimmed = entries.length > _maxCount
        ? entries.sublist(0, _maxCount)
        : entries;
    await Config.installHistory.updateValue(
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
    return trimmed;
  }

  /// 清空记录。
  static Future<void> clear() async {
    await Config.installHistory.updateValue('[]');
  }

  /// 某个包最近是否装过（用于文件条上的「未安装过」提示）。
  static bool wasInstalled(String? packageName) {
    if (packageName == null || packageName.isEmpty) return false;
    return load().any((e) => e.ok && e.packageName == packageName);
  }
}
