import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';

import 'ipa_container.dart';
import 'plist/plist_parser.dart';
import 'plist/plist_value.dart';
import 'plist/xml_plist_parser.dart' show PlistParseException;

/// 一组图标条目（`CFBundlePrimaryIcon` 或某个备用图标）。
class IosIconSet {
  /// `CFBundleIconFiles` —— iOS 5.0+ 使用，值是**不含扩展名**的文件名，
  /// 实际文件通常在 bundle 根目录下以 `@2x`/`@3x` 后缀区分。
  final List<String> iconFiles;

  /// `CFBundleIconName` —— iOS 11+ 使用，指向 `Assets.car` 里的图标名。
  ///
  /// 注意：这个值**不是**文件名，无法直接当路径用。规范 5.3 要求「不得随意把
  /// 启动画面、截图或其他图片当作应用图标」，因此后续解析必须区分这两种来源。
  final String? iconName;

  const IosIconSet({this.iconFiles = const [], this.iconName});

  bool get isEmpty => iconFiles.isEmpty && iconName == null;

  @override
  String toString() =>
      'IosIconSet(files: $iconFiles, name: $iconName)';
}

/// `CFBundleIcons` 及相关图标配置。
class IosIconConfiguration {
  /// `CFBundleIcons.CFBundlePrimaryIcon`。
  final IosIconSet? primary;

  /// `CFBundleIcons.CFBundleAlternateIcons`，键是图标名。
  final Map<String, IosIconSet> alternate;

  /// `CFBundleIcons~ipad.CFBundlePrimaryIcon`。
  final IosIconSet? primaryIpad;

  /// 旧式顶层 `CFBundleIconFiles`（iOS 5 之前）。
  final List<String> legacyIconFiles;

  /// 更旧的顶层 `CFBundleIconFile`（单个文件名）。
  final String? legacyIconFile;

  const IosIconConfiguration({
    this.primary,
    this.alternate = const {},
    this.primaryIpad,
    this.legacyIconFiles = const [],
    this.legacyIconFile,
  });

  /// 是否完全没有图标配置。
  bool get isEmpty =>
      primary == null &&
      alternate.isEmpty &&
      primaryIpad == null &&
      legacyIconFiles.isEmpty &&
      legacyIconFile == null;

  @override
  String toString() => 'IosIconConfiguration(primary: $primary, '
      'alternate: ${alternate.length}, ipad: $primaryIpad, '
      'legacy: $legacyIconFiles / $legacyIconFile)';
}

/// 从 `Info.plist` 提取的字段。
///
/// 每个字段都是 [FieldValue]：**值 + 状态 + 来源 + 诊断**。规范 5.2 要求
/// 「对缺失、类型错误或无法解析的字段分别记录状态，不得将空值替换为虚构数据」，
/// 这个结构就是那句话的落地。
class IpaInfoPlist {
  final IosBundle bundle;

  /// 解析用的原始 plist。读取失败时为 `null`。
  ///
  /// 保留它是为了能查未建模的键，而不必为每个冷门键都加一个字段。
  final PlistValue? raw;

  final FieldValue<String> bundleIdentifier;
  final FieldValue<String> displayName;
  final FieldValue<String> bundleName;
  final FieldValue<String> shortVersionString;
  final FieldValue<String> bundleVersion;
  final FieldValue<String> executable;
  final FieldValue<String> minimumOSVersion;

  /// `UIDeviceFamily`：`[1]` = iPhone，`[1, 2]` = iPhone + iPad。
  final FieldValue<List<int>> deviceFamily;

  final FieldValue<List<String>> queriesSchemes;
  final FieldValue<List<String>> requiredDeviceCapabilities;
  final FieldValue<IosIconConfiguration> icons;

  /// 读取与解析过程中的诊断。
  final List<AnalysisDiagnostic> diagnostics;

