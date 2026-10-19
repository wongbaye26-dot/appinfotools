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

/// 对单个文件跑一次完整调用。
///
/// 返回 `true` 表示拿到了非空位图。
bool RunOne(IClassFactory* factory, const std::wstring& path, UINT cx,
            std::wstring* detail) {
  IThumbnailProvider* provider = nullptr;
  HRESULT hr = factory->CreateInstance(nullptr, IID_IThumbnailProvider,
                                       reinterpret_cast<void**>(&provider));
  if (FAILED(hr) || provider == nullptr) {
    detail->assign(L"CreateInstance(IThumbnailProvider) failed");
    return false;
  }

  // 用 IInitializeWithItem（生产路径的首选）。SHCreateItemFromParsingName
  // 走的是与 Explorer 相同的代码，因此这条路径有代表性。
  IInitializeWithItem* init_item = nullptr;
  hr = provider->QueryInterface(IID_IInitializeWithItem,
                                reinterpret_cast<void**>(&init_item));
  if (SUCCEEDED(hr) && init_item != nullptr) {
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
  // COM 必须在任何 Shell API 之前初始化。STA：与 Explorer 调用缩略图
  // 处理器的线程模型一致（注册表里写的就是 Apartment）。
  const HRESULT co = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(co)) {
    std::fwprintf(stderr, L"CoInitializeEx failed: 0x%08X\n",
                  static_cast<unsigned>(co));
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
    if (arg == L"--help" || arg == L"-h") {
      std::wprintf(
          L"usage: appinfotool_thumbnail_selftest [--cx N] file...\n");
      ::CoUninitialize();
      return 0;
    }
    files.push_back(arg);
  }
  if (files.empty()) {
    std::fwprintf(stderr, L"no input files\n");
    ::CoUninitialize();
    return 2;
  }

  const std::wstring dll_path = ModuleDirectory() + L"appinfotool_thumbnail.dll";
  HMODULE dll = ::LoadLibraryW(dll_path.c_str());
  if (dll == nullptr) {
    std::fwprintf(stderr, L"cannot load %s (error %lu)\n", dll_path.c_str(),
                  ::GetLastError());
    ::CoUninitialize();
    return 2;
  }

  auto get_class_object = reinterpret_cast<DllGetClassObjectFn>(
      ::GetProcAddress(dll, "DllGetClassObject"));
  if (get_class_object == nullptr) {
    std::fwprintf(stderr, L"appinfotool_thumbnail.dll does not export "
                          L"DllGetClassObject\n");
    ::FreeLibrary(dll);
    ::CoUninitialize();
    return 2;
  }

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
  return failures == 0 ? 0 : 1;
}
