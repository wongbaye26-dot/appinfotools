import 'dart:io';

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

/// 文件关联管理类
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
/// 让它「看起来成功了但什么也没发生」，比说清「这里没有这个设置」糟得多。
///
/// Windows 的 `ms-settings:defaultapps` 是真实存在的面板，保留跳转。
class FileAssociationManager {
  /// 检查当前平台是否有可跳转的设置面板。
  ///
  /// 注意：**为 false 不代表不能设置文件关联**，只代表没有可跳转的页面。
  /// 界面不该因此隐藏整行 —— 那会让 macOS 用户以为这个功能不存在。
  static bool get hasSettingsPanel => Platform.isWindows;

  /// 当前平台是否支持设置文件关联（无论是否可跳转）。
  static bool get isSupported => Platform.isWindows || Platform.isMacOS;

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
