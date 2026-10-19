#include "thumbnail_channel.h"

// **windows.h 必须先于 shlobj.h**（`file_association_channel.cpp` 的注释里
// 记着 CI run #93 就是栽在这个顺序上）。
#include <windows.h>

#include <flutter/standard_method_codec.h>
#include <shlobj.h>
// `StrCmpIW` 来自 shlwapi.h，实现在 shlwapi.lib（见 runner/CMakeLists.txt）。
#include <shlwapi.h>

// **必须显式 include**：用了 `std::make_unique` / `std::unique_ptr`。
// 靠 `<string>` 间接带入 `<xmemory>` 是脆弱依赖 —— 换 SDK 版本或加
// `/permissive-` 就可能断掉，而报错会是 C2039「make_unique 不是 std 成员」，
// 看起来完全不像「少了个头」。
#include <memory>
#include <string>
#include <vector>

namespace {

/// 缩略图处理器的 CLSID（与 `windows/thumbnail/thumbnail_provider.cpp` 一致）。
///
/// 两处必须同步：一处写注册表，一处被 COM 工厂响应。改了但没同步，
/// 表现是「注册成功、图标不出来」—— 最难查的那种。
const wchar_t* kClsidString = L"{9C4A7E52-3B7D-4E31-9A4C-6D2F8B1E5A70}";

/// 缩略图处理器的 ShellEx 键名。
///
/// 这是 Windows 固定定义的 GUID（`IThumbnailProvider` 的处理程序 ID），
/// 不是我们自己编的。
const wchar_t* kThumbnailHandlerGuid =
    L"{e357fccd-a995-4576-b01f-ace3639130c9}";

/// 本处理器声明的扩展名（小写，含点）。
///
/// 只挂真正支持的两种。XAPK / APKM / APKS 是**后续评估范围**，
/// 现在挂上会让用户在那些文件上看到一个空缩略图 —— 比没有更糟。
const wchar_t* kSupportedExtensions[] = {L".apk", L".ipa"};

std::wstring WideFromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty()) {
    return std::wstring();
  }
  const int length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.c_str(),
                            static_cast<int>(utf8_string.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(length, L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.c_str(),
                            static_cast<int>(utf8_string.size()), &wide[0],
                            length) == 0) {
    return std::wstring();
  }
  return wide;
}

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int length =
      ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                            static_cast<int>(wide.size()), nullptr, 0, nullptr,
                            nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string utf8(length, '\0');
  if (::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                            static_cast<int>(wide.size()), &utf8[0], length,
                            nullptr, nullptr) == 0) {
    return std::string();
  }
  return utf8;
}

/// 本进程 exe 所在目录（末尾带反斜杠）。
std::wstring ExecutableDirectory() {
  std::vector<wchar_t> buffer(MAX_PATH);
  for (int attempt = 0; attempt < 4; ++attempt) {
    const DWORD written = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (written == 0) {
      return std::wstring();
    }
    if (written < buffer.size()) {
      std::wstring path(buffer.data(), written);
      const size_t slash = path.find_last_of(L"\\/");
      return slash == std::wstring::npos ? std::wstring()
                                         : path.substr(0, slash + 1);
    }
    buffer.resize(buffer.size() * 2);
  }
  return std::wstring();
}

std::wstring ThumbnailDllPath() {
  const std::wstring dir = ExecutableDirectory();
  return dir.empty() ? std::wstring() : dir + L"appinfotool_thumbnail.dll";
}

std::wstring HelperExePath() {
  const std::wstring dir = ExecutableDirectory();
  return dir.empty() ? std::wstring() : dir + L"app_icon_extractor.exe";
}

