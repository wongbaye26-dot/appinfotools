import 'dart:typed_data';

import 'package:archive_safety/archive_safety.dart';

import '../apk_reader.dart';
import '../container_structure.dart';
import 'aab_resources.dart';
import 'proto.dart';

/// AAB（Android App Bundle）的解析结果。
///
/// 与 [ApkMeta] 的区别：AAB 是**发布容器**而不是可安装的 APK —— 它没有根级
/// `AndroidManifest.xml`，没有 `resources.arsc`，也没有签名块。这里只保留
/// 「从 bundle 里如实读到的事实」，不把任何缺失字段伪装成空字符串。
class AabInfo {
  const AabInfo({
    this.packageName,
    this.versionCode,
    this.versionName,
    this.minSdkVersion,
    this.targetSdkVersion,
    this.label,
    this.labels = const {},
    this.iconPaths = const {},
    this.dexEntries = const [],
    this.nativeLibraries = const [],
    this.fileCount = 0,
    this.totalUncompressedBytes = 0,
    this.failureReason,
    this.structure = const ContainerStructure(),
    this.locales = const [],
    this.densities = const [],
    this.mainIconPath,
    this.resourceFailure,
  });

  /// `<manifest package="...">`。
  final String? packageName;

  final int? versionCode;
  final String? versionName;

  /// `<uses-sdk android:minSdkVersion>`。
  ///
  /// 写成代号（`Q` / `Tiramisu`）而非数字时保持 `null`：这个字段的类型是
  /// 数字，塞进代号会让调用方以为拿到了可比较的版本号。
  final int? minSdkVersion;

  final int? targetSdkVersion;

  /// 默认配置下的 `application@label`。
  final String? label;

  /// `application@label` 的语言变体：`locale → 文案`（不含默认值）。
  final Map<String, String> labels;

  /// `application@icon` 的文件变体：配置键（`default` / `xxxhdpi` / `anydpi`…）
  /// → AAB 内条目路径（带模块前缀，例如 `base/res/mipmap-xxxhdpi-v4/...`）。
  final Map<String, String> iconPaths;

  /// `<module>/dex/*.dex` 的条目名。
  final List<String> dexEntries;

  /// `<module>/lib/<abi>/*.so` 的条目。
  final List<({String abi, String name, int size})> nativeLibraries;

  /// 文件条目数（不含目录条目）。
  final int fileCount;

  /// 全部文件条目声明的解压后字节数之和。
  final int totalUncompressedBytes;

  /// 清单层读不出来的原因；`null` 表示清单已解出。
  ///
  /// 这一层是致命的：没有 base manifest 就不是可分析的 AAB。资源表读取失败
  /// **不**进这里，见 [resourceFailure]。
  final String? failureReason;

  /// AAB 层级的结构概览（`<module>/dex/...`、`<module>/lib/...`）。
  ///
  /// 复用 [ContainerStructure] 而不是另造模型：详情页的结构卡片只认这个类型。
  /// 它原本只认 APK 的根级 `classes.dex` / `lib/`，这里按 AAB 的多模块层级
  /// 重新统计。
  final ContainerStructure structure;

  /// `resources.pb` 里出现过的 locale（已排序）。
  final List<String> locales;

  /// `resources.pb` 里出现过的 density（不含默认 / anydpi / nodpi，已排序）。
  final List<int> densities;

  /// 主图标的优先条目路径（位图优先、密度最高）。
  final String? mainIconPath;

  /// 资源表层读不到的原因；`null` 表示资源表已解出（或根本不需要）。
  ///
  /// 与 [failureReason] 分开：资源表坏了仍然能展示包名 / 版本 / 结构，
  /// 只是 label / icon 的引用解析不了 —— 这点必须说清楚，而不是显示空白。
  final String? resourceFailure;

  @override
  String toString() => 'AabInfo($packageName, $versionName($versionCode), '
      'label=$label, dex=${dexEntries.length}, '
      'native=${nativeLibraries.length}, files=$fileCount, '
      'failure=$failureReason, resourceFailure=$resourceFailure)';
}

/// 一个 protobuf XML 元素（AAB 的 `AndroidManifest.xml` 是 proto XML，不是 AXML）。
class AabXmlElement {
  AabXmlElement({
    required this.name,
    required this.namespaceUri,
    required this.attributes,
    required this.children,
    required this.text,
  });

  /// 元素名，例如 `manifest` / `application` / `uses-sdk`。
  final String name;

