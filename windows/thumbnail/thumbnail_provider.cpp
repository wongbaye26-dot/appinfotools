#include "thumbnail_provider.h"

// **windows.h 必须先于其它 Win32 头**：thumbcache.h / wincodec.h 依赖它引入的
// 基础类型。项目里 `file_association_channel.cpp` 也是这个顺序（CI run #93
// 曾因 `shlobj.h` 在前而失败）。
#include <windows.h>

#include <shlobj.h>
// `IInitializeWithStream` 及其 IID 声明在 propsys.h，`shlobj.h` 不保证带入。
#include <propsys.h>
#include <shlwapi.h>
#include <thumbcache.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <new>
#include <string>
#include <vector>

namespace appinfotool {
namespace {

using Microsoft::WRL::ComPtr;

/// 输出文件的大小上限（16 MiB）。
///
/// helper 自己已经限制到 8 MiB 的图标字节，这里留一倍余量纯属防御：
/// 万一 helper 被替换成别的程序，也不能让本 DLL 读进任意大小的文件。
constexpr DWORD kMaxIconFileBytes = 16u * 1024u * 1024u;

/// 请求尺寸的上限。
///
/// Shell 通常请求 16–256 px，偶尔 1024。超过这个值说明调用方异常，
/// 按上限处理 —— 分配一个 100000×100000 的 DIB 会直接把 Explorer 拖死。
constexpr UINT kMaxThumbnailSide = 1024;

/// 取本 DLL 所在目录（末尾带反斜杠）。失败返回空串。
std::wstring ModuleDirectory() {
  std::vector<wchar_t> buffer(MAX_PATH);
  for (int attempt = 0; attempt < 4; ++attempt) {
    DWORD written = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (written == 0) {
      return std::wstring();
    }
    // 返回长度等于缓冲区大小：可能被截断，扩大重试。
    if (written < buffer.size()) {
      std::wstring path(buffer.data(), written);
      const size_t slash = path.find_last_of(L"\\/");
      if (slash == std::wstring::npos) {
        return std::wstring();
      }
      return path.substr(0, slash + 1);
    }
    buffer.resize(buffer.size() * 2);
  }
  return std::wstring();
}

/// helper 的完整路径（与 DLL 同目录）。
///
/// 同目录而不是 `%LOCALAPPDATA%`：安装器把两者放在一起，卸载时一起删；
/// 也避免「装了新版 DLL、还留着旧版 helper」这种版本错配。
std::wstring HelperPath() {
  const std::wstring dir = ModuleDirectory();
  if (dir.empty()) {
    return std::wstring();
  }
  return dir + L"app_icon_extractor.exe";
}

/// 生成一个**尚不存在**的唯一临时文件路径。
///
/// 用 `GetTempFileNameW` 拿唯一名后**立刻删掉**：它的语义是「创建并返回路径」，
/// 而我们要的是让 helper 去创建。留着空文件会让 helper 的写入变成覆盖，
/// 更糟的是「helper 失败时留下一个 0 字节文件」会被下次误判成有效图标。
std::wstring MakeTempOutputPath() {
  wchar_t temp_dir[MAX_PATH + 1] = {0};
  if (::GetTempPathW(MAX_PATH, temp_dir) == 0) {
    return std::wstring();
  }
  wchar_t temp_file[MAX_PATH + 1] = {0};
  if (::GetTempFileNameW(temp_dir, L"ait", 0, temp_file) == 0) {
    return std::wstring();
  }
  ::DeleteFileW(temp_file);
  return std::wstring(temp_file);
}

/// 按 Windows 命令行规则给参数加引号。
///
/// 只处理「含空格或制表符就加引号」这一种情况。**路径里不可能有双引号**
/// （Win32 文件名禁止 `"`），因此不需要完整的反斜杠转义序列 —— 但为稳妥，
/// 遇到引号直接判为非法，返回空串由调用方拒绝。
bool QuoteArgument(const std::wstring& value, std::wstring* out) {
  if (value.find(L'"') != std::wstring::npos) {
    return false;
  }
  const bool needs_quotes =
      value.find(L' ') != std::wstring::npos ||
      value.find(L'\t') != std::wstring::npos;
  if (needs_quotes) {
    *out = L"\"" + value + L"\"";
  } else {
    *out = value;
  }
  return true;
}

/// 读整个文件（有上限）。
bool ReadFileBytes(const std::wstring& path, std::vector<BYTE>* out) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  LARGE_INTEGER size = {};
  if (!::GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      size.QuadPart > static_cast<LONGLONG>(kMaxIconFileBytes)) {
    ::CloseHandle(file);
    return false;
  }
  out->resize(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  const bool ok = ::ReadFile(file, out->data(),
                             static_cast<DWORD>(out->size()), &read, nullptr) !=
                  FALSE;
  ::CloseHandle(file);
  if (!ok || read != out->size()) {
    return false;
  }
  return true;
}

/// 起 helper 进程并等它结束。
///
/// 返回 helper 的退出码；进程起不来返回 -1，超时返回 -2（已强制终止）。
///
/// **不用 shell**：`CreateProcessW` 的第一个参数明确给 exe 路径，
/// 命令行里只放参数。这样即使文件名里带 `&` `|` `^`，也不会被解释成命令。
int RunHelper(const std::wstring& helper, const std::wstring& source,
              const std::wstring& output) {
  std::wstring quoted_helper;
  std::wstring quoted_source;
  std::wstring quoted_output;
  if (!QuoteArgument(helper, &quoted_helper) ||
      !QuoteArgument(source, &quoted_source) ||
      !QuoteArgument(output, &quoted_output)) {
    return -1;
  }

  std::wstring command_line =
      quoted_helper + L" --input " + quoted_source + L" --output " + quoted_output;

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};

