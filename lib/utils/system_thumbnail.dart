import 'dart:io';

import 'package:flutter/services.dart';

/// 单个扩展名的注册状态。
class ThumbnailExtensionStatus {
  /// 扩展名，含点（`.apk`）。
  final String extension;

  /// 该扩展名下是否挂着**我们的** CLSID。
  final bool registered;

  const ThumbnailExtensionStatus({
    required this.extension,
    required this.registered,
  });
}

/// 「系统文件图标」（Windows Shell 缩略图处理器）的状态。
///
/// ## 为什么不是一个 bool
///
/// 规格 8.2 要求「必须显示真实原因，不显示虚假成功状态」。
/// 缩略图不能用的原因至少有四种，每一种的补救动作都不同：
///
/// | 原因 | 用户该做什么 |
/// |---|---|
/// | `helperPresent == false` | 安装不完整，重装 |
/// | `dllPresent == false` | 同上 |
/// | `registered == false` | 点「启用」 |
/// | `registeredPath` 指向旧目录 | 点「重新注册」（安装目录被移动过） |
///
/// 把它们压成一个 bool，界面就只能说「不可用」—— 用户没有任何可执行的下一步。
class SystemThumbnailStatus {
  /// 缩略图处理器 DLL 是否在安装目录里。
  final bool dllPresent;

  /// 图标提取器（外部 exe）是否在安装目录里。
  final bool helperPresent;

  /// 注册表里的 CLSID 是否指向**当前**这个 DLL。
  ///
  /// 注意这不是「键存在」：安装目录被移动后键仍然存在，但路径已失效，
  /// Explorer 会静默失败。判据是路径相等。
  final bool registered;

  /// 三件事都成立（DLL 在、helper 在、注册指向当前 DLL）。
  final bool usable;

  /// DLL 的期望路径（用于诊断展示）。
  final String dllPath;

  /// 注册表里**实际**记录的路径（可能指向旧目录，也可能为空）。
  final String registeredPath;

  /// 逐扩展名的注册状态。
  ///
  /// 分开报告而不是一个总开关：`.apk` 挂上了、`.ipa` 没挂上时，
  /// 「已启用」会掩盖一半的问题。
  final List<ThumbnailExtensionStatus> extensions;

  const SystemThumbnailStatus({
    required this.dllPresent,
    required this.helperPresent,
    required this.registered,
    required this.usable,
    required this.dllPath,
    required this.registeredPath,
    required this.extensions,
  });

  /// 尚未查询过（或非 Windows）时的空状态。
  ///
  /// 全部为 false 而不是 true —— 「没查」绝不能显示成「可用」。
  const SystemThumbnailStatus.unknown()
      : dllPresent = false,
        helperPresent = false,
        registered = false,
        usable = false,
        dllPath = '',
        registeredPath = '',
        extensions = const [];

  /// 注册的路径与当前 DLL 不一致 —— 最典型的是「安装目录被移动/重命名」。
  bool get pathMismatch =>
      registeredPath.isNotEmpty &&
      dllPath.isNotEmpty &&
      registeredPath != dllPath;
}

/// Windows「系统文件图标」的管理入口。
///
/// ## 与文件关联是两件事
///
/// 文件关联决定「双击用什么打开」，缩略图处理器决定「文件管理器里显示什么图」。
/// 规格 1.2 明确禁止把两者混为一谈 —— 实现上也分开（不同的通道、不同的注册键）。
///
/// ## 平台边界
///
/// 只有 Windows 有实现。其它平台 [`isSupported`] 为 false，界面据此**整块隐藏**，
/// 而不是显示一个永远打不开的开关。
class SystemThumbnailManager {
  SystemThumbnailManager._();

  static const MethodChannel _channel = MethodChannel('system_thumbnail');

  /// 当前平台是否支持系统缩略图集成。
  static bool get isSupported => Platform.isWindows;

  /// 查询当前状态。
  ///
  /// 任何异常（通道未注册、参数不符）都退回 [SystemThumbnailStatus.unknown]，
  /// **不抛**：设置页在 `initState` 里就会调它，抛出去会白屏。
  static Future<SystemThumbnailStatus> getStatus() async {
    if (!isSupported) return const SystemThumbnailStatus.unknown();
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('getStatus');
      if (raw == null) return const SystemThumbnailStatus.unknown();
      return _parseStatus(raw);
    } on PlatformException {
      return const SystemThumbnailStatus.unknown();
    } on MissingPluginException {
      // 原生侧没编进来（例如在非 Windows 上用 Windows 的 Dart 代码跑测试）。
      return const SystemThumbnailStatus.unknown();
    }
  }

  /// 注册缩略图处理器。
  ///
  /// 返回**注册后的实际状态**（而不是一个 bool）：失败时界面需要知道
  /// 到底哪一步没成，`usable == false` 加上原始状态才说得清。
  static Future<SystemThumbnailStatus> register() async {
    if (!isSupported) return const SystemThumbnailStatus.unknown();
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('register');
      return raw == null
          ? const SystemThumbnailStatus.unknown()
          : _parseStatus(raw);
    } on PlatformException {
      return const SystemThumbnailStatus.unknown();
    } on MissingPluginException {
      return const SystemThumbnailStatus.unknown();
    }
  }

  /// 注销：只删本项目写的那两个注册键。
  static Future<SystemThumbnailStatus> unregister() async {
    if (!isSupported) return const SystemThumbnailStatus.unknown();
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('unregister');
      return raw == null
          ? const SystemThumbnailStatus.unknown()
          : _parseStatus(raw);
    } on PlatformException {
      return const SystemThumbnailStatus.unknown();
    } on MissingPluginException {
      return const SystemThumbnailStatus.unknown();
    }
  }

  /// 通知 Shell「关联变了」。
  ///
  /// **不是清空缩略图缓存** —— 删系统缓存目录既超范围也危险
  /// （规格 8.3 明确不删系统缓存）。Explorer 会按文件时间戳自行失效单条缩略图。
  static Future<SystemThumbnailStatus> refreshCache() async {
    if (!isSupported) return const SystemThumbnailStatus.unknown();
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('refreshCache');
      return raw == null
          ? const SystemThumbnailStatus.unknown()
          : _parseStatus(raw);
    } on PlatformException {
      return const SystemThumbnailStatus.unknown();
    } on MissingPluginException {
      return const SystemThumbnailStatus.unknown();
    }
  }

  /// 把通道返回的 map 解析成状态对象。
  ///
  /// 逐字段 `is` 判断而不是强转：原生侧改了字段类型时，
  /// 强转会抛 `TypeError`，而这里退化成「未知」——
  /// 显示「查不到」比让设置页崩掉好。
  static SystemThumbnailStatus _parseStatus(Map<Object?, Object?> raw) {
    bool flag(String key) => raw[key] == true;
    String text(String key) => raw[key] is String ? raw[key]! as String : '';

    final extensions = <ThumbnailExtensionStatus>[];
    final rawExtensions = raw['extensions'];
    if (rawExtensions is List) {
      for (final entry in rawExtensions) {
        if (entry is Map) {
          final ext = entry['extension'];
          if (ext is String && ext.isNotEmpty) {
            extensions.add(ThumbnailExtensionStatus(
              extension: ext,
              registered: entry['registered'] == true,
            ));
          }
        }
      }
    }

    return SystemThumbnailStatus(
      dllPresent: flag('dllPresent'),
      helperPresent: flag('helperPresent'),
      registered: flag('registered'),
      usable: flag('usable'),
      dllPath: text('dllPath'),
      registeredPath: text('registeredPath'),
      extensions: extensions,
    );
  }
}
