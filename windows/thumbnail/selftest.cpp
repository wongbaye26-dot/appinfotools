// 缩略图处理器的**自检 / 注册诊断**（2.7.1 起随安装包分发）。
//
// ## 两种模式
//
//   appinfotool_thumbnail_selftest                  → 注册诊断（不需要输入文件）
//   appinfotool_thumbnail_selftest 某个.apk [...]   → 端到端出图自检
//
// 注册诊断查的是「为什么资源管理器不调我们」：DLL/helper 在不在、HKCU/HKLM
// 的 CLSID 指向哪、`.apk`/`.ipa` 的 ShellEx 挂的是不是正确的 GUID。这几件事
// 全在注册表里，不需要用户先想清楚该传哪个文件。
//
// 出图自检则绕开注册表，直接 `LoadLibrary` + `DllGetClassObject`。
//
// ## 为什么需要它
//
// 「两个不同的 APK 是否显示两个不同的图标」这件事，人工看不出来出错原因 ——
// 图标不出来可能是：DLL 没注册、DLL 解析失败、helper 缺失、WIC 解不了、
// Explorer 用了旧缓存。人眼看到的现象全都一样（空白或通用图标）。
//
// 本程序直接 `LoadLibraryW` + `DllGetClassObject` 调用 DLL，**绕过注册表**，
// 因此能把「DLL 本身能不能出图」与「注册有没有生效」彻底分开：
//
//   selftest 失败 → 问题在代码 / helper / 解码
//   selftest 通过但 Explorer 没图 → 问题在注册、缓存或 Shell 配置
//
// 这一层分离让排查从「猜」变成「二选一」。
//
// ## 用法
//
//   appinfotool_thumbnail_selftest [--cx N] [--expect-distinct] file...
//
// 每个输入打印一行：
//
//   OK   <path> <WxH> hash=<hex> alpha=<n>
//   FAIL <path> <原因>
//
// 退出码：全部成功为 0，任一失败为 1（CI 直接用它当门禁）。
//
// ## `--expect-distinct`
//
// 断言「所有成功的输入产出的图标两两不同」。
//
// 这一条正是规格 2.4 的第一条验收项（两个内容不同的 APK 显示不同图标），
// 而它必须由**被测程序自己**判断 —— 否则 CI 脚本要去解析 stdout 的哈希，
// 多一层解析就多一类失败方式（实际踩过：PowerShell 脚本静默退出，
// 连错误都打不出来）。
//
// 断言留在程序里，CI 只需检查退出码。
//
// ## 「坏包应该失败」怎么验
//
// 不是靠这个程序内建断言，而是**由调用方传坏包并期望 FAIL**：
// CI 里同一条命令既传好包也传坏包，好包必须 OK、坏包必须 FAIL。
// 把期望写在命令行里，而不是藏在程序内部，好处是手工复现时看到的
// 与 CI 完全一致。

#include <windows.h>

#include <shellapi.h>
#include <shlobj.h>
// `IThumbnailProvider` 与 `WTS_ALPHATYPE` 都在 thumbcache.h。
// 自检直接调 COM 接口，所以这个头不能省。
#include <thumbcache.h>

#include <cstdio>
// `_wtoi`（--cx 的参数解析）。
#include <cstdlib>
// `_isatty` / `_fileno`：判断 stdout 是不是真正的终端。
#include <io.h>
// `_wcsicmp`：比较注册表里的 CLSID 字符串（大小写不敏感）。
#include <cstring>
// `va_list` / `_vsnwprintf_s`：WriteLineF。
#include <cstdarg>

#include <string>
// `std::pair`（--expect-distinct 收集的 (文件名, 哈希)）。
#include <utility>
#include <vector>