  // `CREATE_NO_WINDOW`：Explorer 是 GUI 进程，起控制台子进程会闪一个黑框。
  // 不继承句柄：helper 不需要我们的任何句柄，继承只会扩大风险面。
  const BOOL started =
      ::CreateProcessW(helper.c_str(), command_line.data(), nullptr, nullptr,
                       FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                       &process);
  if (!started) {
    return -1;
  }

  const DWORD wait = ::WaitForSingleObject(process.hProcess, kHelperTimeoutMs);
  if (wait != WAIT_OBJECT_0) {
    // 超时：必须强制结束，否则残留进程会一直占着文件与内存。
    ::TerminateProcess(process.hProcess, static_cast<UINT>(-2));
    ::WaitForSingleObject(process.hProcess, 200);
    ::CloseHandle(process.hThread);
    ::CloseHandle(process.hProcess);
    return -2;
  }

  DWORD exit_code = 0;
  ::GetExitCodeProcess(process.hProcess, &exit_code);
  ::CloseHandle(process.hThread);
  ::CloseHandle(process.hProcess);
  return static_cast<int>(exit_code);
}

/// 用 WIC 把图片字节解码成 HBITMAP。
///
/// 缩放规则（规格 4.4）：
/// - 保持宽高比；
/// - **不放大** —— 原图比请求尺寸小时按原尺寸返回，放大只会得到糊掉的方块；
/// - 统一转 32bppPBGRA，保留透明通道（自适应图标裁切后的圆角要靠它）。
HRESULT DecodeToBitmap(const std::vector<BYTE>& bytes, UINT requested_side,
                       HBITMAP* out_bitmap, WTS_ALPHATYPE* out_alpha) {
  if (bytes.empty() || out_bitmap == nullptr) {
    return E_INVALIDARG;
  }
  *out_bitmap = nullptr;
  if (out_alpha != nullptr) {
    *out_alpha = WTSAT_ARGB;
  }

  const UINT side =
      requested_side == 0 ? 256 : (requested_side > kMaxThumbnailSide
                                       ? kMaxThumbnailSide
                                       : requested_side);

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(factory.GetAddressOf()));
  if (FAILED(hr)) {
    return hr;
  }

  // 从内存解码：我们已经把字节读进来了，不必再给 WIC 一个文件路径
  // （那会多一次文件打开，且在临时文件被别人替换时引入竞态）。
  ComPtr<IWICStream> stream;
  hr = factory->CreateStream(stream.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  hr = stream->InitializeFromMemory(const_cast<BYTE*>(bytes.data()),
                                    static_cast<DWORD>(bytes.size()));
  if (FAILED(hr)) {
    return hr;
  }

  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromStream(stream.Get(), nullptr,
                                        WICDecodeMetadataCacheOnLoad,
                                        decoder.GetAddressOf());
  if (FAILED(hr)) {
    // 系统没有对应解码器时返回 WINCODEC_ERR_COMPONENTNOTFOUND 之类。
    // 对调用方而言就是「这个格式本机解不了」→ 回退文件图标。
    return hr;
  }

  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, frame.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }

  UINT width = 0;
  UINT height = 0;
  hr = frame->GetSize(&width, &height);
  if (FAILED(hr) || width == 0 || height == 0) {
    return FAILED(hr) ? hr : E_FAIL;
  }

