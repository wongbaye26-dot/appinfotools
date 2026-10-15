import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';

import 'cms.dart';
import 'ipa_container.dart';
import 'plist/plist_fields.dart';
import 'plist/plist_parser.dart';
import 'plist/plist_value.dart';
import 'plist/xml_plist_parser.dart' show PlistParseException;

/// 描述文件里的一条授权（Entitlement）。
///
/// 保持**原始的 plist 类型**，不提前拍平成字符串：`get-task-allow` 是布尔、
/// `aps-environment` 是字符串、某些授权是数组，把它们都变成字符串会让
/// 「是 `false` 还是字符串 `"false"`」这类区别消失。
class IosEntitlement {
  final String key;
  final PlistValue value;

  const IosEntitlement({required this.key, required this.value});

  /// 供 UI 展示的文本形式。
  String get valueText => _describe(value);

  @override
  String toString() => '$key = $valueText';

  static String _describe(PlistValue value) => switch (value) {
        PlistString(:final value) => value,
        PlistInteger(:final value) => '$value',
        PlistReal(:final value) => '$value',
        PlistBoolean(:final value) => '$value',
        PlistDate(:final value) => value.toUtc().toIso8601String(),
        PlistData(:final value) => '<${value.length} bytes>',
        PlistArray(:final value) => value.map(_describe).join(', '),
        PlistDict(:final value) => value.keys.join(', '),
      };
}

/// `embedded.mobileprovision` 的**静态**内容。
///
/// 这个文件是一个 CMS/PKCS#7 `SignedData`，里面裹着一段 plist。本类只把那段
/// plist 读出来并提取字段。
///
/// **不验证 CMS 签名。** 规范 5.5 禁止自行实现签名算法并宣称权威结论；
/// 描述文件是否可信、是否被篡改，只有 `codesign` / 系统信任链能回答。
/// 因此本类产出的每个字段都只是「文件里写了什么」，不是「已被认可」。
class IosProvisioningProfile {
  /// `Name` —— 描述文件的显示名。
  final FieldValue<String> name;

  /// `AppIDName` —— 描述文件创建时的 App ID 名称。
  final FieldValue<String> appIdName;

  /// `TeamIdentifier` —— 团队标识符数组。
  ///
  /// 现实中通常只有一个元素，但它是数组，不假设长度。
  final FieldValue<List<String>> teamIdentifiers;

  /// `ApplicationIdentifierPrefix` —— 应用标识前缀数组。
  final FieldValue<List<String>> applicationIdentifierPrefixes;

  /// `UUID` —— 描述文件的唯一标识。
  final FieldValue<String> uuid;

  /// `CreationDate`。
  final FieldValue<DateTime> creationDate;

  /// `ExpirationDate` —— 描述文件的有效期截止时间。
  final FieldValue<DateTime> expirationDate;

  /// `Entitlements.application-identifier`，形如 `ABCDE12345.com.example.app`。
  ///
  /// 单独提出来是因为它正是「应用声明的 bundle id 是否被授权」的比较对象。
  final FieldValue<String> applicationIdentifier;

  /// 全部授权项，保持 plist 中的顺序。
  final List<IosEntitlement> entitlements;

  /// 完整的 `Entitlements` 字典；缺失或类型不符时为 `null`。
  ///
  /// 保留原始字典是为了让未建模的授权键仍可被查看，而不必为每个冷门键
  /// 都加一个字段。
  final PlistDict? entitlementsRaw;

  const IosProvisioningProfile({
    this.name =
        const FieldValue<String>.absent(source: FieldSource.signatureMaterials),
    this.appIdName =
        const FieldValue<String>.absent(source: FieldSource.signatureMaterials),
    this.teamIdentifiers = const FieldValue<List<String>>.absent(
        source: FieldSource.signatureMaterials),
    this.applicationIdentifierPrefixes = const FieldValue<List<String>>.absent(
        source: FieldSource.signatureMaterials),
    this.uuid =
        const FieldValue<String>.absent(source: FieldSource.signatureMaterials),
    this.creationDate = const FieldValue<DateTime>.absent(
        source: FieldSource.signatureMaterials),
    this.expirationDate = const FieldValue<DateTime>.absent(
        source: FieldSource.signatureMaterials),
    this.applicationIdentifier =
        const FieldValue<String>.absent(source: FieldSource.signatureMaterials),
    this.entitlements = const [],
    this.entitlementsRaw,
  });

