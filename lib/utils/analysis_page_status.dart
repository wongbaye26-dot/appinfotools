/// 分析页当前应该呈现的页面级状态。
///
/// 页面级状态与「详情里某一项能不能读到」是两件事：
/// - 没有打开文件时是 [empty]，不是「解析失败」；
/// - 正在解析且还没有任何结构化结果时是 [loading]；
/// - 解析失败且**没有可用结果**时是 [failure]；
/// - 已有结果但清单等部分没解析出来时是 [partial]；
/// - 其余已拿到结果的情况是 [success]。
///
/// 之所以单独抽成纯函数：页面里 `build` 的分支很多，靠 widget 测试只能覆盖
/// 其中几条；这个函数可以逐条单测，避免「失败态仍然是详情页」这种回归。
enum AnalysisPageStatus {
  /// 还没有选择任何文件。
  empty,

  /// 已选择文件，正在解析，且尚无结构化结果。
  loading,

  /// 已有结构化结果，但解析过程中存在可说明的缺口。
  partial,

  /// 解析失败，且没有可供展示的完整结果。
  failure,

  /// 已有完整可展示结果。
  success,
}

/// 计算分析页状态。
///
/// 判定顺序很重要：
/// 1. 已经有结果时，后续错误不能把结果页替换成错误页（结果仍可看，只是标成
///    [partial] 或 [success]）；
/// 2. 没有结果时才允许 [failure]；
/// 3. 文件已选、正在解析但尚未出结果时是 [loading]；
/// 4. 解析结束但仍无结果（取消/静默失败）也归为 [failure]，让用户有重试入口；
/// 5. 没有选中文件时才是 [empty]。
AnalysisPageStatus resolveAnalysisPageStatus({
  required String? filePath,
  required bool isParsing,
  required bool hasParsedResult,
  required bool parsePartial,
  required bool hasFailure,
}) {
  if (hasParsedResult) {
    return parsePartial
        ? AnalysisPageStatus.partial
        : AnalysisPageStatus.success;
  }
  if (filePath == null || filePath.isEmpty) {
    return AnalysisPageStatus.empty;
  }
  if (isParsing) {
    return AnalysisPageStatus.loading;
  }
  if (hasFailure) {
    return AnalysisPageStatus.failure;
  }
  // 文件已选、解析也结束了，却什么结果都没有：这不是空白页，而是没有完成。
  return AnalysisPageStatus.failure;
}
