import 'dart:typed_data';

import 'proto.dart';

/// 一条资源值的种类。
///
/// 用枚举而不是「字符串 + 前缀」是因为读取方（清单解析）需要**按种类分支**：
/// label 只认字符串，icon 只认文件，其余值只是顺带收集的事实。
enum AabResourceKind {
  /// `Item.str` / `raw_str` / `styled_str`。
  string,

  /// `Item.file`（`FileReference.path`，相对模块根）。
  file,

  /// `Item.ref`，`Reference.type = REFERENCE`（源码里的 `@...`）。
  reference,

  /// `Item.ref`，`Reference.type = ATTRIBUTE`（源码里的 `?...`）。
  attribute,

  /// `Item.prim.color_*`。
  color,

  /// 其余 primitive（int / bool / float / dimension …）。
  primitive,
}

/// 一个资源 ID 在**某个配置**下的值。
class AabResourceValue {
  const AabResourceValue({
    required this.kind,
    this.value,
    this.referenceId,
    this.density = 0,
  });

  final AabResourceKind kind;

  /// 可直接展示的文本。
  ///
  /// - 字符串：原文；
  /// - 文件：模块前缀后的条目路径（`base/res/...`）；
  /// - 引用：`@res/0x7f010000` / `@attr/0x1010435`（与 AXML 路径的写法一致，
  ///   图标渲染器与清单解析器共用这套表示）；
  /// - 颜色：`#aarrggbb`。
  final String? value;

  /// 仅 [AabResourceKind.reference] / [AabResourceKind.attribute] 有值。
  ///
  /// 保留它是因为「字符串形式的引用」只够展示；要查表解析 label / icon，
  /// 必须拿回数值 ID。
  final int? referenceId;

  /// 该值所在配置的 density（0 表示默认配置）。
  final int density;

  @override
  String toString() => 'AabResourceValue($kind, $value)';
}

/// `base/resources.pb`（`Resources.proto`）的解析结果。
///
/// 只保留「资源 ID → 值」这层映射：AAB 的清单用资源 ID 引用 label / icon，
/// 不需要完整的资源表（类型名、可见性、overlay 等）。
class AabResourceTable {
  AabResourceTable._({
    required this.values,
    required this.localized,
    required this.files,
    required this.variants,
    required this.locales,
    required this.densities,
  });

  /// 默认配置下的值；某个资源没有默认配置时，取**第一个**出现的配置。
  ///
  /// 与「表里没有这个 ID」是两件事：`values[id] == null` 表示没读到。
  final Map<int, AabResourceValue> values;

  /// 字符串资源的 locale 变体：`resId → locale → 值`。
  ///
  /// 这是多语言 label 的来源。locale 为空（默认配置）的值不进这里，
  /// 它在 [values] 里。
  final Map<int, Map<String, String>> localized;

  /// 文件资源的配置变体：`resId → 配置键 → 条目路径`。
  ///
  /// 配置键是 [configKey] 的结果（`default` / `xxxhdpi` / `anydpi` …）。
  /// 图标需要全部密度而不只是默认值，所以单独留一份。
  final Map<int, Map<String, String>> files;

  /// 任意种类的配置变体：`resId → 配置键 → 展示文本`。
  ///
  /// 用于排查「这个 ID 有哪些变体」，不参与 label / icon 的选取。
  final Map<int, Map<String, String>> variants;

  /// 资源表里出现过的全部 locale（已排序）。
  final List<String> locales;

  /// 资源表里出现过的 density（不含 0 / anydpi / nodpi，已排序）。
  final List<int> densities;

