#include "single_instance.h"

#include <string>
#include <utility>
#include <vector>

#include "utils.h"

namespace single_instance {

const wchar_t kMutexName[] = L"Local\\AppInfoTool.SingleInstance";
const wchar_t kReceiverClass[] = L"AppInfoToolSingleInstanceReceiver";

namespace {

/// `WM_COPYDATA` 的 `dwData` 标记。
///
/// 只认这个值：`WM_COPYDATA` 是公开消息，任何进程都能往我们的窗口发，
/// 不校验就等于把「别人塞进来的字节」当成命令行。
constexpr ULONG_PTR kCopyDataMagic = 0x41495431;  // 'AIT1'

/// 等接收窗口出现的最长时间（40 × 50ms = 2s）。
///
/// 已有实例可能正处在「互斥体已创建、接收窗口还没建好」的窗口期 ——
/// 那是启动的最初一瞬。等一小会儿，别把用户的文件丢掉。
constexpr int kReceiverWaitAttempts = 40;
constexpr DWORD kReceiverWaitIntervalMs = 50;

/// 互斥体句柄。**故意不关闭**：它要一直活到进程退出，关掉就等于放弃
/// 「单实例」这个身份。进程结束时系统自动回收。
HANDLE g_mutex = nullptr;
HWND g_receiver = nullptr;
HWND g_main_window = nullptr;
std::function<void(const std::vector<std::string>&)> g_handler;

/// 回调登记之前收到的转发。正常情况最多一条。
std::vector<std::string> g_pending;
bool g_has_pending = false;

/// UTF-8 → 宽字符。失败返回空串。
std::wstring WideFromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty()) {
    return std::wstring();
  }
  const int target_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.c_str(),
      static_cast<int>(utf8_string.size()), nullptr, 0);
  if (target_length <= 0) {
    return std::wstring();
  }
  std::wstring wide_string(target_length, L'\0');
  const int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.c_str(),
      static_cast<int>(utf8_string.size()), &wide_string[0], target_length);
  if (converted == 0) {
    return std::wstring();
  }
  return wide_string;
}

/// 按 `'\n'` 拆分载荷并转成 UTF-8。空段丢弃。
///
/// 用换行而不是 `'\0'`：命令行参数本身不可能包含换行，而 `WM_COPYDATA`
/// 的载荷长度是显式给出的，不需要结束符 —— 这样路径里的空格、
/// 中文都不需要额外转义。
std::vector<std::string> SplitArguments(const std::wstring& payload) {
  std::vector<std::string> arguments;
  size_t start = 0;
  for (;;) {
    const size_t separator = payload.find(L'\n', start);
    const size_t length = separator == std::wstring::npos
                              ? payload.size() - start
                              : separator - start;
    if (length > 0) {
      const std::wstring piece = payload.substr(start, length);
      const std::string utf8 = Utf8FromUtf16(piece.c_str());
      if (!utf8.empty()) {
        arguments.push_back(utf8);
      }
    }
    if (separator == std::wstring::npos) {
      break;
    }
    start = separator + 1;
  }
  return arguments;
}

/// 把主窗口恢复并提到最前。
///
/// 用户双击文件时正看着资源管理器，我们要抢一次前台。`SetForegroundWindow`
/// 默认会被系统拒绝（只有前台进程才有资格），所以第二个实例在发送前调了
/// `AllowSetForegroundWindow(ASFW_ANY)` 把资格让出来。
void BringToFront() {
  if (g_main_window == nullptr || !::IsWindow(g_main_window)) {
    return;
  }
  if (::IsIconic(g_main_window)) {
    ::ShowWindow(g_main_window, SW_RESTORE);
  } else {
    ::ShowWindow(g_main_window, SW_SHOW);
  }
  ::SetForegroundWindow(g_main_window);
}

void Deliver(const std::vector<std::string>& arguments) {
  if (arguments.empty()) {
    return;
  }
  if (!g_handler) {
    // 通道还没注册好：先存着，`SetForwardHandler` 里补发。
    g_pending = arguments;
    g_has_pending = true;
    return;
  }
  g_handler(arguments);
}

