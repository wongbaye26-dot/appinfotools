import 'package:apk_parser/apk_parser.dart' show HardeningSignal;

/// 加固线索的置信度。
///
/// 规范 4.2 要求不得仅凭单一特征判断加固方案，因此每条线索都带置信度：
/// 结论应由**多条线索共同**支撑，而不是靠某一条。
enum HintConfidence {
  /// 单独出现时**不足以**说明问题。
  ///
  /// 例如「存在多个 DEX」—— 未加固的现代应用因方法数上限也会分片。
  weak,

  /// 特征本身不正常，通常指向加固。
  ///
  /// 例如「DEX 文件头不是标准魔数」—— 正常构建流程不会产出这种文件。
  strong,
}

/// 一条可解释的加固线索。
///
/// **刻意不包含厂商判定。** 规范 4.2 明确要求「不要仅凭壳文件名、某个 SO
/// 或单一目录结构判断具体加固厂商」。这里只陈述观察到的结构事实、具体证据
/// 与置信度，把判断留给使用者。
///
/// 同理，[HardeningSignal] 里也没有任何以厂商命名的枚举值 —— 那等于把
/// 厂商判定藏进枚举名里。
class HardeningHint {
  final HardeningSignal signal;

  /// 具体证据，例如 `lib/arm64-v8a/libjiagu.so`、`classes.dex 头部为 0x9d 0x01`。
  ///
  /// 保留证据是「可解释」的关键：用户看到的不该只是一句「可能被加固」，
  /// 而是「因为看到了什么」。
  final String evidence;

  final HintConfidence confidence;

  const HardeningHint({
    required this.signal,
    required this.evidence,
    required this.confidence,
  });

  @override
  String toString() => 'HardeningHint(${signal.name}, ${confidence.name}): '
      '$evidence';
}
