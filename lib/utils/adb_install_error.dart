/// 从 adb 安装输出里提取稳定的失败码。
///
/// adb 的原始输出常常混着设备端堆栈、`Performing Streamed Install` 等噪音；
/// 直接把整段 stderr 塞给用户，安装失败页会变成一坨不可读的日志。这里只取
/// `INSTALL_FAILED_*` / `INSTALL_PARSE_FAILED_*` 的稳定前缀，界面再按码本地化。
///
/// 返回 `null` 表示输出里没有已知失败码（可能是 adb 自身错误、超时等）。
String? adbInstallFailureCode(String output) {
  final match = RegExp(
    r'INSTALL_(?:FAILED|PARSE_FAILED)_[A-Z0-9_]+',
  ).firstMatch(output);
  return match?.group(0);
}