namespace {

/// 与 `thumbnail_provider.cpp` 里的 CLSID 必须一致。
///
/// **刻意在这里再写一遍**而不是 include 那个头：自检要能验证「DLL 导出的
/// 是不是这个 CLSID」，两边共用一个常量会让这条检查变成同义反复。
const CLSID kExpectedClsid = {
    0x9c4a7e52,
    0x3b7d,
    0x4e31,
    {0x9a, 0x4c, 0x6d, 0x2f, 0x8b, 0x1e, 0x5a, 0x70}};

using DllGetClassObjectFn = HRESULT(WINAPI*)(REFCLSID, REFIID, void**);

/// 取本 exe 所在目录（末尾带反斜杠）。
std::wstring ModuleDirectory() {
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

/// FNV-1a 32 位哈希，用于比对两张图是否相同。
///
/// 不用 CRC 或 MD5：这里只需要「不同则不同」的粗判据，32 位足够，
/// 而且不必引入 crypto 依赖。
unsigned int HashBytes(const BYTE* data, size_t size) {
  unsigned int hash = 2166136261u;
  for (size_t i = 0; i < size; ++i) {
    hash ^= static_cast<unsigned int>(data[i]);
    hash *= 16777619u;
  }
  return hash;
}

/// 把 HBITMAP 转成像素并算哈希；顺带取出尺寸。
bool HashBitmap(HBITMAP bitmap, unsigned int* out_hash, int* out_width,
                int* out_height) {
  BITMAP info = {};
  if (::GetObjectW(bitmap, sizeof(info), &info) == 0) {
    return false;
  }
  if (info.bmWidth <= 0 || info.bmHeight <= 0) {
    return false;
  }

  BITMAPINFO dib = {};
  dib.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  dib.bmiHeader.biWidth = info.bmWidth;
  dib.bmiHeader.biHeight = -info.bmHeight;  // 自上而下，与写入时一致
  dib.bmiHeader.biPlanes = 1;
  dib.bmiHeader.biBitCount = 32;
  dib.bmiHeader.biCompression = BI_RGB;

  const size_t stride = static_cast<size_t>(info.bmWidth) * 4;
  const size_t bytes = stride * static_cast<size_t>(info.bmHeight);
  std::vector<BYTE> pixels(bytes, 0);

  HDC dc = ::GetDC(nullptr);
  if (dc == nullptr) {
    return false;
  }
  const int lines = ::GetDIBits(dc, bitmap, 0, static_cast<UINT>(info.bmHeight),
                               pixels.data(), &dib, DIB_RGB_COLORS);
  ::ReleaseDC(nullptr, dc);
  if (lines != info.bmHeight) {
    return false;
  }

  *out_hash = HashBytes(pixels.data(), pixels.size());
  *out_width = info.bmWidth;
  *out_height = info.bmHeight;
  return true;
}

// ---------------------------------------------------------------------------
// 崩溃可观测性
//
// 这个工具的核心用途是「在别人的机器上定位问题」。所以它必须做到：
// 崩了也要留下线索。三件事：
//
// 1. **无缓冲输出**：默认 stdout 在全缓冲模式下（重定向到文件时）会把内容
//    留在缓冲区里，进程一崩就全丢了 —— 那就等于什么都没打印。
// 2. **每步一行**：DLL 是 in-proc 加载的，它崩了会带走整个进程。
//    从最后一行输出就能判断崩在哪一步。
// 3. **未处理异常过滤器**：打印异常码与出错的模块名，再交给系统默认处理。
// ---------------------------------------------------------------------------

/// 记录「已经走到第几步」，供异常过滤器打印。
///
/// **存 std::wstring 而不是 const wchar_t\***：调用方可能传临时串
/// （例如 `Step(("正在处理 " + path).c_str())`），存指针会在下一行就悬空，
/// 崩溃时打印出来的是乱码 —— 那比不打印更误导。
std::wstring g_step = L"(not started)";

/// 打印一行并立即落到控制台/文件。
void Step(const wchar_t* text) {
  g_step.assign(text == nullptr ? L"(null)" : text);
  // 用 g_step 而不是 text：text 可能是 nullptr，而 `%s` 遇到空指针会崩 ——
  // 在一个专门用来「留下崩溃线索」的函数里自己崩掉，是最讽刺的失败。
  std::wprintf(L"[step] %s\n", g_step.c_str());
  // **必须 flush**：崩溃时缓冲区内容会丢，那这行就白打了。
  std::fflush(stdout);
}

LONG WINAPI CrashHandler(EXCEPTION_POINTERS* info) {
  std::fwprintf(stderr, L"\n=== CRASH ===\n");
  if (info != nullptr && info->ExceptionRecord != nullptr) {
    const EXCEPTION_RECORD* record = info->ExceptionRecord;
    std::fwprintf(stderr, L"code    : 0x%08X\n",
                  static_cast<unsigned>(record->ExceptionCode));
    std::fwprintf(stderr, L"address : %p\n", record->ExceptionAddress);
    // 出错模块：能区分「崩在我们自己的 DLL 里」与「崩在系统 DLL 里」。
    HMODULE module = nullptr;
    if (::GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(record->ExceptionAddress), &module)) {
      wchar_t name[MAX_PATH] = {0};
      ::GetModuleFileNameW(module, name, MAX_PATH);
      std::fwprintf(stderr, L"module  : %s\n", name);
    }
  }
  std::fwprintf(stderr, L"last step: %s\n", g_step.c_str());
  std::fwprintf(stderr, L"=============\n");
  std::fflush(stderr);
  // 交给系统默认处理：不吞掉崩溃，否则退出码会是 0，
  // 调用方（CI / 用户）会以为成功。
  return EXCEPTION_CONTINUE_SEARCH;
}

/// 本进程是不是**独占一个新控制台**（即双击启动，而不是从已有 cmd 里跑）。
///
/// `GetConsoleProcessList` 返回附着到当前控制台的进程数。等于 1 说明只有
/// 自己 —— 那是双击时 Windows 新建的控制台。这种情况下程序结束窗口立刻消失，
/// 用户看到的就是「闪退」，而程序其实正常跑完了。
bool OwnsConsole() {
  DWORD list[2] = {0, 0};
  const DWORD count = ::GetConsoleProcessList(list, 2);
  return count == 1;
}

/// stdout 是否被重定向到文件/管道（而不是真正的控制台）。
bool IsRedirected() {
  return ::_isatty(::_fileno(stdout)) == 0;
}

/// 如果窗口即将消失，停住等用户按回车。
///
/// ## 这里的判断顺序是为了「既不闪退、也不挂死 CI」
///
/// 只靠 `OwnsConsole()` 是不够的：GitHub Actions 的 `shell: cmd` 步骤里，
/// 那个控制台可能只附着 cmd 自己 —— `GetConsoleProcessList` 返回 1，
/// 于是程序会**傻等回车**，把整条流水线挂到超时。这个后果比闪退严重得多。
///
/// 所以加一道 `IsRedirected()`：CI 会捕获 stdout，它不是终端，
/// 因此绝不会停。三个条件任一成立才停：
///   1. 显式 `--pause`；
///   2. 没有任何参数（双击的最典型形态：程序本来就该给人看用法）；
///   3. 独占控制台 **且** stdout 是终端（用户在资源管理器里双击了带参数的场景）。
void PauseIfNeeded(bool force, bool no_arguments) {
  if (!force && !no_arguments) {
    if (!OwnsConsole() || IsRedirected()) {
      return;
    }
  }
  WriteErrLine(L"\n按回车键关闭...");
  std::getchar();
}

/// 对单个文件跑一次完整调用。
///
/// 返回 `true` 表示拿到了非空位图。
bool RunOne(IClassFactory* factory, const std::wstring& path, UINT cx,
            std::wstring* detail) {
  Step(L"  CreateInstance(IThumbnailProvider)");
  IThumbnailProvider* provider = nullptr;
  HRESULT hr = factory->CreateInstance(nullptr, IID_IThumbnailProvider,
                                       reinterpret_cast<void**>(&provider));
  if (FAILED(hr) || provider == nullptr) {
    detail->assign(L"CreateInstance(IThumbnailProvider) failed");
    return false;
  }

  // 用 IInitializeWithItem（生产路径的首选）。SHCreateItemFromParsingName
  // 走的是与 Explorer 相同的代码，因此这条路径有代表性。
  Step(L"  QueryInterface(IInitializeWithItem)");
  IInitializeWithItem* init_item = nullptr;
  hr = provider->QueryInterface(IID_IInitializeWithItem,
                                reinterpret_cast<void**>(&init_item));
  if (SUCCEEDED(hr) && init_item != nullptr) {
    Step(L"  SHCreateItemFromParsingName");
    IShellItem* item = nullptr;
    hr = ::SHCreateItemFromParsingName(path.c_str(), nullptr, IID_IShellItem,
                                      reinterpret_cast<void**>(&item));
    if (SUCCEEDED(hr) && item != nullptr) {
      hr = init_item->Initialize(item, STGM_READ);
      item->Release();
    }
    init_item->Release();
    if (FAILED(hr)) {
      provider->Release();
      detail->assign(L"IInitializeWithItem::Initialize failed");
      return false;
    }
  } else {
    // DLL 没实现 IInitializeWithItem —— 这本身是个问题（我们声称实现了）。
    provider->Release();
    detail->assign(L"IInitializeWithItem not exposed");
    return false;
  }

  HBITMAP bitmap = nullptr;
  WTS_ALPHATYPE alpha = WTSAT_UNKNOWN;
  hr = provider->GetThumbnail(cx, &bitmap, &alpha);
  provider->Release();

  if (FAILED(hr)) {
    wchar_t buffer[64];
    swprintf_s(buffer, sizeof(buffer) / sizeof(wchar_t),
               L"GetThumbnail hr=0x%08X", static_cast<unsigned>(hr));
    detail->assign(buffer);
    return false;
  }
  if (bitmap == nullptr) {
    detail->assign(L"GetThumbnail returned S_OK but a null bitmap");
    return false;
  }

  unsigned int hash = 0;
  int width = 0;
  int height = 0;
  const bool hashed = HashBitmap(bitmap, &hash, &width, &height);
  ::DeleteObject(bitmap);
  if (!hashed) {
    detail->assign(L"bitmap could not be read back");
    return false;
  }

  wchar_t buffer[96];
  swprintf_s(buffer, sizeof(buffer) / sizeof(wchar_t),
             L"%dx%d hash=%08X alpha=%d", width, height, hash,
             static_cast<int>(alpha));
  detail->assign(buffer);
  return true;
}

}  // namespace