  /// 解析 `resources.pb`。
  ///
  /// [module] 是模块名（base / feature 名）。`FileReference.path` 是**相对
  /// 模块根**的路径，拼上模块名才是 AAB 内的真实条目名 —— 不拼的话图标
  /// 永远读不到，而且看起来像是「这个包没有图标」。
  ///
  /// 返回 `null` 只表示「字节不是合法的 protobuf 消息」；单条 package /
  /// type / entry / config 损坏只会被跳过，其余条目照常收集。
  static AabResourceTable? parse(Uint8List bytes, {String module = 'base'}) {
    final root = PbMessage.parse(bytes);
    if (root == null) return null;

    final defaults = <int, AabResourceValue>{};
    final firstAny = <int, AabResourceValue>{};
    final localized = <int, Map<String, String>>{};
    final files = <int, Map<String, String>>{};
    final variants = <int, Map<String, String>>{};
    final locales = <String>{};
    final densities = <int>{};

    for (final package in root.getMessages(2)) {
      // PackageId / TypeId / EntryId 都是只有 id 一个字段的消息。
      final packageId = package.getMessage(1)?.getInt(1) ?? 0;
      for (final type in package.getMessages(3)) {
        final typeId = type.getMessage(1)?.getInt(1) ?? 0;
        for (final entry in type.getMessages(3)) {
          final entryId = entry.getMessage(1)?.getInt(1) ?? 0;
          // 资源 ID 布局 0xPPTTEEEE。proto3 会省略取值为 0 的字段，
          // 所以 entry_id 缺省时按 0 处理，而不是判为损坏。
          final id = (packageId << 24) | (typeId << 16) | entryId;

          for (final configValue in entry.getMessages(6)) {
            final config = configValue.getMessage(1);
            final locale = config?.getString(3) ?? '';
            final density = config?.getInt(18) ?? 0;

            // locale / density 在**取值之前**登记：即使这条值我们解不出来，
            // 「这个包有哪些语言 / 密度」仍是文件里的事实，不能因为一条
            // 坏记录就把它整片丢掉。
            if (locale.isNotEmpty) locales.add(locale);
            if (_isDensityVariant(density)) densities.add(density);

            final item = configValue.getMessage(2)?.getMessage(4);
            if (item == null) continue;
            final value = aabItemValue(item, module: module);
            if (value == null) continue;

            final key = configKey(locale: locale, density: density);
            final text = value.value;
            if (text != null) {
              (variants[id] ??= {}).putIfAbsent(key, () => text);
            }
            if (value.kind == AabResourceKind.file && text != null) {
              (files[id] ??= {}).putIfAbsent(key, () => text);
            }
            if (value.kind == AabResourceKind.string &&
                text != null &&
                locale.isNotEmpty) {
              (localized[id] ??= {}).putIfAbsent(locale, () => text);
            }

            if (locale.isEmpty && density == 0) {
              defaults.putIfAbsent(id, () => value);
            } else {
              firstAny.putIfAbsent(id, () => value);
            }
          }
        }
      }
    }

    // 默认配置优先；没有默认配置时退回第一个变体（例如只有 values-zh 的
    // 字符串）。这一步放在最后，避免后出现的默认值被先出现的变体挡住。
    final values = <int, AabResourceValue>{}
      ..addAll(firstAny)
      ..addAll(defaults);

    return AabResourceTable._(
      values: values,
      localized: localized,
      files: files,
      variants: variants,
      locales: locales.toList()..sort(),
      densities: densities.toList()..sort(),
    );
  }

  /// 表里是否一条资源都没读到。
  ///
  /// 空 protobuf 消息在编码上合法，但真实 AAB 的 `resources.pb` 不会为空；
  /// 用它区分「读到了一张空表」与「文件被截成 0 字节」。
  bool get isEmpty => values.isEmpty && localized.isEmpty && files.isEmpty;

  /// 解析字符串引用，遇到 reference 链时最多跟 [maxHops] 跳。
  ///
  /// 只跟 reference 不跟 attribute：`?attr/...` 的值取决于主题，静态表里
  /// 没有唯一答案，猜一个比留空更糟。
  String? resolveString(int id, {String? locale, int maxHops = 8}) {
    final seen = <int>{};
    var current = id;
    for (var hop = 0; hop < maxHops; hop++) {
      if (current == 0 || !seen.add(current)) return null;

      // 写成 if 而不是三元：`?[locale]` 紧跟在三元 true 分支里会被解析成
      // 嵌套三元 + 列表字面量，而不是「可空下标」。
      String? localizedHit;
      if (locale != null && locale.isNotEmpty) {
        localizedHit = localized[current]?[locale];
      }
      if (localizedHit != null) return localizedHit;

      final value = values[current];
      if (value == null) return null;
      if (value.kind == AabResourceKind.string) return value.value;
      if (value.kind != AabResourceKind.reference) return null;
      current = value.referenceId ?? 0;
    }
    return null;
  }

  /// 解析文件引用，返回 `配置键 → 条目路径`。
  Map<String, String> resolveFiles(int id) {
    final seen = <int>{};
    var current = id;
    while (current != 0 && seen.add(current)) {
      final direct = files[current];
      if (direct != null && direct.isNotEmpty) return direct;

      final value = values[current];
      if (value == null || value.kind != AabResourceKind.reference) break;
      current = value.referenceId ?? 0;
    }
    return const {};
  }

