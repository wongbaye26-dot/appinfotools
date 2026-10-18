#ifndef RUNNER_FILE_ASSOCIATION_CHANNEL_H_
#define RUNNER_FILE_ASSOCIATION_CHANNEL_H_

#include <flutter/encodable_value.h>
// `flutter::FlutterEngine` 的定义在 flutter_engine.h 里。
//
// **不能省这一行**：`method_channel.h` 与 `encodable_value.h` 都不 include 它
// （实测两者各 0 处提到 FlutterEngine），所以只 include 那两个头时，
// 下面 `Register(flutter::FlutterEngine* …)` 会报
// `error C2039: 'FlutterEngine': is not a member of 'flutter'`。
// CI run #94 就是栽在这里。
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>

/// Windows 侧的 `file_association` 方法通道。
///
/// ## 为什么需要它
///
/// Dart 侧（`lib/pages/info_page.dart`）通过这个通道拿「启动时要打开的文件」，
/// 但此前**只有 macOS 实现了**（`macos/Runner/FileAssociationPlugin.swift`）。
/// Windows 上通道不存在，`getInitialFilePath` 抛 `MissingPluginException`，
/// 被 Dart 侧 catch 成 `null` —— 于是双击关联文件时应用起来了，
/// 却什么都不打开，看起来就像「关联没生效」。
///
/// `windows/runner/main.cpp` 那时确实把命令行参数传给了 Dart 引擎，
/// 但只是作为 entrypoint arguments，Dart 侧没有任何地方读它。
///
/// ## 它管三件事
///
/// 1. **读启动参数**：Windows 把双击的文件作为 `argv[1]` 传进来。
/// 2. **写注册表**：把本程序登记为 `.apk` / `.ipa` 等扩展名的候选打开方式。
/// 3. **查当前是不是默认**：界面据此决定要不要给「怎么设为默认」的引导。
///
/// ## 关于「设为默认」
///
/// Windows 10/11 的默认程序由
/// `HKCU\...\Explorer\FileExts\<ext>\UserChoice` 决定，那个键带哈希校验，
/// **程序不能合法地直接改写**。所以这里只做允许的两件事：
///
/// - 注册 ProgID 并写 `OpenWithProgids` —— 让本程序出现在
///   「打开方式 → 选择其他应用」里；
/// - 当**没有任何 UserChoice** 时，才写扩展名的默认值（这种情况下会生效）。
///
/// 已经有 UserChoice 时不碰它，由界面引导用户去系统设置里改。
/// 「装完就悄悄抢默认程序」既不合法也不是我们想做的事。
class FileAssociationChannel {
 public:
  /// 在引擎上注册通道，并持有实例直到进程退出。
  ///
  /// [startup_arguments] 是进程启动时的命令行参数（不含程序名本身）。
  static void Register(flutter::FlutterEngine* engine,
                       const std::vector<std::string>& startup_arguments);

  /// 注册 ProgID 与扩展名关联。
  ///
  /// 返回失败原因；成功时为空串。
  static std::string RegisterAssociations();

  /// 当前进程是否已经是某个扩展名的默认处理程序。
  static bool IsDefaultHandler(const std::string& extension);

  /// 从启动参数里挑出第一个**存在**的支持文件。
  ///
  /// 只看扩展名不够：`--enable-dart-profiling` 这类开关也会被传进来。
  /// 这里要求「不是开关 + 扩展名在列表里 + 路径存在且是文件」。
  static std::string PickInitialFilePath(
      const std::vector<std::string>& startup_arguments);

 private:
  FileAssociationChannel(flutter::FlutterEngine* engine,
                         const std::vector<std::string>& startup_arguments);

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  /// 启动参数里待取走的文件路径。
  ///
  /// **取一次就清空**：Dart 侧在 `_initPlatformState` 里调一次
  /// `getInitialFilePath`，若每次都返回同一个路径，页面重建时会重复打开。
  /// macOS 侧用 `UserDefaults.removeObject` 表达同一语义。
  std::string pending_file_path_;
};

#endif  // RUNNER_FILE_ASSOCIATION_CHANNEL_H_
