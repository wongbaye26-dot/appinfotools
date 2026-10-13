import 'dart:typed_data';

/// 一个 plist 值。
///
/// 用密封类而不是 `Object` + 强制转换：`Info.plist` 的字段类型在真实应用里
/// 经常与文档不符（把 `CFBundleVersion` 写成整数、把数组写成单值），
/// 有类型可匹配才能在读不到时**如实记录原因**，而不是抛异常或猜一个值。
sealed class PlistValue {
  const PlistValue();

  /// 类型名，用于诊断信息。
  String get typeName;

  @override
  String toString() => '$typeName(${_describe()})';

  String _describe() => switch (this) {
        PlistString(:final value) => value,
        PlistInteger(:final value) => '$value',
        PlistReal(:final value) => '$value',
        PlistBoolean(:final value) => '$value',
        PlistDate(:final value) => value.toIso8601String(),
        PlistData(:final value) => '${value.length} bytes',
        PlistArray(:final value) => '${value.length} items',
        PlistDict(:final value) => '${value.length} keys',
      };
}

final class PlistString extends PlistValue {
  final String value;

  const PlistString(this.value);

  @override
  String get typeName => 'string';
}

final class PlistInteger extends PlistValue {
  final int value;

  const PlistInteger(this.value);

  @override
  String get typeName => 'integer';
}

final class PlistReal extends PlistValue {
  final double value;

  const PlistReal(this.value);

  @override
  String get typeName => 'real';
}

final class PlistBoolean extends PlistValue {
  final bool value;

  const PlistBoolean(this.value);

  @override
  String get typeName => 'boolean';
}

final class PlistDate extends PlistValue {
  /// UTC 时间。
  final DateTime value;

  const PlistDate(this.value);

  @override
  String get typeName => 'date';
}

final class PlistData extends PlistValue {
  final Uint8List value;

  const PlistData(this.value);

  @override
  String get typeName => 'data';
}

final class PlistArray extends PlistValue {
  final List<PlistValue> value;

  const PlistArray(this.value);

  @override
  String get typeName => 'array';
}

final class PlistDict extends PlistValue {
  /// 保持插入顺序 —— plist 是有序字典，而 `Info.plist` 的键顺序在排查时有用。
  final Map<String, PlistValue> value;

  const PlistDict(this.value);

  @override
  String get typeName => 'dict';
}

/// 宽松取值。
///
/// 一律返回可空类型而**不抛异常、不给默认值**：`Info.plist` 里的字段缺失或
/// 类型不符是常态，调用方需要知道「读不到」并如实记录，而不是拿到一个
/// 看起来正常的值。
extension PlistValueAccess on PlistValue? {
  PlistDict? get asDict => this is PlistDict ? this as PlistDict : null;

  PlistArray? get asArray => this is PlistArray ? this as PlistArray : null;

  /// 取字符串。
  ///
  /// 整数也接受并转成字符串：`CFBundleVersion` 被写成 `<integer>` 是真实存在
  /// 的情况，直接丢弃会让用户看到一个空白的版本号。
  String? get asString => switch (this) {
        PlistString(:final value) => value,
        PlistInteger(:final value) => '$value',
        PlistReal(:final value) => '$value',
        _ => null,
      };

  int? get asInt => switch (this) {
        PlistInteger(:final value) => value,
        PlistReal(:final value) => value.toInt(),
        PlistString(:final value) => int.tryParse(value),
        _ => null,
      };

  bool? get asBool => switch (this) {
        PlistBoolean(:final value) => value,
        PlistString(:final value) => value.toLowerCase() == 'true'
            ? true
            : (value.toLowerCase() == 'false' ? false : null),
        _ => null,
      };

  DateTime? get asDate => this is PlistDate ? (this as PlistDate).value : null;

  /// 取字符串数组。
  ///
  /// 单个字符串会被当作单元素数组：`LSApplicationQueriesSchemes` 等键在只有
  /// 一个元素时偶尔被写成标量。这不是猜测，而是 plist 的既有惯例。
  List<String>? get asStringList => switch (this) {
        PlistArray(:final value) =>
          value.map((v) => v.asString).whereType<String>().toList(),
        PlistString(:final value) => [value],
        _ => null,
      };

  /// 取整数数组。
  ///
  /// `UIDeviceFamily` 是典型用例：`[1]` 表示 iPhone，`[1, 2]` 表示
  /// iPhone + iPad。
  List<int>? get asIntList => switch (this) {
        PlistArray(:final value) =>
          value.map((v) => v.asInt).whereType<int>().toList(),
        PlistInteger(:final value) => [value],
        _ => null,
      };
}