  const IpaInfoPlist({
    required this.bundle,
    this.raw,
    this.bundleIdentifier = const FieldValue<String>.absent(),
    this.displayName = const FieldValue<String>.absent(),
    this.bundleName = const FieldValue<String>.absent(),
    this.shortVersionString = const FieldValue<String>.absent(),
    this.bundleVersion = const FieldValue<String>.absent(),
    this.executable = const FieldValue<String>.absent(),
    this.minimumOSVersion = const FieldValue<String>.absent(),
    this.deviceFamily = const FieldValue<List<int>>.absent(),
    this.queriesSchemes = const FieldValue<List<String>>.absent(),
    this.requiredDeviceCapabilities = const FieldValue<List<String>>.absent(),
    this.icons = const FieldValue<IosIconConfiguration>.absent(),
    this.diagnostics = const [],
  });

  /// 名称：优先显示名，退回 `CFBundleName`。
  ///
  /// 两者都取不到时返回**空值状态**而不是空串 —— 调用方据此决定怎么展示
  /// 「读不到」，而不是看到一个看起来正常的空名字。
  FieldValue<String> get preferredName {
    if (displayName.hasValue) return displayName;
    if (bundleName.hasValue) return bundleName;
    // 保留更「有信息量」的那个失败原因：如果 displayName 是类型错误，
    // 那比 bundleName 缺失更值得告诉用户。
    if (displayName.status != FieldStatus.absent) return displayName;
    return bundleName;
  }

  /// 是否有任何字段被成功提取。
  bool get hasAnyValue => [
        bundleIdentifier,
        displayName,
        bundleName,
        shortVersionString,
        bundleVersion,
        executable,
        minimumOSVersion,
        deviceFamily,
        queriesSchemes,
        requiredDeviceCapabilities,
        icons,
      ].any((f) => f.hasValue);
}

/// 读取并提取某个 bundle 的 `Info.plist`。
class IpaInfoPlistReader {
  IpaInfoPlistReader._();

  /// `Info.plist` 的大小上限（8 MiB）。
  ///
  /// 正常的 `Info.plist` 只有几十 KB。超过这个量级说明它多半不是真正的
  /// `Info.plist`（或文件被构造过），拒绝读取而不是继续分配内存。
  static const int maxInfoPlistBytes = 8 * 1024 * 1024;

  static IpaInfoPlist read(Archive archive, IosBundle bundle) {
    final path = bundle.infoPlistPath;
    if (path == null) {
      return _allAbsent(
        bundle,
        AnalysisDiagnostic.warning(
          'ios.info_plist.missing',
          '${bundle.path} has no Info.plist',
        ),
      );
    }

    final entry = archive.findFile(path);
    if (entry == null) {
      // 容器层说有、归档里却没有 —— 内部不一致，值得记一条 error。
      return _allAbsent(
        bundle,
        AnalysisDiagnostic.error(
          'ios.info_plist.vanished',
          '$path was listed but could not be read',
        ),
      );
    }

    if (entry.size > maxInfoPlistBytes) {
      return _allAbsent(
        bundle,
        AnalysisDiagnostic.warning(
          'ios.info_plist.too_large',
          '$path declares ${entry.size} bytes, above the '
          '$maxInfoPlistBytes byte limit',
        ),
      );
    }

    final content = entry.content;
    if (content.length > maxInfoPlistBytes) {
      // 走到这里说明 ZIP 头部的声明尺寸小于上限、实际解出更多 —— 头部在撒谎。
      //
      // 已知局限：此时内存**已经**分配了。归档层的预算只统计声明尺寸，无法
      // 阻止这种情况；这里能做的是拒绝解析并如实报告，而不是把它当正常文件读。
      return _allAbsent(
        bundle,
        AnalysisDiagnostic.error(
          'ios.info_plist.size_lie',
          '$path declared ${entry.size} bytes but decompressed to '
          '${content.length}; refusing to parse it',
        ),
      );
    }

    final PlistValue parsed;
    try {
      parsed = PlistParser.parse(content);
    } on PlistParseException catch (e) {
      return _allFailed(
        bundle,
        AnalysisDiagnostic.error(
          'ios.info_plist.unparsable',
          '$path could not be parsed: ${e.message}',
        ),
      );
    }

    if (parsed is! PlistDict) {
      return _allFailed(
        bundle,
        AnalysisDiagnostic.error(
          'ios.info_plist.not_a_dict',
          '$path root is ${parsed.typeName}, expected a dictionary',
        ),
      );
    }

    return _extract(bundle, parsed, path);
  }

