/// 一个可被用户取消的解析任务。
///
/// 三种任务的取消机制完全不同：
/// - `ApkParseTask` / `IpaParseTask` 用 `Isolate.immediate` 终止 worker；
/// - `Aapt2Task` 终止子进程；
/// - iOS 的解包 + `codesign` 步骤用协作式标志（它要写临时目录，不能被强杀）。
///
/// UI 不该关心这些差别 —— 它只需要知道「现在有没有可取消的东西」。这个接口
/// 就是那层抽象：**只有真正能取消的任务才会实现它**，因此 UI 显示取消按钮的
/// 条件与「取消真的有效」永远是同一件事，不会出现按不动的按钮。
abstract interface class CancellableParseTask {
  /// 请求取消。
  ///
  /// 实现必须**幂等**：重复调用不得抛异常，也不得产生第二份取消通知。
  /// 已结束的任务上调用应当是空操作。
  void cancel();

  /// 供 UI 判断是否还值得显示取消入口。
  bool get isFinished;
}
