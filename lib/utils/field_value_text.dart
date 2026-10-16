import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';

/// 把一个 [FieldValue] 渲染成人能读的文本 —— **全项目只有这一份实现**。
///
/// ## 为什么要收成一份
///
/// 此前「无值怎么显示」在**四处**各写了一遍：详情页的 Android 卡片
/// （`info_page.dart` 的 `_androidField`）、详情页的 iOS 卡片、Markdown 报告
/// 的「说明」列（`analysis_report.dart` 的 `_row`）、差异页与差异报告
/// （`diff_labels.dart`）。四份实现迟早漂移 —— 而这里漂移的代价是
/// 「同一个字段在界面上说 A、在报告里说 B」，正是本项目一直在挡的那类不一致。
///
/// ## 口径（沿用详情页原来那一套，没有新造）
///
/// - 有值 → 值本身（由调用方给格式化函数，例如 SDK 版本要转成 `34 (Android 14)`）；
/// - [FieldStatus.absent] → `-`（**文件里确实没有**）；
/// - 其余 → `[状态名] 原因`，明确说「我们没读到」。
///
/// 状态名保留机器拼写（`unsupported` / `failed`…）：它是稳定标识，也是详情页
/// 一直在用的写法，界面与报告必须一致。
class FieldValueText {
  const FieldValueText._();

  /// 完整文案。有值时走 [format]（不给就直接 `toString`）。
  static String describe(
    FieldValue<Object?> value,
    Translations t, {
    String Function(Object value)? format,
  }) {
    if (value.hasValue) {
      final raw = value.value as Object;
      return format == null ? '$raw' : format(raw);
    }
    if (value.status == FieldStatus.absent) return '-';
    final reason = diagnostic(value, t);
    return reason == null
        ? '[${value.status.name}]'
        : '[${value.status.name}] $reason';
  }

  /// 只渲染「原因」那一截（报告表格的「说明」列只要这一截）。
  ///
  /// 认得出 [FieldValue.diagnosticCode] 就取本地化文案；认不出（或没有 code）
  /// 退回 [FieldValue.diagnostic]（英文回退）。两者都没有时返回 `null` ——
  /// **不编一个空串出来**，调用方据此决定要不要写这一格。
  static String? diagnostic(FieldValue<Object?> value, Translations t) {
    final code = value.diagnosticCode;
    if (code != null) {
      final text = _byCode(code, value.diagnosticArgs, t);
      if (text != null) return text;
    }
    return value.diagnostic;
  }

  /// code → 本地化文案。认不出的 code 返回 `null`，由调用方退回英文原文。
  ///
  /// 实参里的 `{source}` / `{field}` / `{key}` / `{actual}` 都是**机器标识**
  /// （来源枚举名、plist 键名、plist 类型名），刻意原样嵌入 —— 它们同时出现在
  /// 界面的别处（字段名、来源名），翻译成散文反而对不上。本地化的是**句子的
  /// 框架**。
  static String? _byCode(
    String code,
    Map<String, Object> args,
    Translations t,
  ) {
    final d = t.field_diagnostic;
    String arg(String key) => '${args[key] ?? ''}';
    return switch (code) {
      'hashing.disabled' => d.hashing_disabled,
      'signature.disabled' => d.signature_disabled,
      'source.not_reported' =>
        d.source_not_reported(source: arg('source'), field: arg('field')),
      'plist.expected_string' =>
        d.plist_expected_string(key: arg('key'), actual: arg('actual')),
      'plist.expected_string_or_number' => d.plist_expected_string_or_number(
          key: arg('key'),
          actual: arg('actual'),
        ),
      'plist.expected_string_array' => d.plist_expected_string_array(
          key: arg('key'),
          actual: arg('actual'),
        ),
      'plist.array_item_not_string' => d.plist_array_item_not_string(
          key: arg('key'),
          actual: arg('actual'),
        ),
      'plist.expected_int_array' => d.plist_expected_int_array(
          key: arg('key'),
          actual: arg('actual'),
        ),
      'plist.array_item_not_int' => d.plist_array_item_not_int(
          key: arg('key'),
          actual: arg('actual'),
        ),
      'plist.expected_date' =>
        d.plist_expected_date(key: arg('key'), actual: arg('actual')),
      'plist.expected_array' =>
        d.plist_expected_array(key: arg('key'), actual: arg('actual')),
      'plist.expected_boolean' => d.plist_expected_boolean(key: arg('key')),
      'privacy_manifest.too_large' => d.privacy_manifest_too_large,
      'plist.parse_failed' =>
        d.plist_parse_failed(path: arg('path'), message: arg('message')),
      'plist.root_not_dictionary' => d.plist_root_not_dictionary(
          path: arg('path'),
          actual: arg('actual'),
        ),
      _ => null,
    };
  }
}