  // 保持比例、不放大。
  UINT target_width = width;
  UINT target_height = height;
  if (width > side || height > side) {
    const double scale = static_cast<double>(side) /
                         static_cast<double>(width > height ? width : height);
    target_width = static_cast<UINT>(width * scale);
    target_height = static_cast<UINT>(height * scale);
    if (target_width == 0) target_width = 1;
    if (target_height == 0) target_height = 1;
  }

  ComPtr<IWICBitmapSource> source = frame;
  if (target_width != width || target_height != height) {
    ComPtr<IWICBitmapScaler> scaler;
    hr = factory->CreateBitmapScaler(scaler.GetAddressOf());
    if (FAILED(hr)) {
      return hr;
    }
    hr = scaler->Initialize(frame.Get(), target_width, target_height,
                            WICBitmapInterpolationModeHighQualityCubic);
    if (FAILED(hr)) {
      return hr;
    }
    source = scaler;
  }

  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(converter.GetAddressOf());
  if (FAILED(hr)) {
    return hr;
  }
  hr = converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPBGRA,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) {
    return hr;
  }

  // ---- 建 DIB 并拷像素 ----
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = static_cast<LONG>(target_width);
  // 负高度 = 自上而下，与 WIC 的扫描线顺序一致（省一次翻转）。
  info.bmiHeader.biHeight = -static_cast<LONG>(target_height);
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  void* pixels = nullptr;
  HBITMAP bitmap =
      ::CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (bitmap == nullptr || pixels == nullptr) {
    if (bitmap != nullptr) {
      ::DeleteObject(bitmap);
    }
    return E_OUTOFMEMORY;
  }

  const UINT stride = target_width * 4;
  hr = converter->CopyPixels(nullptr, stride, stride * target_height,
                             static_cast<BYTE*>(pixels));
  if (FAILED(hr)) {
    ::DeleteObject(bitmap);
    return hr;
  }

  *out_bitmap = bitmap;
  return S_OK;
}

/// 从 IShellItem 取文件系统路径。
bool PathFromShellItem(IShellItem* item, std::wstring* out) {
  if (item == nullptr) {
    return false;
  }
  PWSTR raw = nullptr;
  const HRESULT hr = item->GetDisplayName(SIGDN_FILESYSPATH, &raw);
  if (FAILED(hr) || raw == nullptr) {
    return false;
  }
  *out = raw;
  ::CoTaskMemFree(raw);
  return !out->empty();
}

/// 只接受本处理器声明的两种扩展名。
///
/// 注册表里只挂了 `.apk` / `.ipa`，理论上不会收到别的；但「理论上」不足以防
/// 第三方直接把我们的 CLSID 挂到别的扩展名上。多一层判断不花钱。
bool IsSupportedExtension(const std::wstring& path) {
  const size_t dot = path.find_last_of(L'.');
  if (dot == std::wstring::npos) {
    return false;
  }
  std::wstring ext = path.substr(dot);
  // 手写 ASCII 小写，不用 `towlower`：
  // 1) 扩展名只可能是 ASCII，locale 相关的大小写映射在这里毫无意义；
  // 2) `towlower` 返回 `wint_t`，在 `/W4` 下与 `wchar_t` 的转换会引警告，
  //    而本项目把警告当错误（/WX）。
  for (auto& ch : ext) {
    if (ch >= L'A' && ch <= L'Z') {
      ch = static_cast<wchar_t>(ch - L'A' + L'a');
    }
  }
  return ext == L".apk" || ext == L".ipa";
}

}  // namespace

const CLSID kThumbnailProviderClsid = {
    0x9c4a7e52,
    0x3b7d,
    0x4e31,
    {0x9a, 0x4c, 0x6d, 0x2f, 0x8b, 0x1e, 0x5a, 0x70}};

ThumbnailProvider::ThumbnailProvider() = default;

ThumbnailProvider::~ThumbnailProvider() {
  if (owns_temporary_file_ && !temporary_file_.empty()) {
    ::DeleteFileW(temporary_file_.c_str());
  }
}

IFACEMETHODIMP ThumbnailProvider::QueryInterface(REFIID riid, void** ppv) {
  if (ppv == nullptr) {
    return E_POINTER;
  }
  *ppv = nullptr;
  if (riid == IID_IUnknown || riid == IID_IThumbnailProvider) {
    *ppv = static_cast<IThumbnailProvider*>(this);
  } else if (riid == IID_IInitializeWithItem) {
    *ppv = static_cast<IInitializeWithItem*>(this);
  } else if (riid == IID_IInitializeWithStream) {
    *ppv = static_cast<IInitializeWithStream*>(this);
  } else {
    return E_NOINTERFACE;
  }
  AddRef();
  return S_OK;
}