bool FileExists(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

/// 写一个字符串值；失败返回 false。
bool WriteStringValue(HKEY root, const std::wstring& subkey,
                      const wchar_t* value_name, const std::wstring& data) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(root, subkey.c_str(), 0, nullptr, 0,
                        KEY_WRITE | KEY_WOW64_64KEY, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status = ::RegSetValueExW(
      key, value_name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(data.c_str()),
      static_cast<DWORD>((data.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

/// 读一个字符串值；不存在或读失败返回空串。
std::wstring ReadStringValue(HKEY root, const std::wstring& subkey,
                             const wchar_t* value_name) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey.c_str(), 0, KEY_READ | KEY_WOW64_64KEY,
                      &key) != ERROR_SUCCESS) {
    return std::wstring();
  }
  DWORD type = 0;
  DWORD bytes = 0;
  std::wstring result;
  if (::RegQueryValueExW(key, value_name, nullptr, &type, nullptr, &bytes) ==
          ERROR_SUCCESS &&
      type == REG_SZ && bytes >= sizeof(wchar_t)) {
    std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
    if (::RegQueryValueExW(key, value_name, nullptr, &type,
                           reinterpret_cast<BYTE*>(buffer.data()),
                           &bytes) == ERROR_SUCCESS) {
      result.assign(buffer.data());
    }
  }
  ::RegCloseKey(key);
  return result;
}

/// 递归删一个键（只用于我们自己写的两个键）。
///
/// `RegDeleteTreeW` 会删子键；调用方必须确保传进来的路径是本项目独有的，
/// 否则会连带删掉别的东西。本文件里只对
/// `Software\Classes\CLSID\{我们的 CLSID}` 与
/// `Software\Classes\<ext>\ShellEx\{缩略图 GUID}` 调用。
void DeleteKeyTree(HKEY root, const std::wstring& subkey) {
  ::RegDeleteTreeW(root, subkey.c_str());
}

}  // namespace

void ThumbnailChannel::Register(flutter::FlutterEngine* engine) {
  if (engine == nullptr) {
    return;
  }

  // 通道对象必须活到进程结束：`SetMethodCallHandler` 不会持有它，
  // 一旦析构，后续调用会静默失效（表现为「设置页一直显示状态不可用」）。
  //
  // 用「幂等 static」而不是函数内 `static ... = std::move(channel)`：
  // 后者只在**首次**执行时初始化，引擎重建（`Register` 被调第二次）时
  // 新 channel 会立刻销毁 —— 而 static 里留着的是指向旧引擎的通道。
  // `file_association_channel.cpp` 用的是同一条写法。
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  if (channel != nullptr) {
    return;
  }

  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "system_thumbnail",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();

        if (method == "getStatus") {
          result->Success(flutter::EncodableValue(CurrentStatus()));
          return;
        }

        if (method == "register") {
          const std::string error = RegisterProvider();
          if (error.empty()) {
            result->Success(flutter::EncodableValue(CurrentStatus()));
          } else {
            // 失败也要把**当前状态**带给 Dart —— 界面要显示「哪一步没成」，
            // 只知道「失败了」没法给出可执行的下一步。
            result->Error("register_failed", error);
          }
          return;
        }

        if (method == "unregister") {
          const std::string error = UnregisterProvider();
          if (error.empty()) {
            result->Success(flutter::EncodableValue(CurrentStatus()));
          } else {
            result->Error("unregister_failed", error);
          }
          return;
        }

        if (method == "refreshCache") {
          // 通知 Shell「关联变了」。这不是「清空缩略图缓存」——
          // 删系统缓存目录既超范围也危险（规格 8.3 明确不删系统缓存）。
          // Explorer 会按文件时间戳自行失效单条缩略图。
          ::SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
          result->Success(flutter::EncodableValue(CurrentStatus()));
          return;
        }

        result->NotImplemented();
      });
}

std::string ThumbnailChannel::RegisterProvider() {
  const std::wstring dll = ThumbnailDllPath();
  const std::wstring helper = HelperExePath();
  if (!FileExists(dll)) {
    // **不假装成功**。DLL 不在时写注册表只会让 Explorer 每次请求都失败，
    // 而且用户看到的是「设置里说已启用，但图标不出来」。
    return "thumbnail_provider.dll is missing from the installation directory";
  }
  if (!FileExists(helper)) {
    return "app_icon_extractor.exe is missing from the installation directory";
  }

  const std::wstring clsid_key =
      std::wstring(L"Software\\Classes\\CLSID\\") + kClsidString;
  if (!WriteStringValue(HKEY_CURRENT_USER, clsid_key, nullptr,
                        L"AppInfoTool thumbnail provider")) {
    return "cannot write the CLSID key";
  }
  if (!WriteStringValue(HKEY_CURRENT_USER, clsid_key + L"\\InprocServer32",
                        nullptr, dll)) {
    return "cannot write InprocServer32";
  }
  // Apartment：Shell 缩略图处理器在 STA 线程上被调用，WIC 也要求这样。
  if (!WriteStringValue(HKEY_CURRENT_USER, clsid_key + L"\\InprocServer32",
                        L"ThreadingModel", L"Apartment")) {
    return "cannot write ThreadingModel";
  }

  for (const wchar_t* ext : kSupportedExtensions) {
    const std::wstring shell_ex =
        std::wstring(L"Software\\Classes\\") + ext + L"\\ShellEx\\" +
        kThumbnailHandlerGuid;
    if (!WriteStringValue(HKEY_CURRENT_USER, shell_ex, nullptr, kClsidString)) {
      return "cannot write the ShellEx entry for " + Utf8FromWide(ext);
    }
  }

  ::SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  return std::string();
}

