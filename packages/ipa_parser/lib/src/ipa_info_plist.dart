import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';

import 'ipa_container.dart';
import 'plist/plist_fields.dart';
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
  String toString() => 'IosIconSet(files: $iconFiles, name: $iconName)';
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
/// `PrivacyInfo.xcprivacy` 隐私清单的摘要。
///
/// 只取与隐私检测相关的三类内容：是否声明追踪、追踪域名、声明的收集数据类型。
/// **不解释、不定级** —— 规格 4.4 明确它是声明性材料， interpretations 属于
/// 审计器（`ios_privacy_audit`）的职责。
class IosPrivacyInfo {
  /// `NSPrivacyTracking`：应用是否声明自己会跟踪用户。
  final bool? tracking;

  /// `NSPrivacyTrackingDomains`。
  final List<String> trackingDomains;

  /// `NSPrivacyCollectedDataTypes[].NSPrivacyCollectedDataType` 的去重列表，
  /// 例如 `NSPrivacyCollectedDataTypePhotos`。
  final List<String> collectedDataTypes;

  const IosPrivacyInfo({
    this.tracking,
    this.trackingDomains = const [],
    this.collectedDataTypes = const [],
  });

  bool get isEmpty =>
      tracking == null && trackingDomains.isEmpty && collectedDataTypes.isEmpty;
}

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

  /// `UIBackgroundModes`：声明申请的后台执行模式。
  ///
  /// 取值是 `audio` / `location` / `fetch` / `remote-notification` / `voip` /
  /// `processing` / `bluetooth-central` 等。它是**声明性事实**：申请了某个
  /// 模式不等于运行时真的在后台跑，但「后台执行 + 敏感读取 + 回传」这个组合
  /// 是规则 E 的输入。
  final FieldValue<List<String>> backgroundModes;

  /// `CFBundleURLTypes` 里注册的 URL scheme。
  ///
  /// 这些是**外部可以唤起本应用**的入口（`myapp://…`），属于攻击面的事实
  /// 描述。只取 scheme，不取 `CFBundleURLName` —— 后者只是展示名。
  final FieldValue<List<String>> urlSchemes;

  final FieldValue<IosIconConfiguration> icons;

  /// `NS*UsageDescription` 系列键：用途说明键名 → 说明原文。
  ///
  /// 规格 4.2 的关键点：**有用途说明不代表一定使用了该能力，没有用途说明
  /// 也不等于发生了恶意访问**。因此这里只记录「声明了什么」，是否使用由
  /// `ios_privacy_audit` 结合 Mach-O 符号线索判断。
  final FieldValue<Map<String, String>> privacyUsageDescriptions;

  /// `NSAppTransportSecurity.NSAllowsArbitraryLoads`（ATS 明文放行开关）。
  ///
  /// 三态：未声明、显式 true、显式 false。与 Android 的
  /// `usesCleartextTraffic` 同一口径 —— 不把「未声明」折算成任何值。
  final FieldValue<bool> allowsArbitraryLoads;

  /// ATS 例外域名（`NSExceptionDomains` 的键）。
  final FieldValue<List<String>> atsExceptionDomains;

  /// `PrivacyInfo.xcprivacy` 隐私清单的摘要。
  ///
  /// 规格 4.4：隐私清单是**声明性材料**，不等于系统已证实的实际数据访问
  /// 行为。因此它只是事实记录，不能据此声称应用「确实收集了」某些数据。
  final FieldValue<IosPrivacyInfo> privacyInfo;

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
    this.backgroundModes = const FieldValue<List<String>>.absent(),
    this.urlSchemes = const FieldValue<List<String>>.absent(),
    this.icons = const FieldValue<IosIconConfiguration>.absent(),
    this.privacyUsageDescriptions =
        const FieldValue<Map<String, String>>.absent(),
    this.allowsArbitraryLoads = const FieldValue<bool>.absent(),
    this.atsExceptionDomains = const FieldValue<List<String>>.absent(),
    this.privacyInfo = const FieldValue<IosPrivacyInfo>.absent(),
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
        privacyUsageDescriptions,
        allowsArbitraryLoads,
        atsExceptionDomains,
        privacyInfo,
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

    return _extract(archive, bundle, parsed, path);
  }

  static IpaInfoPlist _extract(
      Archive archive, IosBundle bundle, PlistDict root, String path) {
    final diagnostics = <AnalysisDiagnostic>[
      AnalysisDiagnostic.info(
        'ios.info_plist.parsed',
        'parsed $path (${root.value.length} keys)',
        source: FieldSource.infoPlist,
      ),
    ];

    // 取值规则统一走 PlistFields —— 与描述文件 plist 用的是同一份实现。
    const source = FieldSource.infoPlist;

    return IpaInfoPlist(
      bundle: bundle,
      raw: root,
      bundleIdentifier:
          PlistFields.strictString(root, 'CFBundleIdentifier', source: source),
      displayName:
          PlistFields.strictString(root, 'CFBundleDisplayName', source: source),
      bundleName:
          PlistFields.strictString(root, 'CFBundleName', source: source),
      shortVersionString: PlistFields.strictString(
          root, 'CFBundleShortVersionString',
          source: source),
      bundleVersion:
          PlistFields.numberOrString(root, 'CFBundleVersion', source: source),
      executable:
          PlistFields.strictString(root, 'CFBundleExecutable', source: source),
      minimumOSVersion:
          PlistFields.strictString(root, 'MinimumOSVersion', source: source),
      deviceFamily: PlistFields.intList(root, 'UIDeviceFamily', source: source),
      queriesSchemes: PlistFields.stringList(
          root, 'LSApplicationQueriesSchemes',
          source: source),
      requiredDeviceCapabilities: PlistFields.stringList(
          root, 'UIRequiredDeviceCapabilities',
          source: source),
      backgroundModes:
          PlistFields.stringList(root, 'UIBackgroundModes', source: source),
      urlSchemes: _urlSchemes(root, source),
      icons: _icons(root),
      privacyUsageDescriptions: _usageDescriptions(root, source),
      allowsArbitraryLoads: _atsArbitraryLoads(root, source),
      atsExceptionDomains: _atsExceptionDomains(root, source),
      privacyInfo: _readPrivacyInfo(archive, bundle, diagnostics),
      diagnostics: diagnostics,
    );
  }

  /// `CFBundleURLTypes` 里注册的 URL scheme。
  ///
  /// 结构是**数组套字典**：每个字典里有 `CFBundleURLSchemes`（字符串数组）
  /// 与 `CFBundleURLName`（展示名）。
  ///
  /// 条目形状不对（不是字典、没有 `CFBundleURLSchemes`）时**如实跳过**，
  /// 不猜也不编；一个条目都没有时返回 `absent`（文件里确实没注册）。
  static FieldValue<List<String>> _urlSchemes(
    PlistValue root,
    FieldSource source,
  ) {
    final value = root.asDict?.value['CFBundleURLTypes'];
    if (value == null) {
      return FieldValue<List<String>>.absent(source: source);
    }
    final array = value.asArray;
    if (array == null) {
      return FieldValue<List<String>>.wrongType(
        diagnostic: 'CFBundleURLTypes is ${value.typeName}, expected array',
        diagnosticCode: 'plist.expected_array',
        diagnosticArgs: {'key': 'CFBundleURLTypes', 'actual': value.typeName},
        source: source,
      );
    }

    final schemes = <String>[];
    for (final entry in array.value) {
      final dict = entry.asDict;
      if (dict == null) continue;
      final entrySchemes = dict.value['CFBundleURLSchemes']?.asStringList;
      if (entrySchemes == null) continue;
      for (final scheme in entrySchemes) {
        if (scheme.isNotEmpty && !schemes.contains(scheme)) {
          schemes.add(scheme);
        }
      }
    }
    return FieldValue<List<String>>.extracted(schemes, source: source);
  }

  /// 用途说明键。
  ///
  /// 只收 `NS` 开头、`UsageDescription` 结尾的键 —— 这是 Apple 规定的
  /// 命名约定（`NSCameraUsageDescription`、`NSPhotoLibraryUsageDescription`…）。
  /// 不按一张写死的表列举：Apple 每加一个新受保护资源就可能加一个新键，
  /// 约定比清单更难过期。值是原文（未截断），供人工阅读。
  static FieldValue<Map<String, String>> _usageDescriptions(
      PlistDict root, FieldSource source) {
    final found = <String, String>{};
    for (final entry in root.value.entries) {
      final key = entry.key;
      if (!key.startsWith('NS') || !key.endsWith('UsageDescription')) continue;
      final text = entry.value.asString;
      if (text == null || text.trim().isEmpty) {
        // 键在但值不是字符串：如实记为空串，让调用方看到「声明了却读不出内容」。
        found[key] = '';
      } else {
        found[key] = text;
      }
    }
    if (found.isEmpty) {
      return FieldValue<Map<String, String>>.absent(source: source);
    }
    return FieldValue<Map<String, String>>.extracted(found, source: source);
  }

  /// `NSAppTransportSecurity.NSAllowsArbitraryLoads`。
  static FieldValue<bool> _atsArbitraryLoads(
      PlistDict root, FieldSource source) {
    final ats = root.value['NSAppTransportSecurity'];
    if (ats is! PlistDict) return FieldValue<bool>.absent(source: source);
    final allows = ats.value['NSAllowsArbitraryLoads'];
    if (allows is! PlistValue) {
      return FieldValue<bool>.absent(source: source);
    }
    final value = allows.asBool;
    if (value == null) {
      return FieldValue<bool>.wrongType(
        source: source,
        diagnostic: 'NSAllowsArbitraryLoads is not a boolean',
        diagnosticCode: 'plist.expected_boolean',
        diagnosticArgs: {'key': 'NSAllowsArbitraryLoads'},
      );
    }
    return FieldValue<bool>.extracted(value, source: source);
  }

  /// ATS 例外域名（不展开每个域内的具体例外设置 —— 那需要继续下钻
  /// `NSExceptionAllowsInsecureHTTPLoads` 等，规格只要求识别放行配置的存在）。
  static FieldValue<List<String>> _atsExceptionDomains(
      PlistDict root, FieldSource source) {
    final ats = root.value['NSAppTransportSecurity'];
    if (ats is! PlistDict) {
      return FieldValue<List<String>>.absent(source: source);
    }
    final domains = ats.value['NSExceptionDomains'];
    if (domains is! PlistDict) {
      return FieldValue<List<String>>.absent(source: source);
    }
    if (domains.value.isEmpty) {
      return FieldValue<List<String>>.absent(source: source);
    }
    return FieldValue<List<String>>.extracted(
      domains.value.keys.toList(),
      source: source,
    );
  }

  /// 读取 bundle 内的 `PrivacyInfo.xcprivacy`。
  ///
  /// 文件不存在是**正常情况**（不是每个应用都有隐私清单），记为 absent；
  /// 存在但解析失败记为 failed —— 两者的区别要留住。
  static FieldValue<IosPrivacyInfo> _readPrivacyInfo(
    Archive archive,
    IosBundle bundle,
    List<AnalysisDiagnostic> diagnostics,
  ) {
    const source = FieldSource.privacyInfo;
    final path = '${bundle.path}/PrivacyInfo.xcprivacy';
    final entry = archive.findFile(path);
    if (entry == null) {
      return const FieldValue<IosPrivacyInfo>.absent(source: source);
    }
    final content = entry.content;
    if (content.length > maxInfoPlistBytes) {
      diagnostics.add(AnalysisDiagnostic.warning(
        'ios.privacy_info.too_large',
        '$path declares ${content.length} bytes, above the limit',
      ));
      return const FieldValue<IosPrivacyInfo>.failed(
        source: source,
        diagnostic: 'PrivacyInfo.xcprivacy exceeds the size limit',
        diagnosticCode: 'privacy_manifest.too_large',
      );
    }
    final PlistValue parsed;
    try {
      parsed = PlistParser.parse(content);
    } on PlistParseException catch (e) {
      diagnostics.add(AnalysisDiagnostic.error(
        'ios.privacy_info.unparsable',
        '$path could not be parsed: ${e.message}',
      ));
      return FieldValue<IosPrivacyInfo>.failed(
        source: source,
        diagnostic: '$path could not be parsed: ${e.message}',
        diagnosticCode: 'plist.parse_failed',
        diagnosticArgs: {'path': path, 'message': e.message},
      );
    }
    if (parsed is! PlistDict) {
      return FieldValue<IosPrivacyInfo>.failed(
        source: source,
        diagnostic: '$path root is ${parsed.typeName}, expected a dictionary',
        diagnosticCode: 'plist.root_not_dictionary',
        diagnosticArgs: {'path': path, 'actual': parsed.typeName},
      );
    }

    final tracking = parsed.value['NSPrivacyTracking'];
    final trackingDomains =
        (parsed.value['NSPrivacyTrackingDomains']).asStringList ?? const [];
    final collectedRaw = parsed.value['NSPrivacyCollectedDataTypes'];
    final collectedTypes = <String>{};
    if (collectedRaw is PlistArray) {
      for (final item in collectedRaw.value) {
        if (item is! PlistDict) continue;
        final type = item.value['NSPrivacyCollectedDataType'];
        final text = type.asString;
        if (text != null) collectedTypes.add(text);
      }
    }

    final info = IosPrivacyInfo(
      tracking: tracking?.asBool,
      trackingDomains: trackingDomains,
      collectedDataTypes: collectedTypes.toList()..sort(),
    );
    if (info.isEmpty) {
      return const FieldValue<IosPrivacyInfo>.absent(source: source);
    }
    return FieldValue<IosPrivacyInfo>.extracted(info, source: source);
  }

  // ---------------------------------------------------------------------------
  // 字段提取
  // ---------------------------------------------------------------------------

  /// 提取图标配置。
  ///
  /// 这一块没有进 `PlistFields`：图标配置是 `Info.plist` 独有的嵌套结构
  /// （`CFBundleIcons` → `CFBundlePrimaryIcon` → …），不属于通用取值规则。
  static FieldValue<IosIconConfiguration> _icons(PlistDict root) {
    const source = FieldSource.infoPlist;
    final config = IosIconConfiguration(
      primary:
          _iconSetFrom(_dictAt(root, 'CFBundleIcons', 'CFBundlePrimaryIcon')),
      alternate: _alternateIcons(root),
      primaryIpad: _iconSetFrom(
          _dictAt(root, 'CFBundleIcons~ipad', 'CFBundlePrimaryIcon')),
      legacyIconFiles:
          PlistFields.stringList(root, 'CFBundleIconFiles', source: source)
                  .value ??
              const [],
      legacyIconFile:
          PlistFields.strictString(root, 'CFBundleIconFile', source: source)
              .value,
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
    const source = FieldSource.infoPlist;
    final set = IosIconSet(
      iconFiles:
          PlistFields.stringList(dict, 'CFBundleIconFiles', source: source)
                  .value ??
              const [],
      iconName:
          PlistFields.strictString(dict, 'CFBundleIconName', source: source)
              .value,
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
      backgroundModes: FieldValue<List<String>>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      urlSchemes: FieldValue<List<String>>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      icons: FieldValue<IosIconConfiguration>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      privacyUsageDescriptions: FieldValue<Map<String, String>>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      allowsArbitraryLoads: FieldValue<bool>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      atsExceptionDomains: FieldValue<List<String>>.failed(
        diagnostic: diagnostic.message,
        source: FieldSource.infoPlist,
      ),
      diagnostics: [diagnostic],
    );
  }
}
