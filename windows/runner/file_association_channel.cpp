#include "file_association_channel.h"

// **windows.h 必须先于 shlobj.h**：后者依赖前者引入的 HWND / HKEY / DWORD
// 等基础类型，顺序反过来会在 MSVC 上报一堆未定义类型。CI 第一次构建就是
// 栽在这一行上。
#include <windows.h>

#include <shlobj.h>

#include <flutter/standard_method_codec.h>

#include <functional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

/// 支持的文件关联扩展名（小写，含点）。
///
/// 与 Dart 侧 `isSupportedPackagePath` 保持同一集合：那里决定「能不能分析」，
/// 这里决定「要不要从命令行接过来」。两处不一致的话，
/// 会出现「关联了但拒收」这种最难查的现象。
const wchar_t* kSupportedExtensions[] = {
    L".apk", L".ipa", L".xapk", L".apks", L".apkm",
};

/// 「推送 fileOpened」的结果回调。
///
/// **为什么自己写一个**：引擎头文件里没有 `flutter::MethodResultFunctor`
/// （这个 Flutter 版本只带 `MethodResultFunctions`），用它编译不过
/// —— CI 报的是 `'MethodResultFunctor': is not a member of 'flutter'`。
/// 继承 `MethodResult` 是稳定接口，版本之间不会变。
class FileOpenedResult : public flutter::MethodResult<flutter::EncodableValue> {
 public:
  explicit FileOpenedResult(std::function<void()> on_delivered)
      : on_delivered_(std::move(on_delivered)) {}

 private:
  void SuccessInternal(const flutter::EncodableValue* result) override {
    if (on_delivered_) {
      on_delivered_();
    }
  }
  // 失败（含 NotImplemented：Dart 侧还没设 handler）什么都不做 ——
  // 待取路径要留着，由 `getInitialFilePath` 取走。
  void ErrorInternal(const std::string& code,
                     const std::string& message,
                     const flutter::EncodableValue* details) override {}
  void NotImplementedInternal() override {}

  std::function<void()> on_delivered_;
};

/// 进程内唯一的通道实例。
///
/// 用 static 持有是为了让方法通道的处理函数在引擎存活期间一直有效 ——
/// 裸 `new` 之后没人释放，而 Flutter 侧可能在任意时刻回调进来，
/// 悬垂指针会直接崩。
///
/// **放在文件作用域而不是 `Register` 的局部 static 里**：单实例转发
/// （`DeliverFile`）也要拿到它，而局部 static 只有那个函数能看见。
std::unique_ptr<FileAssociationChannel> g_instance;

/// 把 UTF-8 转成宽字符。失败时返回空串。
std::wstring WideFromUtf8(const std::string& utf8_string) {
  if (utf8_string.empty()) {
    return std::wstring();
  }
  int target_length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.c_str(),
                            static_cast<int>(utf8_string.size()), nullptr, 0);
  if (target_length <= 0) {
    return std::wstring();
  }
  std::wstring wide_string(target_length, L'\0');
  // 用 `&wide_string[0]` 而不是 `data()`：后者在 C++17 之前是
  // `const wchar_t*`，传给需要可写缓冲区的 API 会编译失败。
  int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8_string.c_str(),
      static_cast<int>(utf8_string.size()), &wide_string[0], target_length);
  if (converted == 0) {
    return std::wstring();
  }
  return wide_string;
}

/// 把 ASCII 字母转小写。
///
/// 不用 `CharLowerBuffW`：它要求可写缓冲区，而 `std::wstring::data()` 在
/// C++17 之前返回 `const wchar_t*`。扩展名本来就只有 ASCII 字母，
/// 自己转比依赖标准版本安全。
std::wstring ToLowerAscii(const std::wstring& text) {
  std::wstring lowered = text;
  for (wchar_t& character : lowered) {
    if (character >= L'A' && character <= L'Z') {
      character = static_cast<wchar_t>(character - L'A' + L'a');
    }
  }
  return lowered;
}

/// 取路径的小写扩展名（含点）；没有扩展名时返回空串。
std::wstring ExtensionOf(const std::wstring& path) {
  const size_t dot = path.find_last_of(L'.');
  const size_t slash = path.find_last_of(L"\\/");
  if (dot == std::wstring::npos) {
    return std::wstring();
  }
  if (slash != std::wstring::npos && dot < slash) {
    return std::wstring();  // 点在目录名里，不是扩展名
  }
  return ToLowerAscii(path.substr(dot));
}

bool IsSupportedExtension(const std::wstring& extension) {
  for (const wchar_t* candidate : kSupportedExtensions) {
    if (extension == candidate) {
      return true;
    }
  }
  return false;
}

/// 路径是否指向一个**已存在**的普通文件。
bool IsExistingFile(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  return (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

/// 本程序可执行文件的完整路径。
std::wstring ExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  for (;;) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return std::wstring();
    }
    // 返回值等于缓冲区大小表示被截断，需要放大重来。
    if (length < buffer.size() - 1) {
      return std::wstring(buffer.data(), length);
    }
    buffer.resize(buffer.size() * 2);
  }
}