std::string ThumbnailChannel::UnregisterProvider() {
  // 只删我们自己的两个键。**不碰** `ShellEx` 下其它 GUID，
  // 也不碰 `UserChoice` 与默认程序。
  for (const wchar_t* ext : kSupportedExtensions) {
    const std::wstring shell_ex =
        std::wstring(L"Software\\Classes\\") + ext + L"\\ShellEx\\" +
        kThumbnailHandlerGuid;
    DeleteKeyTree(HKEY_CURRENT_USER, shell_ex);
  }
  DeleteKeyTree(HKEY_CURRENT_USER,
                std::wstring(L"Software\\Classes\\CLSID\\") + kClsidString);
  ::SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  return std::string();
}

flutter::EncodableMap ThumbnailChannel::CurrentStatus() {
  flutter::EncodableMap status;

  const std::wstring dll = ThumbnailDllPath();
  const std::wstring helper = HelperExePath();
  const bool dll_present = FileExists(dll);
  const bool helper_present = FileExists(helper);
  status[flutter::EncodableValue("dllPresent")] =
      flutter::EncodableValue(dll_present);
  status[flutter::EncodableValue("helperPresent")] =
      flutter::EncodableValue(helper_present);
  status[flutter::EncodableValue("dllPath")] =
      flutter::EncodableValue(Utf8FromWide(dll));

  // 注册判据：**注册表里指向的正是当前目录下这个 DLL**。
  // 仅「键存在」不够 —— 用户可能移动过安装目录，那时键还在但指向一个
  // 不存在的路径，Explorer 会静默失败。
  const std::wstring registered_path = ReadStringValue(
      HKEY_CURRENT_USER,
      std::wstring(L"Software\\Classes\\CLSID\\") + kClsidString +
          L"\\InprocServer32",
      nullptr);
  const bool registered = !registered_path.empty() &&
                          dll_present &&
                          ::StrCmpIW(registered_path.c_str(), dll.c_str()) == 0;
  status[flutter::EncodableValue("registered")] =
      flutter::EncodableValue(registered);
  status[flutter::EncodableValue("registeredPath")] =
      flutter::EncodableValue(Utf8FromWide(registered_path));

  // 逐扩展名报告，而不是一个布尔：`.apk` 挂上了、`.ipa` 没挂上，
  // 用「已启用」概括会掩盖一半的问题。
  flutter::EncodableList extensions;
  for (const wchar_t* ext : kSupportedExtensions) {
    const std::wstring shell_ex =
        std::wstring(L"Software\\Classes\\") + ext + L"\\ShellEx\\" +
        kThumbnailHandlerGuid;
    const std::wstring value = ReadStringValue(HKEY_CURRENT_USER, shell_ex,
                                               nullptr);
    flutter::EncodableMap entry;
    entry[flutter::EncodableValue("extension")] =
        flutter::EncodableValue(Utf8FromWide(ext));
    entry[flutter::EncodableValue("registered")] =
        flutter::EncodableValue(!value.empty() &&
                                ::StrCmpIW(value.c_str(), kClsidString) == 0);
    extensions.push_back(flutter::EncodableValue(entry));
  }
  status[flutter::EncodableValue("extensions")] =
      flutter::EncodableValue(extensions);

  // 「能不能用」是三件事都成立：DLL 在、helper 在、注册指向当前 DLL。
  status[flutter::EncodableValue("usable")] =
      flutter::EncodableValue(dll_present && helper_present && registered);

  return status;
}