  /// 元素自身的命名空间（`xmlns`）；清单里的元素通常为空。
  final String namespaceUri;

  final List<AabXmlAttribute> attributes;
  final List<AabXmlElement> children;

  /// 直接子文本节点拼起来的内容（`XmlNode.text`）。
  final String text;

  /// 递归深度上限。
  ///
  /// 与 protobuf 的深度上限分开：XML 的每一层是一个独立消息（从 bytes 重新
  /// 解析），不会触发 [PbMessage.maxDepth]。128 层已经远超任何真实清单。
  static const int maxDepth = 128;

  /// 解析 `base/manifest/AndroidManifest.xml`。
  static AabXmlElement? parse(Uint8List bytes) {
    final root = PbMessage.parse(bytes);
    final element = root?.getMessage(1);
    if (element == null) return null;
    return _parseElement(element, 0);
  }

  static AabXmlElement? _parseElement(PbMessage message, int depth) {
    if (depth >= maxDepth) return null;

    final name = message.getString(3);
    if (name == null || name.isEmpty) return null;

    final attributes = <AabXmlAttribute>[];
    for (final attribute in message.getMessages(4)) {
      final attributeName = attribute.getString(2);
      // 没有名字的属性无法被读取方使用；保留它只会让「有 5 个属性」这种
      // 统计变得不真实，因此按损坏处理。
      if (attributeName == null || attributeName.isEmpty) return null;
      attributes.add(AabXmlAttribute(
        name: attributeName,
        namespaceUri: attribute.getString(1) ?? '',
        rawValue: attribute.getString(3),
        compiledItem: attribute.getMessage(6),
      ));
    }

    final children = <AabXmlElement>[];
    final text = StringBuffer();
    for (final node in message.getMessages(5)) {
      final elementBytes = node.getBytes(1);
      if (elementBytes != null) {
        final childMessage = PbMessage.parse(elementBytes);
        if (childMessage == null) return null;
        final child = _parseElement(childMessage, depth + 1);
        if (child == null) return null;
        children.add(child);
      } else {
        final value = node.getString(2);
        if (value != null) text.write(value);
      }
    }

    return AabXmlElement(
      name: name,
      namespaceUri: message.getString(2) ?? '',
      attributes: attributes,
      children: children,
      text: text.toString(),
    );
  }

  /// 按名字取属性，优先 Android 命名空间。
  ///
  /// proto XML 把命名空间单独存放在 `namespace_uri` 里，属性名本身**不带**
  /// `android:` 前缀 —— 传 `label` 而不是 `android:label`。
  AabXmlAttribute? attribute(String name) {
    AabXmlAttribute? fallback;
    for (final attribute in attributes) {
      if (attribute.name != name) continue;
      if (attribute.namespaceUri == kAndroidNamespace) return attribute;
      fallback ??= attribute;
    }
    return fallback;
  }

  /// 取第一个同名子元素。
  AabXmlElement? child(String name) {
    for (final child in children) {
      if (child.name == name) return child;
    }
    return null;
  }

  /// 解析后的展示值；解析不出来时返回 `null`。
  String? attributeValue(String name) => attribute(name)?.value;

  @override
  String toString() => 'AabXmlElement($name, ${attributes.length} attrs, '
      '${children.length} children)';
}

/// proto XML 里的一个属性。
class AabXmlAttribute {
  const AabXmlAttribute({
    required this.name,
    required this.namespaceUri,
    this.rawValue,
    this.compiledItem,
  });

  final String name;
  final String namespaceUri;

  /// 源码里的原文（`XmlAttribute.value`）。
  ///
  /// 未编译的属性只有它；已编译属性的原文可能是 `@string/app_name` 这种
  /// 无法直接展示的引用写法，因此只在没有编译值时使用。
  final String? rawValue;

  /// 编译后的值（`XmlAttribute.compiled_item`）。
  final PbMessage? compiledItem;

  /// 编译值里的资源 ID；不是引用时为 `null`。
  int? get compiledReferenceId {
    final id = compiledItem?.getMessage(1)?.getInt(2);
    return id == null || id == 0 ? null : id;
  }

  /// 编译值是否是一个 `?attr/...`（`Reference.type = ATTRIBUTE`）。
  bool get compiledIsAttribute =>
      (compiledItem?.getMessage(1)?.getInt(1) ?? 0) == 1;

