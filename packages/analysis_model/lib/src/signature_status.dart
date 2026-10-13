/// 由受信任工具给出的签名验证结论。
///
/// 平台无关：Android 走 `apksigner`、iOS 走 `codesign`，机制不同，但对用户的
/// 结论只有四种。
///
/// 这四个状态**必须分开**：
/// - 把「工具不可用」显示成「签名无效」，会把没装工具的机器误报成恶意应用；
/// - 把「结果未知」显示成「验证通过」则是更危险的方向 —— 会让用户以为已经
///   验证过。
///
/// 因此只要没有拿到明确结论，就绝不显示「签名有效」。
enum SignatureStatus {
  /// 工具明确验证通过。
  verified,

  /// 工具明确报告验证失败。
  verificationFailed,

  /// 找不到或无法执行验证工具 —— **无法得出结论**，不代表签名有问题。
  ///
  /// 在 iOS 上是常态：没有 macOS 的 `codesign` 时，静态材料只能说明「有什么
  /// 材料」，不能说明「是否有效」。
  toolUnavailable,

  /// 执行了工具，但既非通过也非明确失败（超时、非预期退出码、输出异常）。
  unknown;

  /// 是否拿到了明确结论。
  bool get hasConclusiveResult =>
      this == SignatureStatus.verified ||
      this == SignatureStatus.verificationFailed;
}