IFACEMETHODIMP_(ULONG) ThumbnailProvider::AddRef() {
  return static_cast<ULONG>(::InterlockedIncrement(&ref_count_));
}

IFACEMETHODIMP_(ULONG) ThumbnailProvider::Release() {
  const LONG remaining = ::InterlockedDecrement(&ref_count_);
  if (remaining == 0) {
    delete this;
  }
  return static_cast<ULONG>(remaining);
}

IFACEMETHODIMP ThumbnailProvider::Initialize(IShellItem* shell_item,
                                             DWORD /*mode*/) {
  try {
    std::wstring path;
    if (!PathFromShellItem(shell_item, &path)) {
      // 非文件系统项（搜索结果里的虚拟项等）：我们不处理。
      return E_INVALIDARG;
    }
    source_path_ = path;
    return S_OK;
  } catch (...) {
    return E_UNEXPECTED;
  }
}

IFACEMETHODIMP ThumbnailProvider::Initialize(IStream* stream, DWORD /*mode*/) {
  // 只给了流，没有路径 —— helper 需要**随机访问**（ZIP 的中央目录在文件尾部），
  // 因此必须先落到临时文件。落盘本身不增加风险面：解析仍然发生在
  // helper 进程里，本 DLL 从不解析内容。
  try {
    if (stream == nullptr) {
      return E_INVALIDARG;
    }
    const std::wstring temp_path = MakeTempOutputPath();
    if (temp_path.empty()) {
      return E_FAIL;
    }

    HANDLE file = ::CreateFileW(temp_path.c_str(), GENERIC_WRITE, 0, nullptr,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      return E_FAIL;
    }

    // 有界拷贝：缩略图请求不该把任意大的流写到磁盘。
    constexpr ULONGLONG kMaxCopied = 512ull * 1024ull * 1024ull;
    ULONGLONG copied = 0;
    BYTE buffer[64 * 1024];
    HRESULT hr = S_OK;
    for (;;) {
      ULONG read = 0;
      hr = stream->Read(buffer, sizeof(buffer), &read);
      if (FAILED(hr)) {
        break;
      }
      if (read == 0) {
        break;
      }
      copied += read;
      if (copied > kMaxCopied) {
        hr = E_FAIL;
        break;
      }
      DWORD written = 0;
      if (!::WriteFile(file, buffer, read, &written, nullptr) ||
          written != read) {
        hr = E_FAIL;
        break;
      }
    }
    ::CloseHandle(file);

    if (FAILED(hr)) {
      ::DeleteFileW(temp_path.c_str());
      return hr;
    }

    temporary_file_ = temp_path;
    owns_temporary_file_ = true;
    source_path_ = temp_path;
    return S_OK;
  } catch (...) {
    return E_UNEXPECTED;
  }
}

IFACEMETHODIMP ThumbnailProvider::GetThumbnail(UINT cx, HBITMAP* phbmp,
                                               WTS_ALPHATYPE* pdwAlpha) {
  if (phbmp == nullptr) {
    return E_POINTER;
  }
  *phbmp = nullptr;
  if (pdwAlpha != nullptr) {
    *pdwAlpha = WTSAT_ARGB;
  }
  if (source_path_.empty()) {
    return E_UNEXPECTED;  // 未初始化
  }
  if (!IsSupportedExtension(source_path_)) {
    return E_INVALIDARG;
  }

  // **整段包在 try/catch 里**：这个函数运行在 explorer.exe 内，
  // 任何逃逸的异常都会终止整个桌面进程。COM 边界本身也是 noexcept 的。
  try {
    const std::wstring helper = HelperPath();
    if (helper.empty()) {
      return E_FAIL;
    }
    // helper 不存在（用户只解压了 exe、或安装不完整）时直接失败，
    // 不要留下「图标一片空白但也不知道为什么」的状态。
    if (::GetFileAttributesW(helper.c_str()) == INVALID_FILE_ATTRIBUTES) {
      return E_FAIL;
    }

    const std::wstring output = MakeTempOutputPath();
    if (output.empty()) {
      return E_FAIL;
    }

    const int exit_code = RunHelper(helper, source_path_, output);
    if (exit_code != 0) {
      // 2 = 不支持 / 3 = 输入无效 / 4 = 超预算 / -1 起不来 / -2 超时。
      // 全部回退到系统文件图标 —— 对用户而言「没有缩略图」是正确行为，
      // 而「给一个错的图标」不是。
      ::DeleteFileW(output.c_str());
      return E_FAIL;
    }

    std::vector<BYTE> bytes;
    const bool read_ok = ReadFileBytes(output, &bytes);
    ::DeleteFileW(output.c_str());
    if (!read_ok) {
      return E_FAIL;
    }

    HBITMAP bitmap = nullptr;
    WTS_ALPHATYPE alpha = WTSAT_ARGB;
    const HRESULT hr = DecodeToBitmap(bytes, cx, &bitmap, &alpha);
    if (FAILED(hr) || bitmap == nullptr) {
      return FAILED(hr) ? hr : E_FAIL;
    }

    *phbmp = bitmap;
    if (pdwAlpha != nullptr) {
      *pdwAlpha = alpha;
    }
    return S_OK;
  } catch (...) {
    // 走到这里说明有未预期的异常（例如 STL 分配失败）。
    // 返回失败即可：Shell 会回退到文件图标，Explorer 不受影响。
    return E_UNEXPECTED;
  }
}

}  // namespace appinfotool