/// 往控制台/管道写一段宽字符文本 —— **不经过 locale**。
///
/// ## 为什么不用 `wprintf`
///
/// `wprintf` 把宽字符转多字节时依赖当前 locale：默认 "C" locale 下非 ASCII
/// **直接丢掉**（2.7.1 实机反馈：中文一个字都没出来，只剩 ASCII 的 step 行）。
/// 而 `setlocale(".UTF-8")` / `_setmode(_O_U8TEXT)` / `SetConsoleOutputCP`
/// 这三层在不同 Windows 版本、不同宿主（控制台 / 管道 / 服务）下表现并不一致，
/// 试了两轮都没稳住。
///
/// 这里改成两条固定路径，都不依赖任何全局状态：
///   - **控制台**：`WriteConsoleW` 直接写 UTF-16（系统自己转，任何代码页都对）；
///   - **重定向**：自己转 UTF-8 再 `fwrite`（管道 / 文件都读得到）。
void WriteWide(HANDLE handle, FILE* stream, const std::wstring& text) {
  DWORD mode = 0;
  if (::GetConsoleMode(handle, &mode) != 0) {
    DWORD written = 0;
    ::WriteConsoleW(handle, text.data(), static_cast<DWORD>(text.size()),
                    &written, nullptr);
    return;
  }
  const int bytes = ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                                          static_cast<int>(text.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (bytes <= 0) {
    return;
  }
  std::string utf8(static_cast<size_t>(bytes), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        &utf8[0], bytes, nullptr, nullptr);
  std::fwrite(utf8.data(), 1, utf8.size(), stream);
  std::fflush(stream);
}

/// 往 stdout 写一行。
void WriteLine(const std::wstring& text) {
  std::wstring line = text;
  line.push_back(L'\n');
  WriteWide(::GetStdHandle(STD_OUTPUT_HANDLE), stdout, line);
}

/// 往 stderr 写一行。
void WriteErrLine(const std::wstring& text) {
  std::wstring line = text;
  line.push_back(L'\n');
  WriteWide(::GetStdHandle(STD_ERROR_HANDLE), stderr, line);
}

/// `WriteLine` 的格式化版本（`_vsnwprintf_s`，超长截断而不是崩）。
void WriteLineF(const wchar_t* format, ...) {
  wchar_t buffer[1024] = {};
  va_list args;
  va_start(args, format);
  ::_vsnwprintf_s(buffer, _countof(buffer), _TRUNCATE, format, args);
  va_end(args);
  WriteLine(buffer);
}

/// 路径是否指向一个已存在的文件（目录不算）。
bool FileExists(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

/// 把一个 GUID 格式化成 `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`。
std::wstring GuidToString(const GUID& guid) {
  wchar_t buffer[64] = {};
  const int written =
      ::StringFromGUID2(guid, buffer,
                        static_cast<int>(sizeof(buffer) / sizeof(buffer[0])));
  if (written <= 0) {
    return std::wstring();
  }
  return std::wstring(buffer);
}

/// 读某个键的默认值（`REG_SZ` / `REG_EXPAND_SZ`）。不存在时返回空串。
///
/// 显式用 `KEY_WOW64_64KEY`：安装器在 **64 位视图**写 HKLM，而 32 位宿主
/// 默认读 `WOW6432Node` —— 两边看不见彼此，表现成「明明装了却说没注册」。
std::wstring ReadDefaultString(HKEY root, const std::wstring& subkey,
                               bool* exists) {
  if (exists != nullptr) {
    *exists = false;
  }
  HKEY key = nullptr;
  if (::RegOpenKeyExW(root, subkey.c_str(), 0, KEY_READ | KEY_WOW64_64KEY,
                      &key) != ERROR_SUCCESS) {
    return std::wstring();
  }
  std::vector<wchar_t> buffer(512);
  DWORD type = 0;
  DWORD size = static_cast<DWORD>(buffer.size() * sizeof(wchar_t));
  LONG status = ::RegQueryValueExW(key, nullptr, nullptr, &type,
                                   reinterpret_cast<LPBYTE>(buffer.data()),
                                   &size);
  if (status == ERROR_MORE_DATA) {
    buffer.resize(size / sizeof(wchar_t) + 1);
    size = static_cast<DWORD>(buffer.size() * sizeof(wchar_t));
    status = ::RegQueryValueExW(key, nullptr, nullptr, &type,
                                reinterpret_cast<LPBYTE>(buffer.data()), &size);
  }
  ::RegCloseKey(key);
  if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ)) {
    return std::wstring();
  }
  if (exists != nullptr) {
    *exists = true;
  }
  return std::wstring(buffer.data());
}