  /// 描述文件在 [moment] 时点是否已过期。
  ///
  /// 返回 `null` 表示**无法判断** —— 没读到有效期，或者读到的是类型错误的
  /// 值。此时不能给出「有效」或「已过期」中的任何一个。
  ///
  /// 刻意接收时间参数而不读系统时钟：这样测试可以固定时点，UI 也能在一次
  /// 渲染里用同一个时刻，不会因为跨过零点而自相矛盾。
  bool? isExpiredAt(DateTime moment) {
    final expiry = expirationDate.value;
    if (expiry == null) return null;
    return moment.toUtc().isAfter(expiry.toUtc());
  }

  /// 是否有任何字段被成功提取。
  bool get hasAnyValue => [
        name,
        appIdName,
        teamIdentifiers,
        applicationIdentifierPrefixes,
        uuid,
        creationDate,
        expirationDate,
        applicationIdentifier,
      ].any((f) => f.hasValue);
}

/// 一个 bundle 的签名材料及其静态解读。
///
/// 「材料」与「结论」在这里是分开的两件事：
/// - [hasCodeSignatureDirectory]、[codeSignatureEntries]、[hasEmbeddedProvision]
///   是**观察到的事实**；
/// - [verificationStatus] 是**结论**，而本包只做静态提取，因此它恒为
///   [SignatureStatus.toolUnavailable]（有材料）或 [SignatureStatus.unknown]
///   （没有材料）。真正的结论由调用方交给 `codesign` 得出。
class IosSignatureMaterials {
  final IosBundle bundle;

  /// 是否存在 `_CodeSignature/` 目录。
  final bool hasCodeSignatureDirectory;

  /// `_CodeSignature/` 下的条目名（相对该目录，已排序）。
  ///
  /// 正常应含 `CodeResources`；`CodeDirectory`、`CodeRequirements`、
  /// `CodeSignature` 是否单独成文件随签名版本而异，因此只如实列出。
  final List<String> codeSignatureEntries;

  /// 是否存在 `embedded.mobileprovision`。
  ///
  /// **缺失不代表异常**：App Store 分发的 IPA 不包含这个文件（授权信息在
  /// 签名里），因此它只能作为「有/没有」的事实，不能作为判断依据。
  final bool hasEmbeddedProvision;

  /// `embedded.mobileprovision` 声明的字节数；不存在时为 `null`。
  final int? embeddedProvisionSize;

  /// 描述文件的静态内容。
  ///
  /// 文件不存在时状态为 [FieldStatus.absent]；存在但读不出来时状态是
  /// [FieldStatus.failed] 或 [FieldStatus.wrongType] —— 两者含义不同，
  /// 分开记录。
  final FieldValue<IosProvisioningProfile> profile;

  /// 签名结论。本包无法给出权威结论，取值见类文档。
  final SignatureStatus verificationStatus;

  /// [verificationStatus] 的人类可读说明。
  final String? verificationDetail;

  /// `_CodeSignature/CodeResources` 的**结构**概况；没有该文件时为 `null`。
  ///
  /// 它回答「这个 bundle 声称密封了多少个文件」——**不回答密封是否有效**。
  /// 后者要逐文件重算哈希并与签名比对，属于签名验证，本包不做。
  final IosCodeResourcesSummary? codeResources;

  /// 描述文件 CMS 里的**证书链公开信息**；没有描述文件或读不出来时为 `null`。
  ///
  /// 同样只是材料：它说明「签名里带了哪些证书、自称是谁签的」，
  /// **不能**说明证书可信，更不能说明签名有效。
  final CmsCertificateInfo? certificateChain;

  final List<AnalysisDiagnostic> diagnostics;

