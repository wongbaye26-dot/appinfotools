import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';

/// 解析诊断的**唯一**呈现实现。
///
/// ## 为什么需要它
///
/// `AnalysisDiagnostic.message` 是**硬编码的英文句子**，而数字与路径是插值
/// 出来的 —— 单凭 message 没法翻译。因此模型上配了 `messageArgs`（占位符名 →
/// 实参），这里按 `code` 查本地化模板并填上。
///
/// ## 三条降级路径，保证永远不出半吊子状态
///
/// 1. `code` 没有本地化模板 → 显示 `message` 原文（还没迁移的 code）；
/// 2. 模板里有占位符但**没给对应实参** → 也退回 `message`，绝不在界面上
///    留下一个裸的 `{path}`；
/// 3. 两者都没有 → 调用方决定要不要写这一格。
///
/// `AnalysisReport` 的 JSON 出口**刻意不经过这里**：它保留原始 `code` /
/// `message` 给程序读，与「界面显示本地化名字」不矛盾（同 `coverage` 的
/// 「JSON 保留机器 id」）。
class AnalysisDiagnosticText {
  const AnalysisDiagnosticText._();

  /// 本地化后的正文；无法本地化时返回 `null`（调用方退回 [AnalysisDiagnostic.message]）。
  static String? message(AnalysisDiagnostic d, Translations t) {
    final key = d.code.replaceAll('.', '_');
    final rendered = _byKey(key, d.messageArgs, t);
    if (rendered == null) return null;
    // 模板里的占位符没填全 → 视为「这次说不清」，不把 `{path}` 摆给用户。
    if (RegExp(r'\{[a-z_][a-z0-9_]*\}').hasMatch(rendered)) return null;
    return rendered;
  }

  /// 一条诊断的正文：优先本地化，否则英文回退。
  static String text(AnalysisDiagnostic d, Translations t) =>
      message(d, t) ?? d.message;

  /// 详情页与 Markdown 共用的那一行：`[severity] code: 正文`。
  ///
  /// **机器 id 仍然显示**：解析诊断的读者常常要拿它去检索、报缺陷，
  /// 藏着反而更难查。这与覆盖维度「UI 必须显示本地化名字」不同 ——
  /// 那里 id 是实现细节，这里 id 是排查入口。
  static String line(AnalysisDiagnostic d, Translations t) =>
      '[${d.severity.name}] ${d.code}: ${text(d, t)}';

  static String? _byKey(
    String key,
    Map<String, Object> args,
    Translations t,
  ) {
    final d = t.analysis_diagnostic;
    // **没给的实参原样留成 `{name}`**，不填空串。
    //
    // 原先这里写的是 `args[name] ?? ''` —— 空格串不会触发下面那条
    // 「不许留裸占位符」的检查，于是「模板有占位符但没给实参」会被静默渲染成
    // 「 里没有 Info.plist」。**守卫被自己的实现绕过去了**，比没有守卫更糟。
    String arg(String name) =>
        args.containsKey(name) ? '${args[name]}' : '{$name}';
    return switch (key) {
      'android_manifest_unparsed' => d.android_manifest_unparsed(
          failure: arg('failure'),
        ),
      'android_resource_reference_cycle' => d.android_resource_reference_cycle(
          cycle: arg('cycle'),
        ),
      'android_resource_reference_cycle_truncated' =>
        d.android_resource_reference_cycle_truncated(count: arg('count')),
      'android_split_sampling_truncated' => d.android_split_sampling_truncated(
          checked: arg('checked'),
          total: arg('total'),
        ),
      'ios_container_multiple_main_apps' => d.ios_container_multiple_main_apps(
          count: arg('count'),
          paths: arg('paths'),
        ),
      'ios_container_no_main_app' => d.ios_container_no_main_app,
      'ios_container_no_payload' => d.ios_container_no_payload,
      'ios_info_plist_missing' => d.ios_info_plist_missing(path: arg('path')),
      'ios_info_plist_vanished' => d.ios_info_plist_vanished(path: arg('path')),
      'ios_info_plist_too_large' => d.ios_info_plist_too_large(
          path: arg('path'),
          size: arg('size'),
          limit: arg('limit'),
        ),
      'ios_info_plist_size_lie' => d.ios_info_plist_size_lie(
          path: arg('path'),
          size: arg('size'),
          decompressed: arg('decompressed'),
        ),
      'ios_info_plist_unparsable' => d.ios_info_plist_unparsable(
          path: arg('path'),
          message: arg('message'),
        ),
      'ios_info_plist_not_a_dict' => d.ios_info_plist_not_a_dict(
          path: arg('path'),
          actual: arg('actual'),
        ),
      'ios_info_plist_parsed' => d.ios_info_plist_parsed(
          path: arg('path'),
          keys: arg('keys'),
        ),
      _ => null,
    };
  }
}
