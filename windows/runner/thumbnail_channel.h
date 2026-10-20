#ifndef RUNNER_THUMBNAIL_CHANNEL_H_
#define RUNNER_THUMBNAIL_CHANNEL_H_

#include <flutter/encodable_value.h>
// 与 `file_association_channel.h` 同一个理由：`method_channel.h` 与
// `encodable_value.h` 都不 include `flutter_engine.h`，少了这一行会报
// `'FlutterEngine': is not a member of 'flutter'`（CI run #94 的教训）。
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <string>

/// Windows 侧「系统文件图标」的注册状态与安装/卸载。
///
/// ## 为什么与文件关联分开
///
/// 两者登记的是不同的东西：文件关联决定「双击用什么打开」，缩略图处理器决定
/// 「文件管理器里显示什么图」。规格 1.2 明确要求不得混为一谈 ——
/// 实现上也要分开，否则「关联成功」会被误读成「缩略图可用」。
///
/// ## 注册位置
///
/// 全部写 `HKCU\Software\Classes`，**不需要管理员**，与现有
/// `FileAssociationChannel` 的做法一致：
///
/// ```
/// HKCU\Software\Classes\CLSID\{9C4A7E52-…}\InprocServer32
///     (Default) = <安装目录>\appinfotool_thumbnail.dll
///     ThreadingModel = Apartment
/// HKCU\Software\Classes\.apk\ShellEx\{E357FCCD-A995-4576-B01F-234630154E96}
///     (Default) = {9C4A7E52-…}
/// ```
///
/// ShellEx 那个 GUID 是 **`IID_IThumbnailProvider`**，代码里从 SDK 直接取
/// （`ThumbnailHandlerGuid()`）—— 早先手抄过一份，抄错了两位，于是注册
/// 「成功」但 Explorer 永远不调用，见 `thumbnail_channel.cpp` 的注释。
///
/// 只写**我们自己**的键，不碰 `UserChoice`、不碰其它应用的处理器。
class ThumbnailChannel {
 public:
  static void Register(flutter::FlutterEngine* engine);

  /// 注册；返回失败原因（成功为空串）。
  static std::string RegisterProvider();

  /// 注销：只删本项目写的那两个键。
  static std::string UnregisterProvider();

  /// 当前状态（供设置页显示**真实**情况）。
  ///
  /// 返回的 map 里每个值都是**实测**结果，不是「我们以为应该怎样」：
  /// - `dllPresent`：DLL 文件确实在安装目录里；
  /// - `helperPresent`：helper exe 确实在；
  /// - `registered`：注册表里的 CLSID 指向的正是当前这个 DLL；
  /// - `supportedExtensions`：本次实际挂上的扩展名。
  static flutter::EncodableMap CurrentStatus();
};

#endif  // RUNNER_THUMBNAIL_CHANNEL_H_