  const IosSignatureMaterials({
    required this.bundle,
    this.hasCodeSignatureDirectory = false,
    this.codeSignatureEntries = const [],
    this.hasEmbeddedProvision = false,
    this.embeddedProvisionSize,
    this.profile = const FieldValue<IosProvisioningProfile>.absent(
        source: FieldSource.signatureMaterials),
    this.verificationStatus = SignatureStatus.unknown,
    this.verificationDetail,
    this.codeResources,
    this.certificateChain,
    this.diagnostics = const [],
  });

  /// 是否找到了任何签名材料。
  bool get hasAnyMaterial => hasCodeSignatureDirectory || hasEmbeddedProvision;

  /// 材料存在，但**没有任何工具验证过**。
  bool get isVerified => verificationStatus == SignatureStatus.verified;

  @override
  String toString() => 'IosSignatureMaterials(${bundle.path}, '
      'codeSignature: $hasCodeSignatureDirectory, '
      'provision: $hasEmbeddedProvision, '
      'status: ${verificationStatus.name})';
}

/// 应用声明与描述文件授权之间的关系。
///
/// 规范 5.5 要求「在能可靠解析时说明应用声明与描述文件授权的差异」。这里只
/// 比较**字符串**：应用的 `CFBundleIdentifier` 是否落在描述文件授权的
/// `application-identifier` 范围内。这是一个纯粹的字符串关系判断，
/// **不是**签名验证，也不能替代签名验证 —— 描述文件本身是否被篡改、
/// 是否被系统信任，本包无从得知。
enum IosAuthorizationVerdict {
  /// 完全一致。
  matches,

  /// 描述文件是通配符授权（`TEAM.*`），且应用标识落在该前缀下。
  wildcardMatch,

  /// 描述文件授权的是另一个应用标识。
  mismatch,

  /// 无法比较（缺少任一侧的值，或值类型不符）。
  incomparable,
}

/// 一次应用标识与描述文件授权的比较结果。
class IosAuthorizationComparison {
  final IosAuthorizationVerdict verdict;

  /// 应用声明的标识（`CFBundleIdentifier`）。
  final String? appIdentifier;

  /// 描述文件授权的标识（`Entitlements.application-identifier`）。
  final String? authorizedIdentifier;

  /// 补充说明：为什么无法比较、或者差异在哪。
  final String? note;

  const IosAuthorizationComparison({
    required this.verdict,
    this.appIdentifier,
    this.authorizedIdentifier,
    this.note,
  });

  /// 是否一致（含通配符授权）。
  bool get isConsistent =>
      verdict == IosAuthorizationVerdict.matches ||
      verdict == IosAuthorizationVerdict.wildcardMatch;

  /// 是否拿到了可比较的结论。
  bool get isConclusive => verdict != IosAuthorizationVerdict.incomparable;

  @override
  String toString() => 'IosAuthorizationComparison(${verdict.name}, '
      'app: $appIdentifier, authorized: $authorizedIdentifier)';
}