  /// 从资源 ID 选一个最适合当主图标的文件。
  ///
  /// 优先位图并取最高密度；只有矢量 XML 时才退回 XML —— 调用方的渲染器
  /// 对 AAB 里的 proto XML 是无能为力的，但把 XML 路径交出去至少能如实
  /// 说明「图标是矢量图，没画出来」，而不是假装这个包没有图标。
  String? bestFile(int id) {
    final variants = resolveFiles(id);
    if (variants.isEmpty) return null;

    final bitmaps = <String, String>{};
    for (final entry in variants.entries) {
      if (_isBitmapPath(entry.value)) bitmaps[entry.key] = entry.value;
    }
    if (bitmaps.isEmpty) return variants.values.first;

    var bestKey = '';
    var bestDensity = -1;
    for (final key in bitmaps.keys) {
      final density = densityValue(key);
      if (density > bestDensity) {
        bestDensity = density;
        bestKey = key;
      }
    }
    return bitmaps[bestKey];
  }

  /// 配置的稳定键：`default` / `zh-CN` / `xxxhdpi` / `zh-CN-xxxhdpi`。
  ///
  /// 不用数字（`320`）是因为这个键会出现在 `ApkInfo.icons` 的键与诊断文本里，
  /// 可读的 `xxxhdpi` 能直接对上资源目录名。
  static String configKey({required String locale, required int density}) {
    final parts = <String>[];
    if (locale.isNotEmpty) parts.add(locale);
    if (density != 0) parts.add(densityName(density));
    return parts.isEmpty ? 'default' : parts.join('-');
  }

  /// density 数值 → Android 资源目录里的名字。
  static String densityName(int density) {
    switch (density) {
      case 120:
        return 'ldpi';
      case 160:
        return 'mdpi';
      case 213:
        return 'tvdpi';
      case 240:
        return 'hdpi';
      case 320:
        return 'xhdpi';
      case 480:
        return 'xxhdpi';
      case 640:
        return 'xxxhdpi';
      case 0xFFFE:
        return 'anydpi';
      case 0xFFFF:
        return 'nodpi';
      default:
        // 未知密度不猜名字，直接带上数值，至少能看出是哪一个变体。
        return '${density}dpi';
    }
  }

  /// 配置键 → density 数值；`default` 与 `anydpi` 都算 0。
  static int densityValue(String configKey) {
    for (final entry in const {
      120: 'ldpi',
      160: 'mdpi',
      213: 'tvdpi',
      240: 'hdpi',
      320: 'xhdpi',
      480: 'xxhdpi',
      640: 'xxxhdpi',
    }.entries) {
      if (configKey.endsWith(entry.value)) return entry.key;
    }
    final match = RegExp(r'(\d+)dpi$').firstMatch(configKey);
    if (match != null) return int.tryParse(match.group(1)!) ?? 0;
    return 0;
  }

  /// 0 / anydpi(0xFFFE) / nodpi(0xFFFF) 不是「真实密度」，不进 densites 列表。
  static bool _isDensityVariant(int density) =>
      density != 0 && density != 0xFFFE && density != 0xFFFF;

  static bool _isBitmapPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif');
  }
}

/// 把模块名拼到 `FileReference.path` 前面。
///
/// `path` 相对模块根（`res/mipmap-xxxhdpi/ic_launcher.png`），AAB 条目名则带
/// 模块前缀（`base/res/...`）。已经带前缀的路径原样返回，避免 `base/base/...`。
String aabModulePath(String module, String path) {
  final trimmed = path.startsWith('/') ? path.substring(1) : path;
  if (module.isEmpty || trimmed.startsWith('$module/')) return trimmed;
  return '$module/$trimmed';
}

