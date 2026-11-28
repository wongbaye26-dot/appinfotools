/// Android API 级别 ↔ 系统版本名 / 正式发布年月。
///
/// 之前这里只到 API 36 且没有发布日期，界面上只能显示 `35 (Android 15)`；
/// 参考实现还会标出发布年月，用来回答「这个 targetSdk 到底有多旧」——
/// 光看 API 数字没有时间感。
class AndroidVersion {
  static String getAndroidVersion(int? sdkVersion) {
    if (sdkVersion == null) return "";
    return _versions[sdkVersion] ?? "";
  }

  /// 正式发布年月（`2016-08`）。未知或尚未发布返回 `null`。
  static String? getReleaseDate(int? sdkVersion) {
    if (sdkVersion == null) return null;
    return _releaseDates[sdkVersion];
  }

  /// 带发布日期的一行描述：`35 (Android 15, 2024-09)`。
  ///
  /// 三段都可能缺失：未知 API 只留数字，未知版本名只留发布日期 —— 任何
  /// 一段缺失都不要补占位符，那会看起来像「我们查到了空值」。
  static String describe(int? sdkVersion) {
    if (sdkVersion == null) return '';
    final name = getAndroidVersion(sdkVersion);
    final date = getReleaseDate(sdkVersion);
    final detail = [
      if (name.isNotEmpty) name,
      if (date != null) date,
    ].join(', ');
    return detail.isEmpty ? '$sdkVersion' : '$sdkVersion ($detail)';
  }

  static const _versions = {
    37: "Android 17",
    36: "Android 16",
    35: "Android 15",
    34: "Android 14",
    33: "Android 13",
    32: "Android 12L",
    31: "Android 12",
    30: "Android 11",
    29: "Android 10",
    28: "Android 9.0 (Pie)",
    27: "Android 8.1 (Oreo)",
    26: "Android 8.0 (Oreo)",
    25: "Android 7.1 (Nougat)",
    24: "Android 7.0 (Nougat)",
    23: "Android 6.0 (Marshmallow)",
    22: "Android 5.1 (Lollipop)",
    21: "Android 5.0 (Lollipop)",
    20: "Android 4.4W (KitKat Wear)",
    19: "Android 4.4 (KitKat)",
    18: "Android 4.3 (Jelly Bean)",
    17: "Android 4.2 (Jelly Bean)",
    16: "Android 4.1 (Jelly Bean)",
    15: "Android 4.0.3 (ICS)",
    14: "Android 4.0 (ICS)",
    13: "Android 3.2 (Honeycomb)",
    12: "Android 3.1 (Honeycomb)",
    11: "Android 3.0 (Honeycomb)",
    10: "Android 2.3.3 (Gingerbread)",
    9: "Android 2.3 (Gingerbread)",
    8: "Android 2.2 (Froyo)",
    7: "Android 2.1 (Eclair)",
    6: "Android 2.0.1 (Eclair)",
    5: "Android 2.0 (Eclair)",
    4: "Android 1.6 (Donut)",
    3: "Android 1.5 (Cupcake)",
    2: "Android 1.1",
    1: "Android 1.0",
  };

  /// API 37 尚未公布发布日期，因此不在表内。
  static const _releaseDates = {
    36: "2025-06",
    35: "2024-09",
    34: "2023-10",
    33: "2022-08",
    32: "2022-03",
    31: "2021-10",
    30: "2020-09",
    29: "2019-09",
    28: "2018-08",
    27: "2017-12",
    26: "2017-08",
    25: "2016-10",
    24: "2016-08",
    23: "2015-10",
    22: "2015-03",
    21: "2014-11",
    20: "2014-06",
    19: "2013-10",
    18: "2013-07",
    17: "2012-11",
    16: "2012-07",
    15: "2011-12",
    14: "2011-10",
    13: "2011-07",
    12: "2011-05",
    11: "2011-02",
    10: "2011-02",
    9: "2010-12",
    8: "2010-05",
    7: "2010-01",
    6: "2009-12",
    5: "2009-10",
    4: "2009-09",
    3: "2009-04",
    2: "2009-02",
    1: "2008-09",
  };
}
