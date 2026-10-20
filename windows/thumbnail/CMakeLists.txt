# Windows Shell 缩略图处理器的独立 DLL。
#
# 与 runner.exe 分开是必须的：缩略图处理器由 explorer.exe **in-proc** 加载，
# 而 runner.exe 是 GUI 程序（没有 DllGetClassObject），Explorer 不会加载它。
#
# 构建产物通过 install() 落到 runner.exe 所在目录（`CMAKE_INSTALL_PREFIX`），
# 因此本文件必须被 `add_subdirectory` 在**顶层设置完 CMAKE_INSTALL_PREFIX
# 之后**调用 —— 见 windows/CMakeLists.txt 里的说明。

# 静态链接 CRT（/MT），让 DLL 与自检都不依赖 VC++ 运行库。
#
# ## 为什么这对缩略图处理器是**必须**的
#
# 这个 DLL 由 explorer.exe 加载。如果它是 /MD（CMake 在 Windows 上的默认），
# 就需要目标机器装 VC++ 2015-2022 Redistributable —— 很多普通用户的机器上
# **没有**。缺运行库时 LoadLibrary 直接失败，Explorer 只是静默回退到文件图标，
# 用户和我们都不会看到任何错误。
#
# 自检程序同理：/MD 的 exe 在缺运行库的机器上「双击就消失」。
#
# /MT 让两者自带 CRT，拷到任何 Windows 上都能跑。
# 跨边界只传 COM 接口指针（不传 C++ 对象），因此不存在堆不匹配问题。
#
# CMP0091 必须设为 NEW，`MSVC_RUNTIME_LIBRARY` 属性才会生效；
# 否则 CMake 继续按 `CMAKE_CXX_FLAGS` 里的 /MD 走，设了也没用。
if(POLICY CMP0091)
  cmake_policy(SET CMP0091 NEW)
endif()

add_library(appinfotool_thumbnail SHARED
  "thumbnail_provider.cpp"
  "thumbnail_provider.h"
  # 导出表。**必须是 .def 而不是 __declspec(dllexport)**：
  # combaseapi.h 已把这两个函数声明成 WINOLEAPI，再叠 dllexport 会报
  # C2375「redefinition; different linkage」。详见 .def 文件顶部注释。
  "appinfotool_thumbnail.def"
)

# 与 runner 一致的编译设置（C++17、/W4 /WX）。
#
# 刻意**不**复用 `apply_standard_settings`：那个函数会加
# `_HAS_EXCEPTIONS=0`，而本文件用 try/catch 兜住 COM 边界上的异常 ——
# 关掉异常会让 `catch (...)` 直接编译失败。
#
# `UNICODE` / `_UNICODE` 已由顶层 `add_definitions` 全局加上，这里不重复；
# 重复定义同一个值虽然通常无害，但会让「到底谁在定义」变模糊。
target_compile_features(appinfotool_thumbnail PUBLIC cxx_std_17)
target_compile_options(appinfotool_thumbnail PRIVATE /W4 /WX /EHsc)
set_target_properties(appinfotool_thumbnail PROPERTIES
  MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
)
# `NOMINMAX`：不让 windows.h 定义 min/max 宏，否则 `<algorithm>` /
# `<limits>` 里的同名模板会被宏替换，报一堆看不懂的语法错误。
target_compile_definitions(appinfotool_thumbnail PRIVATE NOMINMAX)

# `ole32`         : CoCreateInstance / CoTaskMemFree
# `windowscodecs` : WIC（PNG / JPEG / GIF / 装了扩展时的 WebP）
# `shlwapi`       : 路径辅助
# `shell32`       : IShellItem
# `uuid`          : `IID_IThumbnailProvider` / `IID_IInitializeWithItem` /
#                   `IID_IInitializeWithStream` 这三个 **IID 是外部符号**，
#                   不是 inline 常量 —— 不链接 uuid.lib 就是 LNK2001 未解析。
#                   CMake 在 Windows 上默认会带 uuid.lib，但那是
#                   `CMAKE_CXX_STANDARD_LIBRARIES` 的行为，被工具链配置覆盖过
#                   就没了；显式写出来不花钱。
target_link_libraries(appinfotool_thumbnail PRIVATE
  "ole32.lib"
  "windowscodecs.lib"
  "shlwapi.lib"
  "shell32.lib"
  "uuid.lib"
)