// ---------------------------------------------------------------------------
// COM 导出
// ---------------------------------------------------------------------------

namespace {

/// 类厂：只为 `IThumbnailProvider` 服务。
class ClassFactory : public IClassFactory {
 public:
  IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) {
      return E_POINTER;
    }
    if (riid == IID_IUnknown || riid == IID_IClassFactory) {
      *ppv = static_cast<IClassFactory*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  IFACEMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(::InterlockedIncrement(&ref_count_));
  }

  IFACEMETHODIMP_(ULONG) Release() override {
    const LONG remaining = ::InterlockedDecrement(&ref_count_);
    if (remaining == 0) {
      delete this;
    }
    return static_cast<ULONG>(remaining);
  }

  IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid,
                                void** ppv) override {
    if (ppv == nullptr) {
      return E_POINTER;
    }
    *ppv = nullptr;
    if (outer != nullptr) {
      return CLASS_E_NOAGGREGATION;
    }
    auto* provider = new (std::nothrow) appinfotool::ThumbnailProvider();
    if (provider == nullptr) {
      return E_OUTOFMEMORY;
    }
    const HRESULT hr = provider->QueryInterface(riid, ppv);
    provider->Release();
    return hr;
  }

  IFACEMETHODIMP LockServer(BOOL /*lock*/) override { return S_OK; }

 private:
  LONG ref_count_ = 1;
};

}  // namespace

// 导出方式说明（CI run #1 的教训）：
//
// **不能在这里写 `__declspec(dllexport)`。** `combaseapi.h` 已经把这两个函数
// 声明为 `WINOLEAPI DllGetClassObject(...)`，而 `WINOLEAPI` 展开成
// `EXTERN_C HRESULT __stdcall`。在同一翻译单元里再用带 `dllexport` 的写法
// 定义同一个函数，MSVC 判定为「linkage 不同」，报：
//
//   error C2375: 'DllGetClassObject': redefinition; different linkage
//   error C2375: 'DllCanUnloadNow': redefinition; different linkage
//
// COM server 的标准做法是**用 .def 文件导出**（见
// `appinfotool_thumbnail.def`）。这样定义处保持 SDK 声明的原样，
// 导出表由链接器生成。
extern "C" HRESULT __stdcall
DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
  if (ppv == nullptr) {
    return E_POINTER;
  }
  *ppv = nullptr;
  if (!::IsEqualCLSID(rclsid, appinfotool::kThumbnailProviderClsid)) {
    return CLASS_E_CLASSNOTAVAILABLE;
  }
  auto* factory = new (std::nothrow) ClassFactory();
  if (factory == nullptr) {
    return E_OUTOFMEMORY;
  }
  const HRESULT hr = factory->QueryInterface(riid, ppv);
  factory->Release();
  return hr;
}

extern "C" HRESULT __stdcall DllCanUnloadNow() {
  // 始终返回 S_FALSE：本 DLL 由 Explorer 长期持有，卸载时机交给系统。
  // 在没有引用计数跟踪的情况下返回 S_OK 会让系统在请求间隙卸载 DLL，
  // 而后续请求会走一次冷加载 —— 每次都要重新初始化。
  return S_FALSE;
}
