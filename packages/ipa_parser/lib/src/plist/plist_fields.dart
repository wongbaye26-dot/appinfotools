import 'package:analysis_model/analysis_model.dart';

import 'plist_value.dart';

/// plist 字段读取的共用实现。
///
/// `Info.plist` 与 `embedded.mobileprovision` 里的描述文件 plist 是同一套
/// 取值规则：类型不符记 [FieldStatus.wrongType]，键不存在记
/// [FieldStatus.absent]，两者**都不填默认值**。抽出这一份，是为了避免第二个
/// plist 消费者出现时把规则抄一遍 —— 抄出来的第二份迟早会和第一份不一致。
///
/// 每个方法都要求调用方显式给出 [FieldSource]，这样「值从哪来」始终可追溯。
class PlistFields {
  PlistFields._();

  /// 严格取字符串：类型不是 `string` 就记 [FieldStatus.wrongType]。
  static FieldValue<String> strictString(
    PlistDict root,
    String key, {
    required FieldSource source,
  }) {
    final raw = root.value[key];
    if (raw == null) {
      return FieldValue<String>.absent(source: source);
    }
    if (raw is! PlistString) {
      return FieldValue<String>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected a string',
        source: source,
      );
    }
    return FieldValue<String>.extracted(raw.value, source: source);
  }

  /// 宽松取字符串：整数/浮点也接受。
  ///
  /// **只用于版本号之类的字段。** 它们按文档是字符串，但被写成 `<integer>`
  /// 是真实存在的情况；直接判为类型错误只会让用户看到一个空白值，而那个数字
  /// 本身是准确可用的。
  static FieldValue<String> numberOrString(
    PlistDict root,
    String key, {
    required FieldSource source,
  }) {
    final raw = root.value[key];
    if (raw == null) {
      return FieldValue<String>.absent(source: source);
    }
    final value = raw.asString;
    if (value == null) {
      return FieldValue<String>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected a string or a number',
        source: source,
      );
    }
    return FieldValue<String>.extracted(value, source: source);
  }

  /// 取字符串数组。
  ///
  /// 要求确实是数组且元素都是字符串。**不接受裸标量**：把 `CFBundleIconFile`
  /// 那样的单值键当数组是替文件补结构，而单值键另有其含义。
  static FieldValue<List<String>> stringList(
    PlistDict root,
    String key, {
    required FieldSource source,
  }) {
    final raw = root.value[key];
    if (raw == null) {
      return FieldValue<List<String>>.absent(source: source);
    }
    if (raw is! PlistArray) {
      return FieldValue<List<String>>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected an array of strings',
        source: source,
      );
    }
    final values = <String>[];
    for (final item in raw.value) {
      final value = item.asString;
      if (value == null) {
        return FieldValue<List<String>>.wrongType(
          diagnostic: '$key contains a ${item.typeName}, expected strings',
          source: source,
        );
      }
      values.add(value);
    }
    return FieldValue<List<String>>.extracted(values, source: source);
  }

  /// 取整数数组。
  ///
  /// `UIDeviceFamily` 是典型用例：`[1]` 表示 iPhone，`[1, 2]` 表示
  /// iPhone + iPad。同样**不接受裸标量**。
  static FieldValue<List<int>> intList(
    PlistDict root,
    String key, {
    required FieldSource source,
  }) {
    final raw = root.value[key];
    if (raw == null) {
      return FieldValue<List<int>>.absent(source: source);
    }
    if (raw is! PlistArray) {
      return FieldValue<List<int>>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected an array of integers',
        source: source,
      );
    }
    final values = <int>[];
    for (final item in raw.value) {
      final value = item.asInt;
      if (value == null) {
        return FieldValue<List<int>>.wrongType(
          diagnostic: '$key contains a ${item.typeName}, expected integers',
          source: source,
        );
      }
      values.add(value);
    }
    return FieldValue<List<int>>.extracted(values, source: source);
  }

  /// 严格取日期。
  ///
  /// **只接受 plist 的 `<date>` 类型。** 不把字符串形式的日期也解析掉：
  /// 那需要猜测格式（ISO-8601？`yyyy-MM-dd`？带不带时区？），猜错会得到一个
  /// 看起来正常、实际偏移几小时的日期 —— 描述文件的有效期正是靠这个判断的。
  /// 类型不符时如实记 [FieldStatus.wrongType]，用户去查文件即可。
  static FieldValue<DateTime> date(
    PlistDict root,
    String key, {
    required FieldSource source,
  }) {
    final raw = root.value[key];
    if (raw == null) {
      return FieldValue<DateTime>.absent(source: source);
    }
    if (raw is! PlistDate) {
      return FieldValue<DateTime>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected a date',
        source: source,
      );
    }
    return FieldValue<DateTime>.extracted(
      raw.value.toUtc(),
      source: source,
    );
  }

  /// 取字典，类型不符时返回 `null` 并给出诊断。
  ///
  /// 返回 `(值, 诊断)` 而不是 [FieldValue]：字典本身的内容由调用方按各自的
  /// 语义继续解析，包成 `FieldValue` 只会多一层拆包。
  static (PlistDict?, AnalysisDiagnostic?) dict(
    PlistDict root,
    String key, {
    required FieldSource source,
  }) {
    final raw = root.value[key];
    if (raw == null) return (null, null);
    if (raw is! PlistDict) {
      return (
        null,
        AnalysisDiagnostic.warning(
          'ios.plist.wrong_type',
          '$key is ${raw.typeName}, expected a dictionary',
          source: source,
        ),
      );
    }
    return (raw, null);
  }
}