/// 无参运行时的「注册诊断」。
///
/// ## 为什么要它
///
/// 「图标不出来」在用户机器上是最常见的问题，而**用户不知道该传哪个文件**。
/// 绝大多数情况下问题也不在 DLL，而在注册：没写、写错 GUID、指向了旧目录。
/// 这几件事全都能在注册表里查出来，不需要任何输入文件。
///
/// 逐条查四件事，最后给一句结论：
///   1. 本目录的 DLL / helper 在不在（DLL 层能不能跑）；
///   2. HKCU / HKLM 的 CLSID 指向哪个 DLL，那个 DLL 在不在；
///   3. `.apk` / `.ipa` 的 ShellEx 挂的是不是 `IID_IThumbnailProvider`；
///   4. 挂的值是不是我们的 CLSID。
///
/// 返回 0 = 至少有一套注册完整可用；1 = 没有。
int DiagnoseRegistration(bool force_pause) {
  const std::wstring directory = ModuleDirectory();
  const std::wstring dll_path = directory + L"appinfotool_thumbnail.dll";
  const std::wstring helper_path = directory + L"app_icon_extractor.exe";
  const std::wstring handler_guid = GuidToString(IID_IThumbnailProvider);
  const std::wstring clsid = GuidToString(kExpectedClsid);

  // ASCII 标题在前：控制台连 UTF-8 都显示不了时（极老的 conhost），
  // 用户至少还能看到结构；CI 也用它做与编码无关的断言。
  WriteLine(L"");
  WriteLine(L"== registration diagnostics ==");
  WriteLine(L"== 注册诊断 ==");
  WriteLineF(L"本目录 : %s", directory.c_str());
  WriteLineF(L"dll    : %s  %s", dll_path.c_str(),
             FileExists(dll_path) ? L"[存在]" : L"[缺失]");
  WriteLineF(L"helper : %s  %s", helper_path.c_str(),
             FileExists(helper_path) ? L"[存在]" : L"[缺失]");
  WriteLineF(L"CLSID       : %s", clsid.c_str());
  WriteLineF(L"ShellEx GUID: %s", handler_guid.c_str());

  struct Root {
    const wchar_t* label;
    HKEY key;
  };
  const Root roots[] = {{L"HKCU", HKEY_CURRENT_USER},
                        {L"HKLM", HKEY_LOCAL_MACHINE}};
  const wchar_t* extensions[] = {L".apk", L".ipa"};

  bool usable = false;
  for (const Root& root : roots) {
    bool clsid_exists = false;
    const std::wstring registered_dll = ReadDefaultString(
        root.key,
        std::wstring(L"Software\\Classes\\CLSID\\") + clsid +
            L"\\InprocServer32",
        &clsid_exists);
    const bool dll_ok = clsid_exists && FileExists(registered_dll);
    WriteLine(L"");
    WriteLine(root.label);
    WriteLineF(L"  CLSID   %s",
               clsid_exists ? registered_dll.c_str() : L"(未注册)");
    if (clsid_exists) {
      WriteLineF(L"          %s",
                 dll_ok ? L"[文件存在]" : L"[文件不存在 —— 指向旧目录？]");
    }

    bool root_ok = dll_ok;
    for (const wchar_t* extension : extensions) {
      bool handler_exists = false;
      const std::wstring value = ReadDefaultString(
          root.key,
          std::wstring(L"Software\\Classes\\") + extension + L"\\ShellEx\\" +
              handler_guid,
          &handler_exists);
      const bool matches =
          handler_exists && _wcsicmp(value.c_str(), clsid.c_str()) == 0;
      WriteLineF(L"  %-5s   %s  %s", extension,
                 handler_exists ? value.c_str() : L"(未注册)",
                 matches ? L"[正确]" : L"[不是我们的处理器]");
      root_ok = root_ok && matches;
    }
    if (root_ok) {
      usable = true;
    }
  }

  WriteLine(L"");
  WriteLine(L"== 结论 ==");
  if (usable) {
    WriteLine(L"注册是完整的。若资源管理器仍显示应用图标，基本就是缓存：");
    WriteLine(L"  taskkill /f /im explorer.exe 然后 start explorer.exe");
  } else if (!FileExists(dll_path)) {
    WriteLine(L"本目录没有 appinfotool_thumbnail.dll —— 这份自检包不完整。");
    WriteLine(L"重新解压发布页的 zip，或直接用安装目录里的那一份。");
  } else {
    WriteLine(L"没有任何一套完整注册。装安装版会自动写；");
    WriteLine(L"便携版打开一次应用（设置页「系统文件图标 → 启用」）即可。");
  }
  WriteLine(L"");
  WriteLine(L"想验证 DLL 本身能不能出图，传一个包：");
  WriteLine(L"  appinfotool_thumbnail_selftest 某个.apk");

  PauseIfNeeded(force_pause, false);
  return usable ? 0 : 1;
}