  /// 可展示的值。
  ///
  /// 优先编译值：`@res/0x7f010000` 这种表示能直接拿去查资源表，而原文
  /// `@string/app_name` 只能靠名字，AAB 里没有名字索引。编译值缺失时退回
  /// 原文 —— 那至少是文件里写着的东西。
  String? get value {
    final compiled = compiledItem;
    if (compiled != null) {
      final parsed = aabItemValue(compiled);
      if (parsed?.value != null) return parsed!.value;
    }
    final raw = rawValue;
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  @override
  String toString() => 'AabXmlAttribute($name=$value)';
}

/// Android 属性命名空间。
const String kAndroidNamespace = 'http://schemas.android.com/apk/res/android';

/// AAB 读取器。
///
/// 复用 [ApkReader] 的 ZIP 打开与解压预算逻辑：AAB 也是 ZIP，安全边界完全
/// 相同（有界读取、结构损坏检测、总解压体积上限），重写一遍只会让两套预算
/// 慢慢漂移。
class AabReader {
  /// base 模块的清单条目。
  static const String manifestPath = 'base/manifest/AndroidManifest.xml';

  /// base 模块的资源表条目。
  static const String resourcesPath = 'base/resources.pb';

  static const String _manifestSuffix = '/manifest/AndroidManifest.xml';

  static final _dexPattern = RegExp(r'^([^/]+)/dex/([^/]+\.dex)$');
  static final _nativeLibraryPattern =
      RegExp(r'^([^/]+)/lib/([^/]+)/([^/]+\.so)$');

  /// 容器层打不开时的原因；成功打开后为 `null`。
  ///
  /// 与 [read] 的返回值分开：返回 `null` 表示「连容器都没打开」，原因必须
  /// 能从某处读到，否则调用方只能猜是坏文件还是权限问题。
  String? lastFailure;

  /// 读取一个 `.aab`。
  ///
  /// - 返回 `null`：容器层没打开（不是 ZIP / 损坏 / 超预算 / IO），原因在
  ///   [lastFailure]；
  /// - 返回非 `null` 但 [AabInfo.failureReason] 非空：容器打开了，但清单层
  ///   读不出来（缺 base manifest、proto 解不开、根元素不对）。条目统计、
  ///   dex / 原生库仍然填好 —— 那些是已经确认的事实；
  /// - [AabInfo.resourceFailure] 只表示资源表层的问题，不影响上面两层。
  Future<AabInfo?> read(String path) async {
    lastFailure = null;
    final reader = ApkReader();
    try {
      final opened = await reader.open(path);
      if (!opened.isOk) {
        lastFailure = _describeOpenFailure(opened, reader);
        return null;
      }
      return _readOpened(reader);
    } finally {
      reader.close();
    }
  }

  String _describeOpenFailure(ArchiveOpenResult result, ApkReader reader) {
    switch (result) {
      case ArchiveOpenResult.notArchive:
        return 'the file is not a ZIP archive; an AAB is a ZIP container';
      case ArchiveOpenResult.corrupt:
        return 'the AAB archive is corrupt or truncated';
      case ArchiveOpenResult.resourceBudgetExceeded:
        final detail = reader.budgetFailure;
        return 'the AAB archive exceeds the safe read budget'
            '${detail == null ? '' : ': $detail'}';
      case ArchiveOpenResult.ioError:
        return 'the file could not be read (missing, locked, or permission denied)';
      case ArchiveOpenResult.ok:
        // 调用方只会在 !isOk 时进来；保持穷尽让新增枚举值不忘处理。
        return 'the AAB archive could not be opened';
    }
  }