/// 写一个 `REG_SZ` 值。键不存在时创建。
bool SetStringValue(HKEY root, const std::wstring& subkey,
                    const wchar_t* value_name, const std::wstring& data) {
  HKEY key = nullptr;
  const LONG created =
      ::RegCreateKeyExW(root, subkey.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr,
                        &key, nullptr);
  if (created != ERROR_SUCCESS) {
    return false;
  }
  const DWORD bytes =
      static_cast<DWORD>((data.size() + 1) * sizeof(wchar_t));
  const LONG written =
      ::RegSetValueExW(key, value_name, 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(data.c_str()), bytes);
  ::RegCloseKey(key);
  return written == ERROR_SUCCESS;
}

/// `HKCU\Software\Classes\<ext>` 的路径。
std::wstring ClassesKeyForExtension(const std::wstring& extension) {
  return L"Software\\Classes\\" + extension;
}

/// 这个扩展名是否已经有用户选择（`UserChoice`）。
///
/// 有的话**绝不能**改写扩展名的默认值 —— 那会被系统忽略，还可能让
/// 用户回到「选择打开方式」的弹窗，反而更糟。
bool HasUserChoice(const std::wstring& extension) {
  const std::wstring subkey =
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\" +
      extension + L"\\UserChoice";
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, subkey.c_str(), 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  ::RegCloseKey(key);
  return true;
}

/// 读一个 `REG_SZ` 值；不存在时返回空串。
std::wstring ReadStringValue(HKEY root, const std::wstring& subkey,
                             const wchar_t* value_name) {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey.c_str(), 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return std::wstring();
  }
  DWORD type = 0;
  DWORD bytes = 0;
  if (::RegQueryValueExW(key, value_name, nullptr, &type, nullptr, &bytes) !=
          ERROR_SUCCESS ||
      type != REG_SZ || bytes == 0) {
    ::RegCloseKey(key);
    return std::wstring();
  }
  std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1, L'\0');
  const LONG read = ::RegQueryValueExW(
      key, value_name, nullptr, &type, reinterpret_cast<BYTE*>(buffer.data()),
      &bytes);
  ::RegCloseKey(key);
  if (read != ERROR_SUCCESS) {
    return std::wstring();
  }
  return std::wstring(buffer.data());
}

}  // namespace

void FileAssociationChannel::Register(
    flutter::FlutterEngine* engine,
    const std::vector<std::string>& startup_arguments) {
  if (engine == nullptr) {
    return;
  }
  if (g_instance != nullptr) {
    return;  // 重复注册会让旧实例被销毁，而通道的回调仍指向它。
  }
  // **不能用 `std::make_unique`**：它在 `<memory>` 内部实例化，
  // 不在本类作用域里，因此访问不到 private 构造函数 —— MSVC 会报
  // `error C2248: cannot access private member`（CI run #95 就是）。
  // `new` 表达式则写在 `Register` 这个成员函数体内，可以访问。
  g_instance.reset(new FileAssociationChannel(engine, startup_arguments));
}

FileAssociationChannel::FileAssociationChannel(
    flutter::FlutterEngine* engine,
    const std::vector<std::string>& startup_arguments) {
  pending_file_path_ = PickInitialFilePath(startup_arguments);

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "file_association",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

void FileAssociationChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "getInitialFilePath") {
    // 取走即清空：Dart 侧只应拿到一次。
    const std::string path = pending_file_path_;
    pending_file_path_.clear();
    result->Success(flutter::EncodableValue(path));
    return;
  }

  if (method == "registerAssociations") {
    const std::string failure = RegisterAssociations();
    if (failure.empty()) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("register_failed", failure);
    }
    return;
  }

  if (method == "isDefaultHandler") {
    // Dart 侧传 ['.apk']。参数缺失或类型不对时回错误，
    // 不猜一个默认扩展名 —— 猜错会让界面显示错误的「是否默认」。
    const flutter::EncodableValue* arguments = method_call.arguments();
    const flutter::EncodableList* list = nullptr;
    if (arguments != nullptr) {
      list = std::get_if<flutter::EncodableList>(arguments);
    }
    if (list == nullptr || list->empty()) {
      result->Error("bad_args", "expected a list with one extension");
      return;
    }
    const auto* extension = std::get_if<std::string>(&list->front());
    if (extension == nullptr) {
      result->Error("bad_args", "extension must be a string");
      return;
    }
    result->Success(flutter::EncodableValue(IsDefaultHandler(*extension)));
    return;
  }

  result->NotImplemented();
}

void FileAssociationChannel::DeliverFile(
    const std::vector<std::string>& arguments) {
  if (g_instance == nullptr || g_instance->channel_ == nullptr) {
    return;
  }
  const std::string path = PickInitialFilePath(arguments);
  if (path.empty()) {
    return;
  }
  FileAssociationChannel* self = g_instance.get();
  // 先记下再推：Dart 侧可能还没设 handler，那次推送会失败，
  // 但路径不能丢 —— `getInitialFilePath` 会把它取走。
  self->pending_file_path_ = path;
  self->channel_->InvokeMethod(
      "fileOpened", std::make_unique<flutter::EncodableValue>(path),
      std::make_unique<FileOpenedResult>([self]() {
        // 送达了：清掉待取路径，免得页面重建时再打开一次。
        self->pending_file_path_.clear();
      }));
}

