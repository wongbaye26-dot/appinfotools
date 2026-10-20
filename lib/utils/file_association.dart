import 'dart:io';

import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 打开「文件关联」设置的结果。
///
/// 这不是「成功 / 失败」二元 —— 两个平台的能力本来就不同，混成一个 bool
/// 会让 UI 只能给出「打不开」这种错误信息，而 macOS 上真正需要的是
/// **怎么做**。所以结果里带着「下一步该干什么」。
enum FileAssociationOutcome {
  /// 已经打开了系统里对应的设置面板（Windows 的「默认应用」）。
  openedSettings,

  /// 当前平台**没有**对应的设置面板，界面需要给出手动操作指引。
  ///
  /// macOS 就是这种：文件关联在 Finder 的「显示简介 → 打开方式」里，
  /// 系统设置里没有这个页面。
  needsManualGuidance,

  /// 当前平台完全不支持（Linux 等）。
  unsupported,
}

/// 文件关联管理。
///
/// ## macOS 为什么不是「打开设置」
///
/// 这里原来写的是
/// `x-apple.systempreferences:com.apple.preferences.extensions`。两处都不对：
///
/// 1. `com.apple.preferences.extensions` 是 **macOS 12 及更早**的「扩展」
///    面板锚点，macOS 13 重写系统设置后失效 —— 实测 macOS 27 上
///    `open` 仍返回 0（URL scheme 本身合法），但系统设置停在默认页，
///    **没有任何跳转**。这正是「点打开设置没反应」的根因。
/// 2. 即使锚点有效，**「扩展」面板也不是文件关联**。它管的是 Finder 扩展、
///    Quick Look 扩展这类插件；「.apk 双击用哪个应用打开」不在那儿。
///
/// 事实是：**macOS 没有「默认应用」设置面板**，也没有任何公开的 URL scheme
/// 能跳到它不存在的东西上。文件关联在 Finder 的「显示简介 → 打开方式」里。
///
/// 所以 macOS 分支不做「假装能跳转」，而是明确告诉调用方
/// [FileAssociationOutcome.needsManualGuidance] —— 由界面给出手动步骤。
///
/// ## Windows 为什么必须注册注册表
///
/// Windows 的 `.apk` 双击由注册表决定。此前两处都缺：安装器（当时是
/// `inno_bundle` 生成的 Inno Setup 脚本）**没有 `[Registry]` 段**，
/// 装完根本没有任何关联；runner 里也**没有 `file_association` 通道的
/// Windows 实现**（只有 macOS 有），于是即使手工关联上，双击也只会打开
/// 一个空窗口。
///
/// 现在两条路都有：安装包由 `windows/installer/appinfotool.iss` 写一份
/// 机器级关联（HKLM），应用自己在启动时再补一份用户级关联（HKCU，
/// 便携版与「关联被别的程序抢走」都靠它）。两边用的 ProgID 完全相同
/// （`AppInfoTool.<ext>`），不会出现两套互相看不见的关联。
///
/// 关于「设为默认」：Windows 10/11 的默认程序写在
/// `HKCU\...\Explorer\FileExts\<ext>\UserChoice`，那个键带哈希校验，
/// **程序不能合法地改写**。所以这里做的是「登记为候选」——
/// 用户能在「打开方式」里看到本程序，但要不要设为默认由用户决定。
/// 已经有 `UserChoice` 时不去抢。
class FileAssociationManager {
  FileAssociationManager._();

  static const MethodChannel _channel = MethodChannel('file_association');

  /// 支持文件关联的扩展名。
  ///
  /// **从 [kPickableExtensions] 派生**，不另写一份 —— 两处不一致会出现
  /// 「关联了但应用拒收」这种最难查的现象。
  ///
  /// 过滤掉多段后缀（`apk.1` / `apk.1.1`）：那是下载渠道给重名文件加的，
  /// 不是可注册的文件类型。
  static final List<String> extensions = [
    for (final extension in kPickableExtensions)
      if (!extension.contains('.')) '.$extension',
  ];

  /// 检查当前平台是否有可跳转的设置面板。
  ///
  /// 注意：**为 false 不代表不能设置文件关联**，只代表没有可跳转的页面。
  /// 界面不该因此隐藏整行 —— 那会让 macOS 用户以为这个功能不存在。
  static bool get hasSettingsPanel => Platform.isWindows;

  /// 当前平台是否支持设置文件关联（无论是否可跳转）。
  static bool get isSupported => Platform.isWindows || Platform.isMacOS;

  /// 当前平台是否支持**由应用自己登记**关联。
  ///
  /// 只有 Windows：macOS 的关联由 `Info.plist` 的 `CFBundleDocumentTypes`
  /// 在打包时声明，应用运行时改不了。
  static bool get canRegisterItself => Platform.isWindows;

  /// 把本程序登记为 [extensions] 的候选打开方式。
  ///
  /// 返回 `true` 表示登记成功。**不代表已成为默认程序** ——
  /// 那需要用户在系统里确认（见类注释）。
  ///
  /// 非 Windows 平台直接返回 `false`，不抛异常：调用方通常在启动时
  /// 无脑调一次，不该因为平台不同而崩。
  static Future<bool> registerAssociations() async {
    if (!Platform.isWindows) return false;
    try {
      final result = await _channel.invokeMethod<bool>('registerAssociations');
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // 通道没注册（例如 native 侧没编进去）。返回 false，
      // 让界面能如实说「本版本没有登记成功」。
      return false;
    }
  }

  /// 某个扩展名当前是否由本程序处理。
  ///
  /// [extension] 可带点或不带点。无法判断时返回 `false`。
  static Future<bool> isDefaultHandler(String extension) async {
    if (!Platform.isWindows) return false;
    final normalized = extension.startsWith('.') ? extension : '.$extension';
    try {
      final result =
          await _channel.invokeMethod<bool>('isDefaultHandler', [normalized]);
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 尝试打开文件关联设置。
  ///
  /// 返回值说明「实际发生了什么」，由调用方决定怎么展示；不抛异常。
  static Future<FileAssociationOutcome> openDefaultAppsSettings() async {
    if (Platform.isWindows) {
      const uri = 'ms-settings:defaultapps';
      if (await canLaunchUrl(Uri.parse(uri))) {
        await launchUrl(Uri.parse(uri));
        return FileAssociationOutcome.openedSettings;
      }
      return FileAssociationOutcome.needsManualGuidance;
    }
    if (Platform.isMacOS) {
      // 没有可跳转的面板（见类注释）。**不装样子**。
      return FileAssociationOutcome.needsManualGuidance;
    }
    return FileAssociationOutcome.unsupported;
  }
}