/// 比较应用声明的标识与描述文件授权的标识。
///
/// 两侧都取不到值、或取到的值不完整时返回 [IosAuthorizationVerdict.incomparable]
/// 并给出原因 —— **不猜测、不假设「大概是匹配的」**。
///
/// 匹配规则必须考虑标识的构成：描述文件里的 `application-identifier` 是
/// **`<App ID 前缀>.<bundle id>`**，而 `CFBundleIdentifier` 只有 `<bundle id>`。
/// 直接做字符串相等会让每一个正常应用都被判成「授权的是别的应用」——
/// 那比不比较更糟。因此按后缀比较，通配符单独处理。
IosAuthorizationComparison compareIosAuthorization({
  required FieldValue<String> bundleIdentifier,
  required IosProvisioningProfile profile,
}) {
  final appId = bundleIdentifier.value;
  final authorized = profile.applicationIdentifier.value;

  if (appId == null) {
    return IosAuthorizationComparison(
      verdict: IosAuthorizationVerdict.incomparable,
      authorizedIdentifier: authorized,
      note: 'the app declares no usable CFBundleIdentifier '
          '(${bundleIdentifier.status.name})',
    );
  }
  if (authorized == null) {
    return IosAuthorizationComparison(
      verdict: IosAuthorizationVerdict.incomparable,
      appIdentifier: appId,
      note: 'the profile declares no usable application-identifier '
          '(${profile.applicationIdentifier.status.name})',
    );
  }

  // 授权标识本身就是应用标识（描述文件不带前缀的少见写法）。
  if (authorized == appId) {
    return IosAuthorizationComparison(
      verdict: IosAuthorizationVerdict.matches,
      appIdentifier: appId,
      authorizedIdentifier: authorized,
    );
  }

  // 标准写法：`<App ID 前缀>.<bundle id>`。
  if (authorized.endsWith('.$appId')) {
    return IosAuthorizationComparison(
      verdict: IosAuthorizationVerdict.matches,
      appIdentifier: appId,
      authorizedIdentifier: authorized,
      note: 'the profile grants $authorized, whose bundle id part is $appId',
    );
  }

  // 通配符授权：`<App ID 前缀>.*` 覆盖该前缀下的任意应用标识。
  //
  // 结论只能是「覆盖」，不能是「确认」：通配符并没有点名这个应用标识，
  // 而应用侧无法从这两个值里独立验证前缀归属。如实说明这一点。
  if (authorized == '*' || authorized.endsWith('.*')) {
    return IosAuthorizationComparison(
      verdict: IosAuthorizationVerdict.wildcardMatch,
      appIdentifier: appId,
      authorizedIdentifier: authorized,
      note: 'the profile grants the wildcard $authorized, which covers any '
          'bundle id under that prefix; it does not pin $appId specifically',
    );
  }

  return IosAuthorizationComparison(
    verdict: IosAuthorizationVerdict.mismatch,
    appIdentifier: appId,
    authorizedIdentifier: authorized,
    note: 'the profile grants $authorized, but the app declares $appId',
  );
}

/// 读取一个 bundle 的签名材料。
///
/// **只读，不解压到磁盘，不执行任何外部命令。** 因此这一层既没有路径穿越
/// 风险，也不会因为没有 `codesign` 而失败。
class IpaSignatureMaterialReader {
  IpaSignatureMaterialReader._();

  /// `embedded.mobileprovision` 的大小上限（16 MiB）。
  ///
  /// 真实描述文件只有几 KB。超过这个量级说明它多半不是描述文件，拒绝读取
  /// 而不是继续分配内存。
  static const int maxProvisionBytes = 16 * 1024 * 1024;

  /// `CodeResources` 的大小上限（8 MiB）。
  ///
  /// 真实的大应用也就几百 KB。超过说明这不是一份正常的密封清单，
  /// 拒绝解析而不是继续分配内存。
  static const int maxCodeResourcesBytes = 8 * 1024 * 1024;

  static const String _codeSignatureDir = '_CodeSignature/';

  static const String _provisionName = 'embedded.mobileprovision';

  static IosSignatureMaterials read(Archive archive, IosBundle bundle) {
    final prefix = '${bundle.path}/';

    final codeSignatureEntries = <String>[];
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (!name.startsWith(prefix)) continue;
      final relative = name.substring(prefix.length);
      if (relative.startsWith(_codeSignatureDir) &&
          relative.length > _codeSignatureDir.length) {
        codeSignatureEntries.add(relative.substring(_codeSignatureDir.length));
      }
    }
    codeSignatureEntries.sort();

    final provisionPath = '$prefix$_provisionName';
    final provisionEntry = archive.findFile(provisionPath);

    final hasCodeSignature = codeSignatureEntries.isNotEmpty;
    final hasProvision = provisionEntry != null;

    final diagnostics = <AnalysisDiagnostic>[];
    final codeResources = _readCodeResources(archive, prefix, diagnostics);
    final certificateChain = hasProvision
        ? _readCertificates(archive, provisionPath, diagnostics)
        : null;
    final profile = hasProvision
        ? _readProfile(archive, provisionPath, diagnostics)
        : const FieldValue<IosProvisioningProfile>.absent(
            source: FieldSource.signatureMaterials,
          );