std::string FileAssociationChannel::PickInitialFilePath(
    const std::vector<std::string>& startup_arguments) {
  for (const std::string& argument : startup_arguments) {
    const std::wstring wide = WideFromUtf8(argument);
    if (wide.empty()) {
      continue;
    }
    // 开关（`--foo`）不是路径，跳过。
    if (wide.size() >= 2 && wide[0] == L'-' && wide[1] == L'-') {
      continue;
    }
    if (!IsSupportedExtension(ExtensionOf(wide))) {
      continue;
    }
    if (!IsExistingFile(wide)) {
      continue;
    }
    return argument;
  }
  return std::string();
}

std::string FileAssociationChannel::RegisterAssociations() {
  const std::wstring exe = ExecutablePath();
  if (exe.empty()) {
    return "could not determine the executable path";
  }

  // ProgID 用 `<程序名>.<扩展名>`，与 Inno Setup 安装器的惯例一致，
  // 免得同一台机器上出现两套互相看不见的关联。
  struct Association {
    const wchar_t* extension;
    const wchar_t* prog_id;
    const wchar_t* description;
  };
  const Association associations[] = {
      {L".apk", L"AppInfoTool.apk", L"Android Package"},
      {L".ipa", L"AppInfoTool.ipa", L"iOS App Package"},
      {L".xapk", L"AppInfoTool.xapk", L"Android Package (XAPK)"},
      {L".apks", L"AppInfoTool.apks", L"Android Package Set"},
      {L".apkm", L"AppInfoTool.apkm", L"Android App Bundle (APKM)"},
  };

  int failures = 0;
  for (const Association& association : associations) {
    const std::wstring prog_id_key =
        std::wstring(L"Software\\Classes\\") + association.prog_id;

    // 1) ProgID 本体：描述、图标、打开命令。
    if (!SetStringValue(HKEY_CURRENT_USER, prog_id_key, nullptr,
                        association.description)) {
      ++failures;
    }
    if (!SetStringValue(HKEY_CURRENT_USER, prog_id_key + L"\\DefaultIcon",
                        nullptr, L"\"" + exe + L"\",0")) {
      ++failures;
    }
    if (!SetStringValue(HKEY_CURRENT_USER,
                        prog_id_key + L"\\shell\\open\\command", nullptr,
                        L"\"" + exe + L"\" \"%1\"")) {
      ++failures;
    }

    // 2) 让本程序出现在「打开方式 → 选择其他应用」里。
    //    这一步任何情况下都要做 —— 即使系统已经有别的默认程序，
    //    用户也应当能在候选列表里看到我们。
    const std::wstring open_with =
        ClassesKeyForExtension(association.extension) + L"\\OpenWithProgids";
    if (!SetStringValue(HKEY_CURRENT_USER, open_with, association.prog_id,
                        std::wstring())) {
      ++failures;
    }

    // 3) 只有在用户**还没选过**打开方式时，才把默认值写成我们。
    //    已经有 UserChoice 时改写会被系统忽略，且容易把用户带回
    //    「选择打开方式」弹窗 —— 那不是帮忙。
    if (!HasUserChoice(association.extension)) {
      SetStringValue(HKEY_CURRENT_USER,
                     ClassesKeyForExtension(association.extension), nullptr,
                     association.prog_id);
    }
  }

  // 让资源管理器立刻刷新关联，否则新装的程序要等注销才出现在「打开方式」里。
  ::SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);

  if (failures > 0) {
    // 如实报失败：静默失败会让界面显示「已登记」，而用户仍然找不到我们。
    return std::to_string(failures) + " registry write(s) failed";
  }
  return std::string();
}

bool FileAssociationChannel::IsDefaultHandler(const std::string& extension) {
  const std::wstring wide_extension = WideFromUtf8(extension);
  if (wide_extension.empty()) {
    return false;
  }

  std::wstring normalized = wide_extension;
  if (normalized.front() != L'.') {
    normalized = L"." + normalized;
  }
  normalized = ToLowerAscii(normalized);

  const std::wstring prog_id = L"AppInfoTool" + normalized;

  // 用户选过就用 UserChoice 判定；没选过才看扩展名的默认值。
  const std::wstring user_choice_key =
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\" +
      normalized + L"\\UserChoice";
  const std::wstring chosen =
      ReadStringValue(HKEY_CURRENT_USER, user_choice_key, L"ProgId");
  if (!chosen.empty()) {
    return chosen == prog_id;
  }

  const std::wstring default_value =
      ReadStringValue(HKEY_CURRENT_USER,
                      ClassesKeyForExtension(normalized), nullptr);
  return default_value == prog_id;
}