  AabInfo _readOpened(ApkReader reader) {
    final entries = reader.listFilesWithSize();
    final scan = _scanEntries(entries);

    final manifestBytes = reader.readFile(manifestPath);
    if (manifestBytes == null) {
      final found = entries
          .where((entry) => entry.name.endsWith(_manifestSuffix))
          .map((entry) => entry.name)
          .toList()
        ..sort();
      final detail = found.isEmpty
          // 没有模块清单：这个 ZIP 不是 AAB（APK 的清单在根级，不带 /manifest/）。
          ? '$manifestPath is missing and no <module>$_manifestSuffix was '
              'found; this ZIP is not an Android App Bundle'
          // 有清单但不是 base：模块清单齐全度可以直接列出来，用户能看出
          // 是下载不完整还是被别的工具改过。
          : '$manifestPath is missing; module manifests found: '
              '${found.join(', ')}';
      return scan.toInfo(failureReason: detail);
    }

    final root = AabXmlElement.parse(manifestBytes);
    if (root == null) {
      return scan.toInfo(
        failureReason: '$manifestPath could not be decoded as protobuf XML',
      );
    }
    if (root.name != 'manifest') {
      return scan.toInfo(
        failureReason: '$manifestPath root element is <${root.name}>, '
            'not <manifest>',
      );
    }

    final resourceNotes = <String>[];
    final table = _readResources(reader, resourceNotes);

    // ---- manifest 字段 ----
    final packageName = _cleanString(root.attributeValue('package'));
    final versionCode = int.tryParse(root.attributeValue('versionCode') ?? '');
    final versionName = _resolveStringAttribute(
      root.attribute('versionName'),
      table,
      what: 'versionName',
      notes: resourceNotes,
    );

    final usesSdk = root.child('uses-sdk');
    final minSdkVersion =
        int.tryParse(usesSdk?.attributeValue('minSdkVersion') ?? '');
    final targetSdkVersion =
        int.tryParse(usesSdk?.attributeValue('targetSdkVersion') ?? '');

    final application = root.child('application');
    final labelAttribute = application?.attribute('label');
    final iconAttribute = application?.attribute('icon');

    String? label;
    final labels = <String, String>{};
    final labelId = labelAttribute?.compiledReferenceId;
    if (labelId != null) {
      if (table != null) {
        label = table.resolveString(labelId);
        for (final locale
            in table.localized[labelId]?.keys ?? const <String>[]) {
          final localized = table.resolveString(labelId, locale: locale);
          if (localized != null) labels[locale] = localized;
        }
        if (label == null) {
          resourceNotes.add('label reference 0x${labelId.toRadixString(16)} '
              'does not resolve to a string in $resourcesPath');
        }
      }
    } else {
      label = _cleanString(labelAttribute?.value);
      // 原文是 `@string/...` 时上面会原样返回，但那不是一个可展示的 label。
      if (label != null && _looksLikeReference(label)) label = null;
    }

    final iconPaths = <String, String>{};
    String? mainIconPath;
    final iconId = iconAttribute?.compiledReferenceId;
    if (iconId != null) {
      if (table != null) {
        iconPaths.addAll(table.resolveFiles(iconId));
        if (iconPaths.isEmpty) {
          resourceNotes.add('icon reference 0x${iconId.toRadixString(16)} '
              'does not resolve to a file in $resourcesPath');
        }
        mainIconPath = table.bestFile(iconId);
      }
    } else {
      final inline = _cleanString(iconAttribute?.value);
      if (inline != null && !_looksLikeReference(inline)) {
        iconPaths['default'] = aabModulePath('base', inline);
        mainIconPath = iconPaths['default'];
      }
    }

    return scan.toInfo(
      packageName: packageName,
      versionCode: versionCode,
      versionName: versionName,
      minSdkVersion: minSdkVersion,
      targetSdkVersion: targetSdkVersion,
      label: label,
      labels: labels,
      iconPaths: iconPaths,
      mainIconPath: mainIconPath,
      locales: table?.locales ?? const [],
      densities: table?.densities ?? const [],
      resourceFailure: resourceNotes.isEmpty ? null : resourceNotes.join('; '),
    );
  }

  /// 读 `base/resources.pb`；读不到时把原因写进 [notes] 并返回 `null`。
  AabResourceTable? _readResources(ApkReader reader, List<String> notes) {
    final bytes = reader.readFile(resourcesPath);
    if (bytes == null) {
      notes.add('$resourcesPath is missing; label and icon references '
          'cannot be resolved');
      return null;
    }
    final table = AabResourceTable.parse(bytes);
    if (table == null) {
      notes.add(
          '$resourcesPath could not be parsed as a protobuf resource table');
      return null;
    }
    if (table.isEmpty) {
      // 空 protobuf 消息编码上合法，但真实 bundle 不会没有资源；按「截断成
      // 空文件」报告，而不是当成一张合法的空表。
      notes.add('$resourcesPath contains no resources');
      return null;
    }
    return table;
  }