    if (!hasCodeSignature) {
      // 只作为事实记录。App Store 分发的包一定有 `_CodeSignature/`，
      // 缺失值得注意，但**不能**据此判定为恶意 —— 容器可能只是被重新打包过。
      diagnostics.add(
        AnalysisDiagnostic.warning(
          'ios.signature.no_code_signature_dir',
          '${bundle.path} has no $_codeSignatureDir directory',
          source: FieldSource.signatureMaterials,
        ),
      );
    }

    final status = hasCodeSignature || hasProvision
        ? SignatureStatus.toolUnavailable
        : SignatureStatus.unknown;
    final detail = switch (status) {
      SignatureStatus.toolUnavailable =>
        'signature material was found, but no signature verification tool '
            'was run; the materials alone do not prove the signature is valid',
      _ => 'no $_codeSignatureDir or $_provisionName was found in '
          '${bundle.path}; the signature could not be assessed',
    };

    return IosSignatureMaterials(
      bundle: bundle,
      hasCodeSignatureDirectory: hasCodeSignature,
      codeSignatureEntries: codeSignatureEntries,
      hasEmbeddedProvision: hasProvision,
      embeddedProvisionSize: provisionEntry?.size,
      profile: profile,
      codeResources: codeResources,
      certificateChain: certificateChain,
      verificationStatus: status,
      verificationDetail: detail,
      diagnostics: diagnostics,
    );
  }

  /// 读取并解析 `_CodeSignature/CodeResources`。
  ///
  /// 它是一个 plist：`files` / `files2` 是**密封清单**（路径 → 哈希信息），
  /// `rules` / `rules2` 是匹配规则。这里只数条目，**不重算哈希** ——
  /// 重算并与签名比对属于验证，本包不做（规范 5.5）。
  static IosCodeResourcesSummary? _readCodeResources(
    Archive archive,
    String prefix,
    List<AnalysisDiagnostic> diagnostics,
  ) {
    const name = 'CodeResources';
    final entry = archive.findFile('$prefix$_codeSignatureDir$name');
    if (entry == null) return null;

    final bytes = entry.content;
    if (bytes.length > maxCodeResourcesBytes) {
      const message =
          'CodeResources is above the size limit and was not parsed';
      diagnostics.add(
        AnalysisDiagnostic.warning(
          'ios.coderesources.too_large',
          message,
          source: FieldSource.signatureMaterials,
        ),
      );
      return const IosCodeResourcesSummary(parseFailure: message);
    }

    try {
      final value = PlistParser.parse(bytes);
      if (value is! PlistDict) {
        const message = 'CodeResources is not a plist dictionary';
        diagnostics.add(
          AnalysisDiagnostic.warning(
            'ios.coderesources.not_a_dict',
            message,
            source: FieldSource.signatureMaterials,
          ),
        );
        return const IosCodeResourcesSummary(parseFailure: message);
      }
      final files = value.value['files'];
      final files2 = value.value['files2'];
      final rules = value.value['rules'];
      final rules2 = value.value['rules2'];
      int sizeOf(Object? node) => node is PlistDict ? node.value.length : 0;

      return IosCodeResourcesSummary(
        fileCount: sizeOf(files),
        file2Count: sizeOf(files2),
        ruleCount: sizeOf(rules) + sizeOf(rules2),
        isV2: files2 is PlistDict,
      );
    } catch (e) {
      // 畸形 plist 不该让整个解析失败 —— 记一条诊断，其余材料照常给出。
      final message = 'CodeResources could not be parsed: $e';
      diagnostics.add(
        AnalysisDiagnostic.warning(
          'ios.coderesources.unparsable',
          message,
          source: FieldSource.signatureMaterials,
        ),
      );
      return IosCodeResourcesSummary(parseFailure: message);
    }
  }

  /// 读取描述文件 CMS 里的证书链公开信息。
  static CmsCertificateInfo? _readCertificates(
    Archive archive,
    String path,
    List<AnalysisDiagnostic> diagnostics,
  ) {
    final entry = archive.findFile(path);
    if (entry == null) return null;
    final bytes = entry.content;

    // 注意：这里喂进去的必须是**CMS 原文**，不是 `extract` 出来的载荷。
    // 载荷是描述文件 plist，里面当然没有证书 —— 早先写成
    // `extractCertificates(extracted.content!)`，于是真实 Apple 描述文件
    // （openssl 说链上有 3 张证书）在这里恒定解出 0 张。
    final info = CmsContentExtractor.extractCertificates(bytes);
    if (info.failure != null) {
      diagnostics.add(
        AnalysisDiagnostic.info(
          'ios.provision.certificates_unreadable',
          'the certificate chain could not be read: ${info.failure}',
          source: FieldSource.signatureMaterials,
        ),
      );
    } else if (info.hasUnparsableCertificates) {
      diagnostics.add(
        AnalysisDiagnostic.info(
          'ios.provision.certificates_unparsable',
          '${info.entryCount} certificate(s) were present but their public '
              'fields could not be read',
          source: FieldSource.signatureMaterials,
        ),
      );
    }
    return info;
  }

  /// 读取并解析 `embedded.mobileprovision`。
  static FieldValue<IosProvisioningProfile> _readProfile(
    Archive archive,
    String path,
    List<AnalysisDiagnostic> diagnostics,
  ) {
    final entry = archive.findFile(path);
    if (entry == null) {
      // 容器层说有、归档里却没有 —— 内部不一致。
      const message =
          'embedded.mobileprovision was listed but could not be read';
      diagnostics.add(
        AnalysisDiagnostic.error(
          'ios.provision.vanished',
          message,
          source: FieldSource.signatureMaterials,
        ),
      );
      return const FieldValue<IosProvisioningProfile>.failed(
        diagnostic: message,
        source: FieldSource.signatureMaterials,
      );
    }

    if (entry.size > maxProvisionBytes) {
      final message = '$path declares ${entry.size} bytes, above the '
          '$maxProvisionBytes byte limit';
      diagnostics.add(
        AnalysisDiagnostic.warning(
          'ios.provision.too_large',
          message,
          source: FieldSource.signatureMaterials,
        ),
      );
      return FieldValue<IosProvisioningProfile>.failed(
        diagnostic: message,
        source: FieldSource.signatureMaterials,
      );
    }

    final content = entry.content;
    if (content.length > maxProvisionBytes) {
      // 走到这里说明 ZIP 头声明的尺寸小于上限、实际解出更多 —— 头部在撒谎。
      //
      // 已知局限：此时内存**已经**分配了。归档层的预算只统计声明尺寸，
      // 无法阻止这种情况；这里能做的是拒绝解析并如实报告。
      final message = '$path declared ${entry.size} bytes but decompressed to '
          '${content.length}; refusing to parse it';
      diagnostics.add(
        AnalysisDiagnostic.error(
          'ios.provision.size_lie',
          message,
          source: FieldSource.signatureMaterials,
        ),
      );
      return FieldValue<IosProvisioningProfile>.failed(
        diagnostic: message,
        source: FieldSource.signatureMaterials,
      );
    }

    // 第一步：从 CMS 外壳里取出 plist 字节。这一步不做任何密码学验证。
    final extracted = CmsContentExtractor.extract(content);
    if (!extracted.ok) {
      final message = '$path could not be unwrapped from its CMS container: '
          '${extracted.failure}';
      diagnostics.add(
        AnalysisDiagnostic.error(
          'ios.provision.cms_unreadable',
          message,
          source: FieldSource.signatureMaterials,
        ),
      );
      return FieldValue<IosProvisioningProfile>.failed(
        diagnostic: message,
        source: FieldSource.signatureMaterials,
      );
    }

    // 第二步：解析 plist。可能是 XML，也可能是二进制。
    final PlistValue parsed;
    try {
      parsed = PlistParser.parse(extracted.content!);
    } on PlistParseException catch (e) {
      final message =
          'the plist inside $path could not be parsed: ${e.message}';
      diagnostics.add(
        AnalysisDiagnostic.error(
          'ios.provision.unparsable',
          message,
          source: FieldSource.signatureMaterials,
        ),
      );
      return FieldValue<IosProvisioningProfile>.failed(
        diagnostic: message,
        source: FieldSource.signatureMaterials,
      );
    }

    if (parsed is! PlistDict) {
      final message = 'the plist inside $path is ${parsed.typeName}, '
          'expected a dictionary';
      diagnostics.add(
        AnalysisDiagnostic.error(
          'ios.provision.not_a_dict',
          message,
          source: FieldSource.signatureMaterials,
        ),
      );
      return FieldValue<IosProvisioningProfile>.failed(
        diagnostic: message,
        source: FieldSource.signatureMaterials,
      );
    }

    final profile = _extract(parsed, path, diagnostics);
    return FieldValue<IosProvisioningProfile>.extracted(
      profile,
      source: FieldSource.signatureMaterials,
    );
  }

  /// 从描述文件 plist 里提取字段。
  static IosProvisioningProfile _extract(
    PlistDict root,
    String path,
    List<AnalysisDiagnostic> diagnostics,
  ) {
    diagnostics.add(
      AnalysisDiagnostic.info(
        'ios.provision.parsed',
        'parsed $path (${root.value.length} keys)',
        source: FieldSource.signatureMaterials,
      ),
    );

    const source = FieldSource.signatureMaterials;
    final (entitlementsDict, entitlementDiagnostic) =
        PlistFields.dict(root, 'Entitlements', source: source);
    if (entitlementDiagnostic != null) {
      diagnostics.add(entitlementDiagnostic);
    }

    final entitlements = <IosEntitlement>[
      if (entitlementsDict != null)
        for (final entry in entitlementsDict.value.entries)
          IosEntitlement(key: entry.key, value: entry.value),
    ];

    // `application-identifier` 按文档是字符串，但历史上出现过被写成整数或
    // 其他类型的情况；这里用严格取字符串，类型不符时如实记录而不是转换。
    final applicationIdentifier = entitlementsDict == null
        ? const FieldValue<String>.absent(source: source)
        : PlistFields.strictString(
            entitlementsDict,
            'application-identifier',
            source: source,
          );

    return IosProvisioningProfile(
      name: PlistFields.strictString(root, 'Name', source: source),
      appIdName: PlistFields.strictString(root, 'AppIDName', source: source),
      teamIdentifiers:
          PlistFields.stringList(root, 'TeamIdentifier', source: source),
      applicationIdentifierPrefixes: PlistFields.stringList(
        root,
        'ApplicationIdentifierPrefix',
        source: source,
      ),
      uuid: PlistFields.strictString(root, 'UUID', source: source),
      creationDate: PlistFields.date(root, 'CreationDate', source: source),
      expirationDate: PlistFields.date(root, 'ExpirationDate', source: source),
      applicationIdentifier: applicationIdentifier,
      entitlements: entitlements,
      entitlementsRaw: entitlementsDict,
    );
  }
}

/// `_CodeSignature/CodeResources` 的结构概况。
///
/// **这是材料，不是结论**：它说明「密封清单里列了多少个文件与规则」。
/// 「这些文件的哈希是否与签名一致」需要逐文件重算，本包不做。
class IosCodeResourcesSummary {
  /// `files` 里的条目数（v1 密封清单）。
  final int fileCount;

  /// `files2` 里的条目数（v2 密封清单，带规则）。
  final int file2Count;

  /// `rules` 与 `rules2` 的规则数之和。
  final int ruleCount;

  /// 是否含 `files2`（v2 格式）。
  final bool isV2;

  /// 解析失败的原因；成功时为 `null`。
  final String? parseFailure;

  const IosCodeResourcesSummary({
    this.fileCount = 0,
    this.file2Count = 0,
    this.ruleCount = 0,
    this.isV2 = false,
    this.parseFailure,
  });

  /// 密封清单里的文件总数。
  int get sealedFileCount => fileCount + file2Count;

  bool get isParsed => parseFailure == null;

  @override
  String toString() => 'IosCodeResourcesSummary(sealed: $sealedFileCount, '
      'rules: $ruleCount, v2: $isV2${isParsed ? '' : ', failed'})';
}