/// 把一个 `Item` 消息转成可展示的资源值。
///
/// 判定顺序与 `Resources.proto` 里 `Item` 的 oneof 一致：file → ref →
/// str/raw_str/styled_str → prim。`Item.id`（字段 6）是动态 ID，不携带值，
/// 因此不处理。
AabResourceValue? aabItemValue(PbMessage item, {String module = 'base'}) {
  final file = item.getMessage(5);
  if (file != null) {
    final path = file.getString(1);
    if (path != null && path.isNotEmpty) {
      return AabResourceValue(
        kind: AabResourceKind.file,
        value: aabModulePath(module, path),
      );
    }
  }

  final reference = item.getMessage(1);
  if (reference != null) {
    final id = reference.getInt(2);
    if (id != null && id != 0) {
      final isAttribute = (reference.getInt(1) ?? 0) == 1;
      final hex = id.toRadixString(16);
      return AabResourceValue(
        kind:
            isAttribute ? AabResourceKind.attribute : AabResourceKind.reference,
        value: isAttribute ? '@attr/0x$hex' : '@res/0x$hex',
        referenceId: id,
      );
    }
  }

  for (final field in const [2, 3, 4]) {
    final string = item.getMessage(field)?.getString(1);
    if (string != null) {
      return AabResourceValue(kind: AabResourceKind.string, value: string);
    }
  }

  final primitive = item.getMessage(7);
  if (primitive != null) {
    final value = _primitiveValue(primitive);
    if (value != null) return value;
  }

  return null;
}

/// `Primitive` → 展示文本。
AabResourceValue? _primitiveValue(PbMessage primitive) {
  final floatBits = primitive.getFixed32(3);
  if (floatBits != null) {
    return AabResourceValue(
      kind: AabResourceKind.primitive,
      value: _formatDouble(_asFloat32(floatBits)),
    );
  }

  final decimal = primitive.getInt(6);
  if (decimal != null) {
    return AabResourceValue(
      kind: AabResourceKind.primitive,
      value: _asInt32(decimal).toString(),
    );
  }

  final hex = primitive.getInt(7);
  if (hex != null) {
    return AabResourceValue(
      kind: AabResourceKind.primitive,
      value: '0x${hex.toRadixString(16)}',
    );
  }

  final boolean = primitive.getInt(8);
  if (boolean != null) {
    return AabResourceValue(
      kind: AabResourceKind.primitive,
      value: boolean != 0 ? 'true' : 'false',
    );
  }

  final dimension = primitive.getInt(13);
  if (dimension != null) {
    return AabResourceValue(
      kind: AabResourceKind.primitive,
      value: _formatDimension(dimension),
    );
  }

  // 颜色字段 9..12。argb8 / argb4 本身已含 alpha；rgb8 / rgb4 不含，
  // 与 Android 的 `#aarrggbb` 表示对齐时补上不透明 alpha。
  final color = primitive.getInt(9) ??
      (primitive.getInt(10) == null
          ? null
          : primitive.getInt(10)! | 0xff000000) ??
      primitive.getInt(11) ??
      (primitive.getInt(12) == null
          ? null
          : primitive.getInt(12)! | 0xff000000);
  if (color != null) {
    return AabResourceValue(
      kind: AabResourceKind.color,
      value: '#${color.toRadixString(16).padLeft(8, '0')}',
    );
  }

  return null;
}

/// primitive 里的 int32 用 varint 编码，负数会占满 10 字节；取回有符号值。
int _asInt32(int value) => value > 0x7fffffff ? value - 0x100000000 : value;

/// `Primitive.float` 是 fixed32 存 IEEE-754 单精度。
double _asFloat32(int bits) {
  final data = ByteData(4)..setUint32(0, bits, Endian.little);
  return data.getFloat32(0, Endian.little);
}

/// 浮点展示与 AXML 路径保持一致：整数值输出 `2.0` 而不是 `2`。
String _formatDouble(double value) {
  if (!value.isFinite) return value.toString();
  if (value == value.truncateToDouble() && value.abs() < 1e15) {
    return '${value.toInt()}.0';
  }
  return value.toString();
}

/// primitives.proto 的 dimension：高 24 位是尾数，低 4 位是单位。
///
/// 尾数还带了 3 位 radix 指数（bit 4-5），换算方式与 Android 的
/// `complexToFloat` 相同。
String _formatDimension(int data) {
  const radixMults = [1.0, 1.0 / 128, 1.0 / 32768, 1.0 / 8388608];
  final mantissa = _asInt32(data & 0xFFFFFF00);
  final value = mantissa / 256 * radixMults[(data >> 4) & 0x3];
  const units = ['px', 'dp', 'sp', 'pt', 'in', 'mm'];
  final unit = (data & 0xf) < units.length ? units[data & 0xf] : '';
  return '${_formatDouble(value)}$unit';
}
