#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

/// 单实例：第二次双击 .apk / .ipa 时把路径交给**已经在跑的那个窗口**，
/// 而不是再开一个进程、再开一个窗口。
///
/// ## 为什么需要它
///
/// 文件关联的打开命令是 `"apk_info_tool.exe" "%1"`。资源管理器每双击一次
/// 就起一个新进程，而这个进程会创建自己的 Flutter 窗口 —— 连开三个包就得到
/// 三个窗口，每个只认识自己那一个文件。用户期望的是「像系统自带的查看器
/// 那样，始终只有一个窗口」。
///
/// ## 怎么做的
///
/// 1. 启动时创建命名互斥体 `Local\AppInfoTool.SingleInstance`：
///    - 此前不存在 → 本进程是第一个实例，建一个**隐藏的接收窗口**
///      （消息专用窗口），然后照常启动；
///    - 已存在 → 找到那个接收窗口，用 `WM_COPYDATA` 把命令行参数送过去，
///      本进程直接退出（退出码 0）。
/// 2. 第一个实例收到 `WM_COPYDATA` 后把参数解成 UTF-8，交给
///    [SetForwardHandler] 登记的回调 —— 由 `FlutterWindow` 提供：推给 Dart
///    的 `file_association` 通道，并把窗口提到前面。
///
/// ## 为什么另开一个隐藏窗口，而不是直接找 Flutter 的窗口
///
/// Flutter 的窗口类名是固定的，一个进程里可能有多个；它的 `WndProc`
/// （`Win32Window::MessageHandler`）只认自己关心的那几条消息，塞自定义消息
/// 进去要么被忽略、要么被当成尺寸/DPI 事件。另开一个类名唯一的隐藏窗口，
/// 既不干扰 Flutter，也不依赖它的内部实现。
///
/// ## 互斥体名与安装器共享
///
/// `windows/installer/appinfotool.iss` 的 `AppMutex` 用的是同一个名字，
/// 于是「应用正在运行」时安装/卸载会先提示关闭 —— 那两个动作会覆盖或删除
/// 正在被加载的 DLL。
namespace single_instance {

/// 互斥体名。安装脚本的 `AppMutex` 必须与它**逐字符一致**。
extern const wchar_t kMutexName[];

/// 接收窗口的窗口类名。
extern const wchar_t kReceiverClass[];

/// 启动时调用一次，**必须在创建窗口之前**。
///
/// 返回 `true` 表示「本进程是（或退化为）主实例，可以继续创建窗口」；
/// 返回 `false` 表示「参数已经交给已有实例，本进程应立即退出」。
///
/// [arguments] 是 `GetCommandLineArguments()` 的结果（不含程序名本身）。
bool Acquire(const std::vector<std::string>& arguments);

/// 登记「收到转发参数时做什么」。
///
/// **必须在 Flutter 通道注册之后调用** —— 回调里要往 Dart 推消息。
/// 在这之前收到的转发会先缓存，登记时立刻补发（启动瞬间的竞态）。
void SetForwardHandler(
    std::function<void(const std::vector<std::string>&)> handler);

/// 登记主窗口句柄，用于把窗口从最小化恢复并提到前面。
void SetMainWindow(HWND window);

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_