  /// 按 AAB 的多模块层级扫描条目，得到结构、dex、原生库。
  _AabScan _scanEntries(List<({String name, int size})> entries) {
    final dexEntries = <String>[];
    final dexFiles = <DexEntry>[];
    final nativeLibraries = <({String abi, String name, int size})>[];
    final nativeEntries = <NativeLibraryEntry>[];
    final abis = <String>{};
    final directories = <String, DirectoryStat>{};
    var totalBytes = 0;

    for (final entry in entries) {
      totalBytes += entry.size;

      final dex = _dexPattern.firstMatch(entry.name);
      if (dex != null) {
        dexEntries.add(entry.name);
        dexFiles.add(DexEntry(name: entry.name, size: entry.size));
      }

      final library = _nativeLibraryPattern.firstMatch(entry.name);
      if (library != null) {
        final abi = library.group(2)!;
        final name = library.group(3)!;
        abis.add(abi);
        nativeLibraries.add((abi: abi, name: name, size: entry.size));
        nativeEntries.add(NativeLibraryEntry(
          abi: abi,
          name: name,
          path: entry.name,
          size: entry.size,
        ));
      }

      final slash = entry.name.indexOf('/');
      final topLevel = slash <= 0 ? '(root)' : entry.name.substring(0, slash);
      final previous = directories[topLevel];
      directories[topLevel] = DirectoryStat(
        fileCount: (previous?.fileCount ?? 0) + 1,
        uncompressedBytes: (previous?.uncompressedBytes ?? 0) + entry.size,
      );
    }

    dexEntries.sort();
    dexFiles.sort((a, b) => a.name.compareTo(b.name));
    nativeLibraries.sort((a, b) {
      final byAbi = a.abi.compareTo(b.abi);
      return byAbi != 0 ? byAbi : a.name.compareTo(b.name);
    });
    nativeEntries.sort((a, b) => a.path.compareTo(b.path));

    return _AabScan(
      entries: entries,
      dexEntries: dexEntries,
      nativeLibraries: nativeLibraries,
      structure: ContainerStructure(
        fileEntryCount: entries.length,
        dexFiles: dexFiles,
        nativeLibraries: nativeEntries,
        abis: abis.toList()..sort(),
        topLevelDirectories: directories,
        totalUncompressedBytes: totalBytes,
      ),
    );
  }

  static String? _cleanString(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static bool _looksLikeReference(String value) =>
      value.startsWith('@') || value.startsWith('?');

  /// 清单里的字符串属性可能本身是资源引用（`versionName` 很少见，但合法）。
  static String? _resolveStringAttribute(
    AabXmlAttribute? attribute,
    AabResourceTable? table, {
    required String what,
    required List<String> notes,
  }) {
    if (attribute == null) return null;
    final id = attribute.compiledReferenceId;
    if (id != null) {
      if (table == null) return null;
      final resolved = table.resolveString(id);
      if (resolved == null) {
        notes.add('$what reference 0x${id.toRadixString(16)} does not resolve '
            'to a string in $resourcesPath');
      }
      return resolved;
    }
    final value = _cleanString(attribute.value);
    if (value == null || _looksLikeReference(value)) return null;
    return value;
  }
}

/// 条目扫描的中间结果 —— 清单读失败时也要能交出一份完整的结构统计。
class _AabScan {
  const _AabScan({
    required this.entries,
    required this.dexEntries,
    required this.nativeLibraries,
    required this.structure,
  });

  final List<({String name, int size})> entries;
  final List<String> dexEntries;
  final List<({String abi, String name, int size})> nativeLibraries;
  final ContainerStructure structure;

  int get totalBytes => structure.totalUncompressedBytes;

  AabInfo toInfo({
    String? packageName,
    int? versionCode,
    String? versionName,
    int? minSdkVersion,
    int? targetSdkVersion,
    String? label,
    Map<String, String> labels = const {},
    Map<String, String> iconPaths = const {},
    String? mainIconPath,
    List<String> locales = const [],
    List<int> densities = const [],
    String? failureReason,
    String? resourceFailure,
  }) {
    return AabInfo(
      packageName: packageName,
      versionCode: versionCode,
      versionName: versionName,
      minSdkVersion: minSdkVersion,
      targetSdkVersion: targetSdkVersion,
      label: label,
      labels: labels,
      iconPaths: iconPaths,
      dexEntries: dexEntries,
      nativeLibraries: nativeLibraries,
      fileCount: entries.length,
      totalUncompressedBytes: totalBytes,
      failureReason: failureReason,
      structure: structure,
      locales: locales,
      densities: densities,
      mainIconPath: mainIconPath,
      resourceFailure: resourceFailure,
    );
  }
}
