import 'dart:convert';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/adb_service.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// 「连过的设备」的持久化。
///
/// ## 为什么只存无线设备的连接价值
///
/// USB 设备插上就在列表里，序列号也不会变，存不存都能用。无线设备不一样：
/// `adb connect` 需要 IP:端口，而端口（尤其配对端口）每次可能不同 —— 至少
/// 把「上次那台机器在 192.168.1.5:5555、叫 SM_G9910、Android 14」记下来，
/// 用户不用再去手机里翻 IP。
///
/// ## 上限
///
/// 只留最近 [maxEntries] 台。这个列表是给人看的，不是审计日志；无限增长
/// 会让「已保存」区块比设备列表还长。
class KnownDeviceStore {
  KnownDeviceStore._();

  static const int maxEntries = 8;

  /// 读出全部记录，按最后连接时间倒序。
  static List<KnownAdbDevice> load() {
    final raw = Config.knownDevices.value;
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final devices = <KnownAdbDevice>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final parsed = KnownAdbDevice.fromJson(Map<String, dynamic>.from(item));
        if (parsed != null) devices.add(parsed);
      }
      devices.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
      return devices;
    } catch (e) {
      // 配置被写坏时不该让安装页打不开 —— 当成「没有历史」。
      log.warning('KnownDeviceStore: 读取失败: $e');
      return const [];
    }
  }

  /// 记住一台设备（已存在则更新型号与时间）。
  static Future<void> remember({
    required String id,
    required bool wireless,
    AdbDeviceInfo? info,
  }) async {
    final existing = load();
    KnownAdbDevice? previous;
    for (final device in existing) {
      if (device.id == id) {
        previous = device;
        break;
      }
    }
    final merged = KnownAdbDevice(
      id: id,
      wireless: wireless,
      // 这次读不到信息时保留上次的 —— 比清空好：用户至少还知道那是哪台。
      info: (info != null && info.hasAny)
          ? info
          : (previous?.info ?? const AdbDeviceInfo()),
      lastSeen: DateTime.now(),
    );
    final next = <KnownAdbDevice>[
      merged,
      ...existing.where((d) => d.id != id),
    ].take(maxEntries).toList();
    await _save(next);
  }

  /// 忘掉一台设备。
  static Future<void> forget(String id) async {
    final next = load().where((d) => d.id != id).toList();
    await _save(next);
  }

  static Future<void> _save(List<KnownAdbDevice> devices) async {
    await Config.knownDevices
        .updateValue(jsonEncode([for (final d in devices) d.toJson()]));
  }
}
