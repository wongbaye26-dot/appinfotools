// 缩略图处理器的**自动化自检**（不进安装包）。
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
  std::fwprintf(stderr, L"\n按回车键关闭...\n");
  std::fflush(stderr);
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

int wmain(int argc, wchar_t** argv) {
  // **先关掉缓冲**，再干任何事。
  //
  // 崩溃时缓冲区里的内容会全部丢失 —— 而「崩溃前最后打印了什么」正是
  // 定位问题最需要的信息。宁可多几次系统调用，也不能让它丢。
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::setvbuf(stderr, nullptr, _IONBF, 0);

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
      std::wprintf(
          L"usage: appinfotool_thumbnail_selftest [--cx N] "
          L"[--expect-distinct] [--pause] file...\n");
      ::CoUninitialize();
      return 0;
    }
    files.push_back(arg);
  }
  if (files.empty()) {
    std::wprintf(
        L"没有输入文件。\n\n"
        L"用法：appinfotool_thumbnail_selftest [选项] 文件1.apk [文件2.ipa ...]\n\n"
        L"  选项：\n"
        L"    --cx N              请求的缩略图边长，默认 256\n"
        L"    --expect-distinct   断言所有成功的输入产出的图标两两不同\n"
        L"    --pause             结束时等待回车（双击运行时自动生效）\n\n"
        L"  示例：\n"
        L"    appinfotool_thumbnail_selftest icon-png.apk\n\n"
        L"注意：本目录下还需要 appinfotool_thumbnail.dll 与 "
        L"app_icon_extractor.exe。\n");
    ::CoUninitialize();
    PauseIfNeeded(force_pause, files.empty());
    return 2;
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
