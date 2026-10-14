import 'security_finding.dart';

/// 一个待匹配的原生符号标记。
///
/// **按精确符号名匹配，不做子串匹配** —— 这是符号证据相对字符串扫描的核心
/// 优势：`connect` 作为符号名是一个确定的标识符，而字符串里出现 `connect`
/// 可能只是某个 URL 或日志文案的一部分。
///
/// 只匹配**导入**（`st_shndx == 0`）的符号：导入意味着这个库从 libc 或别的
/// 库里拿到了这项能力。库自己**定义**一个叫 `connect` 的函数不会被命中 ——
/// 那多半是同名封装，不是 libc 调用。
class NativeSymbolMarker {
  /// 精确的符号名（已去掉 `@版本` 后缀）。
  final String symbol;

  final SecurityCategory category;

  /// 面向用户的说明。
  final String description;

  const NativeSymbolMarker(this.symbol, this.category, this.description);
}

/// 全部原生符号标记。
///
/// 选取原则：**只收「这个符号存在就意味着某项具体能力」的条目**。
/// 刻意不收 `__android_log_print`、`memcpy`、`fopen` 这类几乎每个原生库都会
/// 导入的符号 —— 它们命中率太高，只会把报告变成噪音。
const List<NativeSymbolMarker> nativeSymbolMarkers = [
  // ---- 命令执行 ----
  NativeSymbolMarker(
      'system', SecurityCategory.backgroundTask, '执行 shell 命令（system）'),
  NativeSymbolMarker(
      'popen', SecurityCategory.backgroundTask, '执行 shell 命令并读输出（popen）'),
  NativeSymbolMarker(
      'execl', SecurityCategory.backgroundTask, '替换进程映像执行程序（execl）'),
  NativeSymbolMarker(
      'execlp', SecurityCategory.backgroundTask, '替换进程映像执行程序（execlp）'),
  NativeSymbolMarker(
      'execle', SecurityCategory.backgroundTask, '替换进程映像执行程序（execle）'),
  NativeSymbolMarker(
      'execv', SecurityCategory.backgroundTask, '替换进程映像执行程序（execv）'),
  NativeSymbolMarker(
      'execvp', SecurityCategory.backgroundTask, '替换进程映像执行程序（execvp）'),
  NativeSymbolMarker(
      'execvpe', SecurityCategory.backgroundTask, '替换进程映像执行程序（execvpe）'),
  // ---- 进程派生 ----
  NativeSymbolMarker('fork', SecurityCategory.backgroundTask, '派生新进程（fork）'),
  NativeSymbolMarker('vfork', SecurityCategory.backgroundTask, '派生新进程（vfork）'),
  NativeSymbolMarker(
      'posix_spawn', SecurityCategory.backgroundTask, '派生新进程（posix_spawn）'),
  // ---- 运行时动态加载 ----
  NativeSymbolMarker(
      'dlopen', SecurityCategory.backgroundTask, '运行时加载动态库（dlopen）'),
  NativeSymbolMarker('android_dlopen_ext', SecurityCategory.backgroundTask,
      '运行时加载动态库（android_dlopen_ext）'),
  NativeSymbolMarker(
      'dlsym', SecurityCategory.backgroundTask, '运行时解析符号（dlsym）'),
  NativeSymbolMarker(
      'dladdr', SecurityCategory.backgroundTask, '运行时查询符号来源（dladdr）'),
  // ---- 反调试 / 进程注入 ----
  NativeSymbolMarker(
      'ptrace', SecurityCategory.other, '进程跟踪（ptrace）—— 反调试或注入的常见手段'),
  // ---- 原生网络 ----
  NativeSymbolMarker('socket', SecurityCategory.network, '创建套接字（socket）'),
  NativeSymbolMarker('connect', SecurityCategory.network, '建立连接（connect）'),
  NativeSymbolMarker('send', SecurityCategory.network, '发送数据（send）'),
  NativeSymbolMarker('sendto', SecurityCategory.network, '发送数据（sendto）'),
  NativeSymbolMarker('recv', SecurityCategory.network, '接收数据（recv）'),
  NativeSymbolMarker('recvfrom', SecurityCategory.network, '接收数据（recvfrom）'),
  NativeSymbolMarker(
      'getaddrinfo', SecurityCategory.network, '域名解析（getaddrinfo）'),
  NativeSymbolMarker(
      'gethostbyname', SecurityCategory.network, '域名解析（gethostbyname）'),
  // ---- 设备 / 系统信息 ----
  NativeSymbolMarker('__system_property_get', SecurityCategory.deviceData,
      '读取 Android 系统属性（__system_property_get）'),
];

/// 按符号名查标记；没有时返回 `null`。
///
/// 用 Map 而不是线性查找：一个库可以有几万个符号，线性查找会让扫描变成
/// O(符号数 × 标记数)。
final Map<String, NativeSymbolMarker> nativeSymbolMarkerIndex = {
  for (final marker in nativeSymbolMarkers) marker.symbol: marker,
};
