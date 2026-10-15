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
  ///
  /// 它同时充当这张表的**稳定 id**：说明与符号是一一对应的，符号本身就是
  /// 这条记录的身份。i18n 的键就是它（`security.native_symbols.<symbol>` 的
  /// 语义由 [descriptionCode] 承载，见下）。
  final String symbol;

  final SecurityCategory category;

  /// 面向用户的说明的**稳定 id**。
  ///
  /// **按「能力类别」收敛，不是每个符号一条**：6 个 `exec*` 都是「替换进程映像
  /// 执行程序」，2 个 `send*` 都是「发送数据」—— 逐个写会把同一句话抄十几遍，
  /// 而且改一处措辞就会漏掉另外几处。
  ///
  /// 呈现层按它取本地化文案（`AnalysisReport.nativeSymbolText`），
  /// 认不出来就回退到 [description]。
  final String descriptionCode;

  /// 面向用户的说明（**英文回退**）。
  ///
  /// 引擎层不依赖 slang，产不出本地化文案 —— 这里放英文，与
  /// `SecurityFinding.finding` 的处理方式一致。
  final String description;

  const NativeSymbolMarker(
      this.symbol, this.category, this.descriptionCode, this.description);
}

/// 全部原生符号标记。
///
/// 选取原则：**只收「这个符号存在就意味着某项具体能力」的条目**。
/// 刻意不收 `__android_log_print`、`memcpy`、`fopen` 这类几乎每个原生库都会
/// 导入的符号 —— 它们命中率太高，只会把报告变成噪音。
const List<NativeSymbolMarker> nativeSymbolMarkers = [
  // ---- 命令执行 ----
  NativeSymbolMarker('system', SecurityCategory.backgroundTask, 'shell',
      'run a shell command'),
  NativeSymbolMarker('popen', SecurityCategory.backgroundTask, 'shell_popen',
      'run a shell command and read its output'),
  NativeSymbolMarker('execl', SecurityCategory.backgroundTask, 'exec_image',
      'replace the process image and execute a program'),
  NativeSymbolMarker('execlp', SecurityCategory.backgroundTask, 'exec_image',
      'replace the process image and execute a program'),
  NativeSymbolMarker('execle', SecurityCategory.backgroundTask, 'exec_image',
      'replace the process image and execute a program'),
  NativeSymbolMarker('execv', SecurityCategory.backgroundTask, 'exec_image',
      'replace the process image and execute a program'),
  NativeSymbolMarker('execvp', SecurityCategory.backgroundTask, 'exec_image',
      'replace the process image and execute a program'),
  NativeSymbolMarker('execvpe', SecurityCategory.backgroundTask, 'exec_image',
      'replace the process image and execute a program'),
  // ---- 进程派生 ----
  NativeSymbolMarker(
      'fork', SecurityCategory.backgroundTask, 'fork', 'spawn a new process'),
  NativeSymbolMarker(
      'vfork', SecurityCategory.backgroundTask, 'fork', 'spawn a new process'),
  NativeSymbolMarker('posix_spawn', SecurityCategory.backgroundTask, 'fork',
      'spawn a new process'),
  // ---- 运行时动态加载 ----
  NativeSymbolMarker('dlopen', SecurityCategory.backgroundTask, 'dlopen',
      'load a dynamic library at runtime'),
  NativeSymbolMarker('android_dlopen_ext', SecurityCategory.backgroundTask,
      'dlopen', 'load a dynamic library at runtime'),
  NativeSymbolMarker('dlsym', SecurityCategory.backgroundTask, 'dlsym',
      'resolve a symbol at runtime'),
  NativeSymbolMarker('dladdr', SecurityCategory.backgroundTask, 'dladdr',
      'look up the source of a symbol at runtime'),
  // ---- 反调试 / 进程注入 ----
  NativeSymbolMarker('ptrace', SecurityCategory.other, 'ptrace',
      'trace a process — a common anti-debugging or injection technique'),
  // ---- 原生网络 ----
  NativeSymbolMarker(
      'socket', SecurityCategory.network, 'socket', 'create a socket'),
  NativeSymbolMarker(
      'connect', SecurityCategory.network, 'connect', 'establish a connection'),
  NativeSymbolMarker('send', SecurityCategory.network, 'send', 'send data'),
  NativeSymbolMarker('sendto', SecurityCategory.network, 'send', 'send data'),
  NativeSymbolMarker('recv', SecurityCategory.network, 'recv', 'receive data'),
  NativeSymbolMarker(
      'recvfrom', SecurityCategory.network, 'recv', 'receive data'),
  NativeSymbolMarker('getaddrinfo', SecurityCategory.network, 'resolve',
      'resolve a domain name'),
  NativeSymbolMarker('gethostbyname', SecurityCategory.network, 'resolve',
      'resolve a domain name'),
  // ---- 设备 / 系统信息 ----
  NativeSymbolMarker('__system_property_get', SecurityCategory.deviceData,
      'system_property', 'read an Android system property'),
];

/// 按符号名查标记；没有时返回 `null`。
///
/// 用 Map 而不是线性查找：一个库可以有几万个符号，线性查找会让扫描变成
/// O(符号数 × 标记数)。
final Map<String, NativeSymbolMarker> nativeSymbolMarkerIndex = {
  for (final marker in nativeSymbolMarkers) marker.symbol: marker,
};
