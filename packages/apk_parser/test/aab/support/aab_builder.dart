/// 测试用的最小 protobuf / AAB 构造器。
///
/// 生产代码里不引 protobuf 包（AAB 解析是手写读取），测试因此也不能用
/// `protoc` 生成物：这里手写一个只够造测试向量的编码器，字段号与
/// Resources.proto / ResourcesXml.proto 一致。造出来的 AAB 是真实的 ZIP，
/// 解析器按正常路径打开它，因此测试覆盖的是真解析而不是 mock。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';

/// Android 资源的属性都在这个命名空间下。
const String kTestAndroidNamespace = 'http://schemas.android.com/apk/res/android';

/// 最小 protobuf 编码器。
///
/// 只覆盖测试用得到的 wire type：0（varint）、1（fixed64，用于验证跳过）、
/// 2（length-delimited）、5（fixed32，float）。生产读取器对其它位宽只做
/// 跳过/拒绝，不需要编码。
class PbOut {
  final List<int> _bytes = <int>[];

  void _varint(int value) {
    var remaining = value;
    while (remaining >= 0x80) {
      _bytes.add((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.add(remaining);
  }

  void _tag(int number, int wireType) => _varint((number << 3) | wireType);

  void intField(int number, int value) {
    _tag(number, 0);
    _varint(value);
  }

  void bytesField(int number, List<int> value) {
    _tag(number, 2);
    _varint(value.length);
    _bytes.addAll(value);
  }

  void stringField(int number, String value) =>
      bytesField(number, utf8.encode(value));

  void messageField(int number, PbOut value) =>
      bytesField(number, value.toBytes());

  void floatField(int number, double value) {
    _tag(number, 5);
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    _bytes.addAll(data.buffer.asUint8List());
  }

  void fixed64Field(int number, List<int> value) {
    assert(value.length == 8, 'fixed64 必须正好 8 字节');
    _tag(number, 1);
    _bytes.addAll(value);
  }

  Uint8List toBytes() => Uint8List.fromList(_bytes);
}

// ---------------------------------------------------------------------------
// Resources.pb（Resources.proto）
// ---------------------------------------------------------------------------

/// 把编码好的字节当一条 protobuf 消息读回来。
///
/// `aabItemValue` 接收的是 [PbMessage]（已解析的 Item），而测试里先用
/// [PbOut] 造字节，所以统一在边界上做一次解析。
PbMessage messageOf(PbOut out) => PbMessage.parse(out.toBytes())!;

/// `Item.string_value`（field 2 → StringValue.value field 1）。
PbOut itemString(String value) =>
    PbOut()..messageField(2, PbOut()..stringField(1, value));

/// `Item.raw_string_value`（field 3）。AAB 里通常是已编译的 string，但保留
/// 这个分支用于验证读取器对三种字符串容器的兼容。
PbOut itemRawString(String value) =>
    PbOut()..messageField(3, PbOut()..stringField(1, value));

/// `Item.file`（field 5 → FileReference.path field 1）。路径是模块内相对路径，
/// 不含 `base/` 前缀。
PbOut itemFile(String path) =>
    PbOut()..messageField(5, PbOut()..stringField(1, path));

/// `Item.ref`（field 1 → Reference）。`type` 0=资源引用、1=属性引用。
PbOut itemReference(int id, {int type = 0}) => PbOut()
  ..messageField(
    1,
    PbOut()
      ..intField(1, type)
      ..intField(2, id),
  );

/// `Item.prim`（field 7 → Primitive）。整型用 int_decimal（field 6）更贴近
/// aapt2 的输出。
PbOut itemInt(int value) =>
    PbOut()..messageField(7, PbOut()..intField(6, value));

PbOut itemBool(bool value) =>
    PbOut()..messageField(7, PbOut()..intField(8, value ? 1 : 0));

PbOut itemFloat(double value) =>
    PbOut()..messageField(7, PbOut()..floatField(3, value));

/// `Primitive.color_argb8`（field 9），0xAARRGGBB。
PbOut itemColor(int argb) =>
    PbOut()..messageField(7, PbOut()..intField(9, argb));

/// `Configuration`：AAB 用它区分 locale（field 3）与 density（field 18）。
/// 默认配置是空 message，所以两个字段都可缺省。
PbOut config({String locale = '', int density = 0}) {
  final out = PbOut();
  if (locale.isNotEmpty) out.stringField(3, locale);
  if (density != 0) out.intField(18, density);
  return out;
}

/// `ConfigValue{ config=1, value=2 }`，`Value.item` 是 field 4。
PbOut configValue({String locale = '', int density = 0, required PbOut item}) =>
    PbOut()
      ..messageField(1, config(locale: locale, density: density))
      ..messageField(2, PbOut()..messageField(4, item));

/// `Entry{ entry_id=1, name=2, config_value=6 }`。
///
/// proto3 里 entry_id 为 0 时会被省略，这里照做，用来验证读取器把缺失的
/// entry_id 当成 0（真实 aapt2 输出同样会省略第一个条目）。
PbOut entry(int entryId, String name, List<PbOut> values) {
  final out = PbOut();
  if (entryId != 0) out.messageField(1, PbOut()..intField(1, entryId));
  if (name.isNotEmpty) out.stringField(2, name);
  for (final value in values) {
    out.messageField(6, value);
  }
  return out;
}

/// `Type{ type_id=1, name=2, entry=3 }`。
PbOut type(int typeId, String name, List<PbOut> entries) {
  final out = PbOut()
    ..messageField(1, PbOut()..intField(1, typeId))
    ..stringField(2, name);
  for (final entry in entries) {
    out.messageField(3, entry);
  }
  return out;
}

/// `ResourceTable{ package=2 }`；package 的 id 是 field 1 的 message。
PbOut resourceTable({int packageId = 0x7f, required List<PbOut> types}) {
  final package = PbOut()..messageField(1, PbOut()..intField(1, packageId));
  for (final type in types) {
    package.messageField(3, type);
  }
  return PbOut()..messageField(2, package);
}

/// 测试基准资源表。
///
/// 资源 id 由 (package << 24) | (type << 16) | entry 拼成：
/// - 0x7f010000 `string/app_name`：默认 `Demo App`，另有 zh-CN / en；
/// - 0x7f010001 `string/app_name_alias`：引用 0x7f010000，验证引用链；
/// - 0x7f020000 `mipmap/ic_launcher`：mdpi / xxxhdpi 位图 + anydpi 矢量；
/// - 0x7f030000 `color/brand`：颜色值。
PbOut standardResourceTable({int packageId = 0x7f}) {
  final strings = type(1, 'string', [
    entry(0, 'app_name', [
      configValue(item: itemString('Demo App')),
      configValue(locale: 'zh-CN', item: itemString('演示应用')),
      configValue(locale: 'en', item: itemString('Demo EN')),
    ]),
    entry(1, 'app_name_alias', [
      configValue(item: itemReference(0x7f010000)),
    ]),
  ]);
  final mipmaps = type(2, 'mipmap', [
    entry(0, 'ic_launcher', [
      configValue(
        density: 160,
        item: itemFile('res/mipmap-mdpi-v4/ic_launcher.png'),
      ),
      configValue(
        density: 640,
        item: itemFile('res/mipmap-xxxhdpi-v4/ic_launcher.png'),
      ),
      configValue(
        density: 0xFFFE,
        item: itemFile('res/mipmap-anydpi-v26/ic_launcher.xml'),
      ),
    ]),
  ]);
  final colors = type(3, 'color', [
    entry(0, 'brand', [
      configValue(item: itemColor(0xff112233)),
    ]),
  ]);
  return resourceTable(
    packageId: packageId,
    types: [strings, mipmaps, colors],
  );
}

// ---------------------------------------------------------------------------
// 清单（ResourcesXml.proto，AAB 里是 protobuf 而不是 AXML）
// ---------------------------------------------------------------------------

/// `XmlElement{ name=3, attribute=4, child=5 }`。
PbOut xmlElement(
  String name, {
  List<PbOut> attributes = const <PbOut>[],
  List<PbOut> children = const <PbOut>[],
}) {
  final out = PbOut()..stringField(3, name);
  for (final attribute in attributes) {
    out.messageField(4, attribute);
  }
  for (final child in children) {
    out.messageField(5, child);
  }
  return out;
}

/// `XmlNode{ element=1 }`。清单文件的顶层就是一个 XmlNode。
PbOut xmlChild(PbOut element) => PbOut()..messageField(1, element);

/// `XmlAttribute{ namespace_uri=1, name=2, value=3, compiled_item=6 }`。
///
/// `value` 是未编译的原文（如 `@string/app_name`），`compiled_item` 才是
/// 已解析的值；真实 AAB 两者都有，读取器优先用后者。
PbOut xmlAttribute(
  String name, {
  String? rawValue,
  PbOut? compiledItem,
  String namespaceUri = kTestAndroidNamespace,
}) {
  final out = PbOut();
  if (namespaceUri.isNotEmpty) out.stringField(1, namespaceUri);
  out.stringField(2, name);
  if (rawValue != null) out.stringField(3, rawValue);
  if (compiledItem != null) out.messageField(6, compiledItem);
  return out;
}

/// 构造 `base/manifest/AndroidManifest.xml` 的字节。
///
/// 缺省值对应 [standardResourceTable] 里的 `string/app_name` 与
/// `mipmap/ic_launcher`；把 `labelRef` / `iconRef` 传 null 可以模拟
/// 「清单里只有原文、没有编译值」的降级情形。
Uint8List standardManifest({
  String packageName = 'com.example.aab',
  int? versionCode = 42,
  String? versionName = '1.2.3',
  int? minSdk = 21,
  int? targetSdk = 33,
  String? minSdkCodename,
  int? labelRef = 0x7f010000,
  int? iconRef = 0x7f020000,
  String? inlineLabel,
  String? inlineIcon,
  String rootName = 'manifest',
}) {
  final attributes = <PbOut>[
    // package 是 manifest 自己的属性，没有 android: 命名空间。
    xmlAttribute('package', rawValue: packageName, namespaceUri: ''),
  ];
  if (versionCode != null) {
    attributes.add(
      xmlAttribute('versionCode', compiledItem: itemInt(versionCode)),
    );
  }
  if (versionName != null) {
    attributes.add(xmlAttribute('versionName', rawValue: versionName));
  }

  final children = <PbOut>[];
  if (minSdk != null || targetSdk != null || minSdkCodename != null) {
    children.add(
      xmlChild(xmlElement('uses-sdk', attributes: [
        if (minSdk != null)
          xmlAttribute('minSdkVersion', compiledItem: itemInt(minSdk)),
        if (minSdkCodename != null)
          xmlAttribute('minSdkVersion', rawValue: minSdkCodename),
        if (targetSdk != null)
          xmlAttribute('targetSdkVersion', compiledItem: itemInt(targetSdk)),
      ])),
    );
  }

  final applicationAttributes = <PbOut>[];
  if (inlineLabel != null) {
    applicationAttributes.add(xmlAttribute('label', rawValue: inlineLabel));
  } else if (labelRef != null) {
    applicationAttributes.add(
      xmlAttribute(
        'label',
        rawValue: '@string/app_name',
        compiledItem: itemReference(labelRef),
      ),
    );
  }
  if (inlineIcon != null) {
    applicationAttributes.add(xmlAttribute('icon', rawValue: inlineIcon));
  } else if (iconRef != null) {
    applicationAttributes.add(
      xmlAttribute(
        'icon',
        rawValue: '@mipmap/ic_launcher',
        compiledItem: itemReference(iconRef),
      ),
    );
  }
  children.add(xmlChild(xmlElement('application', attributes: applicationAttributes)));

  final root = xmlElement(
    rootName,
    attributes: attributes,
    children: children,
  );
  return (PbOut()..messageField(1, root)).toBytes();
}

// ---------------------------------------------------------------------------
// AAB 容器
// ---------------------------------------------------------------------------

/// 往 ZIP 里塞条目，最后编码成 `.aab` 字节。
class AabFixture {
  final Archive _archive = Archive();

  void add(String name, List<int> bytes) {
    _archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  /// 真实的 AAB 顶层有 BundleConfig.pb；加上它是为了让「顶层目录」统计里
  /// 同时出现 `base/` 与 `(root)` 两种条目。
  void addBundleConfig() => add('BundleConfig.pb', const [0x0a, 0x00]);

  void addDex(String module, String name, {int size = 64}) {
    add('$module/dex/$name', List<int>.filled(size, 0x64));
  }

  void addNative(String module, String abi, String name, {int size = 128}) {
    add('$module/lib/$abi/$name', List<int>.filled(size, 0x7f));
  }

  Uint8List build() => Uint8List.fromList(ZipEncoder().encode(_archive));
}

/// 构造一个完整、可解析的 AAB。
///
/// 条目数（未压缩）：
/// base/manifest/AndroidManifest.xml、base/resources.pb、BundleConfig.pb、
/// base/dex/classes.dex、base/dex/classes2.dex、base/lib/arm64-v8a/libfoo.so，
/// 共 6 个。
Uint8List buildStandardAab({
  Uint8List? manifest,
  bool includeResources = true,
  bool includeDex = true,
  bool includeNative = true,
  bool includeBundleConfig = true,
}) {
  final fixture = AabFixture();
  fixture.add(
    'base/manifest/AndroidManifest.xml',
    manifest ?? standardManifest(),
  );
  if (includeResources) {
    fixture.add('base/resources.pb', standardResourceTable().toBytes());
  }
  if (includeBundleConfig) fixture.addBundleConfig();
  if (includeDex) {
    fixture.addDex('base', 'classes.dex');
    fixture.addDex('base', 'classes2.dex');
  }
  if (includeNative) {
    fixture.addNative('base', 'arm64-v8a', 'libfoo.so');
  }
  return fixture.build();
}