LRESULT CALLBACK ReceiverProc(HWND window,
                              UINT message,
                              WPARAM wparam,
                              LPARAM lparam) {
  switch (message) {
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      // `cbData == 0` 是合法的：那表示「没有参数，只把窗口提到前面」——
      // 用户点开始菜单/桌面快捷方式而应用已经在跑时就是这种情况。
      // 它必须和「送不进」区分开，否则会多开一个窗口。
      if (data == nullptr || data->dwData != kCopyDataMagic ||
          data->lpData == nullptr) {
        return FALSE;
      }
      const size_t length = data->cbData / sizeof(wchar_t);
      const std::wstring payload(
          reinterpret_cast<const wchar_t*>(data->lpData), length);
      Deliver(SplitArguments(payload));
      BringToFront();
      return TRUE;
    }
    case WM_DESTROY:
      if (window == g_receiver) {
        g_receiver = nullptr;
      }
      return 0;
    default:
      return ::DefWindowProcW(window, message, wparam, lparam);
  }
}

/// 注册窗口类并创建隐藏的接收窗口。重复调用是安全的。
bool EnsureReceiver() {
  if (g_receiver != nullptr && ::IsWindow(g_receiver)) {
    return true;
  }
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = ReceiverProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kReceiverClass;
  // 已注册时返回 0 且 GetLastError 为 ERROR_CLASS_ALREADY_EXISTS ——
  // 那说明同一进程里已经建过（`Acquire` 被重复调用），照常建窗口即可。
  ::RegisterClassExW(&window_class);
  g_receiver = ::CreateWindowExW(0, kReceiverClass, L"", 0, 0, 0, 0, 0,
                                 HWND_MESSAGE, nullptr, window_class.hInstance,
                                 nullptr);
  return g_receiver != nullptr;
}

/// 找第一个实例的接收窗口。
///
/// 消息专用窗口**不在 Z 序里**，`FindWindow` 找不到它们，必须用
/// `FindWindowEx(HWND_MESSAGE, …)`。两条都试一次，代价可忽略，
/// 换来的是「换个实现也不会突然失效」。
HWND FindReceiver() {
  HWND found = ::FindWindowExW(HWND_MESSAGE, nullptr, kReceiverClass, nullptr);
  if (found == nullptr) {
    found = ::FindWindowW(kReceiverClass, nullptr);
  }
  return found;
}

}  // namespace

bool Acquire(const std::vector<std::string>& arguments) {
  ::SetLastError(ERROR_SUCCESS);
  g_mutex = ::CreateMutexW(nullptr, FALSE, kMutexName);
  const DWORD mutex_error = ::GetLastError();

  if (g_mutex == nullptr || mutex_error != ERROR_ALREADY_EXISTS) {
    // 第一个实例。互斥体建不出来时也走这条路：单实例失效，
    // 但用户至少还能打开文件 —— 不该因为这个功能阻断整个应用。
    EnsureReceiver();
    return true;
  }

  // 已有实例：把前台资格让给它，否则窗口只会闪一下任务栏。
  ::AllowSetForegroundWindow(ASFW_ANY);

  std::wstring payload;
  for (const std::string& argument : arguments) {
    const std::wstring wide = WideFromUtf8(argument);
    if (wide.empty()) {
      continue;
    }
    if (!payload.empty()) {
      payload.push_back(L'\n');
    }
    payload.append(wide);
  }

  COPYDATASTRUCT data = {};
  data.dwData = kCopyDataMagic;
  data.cbData = static_cast<DWORD>(payload.size() * sizeof(wchar_t));
  data.lpData = const_cast<wchar_t*>(payload.c_str());

  for (int attempt = 0; attempt < kReceiverWaitAttempts; ++attempt) {
    HWND receiver = FindReceiver();
    if (receiver != nullptr) {
      DWORD_PTR ignored = 0;
      const LRESULT sent = ::SendMessageTimeoutW(
          receiver, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
          SMTO_ABORTIFHUNG | SMTO_NORMAL, 5000, &ignored);
      if (sent != 0) {
        return false;
      }
      // 窗口在但送不进去（对方卡住）：退化成新实例，别让双击毫无反应。
      break;
    }
    ::Sleep(kReceiverWaitIntervalMs);
  }

  EnsureReceiver();
  return true;
}

void SetForwardHandler(
    std::function<void(const std::vector<std::string>&)> handler) {
  g_handler = std::move(handler);
  if (!g_has_pending) {
    return;
  }
  const std::vector<std::string> pending = g_pending;
  g_pending.clear();
  g_has_pending = false;
  Deliver(pending);
}

void SetMainWindow(HWND window) { g_main_window = window; }

}  // namespace single_instance