  static IpaInfoPlist _extract(
      IosBundle bundle, PlistDict root, String path) {
    final diagnostics = <AnalysisDiagnostic>[
      AnalysisDiagnostic.info(
        'ios.info_plist.parsed',
        'parsed $path (${root.value.length} keys)',
        source: FieldSource.infoPlist,
      ),
    ];

    return IpaInfoPlist(
      bundle: bundle,
      raw: root,
      bundleIdentifier: _strictString(root, 'CFBundleIdentifier'),
      displayName: _strictString(root, 'CFBundleDisplayName'),
      bundleName: _strictString(root, 'CFBundleName'),
      shortVersionString: _strictString(root, 'CFBundleShortVersionString'),
      bundleVersion: _numberOrString(root, 'CFBundleVersion'),
      executable: _strictString(root, 'CFBundleExecutable'),
      minimumOSVersion: _strictString(root, 'MinimumOSVersion'),
      deviceFamily: _intList(root, 'UIDeviceFamily'),
      queriesSchemes: _stringList(root, 'LSApplicationQueriesSchemes'),
      requiredDeviceCapabilities:
          _stringList(root, 'UIRequiredDeviceCapabilities'),
      icons: _icons(root),
      diagnostics: diagnostics,
    );
  }

  // ---------------------------------------------------------------------------
  // 字段提取
  // ---------------------------------------------------------------------------