int wmain(int argc, wchar_t** argv) {
  // **先关掉缓冲**，再干任何事。
  //
  // 崩溃时缓冲区里的内容会全部丢失 —— 而「崩溃前最后打印了什么」正是
  // 定位问题最需要的信息。宁可多几次系统调用，也不能让它丢。
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::setvbuf(stderr, nullptr, _IONBF, 0);

  // 中文输出**不走 `wprintf`**：它按 locale 转多字节，非 ASCII 会被丢掉。
  // 所有非 ASCII 文本都用 `WriteLine` / `WriteLineF`（控制台走 WriteConsoleW，
  // 重定向走 UTF-8），见那个函数的注释。剩下的 `wprintf` 只打 ASCII。

  // 装崩溃处理器。放在最前面：后面任何一步崩了都能留下异常码与模块名。
  ::SetUnhandledExceptionFilter(CrashHandler);

  Step(L"started");
  std::wprintf(L"exe  : %s\n", argv[0]);
  std::wprintf(L"argc : %d\n", argc);

  bool force_pause = false;
  // 双击启动时窗口会立刻消失，看起来像闪退 —— 这里主动停住。
  // 从 cmd 里跑（或 CI 重定向）则不停。
  const bool attached_console = OwnsConsole();
  std::wprintf(L"console: %s\n",
               attached_console ? L"own (double-clicked?)" : L"inherited");
  std::fflush(stdout);

  // COM 必须在任何 Shell API 之前初始化。STA：与 Explorer 调用缩略图
  // 处理器的线程模型一致（注册表里写的就是 Apartment）。
  Step(L"CoInitializeEx");
  const HRESULT co = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(co)) {
    std::fwprintf(stderr, L"CoInitializeEx failed: 0x%08X\n",
                  static_cast<unsigned>(co));
    // 这里 `files` 还没解析出来，不能传 `files.empty()`。
    // 传 false：只有「独占控制台且 stdout 是终端」才停 —— 双击能看到错误，
    // CI（stdout 被捕获）不会挂住。
    PauseIfNeeded(false, false);
    return 2;
  }

  UINT cx = 256;
  bool expect_distinct = false;
  std::vector<std::wstring> files;
  for (int i = 1; i < argc; ++i) {
    const std::wstring arg = argv[i];
    if (arg == L"--cx" && i + 1 < argc) {
      cx = static_cast<UINT>(_wtoi(argv[++i]));
      continue;
    }
    if (arg == L"--expect-distinct") {
      expect_distinct = true;
      continue;
    }
    if (arg == L"--pause") {
      force_pause = true;
      continue;
    }
    if (arg == L"--help" || arg == L"-h") {
      WriteLine(
          L"usage: appinfotool_thumbnail_selftest [--cx N] "
          L"[--expect-distinct] [--pause] file...");
      WriteLine(L"       appinfotool_thumbnail_selftest            (注册诊断)");
      ::CoUninitialize();
      return 0;
    }
    files.push_back(arg);
  }
  if (files.empty()) {
    // 没有输入文件时做**注册诊断**，而不是只打用法。
    //
    // 「图标不出来」是这个工具存在的理由，而那时候用户并不知道该传哪个文件；
    // 真正的断点九成在注册表（没写 / GUID 写错 / 指向旧目录），这些都能在
    // 没有输入文件的情况下查清。
    ::CoUninitialize();
    return DiagnoseRegistration(force_pause);
  }

  Step(L"locate DLL");
  const std::wstring dll_path = ModuleDirectory() + L"appinfotool_thumbnail.dll";
  std::wprintf(L"dll  : %s\n", dll_path.c_str());
  std::fflush(stdout);

  Step(L"LoadLibrary");
  HMODULE dll = ::LoadLibraryW(dll_path.c_str());
  if (dll == nullptr) {
    const DWORD error = ::GetLastError();
    std::fwprintf(stderr, L"cannot load %s (error %lu)\n", dll_path.c_str(),
                  error);
    if (error == 126 /* ERROR_MOD_NOT_FOUND */) {
      // 126 几乎总是「DLL 的依赖不在」—— 常见是缺 VC++ 运行库。
      // 直接把这个判断说出来，不然用户只会看到一句看不懂的英文。
      std::fwprintf(stderr,
                    L"hint: ERROR_MOD_NOT_FOUND usually means a dependency of "
                    L"the DLL is missing (e.g. the Visual C++ runtime).\n");
    }
    ::CoUninitialize();
    PauseIfNeeded(force_pause, files.empty());
    return 2;
  }

  Step(L"GetProcAddress(DllGetClassObject)");
  auto get_class_object = reinterpret_cast<DllGetClassObjectFn>(
      ::GetProcAddress(dll, "DllGetClassObject"));
  if (get_class_object == nullptr) {
    std::fwprintf(stderr, L"appinfotool_thumbnail.dll does not export "
                          L"DllGetClassObject\n");
    ::FreeLibrary(dll);
    ::CoUninitialize();
    PauseIfNeeded(force_pause, files.empty());
    return 2;
  }

  Step(L"DllGetClassObject");
  IClassFactory* factory = nullptr;
  HRESULT hr = get_class_object(kExpectedClsid, IID_IClassFactory,
                                reinterpret_cast<void**>(&factory));
  if (FAILED(hr) || factory == nullptr) {
    std::fwprintf(stderr,
                  L"DllGetClassObject(CLSID) failed: 0x%08X — the DLL exports "
                  L"a different CLSID than the one registered\n",
                  static_cast<unsigned>(hr));
    ::FreeLibrary(dll);
    ::CoUninitialize();
    PauseIfNeeded(force_pause, files.empty());
    return 2;
  }

  int failures = 0;
  // 成功项的像素哈希（用于 `--expect-distinct`）。
  std::vector<std::pair<std::wstring, unsigned int>> succeeded;
  for (const auto& file : files) {
    // **转成绝对路径再传**。
    //
    // `SHCreateItemFromParsingName` 对相对路径的解析基准不保证是当前工作
    // 目录（它不是 `CreateFileW`），而 helper 子进程继承的是父进程的 cwd ——
    // 一旦两者不一致，DLL 里 `IsSupportedExtension` 通过、`CreateProcessW`
    // 也成功，但 helper 打开文件失败，最终表现成「没产出缩略图」而没有
    // 任何线索。在边界上消掉这类不确定性，比事后排查便宜得多。
    wchar_t absolute[MAX_PATH * 2] = {0};
    constexpr DWORD kAbsoluteCapacity =
        static_cast<DWORD>(sizeof(absolute) / sizeof(absolute[0]));
    const DWORD full =
        ::GetFullPathNameW(file.c_str(), kAbsoluteCapacity, absolute, nullptr);
    // `full` 返回所需长度（含结尾 0）；超过容量说明被截断，退回原值。
    const std::wstring resolved =
        (full > 0 && full < kAbsoluteCapacity) ? std::wstring(absolute) : file;

    // 每一步都打印 + flush：DLL 是 in-proc 的，它崩了会带走整个进程。
    // 「最后一行是哪一步」就是唯一的崩溃位置线索。
    std::wstring step_text = L"GetThumbnail(" + resolved + L")";
    Step(step_text.c_str());

    std::wstring detail;
    const bool ok = RunOne(factory, resolved, cx, &detail);
    // 只打印文件名，避免 CI 日志里出现超长路径。
    const size_t slash = resolved.find_last_of(L"\\/");
    const std::wstring name =
        slash == std::wstring::npos ? resolved : resolved.substr(slash + 1);
    if (ok) {
      std::wprintf(L"OK   %s %s\n", name.c_str(), detail.c_str());
      // detail 形如 `72x72 hash=1A2B3C4D alpha=3`：取 hash= 之后的 8 个字符。
      const std::wstring marker = L"hash=";
      const size_t at = detail.find(marker);
      if (at != std::wstring::npos && at + marker.size() + 8 <= detail.size()) {
        const std::wstring hex = detail.substr(at + marker.size(), 8);
        succeeded.emplace_back(name, static_cast<unsigned int>(
                                         wcstoul(hex.c_str(), nullptr, 16)));
      }
    } else {
      std::wprintf(L"FAIL %s %s\n", name.c_str(), detail.c_str());
      ++failures;
    }
  }

  // `--expect-distinct`：所有成功项的图标必须两两不同。
  //
  // 用「两两比较」而不是「去重后计数」：条目很少（CI 里 2 个），
  // 而两两比较能直接报出**哪两个**撞了 —— 那个信息在排查时才有用。
  if (expect_distinct && succeeded.size() >= 2) {
    for (size_t i = 0; i < succeeded.size(); ++i) {
      for (size_t j = i + 1; j < succeeded.size(); ++j) {
        if (succeeded[i].second == succeeded[j].second) {
          std::wprintf(
              L"MISMATCH %s and %s produced the same icon (hash %08X)\n",
              succeeded[i].first.c_str(), succeeded[j].first.c_str(),
              succeeded[i].second);
          ++failures;
        }
      }
    }
  }

  factory->Release();
  ::FreeLibrary(dll);
  ::CoUninitialize();

  std::wprintf(L"\n%d of %zu succeeded\n", static_cast<int>(files.size()) -
                                              failures, files.size());
  std::fflush(stdout);
  PauseIfNeeded(force_pause, files.empty());
  return failures == 0 ? 0 : 1;
}
