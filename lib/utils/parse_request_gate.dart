/// 「同一个文件正在解析」的去重闸门。
///
/// ## 为什么需要它
///
/// 双击一个包启动应用时，路径会从**两条入口**同时到达分析页：
/// 命令行参数（`main.dart` 的 `arguments`）与文件关联事件
/// （`_setupFileAssociationHandler` 的 `fileOpened`）。两者都会调
/// `loadApkInfo`，于是同一个 75 MB 的包被**并行解析两遍**，两份都跑到完成，
/// 前一份的结果随后被代际号丢弃 —— 纯浪费一半 CPU 与 IO。
///
/// Windows 日志实测（v2.10.2，同一文件）：
/// `16:34:50.976 start` / `16:34:51.171 start` → `19728ms` + `19842ms`。
///
/// ## 为什么 finish 要带路径
///
/// 换文件时新请求会立刻把闸门指向新路径，而**旧请求的 `finish` 随后才到**
/// （它的 await 刚返回）。不带路径地清空会把新请求的占用一起清掉，之后
/// 同一个文件再被打开就会重复解析 —— 这正是这类闸门最典型的错法。
class ParseRequestGate {
  String? _inFlight;

  /// 当前占用闸门的文件路径；`null` 表示没有解析在跑。
  String? get inFlight => _inFlight;

  /// [path] 是否已经在解析中（调用方应直接返回，复用那次的结果）。
  bool isDuplicate(String path) => _inFlight == path;

  /// 标记 [path] 开始解析。
  void begin(String path) => _inFlight = path;

  /// [path] 的解析结束。**只清自己那一条**。
  void finish(String path) {
    if (_inFlight == path) _inFlight = null;
  }
}
