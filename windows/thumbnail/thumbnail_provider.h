#ifndef THUMBNAIL_THUMBNAIL_PROVIDER_H_
#define THUMBNAIL_THUMBNAIL_PROVIDER_H_

// Windows Shell 缩略图处理器。
//
// ## 为什么它是一个**独立的 DLL**，而不是塞进 runner.exe
//
// 缩略图处理器由 `explorer.exe` 加载（in-proc COM）。runner.exe 是 GUI 程序，
// 没有 `DllGetClassObject`，Explorer 根本不会去加载它。所以必须单独产出
// 一个 `.dll`。
//
// ## 为什么 DLL 里不能直接跑解析逻辑
//
// 两个硬约束：
// 1. Dart 运行时无法嵌进一个已有消息循环的宿主进程；
// 2. 解析崩溃会**带崩整个桌面** —— 这是 Explorer 扩展最常见的故障形态。
//
// 因此 DLL 只做三件事：拿路径 → 起 `app_icon_extractor.exe` → 把它的输出
// 解码成 HBITMAP。所有解析都在独立进程里，超时可以直接 kill。
//
// ## 接口
//
// - `IThumbnailProvider`：核心，返回 HBITMAP。
// - `IInitializeWithItem`：**首选**。Shell 传 IShellItem，能拿到真实文件路径，
//   正合我们「把路径交给 helper」的需要。
// - `IInitializeWithStream`：备选。某些调用方只给流；此时把流落到临时文件
//   再交给 helper（我们不自己解析，落盘不是额外风险面）。
//
// 规格 2.1 提到「`IInitializeWithStream` 或经过验证的等效初始化方式」——
// 这里采用 `IInitializeWithItem` 为主，因为它避免了不必要的落盘。

#include <windows.h>

#include <thumbcache.h>
#include <wincodec.h>

#include <string>

namespace appinfotool {

/// 缩略图处理器的 CLSID。
///
/// **不能改**：注册表里的 `ShellEx\{e357fccd-…}` 指向的就是这个值，
/// 改了等于让已安装的机器全部失效。
///
/// {9C4A7E52-3B7D-4E31-9A4C-6D2F8B1E5A70}
extern const CLSID kThumbnailProviderClsid;

/// 等待 helper 的最长时间（毫秒）。
///
/// 实测（本机，32 个真实样本）：单包 55–630 ms，其中 343 MB 的包最慢。
/// 1.5 s 是「正常包必定跑完、异常包不拖住 Explorer」的折中。
/// **不能设成无限**：Explorer 的缩略图请求是同步队列，一个卡住的请求会
/// 拖慢整个目录的显示。
constexpr DWORD kHelperTimeoutMs = 1500;

/// 一次缩略图请求的上下文（由 COM 对象持有）。
class ThumbnailProvider : public IThumbnailProvider,
                          public IInitializeWithItem,
                          public IInitializeWithStream {
 public:
  ThumbnailProvider();

  // IUnknown
  IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
  IFACEMETHODIMP_(ULONG) AddRef() override;
  IFACEMETHODIMP_(ULONG) Release() override;

  // IInitializeWithItem
  IFACEMETHODIMP Initialize(IShellItem* shell_item, DWORD mode) override;

  // IInitializeWithStream
  IFACEMETHODIMP Initialize(IStream* stream, DWORD mode) override;

  // IThumbnailProvider
  IFACEMETHODIMP GetThumbnail(UINT cx, HBITMAP* phbmp,
                              WTS_ALPHATYPE* pdwAlpha) override;

 private:
  ~ThumbnailProvider();

  /// 已确定的、可交给 helper 的文件路径（宽字符）。
  std::wstring source_path_;

  /// `IInitializeWithStream` 落盘出来的临时文件；空表示没有。
  ///
  /// 析构时删除。**只在流式初始化时非空** —— 走 IShellItem 时不需要落盘。
  std::wstring temporary_file_;

  /// 从流写出的临时文件是否已创建（用于安全删除）。
  bool owns_temporary_file_ = false;

  LONG ref_count_ = 1;
};

}  // namespace appinfotool

#endif  // THUMBNAIL_THUMBNAIL_PROVIDER_H_
