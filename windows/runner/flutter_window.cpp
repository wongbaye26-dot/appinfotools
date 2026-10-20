#include "flutter_window.h"

#include <optional>

#include "file_association_channel.h"
#include "single_instance.h"
#include "thumbnail_channel.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // 文件关联通道**必须在插件之后、首帧之前**注册：
  // Dart 侧在 `_initPlatformState` 里调 `getInitialFilePath`，
  // 那是页面首次 build 时发生的。晚一步就是 MissingPluginException，
  // 表现为「双击 apk 打开了应用，但什么都没加载」。
  //
  // 参数从 `GetCommandLineArguments()` 重新取（它只是解析
  // `GetCommandLineW`，可重复调用，无副作用），而不是从 main.cpp
  // 传进来 —— 后者已经 `std::move` 给了 DartProject。
  FileAssociationChannel::Register(flutter_controller_->engine(),
                                   GetCommandLineArguments());

  // 「系统文件图标」通道：与文件关联**分开**（登记的是不同的东西）。
  // 它只被设置页调用，没有启动时序要求，但放在同一处便于对照。
  ThumbnailChannel::Register(flutter_controller_->engine());

  // 单实例：把「第二个进程转发过来的文件」交给 Dart，并把窗口提到前面。
  //
  // 登记时机与文件关联通道一致 —— 回调里要往 `file_association` 通道推
  // `fileOpened`，通道没注册就推等于丢。启动瞬间收到的转发会先在 native
  // 侧缓存，这里一登记就补发。
  single_instance::SetMainWindow(GetHandle());
  single_instance::SetForwardHandler(
      [this](const std::vector<std::string>& arguments) {
        FileAssociationChannel::DeliverFile(arguments);
        // 窗口可能在最小化或躲在别的窗口后面：恢复并抢一次前台，
        // 否则用户双击文件后只看到任务栏闪一下，以为没反应。
        if (::IsIconic(GetHandle())) {
          ::ShowWindow(GetHandle(), SW_RESTORE);
        } else {
          Show();
        }
        ::SetForegroundWindow(GetHandle());
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