set_target_properties(appinfotool_thumbnail PROPERTIES
  # 产物名固定为 appinfotool_thumbnail.dll —— 注册表里的 InprocServer32
  # 与 `ThumbnailDllPath()` 都按这个名字找。
  OUTPUT_NAME "appinfotool_thumbnail"
  PREFIX ""
)

# 装到 runner.exe 所在的目录（`CMAKE_INSTALL_PREFIX` 已被顶层改成那里）。
# Windows 上 DLL 属于 RUNTIME 类型，不是 LIBRARY。
install(TARGETS appinfotool_thumbnail
  RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime
)

# ---------------------------------------------------------------------------
# 自动化自检程序（**不进安装包**，只在构建目录里）
#
# 它 LoadLibrary 我们的 DLL 并直接调 GetThumbnail，绕过注册表 ——
# 这样能把「DLL 出不出得来图」与「注册有没有生效」分开验。
# CI 拿它当门禁；手工排查时也可以直接跑。
#
# 没有 install(...) 是**有意的**：这个 exe 不该出现在用户机器上。
# ---------------------------------------------------------------------------
# **不加 WIN32**：那是 Windows 子系统，入口是 WinMain，而本程序用 wmain
# 且要向 stdout 打印结果（CI 靠这些行判断成败）。
add_executable(appinfotool_thumbnail_selftest
  "selftest.cpp"
)
target_compile_features(appinfotool_thumbnail_selftest PUBLIC cxx_std_17)
target_compile_options(appinfotool_thumbnail_selftest PRIVATE /W4 /WX /EHsc)
# 静态 CRT：诊断工具不该要求目标机器先装 VC++ 运行库。
# 「双击就消失」最常见的原因就是这个 —— 进程根本没起来。
set_target_properties(appinfotool_thumbnail_selftest PROPERTIES
  MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
)
target_compile_definitions(appinfotool_thumbnail_selftest PRIVATE
  UNICODE
  _UNICODE
  NOMINMAX
)
target_link_libraries(appinfotool_thumbnail_selftest PRIVATE
  "ole32.lib"
  "shell32.lib"
  "shlwapi.lib"
  "uuid.lib"
)
# **输出到独立目录**，不和 DLL 混在 `runner/Release` 里：
#
# 那里是「应用本体」的产物目录，安装包整目录打包。自检 exe 混进去会让
# 「应用目录里哪些是运行时需要的」变得不清楚。
#
# 它**确实会进安装包**，但由安装脚本单独、显式地放进去（见
# `windows/installer/appinfotool.iss` 的 `[Files]`），落点是 `{app}` 而不是
# 子目录 —— 自检按 exe 所在目录找 DLL，换目录就加载不到。
#
# 为什么要进安装包：「图标不出来」这类问题在用户机器上没有别的自证手段，
# 自检能把「DLL 层坏了」与「注册/缓存没生效」分开。
#
# 三个配置分别指定，因为多配置生成器（VS）会忽略不带后缀的
# `RUNTIME_OUTPUT_DIRECTORY` —— 只写那一个时 Release 产物仍会落在
# 默认的 `thumbnail/Release/`，CI 按固定路径找不到。
#
# 代价：自检按 exe 所在目录找 DLL 与 helper，所以 CI 跑之前要把这两个
# 文件拷进 selftest 目录（见 workflow 里的步骤）。
set(_selftest_dir "${CMAKE_BINARY_DIR}/selftest")
set_target_properties(appinfotool_thumbnail_selftest PROPERTIES
  OUTPUT_NAME "appinfotool_thumbnail_selftest"
  RUNTIME_OUTPUT_DIRECTORY "${_selftest_dir}"
  RUNTIME_OUTPUT_DIRECTORY_DEBUG "${_selftest_dir}"
  RUNTIME_OUTPUT_DIRECTORY_RELEASE "${_selftest_dir}"
  RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${_selftest_dir}"
  RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${_selftest_dir}"
)
add_dependencies(appinfotool_thumbnail_selftest appinfotool_thumbnail)