  /// 严格取字符串：类型不是 `string` 就记 [FieldStatus.wrongType]。
  static FieldValue<String> _strictString(PlistDict root, String key) {
    final raw = root.value[key];
    if (raw == null) {
      return const FieldValue<String>.absent(source: FieldSource.infoPlist);
    }
    if (raw is! PlistString) {
      return FieldValue<String>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected a string',
        source: FieldSource.infoPlist,
      );
    }
    return FieldValue<String>.extracted(raw.value, source: FieldSource.infoPlist);
  }

  /// 宽松取字符串：整数/浮点也接受。
  ///
  /// **只用于 `CFBundleVersion`。** 它按文档是字符串，但被写成 `<integer>`
  /// 是真实存在的情况；直接判为类型错误只会让用户看到一个空白的构建号，
  /// 而那个数字本身是准确可用的。
  static FieldValue<String> _numberOrString(PlistDict root, String key) {
    final raw = root.value[key];
    if (raw == null) {
      return const FieldValue<String>.absent(source: FieldSource.infoPlist);
    }
    final value = raw.asString;
    if (value == null) {
      return FieldValue<String>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected a string or a number',
        source: FieldSource.infoPlist,
      );
    }
    return FieldValue<String>.extracted(value, source: FieldSource.infoPlist);
  }

  /// 取整数数组。
  ///
  /// 要求确实是数组且元素都是整数。**不接受裸标量**：把 `UIDeviceFamily = 1`
  /// 当成 `[1]` 是在替文件补结构，而我们无法区分那到底是简写还是写错了。
  static FieldValue<List<int>> _intList(PlistDict root, String key) {
    final raw = root.value[key];
    if (raw == null) {
      return const FieldValue<List<int>>.absent(source: FieldSource.infoPlist);
    }
    if (raw is! PlistArray) {
      return FieldValue<List<int>>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected an array of integers',
        source: FieldSource.infoPlist,
      );
    }
    final values = <int>[];
    for (final item in raw.value) {
      final value = item.asInt;
      if (value == null) {
        return FieldValue<List<int>>.wrongType(
          diagnostic: '$key contains a ${item.typeName}, expected integers',
          source: FieldSource.infoPlist,
        );
      }
      values.add(value);
    }
    return FieldValue<List<int>>.extracted(values, source: FieldSource.infoPlist);
  }

  /// 取字符串数组。同样要求确实是数组。
  static FieldValue<List<String>> _stringList(PlistDict root, String key) {
    final raw = root.value[key];
    if (raw == null) {
      return const FieldValue<List<String>>.absent(source: FieldSource.infoPlist);
    }
    if (raw is! PlistArray) {
      return FieldValue<List<String>>.wrongType(
        diagnostic: '$key is ${raw.typeName}, expected an array of strings',
        source: FieldSource.infoPlist,
      );
    }
    final values = <String>[];
    for (final item in raw.value) {
      final value = item.asString;
      if (value == null) {
        return FieldValue<List<String>>.wrongType(
          diagnostic: '$key contains a ${item.typeName}, expected strings',
          source: FieldSource.infoPlist,
        );
      }
      values.add(value);
    }
    return FieldValue<List<String>>.extracted(values, source: FieldSource.infoPlist);
  }

  /// 提取图标配置。
  static FieldValue<IosIconConfiguration> _icons(PlistDict root) {
    final config = IosIconConfiguration(
      primary: _iconSetFrom(_dictAt(root, 'CFBundleIcons', 'CFBundlePrimaryIcon')),
      alternate: _alternateIcons(root),
      primaryIpad:
          _iconSetFrom(_dictAt(root, 'CFBundleIcons~ipad', 'CFBundlePrimaryIcon')),
      legacyIconFiles:
          _stringList(root, 'CFBundleIconFiles').value ?? const [],
      legacyIconFile: _strictString(root, 'CFBundleIconFile').value,
    );

    if (config.isEmpty) {
      return const FieldValue<IosIconConfiguration>.absent(
        source: FieldSource.infoPlist,
      );
    }
    return FieldValue<IosIconConfiguration>.extracted(
      config,
      source: FieldSource.infoPlist,
    );
  }

  /// 取 `root[outer][inner]`，任一层缺失或类型不符都返回 `null`。
  static PlistDict? _dictAt(PlistDict root, String outer, String inner) {
    final outerValue = root.value[outer];
    if (outerValue is! PlistDict) return null;
    final innerValue = outerValue.value[inner];
    return innerValue is PlistDict ? innerValue : null;
  }

  static IosIconSet? _iconSetFrom(PlistDict? dict) {
    if (dict == null) return null;
    final set = IosIconSet(
      iconFiles: _stringList(dict, 'CFBundleIconFiles').value ?? const [],
      iconName: _strictString(dict, 'CFBundleIconName').value,
    );
    return set.isEmpty ? null : set;
  }

  static Map<String, IosIconSet> _alternateIcons(PlistDict root) {
    final outer = root.value['CFBundleIcons'];
    if (outer is! PlistDict) return const {};
    final alternates = outer.value['CFBundleAlternateIcons'];
    if (alternates is! PlistDict) return const {};

    final result = <String, IosIconSet>{};
    for (final entry in alternates.value.entries) {
      if (entry.value is! PlistDict) continue;
      final set = _iconSetFrom(entry.value as PlistDict);
      if (set != null) result[entry.key] = set;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 整体失败
  // ---------------------------------------------------------------------------

  /// 文件不存在 / 读不了：所有字段记为「缺失」，附一条诊断。
  static IpaInfoPlist _allAbsent(
      IosBundle bundle, AnalysisDiagnostic diagnostic) {
    return IpaInfoPlist(bundle: bundle, diagnostics: [diagnostic]);
  }

  /// 文件在但解析不了：所有字段记为「解析失败」，而不是「缺失」。
  ///
  /// 这个区分很重要：`absent` 会让用户以为应用没有这些信息，而真相是我们
  /// 读不出来 —— 后者需要用户去查文件，前者不需要。
  static IpaInfoPlist _allFailed(
      IosBundle bundle, AnalysisDiagnostic diagnostic) {
    final failed = FieldValue<String>.failed(
      diagnostic: diagnostic.message,
      source: FieldSource.infoPlist,
    );
    return IpaInfoPlist(
      bundle: bundle,
      bundleIdentifier: failed,
      displayName: failed,
      bundleName: failed,
      shortVersionString: failed,
      bundleVersion: failed,
      executable: failed,
      minimumOSVersion: failed,
      deviceFamily: FieldValue<List<int>>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      queriesSchemes: FieldValue<List<String>>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      requiredDeviceCapabilities: FieldValue<List<String>>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      icons: FieldValue<IosIconConfiguration>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      diagnostics: [diagnostic],
    );
  }
}
