import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

import '../ipa_container.dart';
import '../ipa_info_plist.dart';
import 'ios_native_symbol_audit.dart';

/// Mach-O 可执行文件的字符串线索扫描预算。
///
/// 与 Android 侧 `DexClueScanner` 的预算口径一致：先定上限再读，
/// 超限的部分如实记为未覆盖。
class _Budget {
  static const int maxBytes = 16 * 1024 * 1024;
  static const int minStringLength = 6;
  static const int maxSamplesPerMarker = 5;
}

/// 从 Mach-O 可执行文件里观察到的一类符号/字符串线索。
class _MachOClue {
  final String markerId;
  final String description;
  final List<String> samples;

  /// 命中出现在**哪些可执行文件**里（归档内路径）。
  ///
  /// 阶段 5b 起扫描范围包含嵌套 bundle，因此同一个标记可能来自多个文件 ——
  /// 报告里要能指出是哪一个，否则「扩展里有 OCR」这种结论无从核对。
  final List<String> sources;

  const _MachOClue(this.markerId, this.description, this.samples,
      {this.sources = const []});
}

/// 一个参与安全扫描的嵌套可执行文件。
///
/// 与 [IosNestedBinary]（解析层）分开：那一层关心「能不能解析」，
/// 这一层关心「有没有字节可以扫」。
class IosNestedExecutableInput {
  /// 可执行文件在归档中的路径（证据位置）。
  final String path;

  /// 所属 bundle 的路径。
  final String bundlePath;

  final IosBundleKind kind;

  /// 字节；`null` 表示没保留下来或读不到（原因见 [failure]）。
  final Uint8List? bytes;

  final String? failure;

  /// 该嵌套 bundle 自己 `Info.plist` 里的用途说明；`null` 表示没读到。
  ///
  /// 主应用的用途说明走 `infoPlist`，这里只放**嵌套 bundle 的** ——
  /// 扩展常常正是处理照片与 OCR 的地方，而主应用的 Info.plist 里可能
  /// 一条相册用途都没有。
  final Map<String, String>? usageDescriptions;

  const IosNestedExecutableInput({
    required this.path,
    required this.bundlePath,
    required this.kind,
    this.bytes,
    this.failure,
    this.usageDescriptions,
  });
}

/// iOS 侧隐私审计。
///
/// 与 Android 侧同样的分工：只读**已经解析好的** [IpaInfoPlist] 与主 Mach-O
/// 可执行文件的字节，不自己开归档，不做反汇编。
///
/// 与 Android 侧**不同**的地方（平台差异，不是实现偏好）：
/// - iOS 没有「权限清单」，只有 `Info.plist` 的用途说明键。因此
///   「应用是否可能访问某类数据」靠 Mach-O 里的 API 符号线索推断，
///   而用途说明与 API 线索是否吻合本身就是一条检测规则
///   （有 API 没说明 → P2）；
/// - `PHPickerViewController`（系统照片选择器）与 PhotoKit（完整照片库）
///   是两条不同的路径，Apple 明确前者不需要完整相册授权 —— 必须分开判断，
///   不能因为见到「照片」字样就把两者混为一谈；
/// - `PrivacyInfo.xcprivacy` 只是**声明性材料**，不等于系统已证实的
///   实际数据访问行为。
class IosPrivacyAudit {
  IosPrivacyAudit._();

  static const String engineVersion = 'ios-security-1.1.0';
  static const String rulesVersion = 'ios-privacy-2026.10.1';

  static final List<(String, String, String)> _markers = [
    // (id, 说明, 字面量) —— 与 Android 侧同样只用字面量，不用宽正则。
    ('photo-full-library', 'PhotoKit full photo library API', 'PHPhotoLibrary'),
    ('photo-asset', 'PHAsset media object API', 'PHAsset'),
    (
      'photo-picker',
      'PHPickerViewController (system photo picker)',
      'PHPickerViewController'
    ),
    ('photos-ui', 'PhotosUI framework reference', 'PhotosUI'),
    ('camera', 'AVCapture camera API', 'AVCapture'),
    ('ocr', 'Vision text recognition API', 'VNRecognizeText'),
    (
      'ocr-image-request',
      'Vision image request handler',
      'VNImageRequestHandler'
    ),
    ('clipboard', 'UIPasteboard clipboard API', 'UIPasteboard'),
    ('network-session', 'NSURLSession networking', 'NSURLSession'),
    ('network-upload', 'multipart form upload', 'multipart/form-data'),
    ('network-alamofire', 'Alamofire HTTP library', 'Alamofire'),
    ('network-afnetworking', 'AFNetworking HTTP library', 'AFNetworking'),
  ];

  /// [executableBytes] 为主 Mach-O 的内容；`null` 表示读不到
  /// （此时会在 limitations 里明确说明覆盖不足）。
  static SecurityAnalysisResult audit({
    required IpaInfoPlist infoPlist,
    Uint8List? executableBytes,
    String? executablePath,

    /// 嵌套 bundle 的可执行文件（扩展 / Watch / 框架）。
    ///
    /// 阶段 5b 起扫描范围不再只有主应用：App Extension 里的代码同样是这个
    /// 应用的一部分，而且扩展常常**正是**处理照片与 OCR 的地方。
    List<IosNestedExecutableInput> nestedExecutables = const [],
  }) {
    final findings = <SecurityFinding>[];
    final limitations = <AnalysisNote>[];

    // ---- 用途说明键：逐条事实记录 ----
    final usage = infoPlist.privacyUsageDescriptions;
    if (usage.hasValue) {
      for (final entry in usage.value!.entries) {
        findings.add(SecurityFinding(
          ruleId: 'IOS-USAGE-DESCRIPTION',
          platform: SecurityPlatform.ios,
          category: _categoryForKey(entry.key),
          severity: SecuritySeverity.info,
          confidence: SecurityConfidence.confirmed,
          // 已迁移到「稳定 code + 英文回退 + 参数」（B11）。没迁移的发现项
          // 仍按原文渲染，因此不会出现「英文界面下一半中文一半英文」。
          finding: 'Info.plist declares ${entry.key} '
              '(a usage description is provided).',
          messageCode: 'ios.usage_description',
          messageArgs: {'key': entry.key},
          evidence: [
            SecurityEvidence(
              source: SecurityEvidenceSource.infoPlist,
              location: '${infoPlist.bundle.path}/Info.plist / $entry.key',
              detail: entry.value.isEmpty ? '(value is empty)' : entry.value,
            ),
          ],
          recommendation: 'Cross-check against the APIs actually used: see '
              'the corresponding API clue entries in this report.',
          recommendationCode: 'ios.usage_description.cross_check',
        ));
      }
    }

    // ---- 注册的 URL scheme：外部可以唤起本应用的入口 ----
    final urlSchemes = infoPlist.urlSchemes;
    if (urlSchemes.hasValue && urlSchemes.value!.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'IOS-URL-SCHEMES',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: 'Info.plist registers ${urlSchemes.value!.length} custom '
            'URL scheme(s): ${urlSchemes.value!.join(', ')}. These are entry '
            'points that external callers can use to launch this app — a '
            'factual description of the attack surface; registering a scheme '
            'does not mean the handling logic is flawed.',
        messageCode: 'ios.url_schemes',
        messageArgs: {
          'count': urlSchemes.value!.length,
          'schemes': urlSchemes.value!.join(', '),
        },
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.infoPlist,
            location: '${infoPlist.bundle.path}/Info.plist / CFBundleURLTypes',
            detail: urlSchemes.value!.join(', '),
          ),
        ],
        limitation: 'The scheme handling code was not inspected (no '
            'disassembly); "the entry point exists" and "the entry point is '
            'safe" are two different things.',
        limitationCode: 'ios.url_schemes.limitation',
        recommendation: 'To assess the attack surface, manually check whether '
            'the scheme handling logic validates the caller and whether it '
            'concatenates parameters straight into paths or SQL.',
        recommendationCode: 'ios.url_schemes.manual_review',
      ));
    } else if (urlSchemes.status == FieldStatus.wrongType ||
        urlSchemes.status == FieldStatus.failed) {
      // 读不出来就说出来 —— 不能让「读不到」长得像「没注册」。
      limitations.add(AnalysisNote(
        'ios.url_schemes.unreadable',
        'CFBundleURLTypes could not be read '
            '(${urlSchemes.diagnostic ?? urlSchemes.status.name}): the '
            'registered URL schemes are not covered.',
        {'reason': urlSchemes.diagnostic ?? urlSchemes.status.name},
      ));
    }

    // ---- 嵌套 bundle 的用途说明 ----
    //
    // 主应用的用途说明在上面已逐条记过。这里补上**每个嵌套 bundle 自己**的
    // 用途说明 —— App Extension 常常正是处理照片与 OCR 的地方，而主应用的
    // Info.plist 里可能一条相册用途都没有。只看主应用，「扩展声明了相册访问」
    // 这件事就完全看不见。
    //
    // 每条 finding 的 `location` 都指向**那个 bundle 的** Info.plist，
    // 主应用的结论不会被嵌套 bundle 污染（ruleId 也刻意与主应用不同）。
    var nestedDescriptionCount = 0;
    final nestedWithoutDescriptions = <String>[];
    for (final nested in nestedExecutables) {
      final descriptions = nested.usageDescriptions;
      if (descriptions == null) {
        // 没读到 ≠ 没有：如实记下来，不让覆盖率虚高。
        nestedWithoutDescriptions.add(nested.bundlePath);
        continue;
      }
      nestedDescriptionCount += descriptions.length;
      for (final entry in descriptions.entries) {
        findings.add(SecurityFinding(
          ruleId: 'IOS-NESTED-USAGE-DESCRIPTION',
          platform: SecurityPlatform.ios,
          category: _categoryForKey(entry.key),
          severity: SecuritySeverity.info,
          confidence: SecurityConfidence.confirmed,
          finding: 'Nested bundle ${nested.bundlePath} declares ${entry.key} '
              '(a usage description is provided).',
          messageCode: 'ios.nested_usage_description',
          messageArgs: {
            'bundle': nested.bundlePath,
            'key': entry.key,
          },
          evidence: [
            SecurityEvidence(
              source: SecurityEvidenceSource.infoPlist,
              location: '${nested.bundlePath}/Info.plist / ${entry.key}',
              detail: entry.value.isEmpty ? '(value is empty)' : entry.value,
            ),
          ],
          recommendation: 'Cross-check against the APIs actually used: see '
              'the corresponding API clue entries in this report.',
          recommendationCode: 'ios.usage_description.cross_check',
        ));
      }
    }
    if (nestedWithoutDescriptions.isNotEmpty) {
      limitations.add(AnalysisNote(
        'ios.nested_plist.missing',
        'The Info.plist of ${nestedWithoutDescriptions.length} nested '
            'bundle(s) could not be read, so their usage descriptions are '
            'not covered.',
        {'count': nestedWithoutDescriptions.length},
      ));
    }

    // ---- Mach-O 符号线索（主可执行文件 + 嵌套 bundle）----
    //
    // 阶段 5b：不再只扫主应用。App Extension 里的代码同样是这个应用的一部分，
    // 而且扩展常常**正是**处理照片与 OCR 的地方。
    final mainPath = executablePath ?? 'main executable';
    final targets =
        <({String path, String bundlePath, Uint8List? bytes, String? failure})>[
      (
        path: mainPath,
        bundlePath: infoPlist.bundle.path,
        bytes: executableBytes,
        failure: (executableBytes == null || executableBytes.isEmpty)
            ? 'entry missing or empty'
            : null,
      ),
      for (final nested in nestedExecutables)
        (
          path: nested.path.isEmpty ? nested.bundlePath : nested.path,
          bundlePath: nested.bundlePath,
          bytes: nested.bytes,
          failure: nested.failure,
        ),
    ];

    final clues = <String, _MachOClue>{};
    final byMarker = <String, List<String>>{};
    final sourcesByMarker = <String, Set<String>>{};
    final scannedPaths = <String>[];
    final unscanned = <String>[];
    var scanned = 0;
    var truncated = false;

    for (final target in targets) {
      final bytes = target.bytes;
      if (bytes == null || bytes.isEmpty) {
        // **只放路径，不带原因。** 原因（`bytes not retained (nested budget
        // of 32 MiB reached)` 这类）是英文，而这句话会原样进中文界面 ——
        // 实测用户看到的就是「Payload/…/App（bytes not retained (nested
        // budget of 32 MiB reached)）」，一半中文一半英文。
        //
        // 原因没有丢：`IosNestedBinary.failure` / `bytesFailure` 在详情页的
        // 嵌套清单与解析诊断里都能看到。
        unscanned.add(target.path);
        continue;
      }
      scannedPaths.add(target.path);

      if (bytes.length > _Budget.maxBytes) {
        truncated = true;
        limitations.add(AnalysisNote(
          'ios.executable.over_budget',
          '${target.path} is ${bytes.length} bytes, over the '
              '${_Budget.maxBytes}-byte scan budget: only the first '
              '${_Budget.maxBytes} bytes were scanned, and the uncovered '
              'part may contain clues that were not found.',
          {
            'path': target.path,
            'bytes': bytes.length,
            'limit': _Budget.maxBytes,
          },
        ));
      }
      final limit =
          bytes.length < _Budget.maxBytes ? bytes.length : _Budget.maxBytes;
      scanned += limit;

      for (final str in AsciiStrings.extract(
        bytes,
        limit: limit,
        minLength: _Budget.minStringLength,
      )) {
        for (final (id, _, literal) in _markers) {
          if (!str.contains(literal)) continue;
          (byMarker[id] ??= <String>[]).add(str);
          (sourcesByMarker[id] ??= <String>{}).add(target.path);
        }
      }
    }

    for (final (id, description, _) in _markers) {
      final samples = byMarker[id];
      if (samples == null || samples.isEmpty) continue;
      clues[id] = _MachOClue(
        id,
        description,
        samples.toSet().take(_Budget.maxSamplesPerMarker).toList(),
        sources: (sourcesByMarker[id] ?? const <String>{}).toList()..sort(),
      );
    }

    // ---- 覆盖范围：按可执行文件统计 ----
    //
    // 审计报告明确要求覆盖率本身进报告：「本次覆盖了 N 个可执行文件中的 M 个」。
    // 只报覆盖到的、不报没覆盖的，等于让读者以为结论是完整的。
    if (scannedPaths.isEmpty) {
      limitations.add(AnalysisNote(
        'ios.executable.none_readable',
        'No Mach-O executable content could be read: API usage clues cannot '
            'be checked. The usage-description and privacy-manifest '
            'conclusions are unaffected, but this is not a complete '
            'analysis.',
      ));
    } else {
      findings.add(SecurityFinding(
        ruleId: 'IOS-SCAN-COVERAGE',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: unscanned.isEmpty
            ? 'API usage clue scanning covered ${scannedPaths.length} of '
                '${targets.length} executables, $scanned bytes in total. '
                'Every executable was covered.'
            : 'API usage clue scanning covered ${scannedPaths.length} of '
                '${targets.length} executables, $scanned bytes in total. '
                'Executables not covered: ${unscanned.length}.',
        messageCode:
            unscanned.isEmpty ? 'ios.scan_coverage' : 'ios.scan_coverage_gap',
        messageArgs: {
          'total': targets.length,
          'scanned': scannedPaths.length,
          'bytes': scanned,
          if (unscanned.isNotEmpty) 'uncovered': unscanned.length,
        },
        evidence: [
          for (final path in scannedPaths)
            SecurityEvidence(
              source: SecurityEvidenceSource.machoSymbol,
              location: path,
              detail: 'scanned',
            ),
          for (final entry in unscanned)
            SecurityEvidence(
              source: SecurityEvidenceSource.machoSymbol,
              location: entry,
              detail: 'NOT scanned',
            ),
        ],
        limitation: 'The scan only extracts printable ASCII strings: system '
            'framework symbols in the dyld shared cache, non-ASCII literals '
            'and encrypted/hardened sections are all missed.',
        limitationCode: 'ios.scan_coverage.limitation',
        recommendation: 'For a more complete conclusion, manually inspect '
            'the executables that were not covered.',
        recommendationCode: 'ios.scan_coverage.manual_review',
      ));
      if (unscanned.isNotEmpty) {
        limitations.add(AnalysisNote(
          'ios.executable.unscanned',
          '${unscanned.length} executable(s) were not scanned '
              '(${[
            ...unscanned.take(4),
            if (unscanned.length > 4) '…',
          ].join(', ')}): "no clues found" on these files means "not looked '
              'at", not "none".',
          {
            'count': unscanned.length,
            'names': [
              ...unscanned.take(4),
              if (unscanned.length > 4) '…',
            ],
          },
        ));
      }
      limitations.add(AnalysisNote(
        'ios.macho.scan_summary',
        'The Mach-O scan covered $scanned bytes in total and only extracted '
            'printable ASCII strings: symbols in the dyld shared cache are '
            'outside the coverage, and non-ASCII literals are missed too.',
        {'bytes': scanned},
      ));
    }

    final hasPhotoLibrary = clues.containsKey('photo-full-library') ||
        clues.containsKey('photo-asset');
    final hasPhotoPicker =
        clues.containsKey('photo-picker') || clues.containsKey('photos-ui');
    final hasCamera = clues.containsKey('camera');
    final hasOcr =
        clues.containsKey('ocr') || clues.containsKey('ocr-image-request');
    final hasUpload = clues.containsKey('network-upload') ||
        clues.containsKey('network-session') ||
        clues.containsKey('network-alamofire') ||
        clues.containsKey('network-afnetworking');
    final hasClipboard = clues.containsKey('clipboard');

    String? usageKeyFor(String prefix) {
      if (!usage.hasValue) return null;
      for (final key in usage.value!.keys) {
        if (key.startsWith(prefix)) return key;
      }
      return null;
    }

    final photoUsageKey = usageKeyFor('NSPhotoLibrary');
    final cameraUsageKey = usageKeyFor('NSCamera');

    // ---- 照片：完整库 vs 用户主动选择，两条路必须分开 ----
    if (hasPhotoPicker) {
      findings.add(SecurityFinding(
        ruleId: 'IOS-PHOTO-PICKER',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.photoAccess,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.suspected,
        finding: 'Found system photo picker clues (PHPickerViewController / '
            'PhotosUI): the path where the user picks photos does not require '
            'full photo library authorization, which is a different access '
            'method from using PhotoKit directly.',
        messageCode: 'ios.photo_picker',
        evidence: _clueEvidence(clues, const [
          'photo-picker',
          'photos-ui',
        ]),
        recommendation: 'Confirm the actual input path: whether the user '
            'picks photos one by one, or whether full library access also '
            'exists.',
        recommendationCode: 'ios.photo_picker.confirm_input_path',
      ));
    }

    if (hasPhotoLibrary) {
      final missingUsage = photoUsageKey == null;
      findings.add(SecurityFinding(
        ruleId:
            missingUsage ? 'IOS-PHOTO-LIBRARY-NO-USAGE' : 'IOS-PHOTO-LIBRARY',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.photoAccess,
        severity: missingUsage ? SecuritySeverity.p2 : SecuritySeverity.p3,
        confidence: SecurityConfidence.suspected,
        finding: missingUsage
            ? 'Found full photo library access API clues (PhotoKit), but no '
                'NSPhotoLibraryUsageDescription in Info.plist: the usage '
                'description is missing, so the system will refuse access at '
                'runtime — and the source of the access is worth confirming '
                'manually.'
            : 'Found full photo library access API clues (PhotoKit), and '
                'Info.plist provides an NSPhotoLibraryUsageDescription.',
        messageCode:
            missingUsage ? 'ios.photo_library_no_usage' : 'ios.photo_library',
        evidence: [
          ..._clueEvidence(clues, const [
            'photo-full-library',
            'photo-asset',
          ]),
          if (missingUsage)
            SecurityEvidence(
              source: SecurityEvidenceSource.infoPlist,
              location: '${infoPlist.bundle.path}/Info.plist',
              detail: 'NSPhotoLibraryUsageDescription not found',
            ),
        ],
        limitation: 'The presence of an API symbol does not mean it is '
            'called at runtime; the symbol may also come from an unused '
            'framework reference.',
        limitationCode: 'ios.photo_library.limitation',
        recommendation: missingUsage
            ? 'Manually check the call sites and the build configuration; add '
                'a usage description as Apple requires, or remove the '
                'capability.'
            : 'Confirm the actual purpose of the photos and how the user '
                'authorises them in the recognition/upload pipeline.',
        recommendationCode: missingUsage
            ? 'ios.photo_library_no_usage.add_usage'
            : 'ios.photo_library.review',
      ));
    }

    if (hasCamera) {
      final missingUsage = cameraUsageKey == null;
      findings.add(SecurityFinding(
        ruleId: missingUsage ? 'IOS-CAMERA-NO-USAGE' : 'IOS-CAMERA',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.photoAccess,
        severity: missingUsage ? SecuritySeverity.p2 : SecuritySeverity.p3,
        confidence: SecurityConfidence.suspected,
        finding: missingUsage
            ? 'Found camera API clues, but no NSCameraUsageDescription in '
                'Info.plist.'
            : 'Found camera API clues, and Info.plist provides a camera usage '
                'description.',
        messageCode: missingUsage ? 'ios.camera_no_usage' : 'ios.camera',
        evidence: _clueEvidence(clues, const ['camera']),
        recommendation: missingUsage
            ? 'Manually check the call sites; add a usage description as '
                'Apple requires.'
            : 'Judge whether this is reasonable in the light of the capture, '
                'recognition and upload behaviour.',
        recommendationCode: missingUsage
            ? 'ios.camera_no_usage.add_usage'
            : 'ios.camera.check_purpose',
      ));
    }

    // ---- 反方向：声明了用途说明，却没有对应的 API 线索 ----
    //
    // 上面两条是「有实现、没声明」（会崩、会被拒）。这里是它的镜像：
    // **声明了、但扫描范围内找不到实现**。常见原因是这段声明是从模板/示例
    // 复制来的，实际并不使用 —— 过度声明本身就是隐私问题（用户会以为
    // 这个应用在读相册）。
    //
    // **只在确实扫到可执行文件时才判。** 没读到二进制时「没有符号」只说明
    // 我们没看到，不说明应用没用 —— 那是覆盖不足，不是矛盾。
    // 这条规则的判据是**缺失**（没找到线索），所以对「我们没看到」特别敏感。
    // 两个必须排除的情况：
    //
    // 1. **一个字节都没读到** —— 那是覆盖不足，不是矛盾。
    // 2. **扫描被预算截断**（`_Budget.maxBytes`）—— 线索可能在截断之后。
    //    实测：`sun_signed.ipa` 的主可执行文件 45 MB，只扫前 16 MB，而
    //    `AVCapture` 出现在 16 MB 之后 —— 不排除截断就会误报「声明了相机
    //    但没有实现」。
    //
    // 注意只数**真的拿到字节**的嵌套条目：生产路径会把读失败的也传进来
    // （`bytes == null`），把它们算成「扫过」同样会误报。
    final scannedNested =
        nestedExecutables.where((e) => e.bytes != null).length;
    final scannedAnyExecutable = executableBytes != null || scannedNested > 0;
    if (scannedAnyExecutable && !truncated) {
      final scope = _scannedScopeLabel(
        hasMain: executableBytes != null,
        nestedCount: scannedNested,
      );
      void usageWithoutApi(String usagePrefix, List<String> markerIds) {
        final key = usageKeyFor(usagePrefix);
        if (key == null) return;
        // 有任何一个对应线索就**不判** —— 宁可漏报，不可把「用了别的方式」
        // 说成「声明是假的」。
        if (markerIds.any(clues.containsKey)) return;

        findings.add(SecurityFinding(
          ruleId: 'IOS-USAGE-WITHOUT-API',
          platform: SecurityPlatform.ios,
          category: _categoryForKey(key),
          // info + unknown：这是「值得看一眼」，不是「有问题」。
          severity: SecuritySeverity.info,
          confidence: SecurityConfidence.unknown,
          finding: 'Info.plist declares $key, but no matching API clue was '
              'found in the scanned executables ($scope). The '
              'declaration may come from a template, or the feature may be '
              'implemented in a way that leaves no scannable symbol.',
          messageCode: 'ios.usage_without_api',
          messageArgs: {'key': key, 'scope': scope},
          evidence: [
            SecurityEvidence(
              source: SecurityEvidenceSource.infoPlist,
              location: '${infoPlist.bundle.path}/Info.plist / $key',
              detail: usage.value?[key] ?? '(usage description present)',
            ),
            SecurityEvidence(
              source: SecurityEvidenceSource.machoSymbol,
              location: executablePath ?? '${infoPlist.bundle.path}/<main>',
              detail: 'no clue matched: ${markerIds.join(', ')}',
            ),
          ],
          relationship: 'The declaration and the absence of a symbol are '
              'both facts; the conclusion "this permission is unused" is '
              '**not** established.',
          relationshipCode: 'ios.usage_without_api.relationship',
          limitation: 'Out-of-process pickers (PHPickerViewController), '
              'SwiftUI wrappers (PhotosPicker) and dynamically loaded code '
              'do not necessarily leave a scannable symbol, so a missing '
              'clue does not prove the feature is absent.',
          limitationCode: 'ios.usage_without_api.limitation',
          recommendation: 'Confirm whether this declaration is actually used. '
              'If it is not, remove it: over-declaring a permission is itself '
              'a privacy problem and it makes the App Store privacy label '
              'inaccurate.',
          recommendationCode: 'ios.usage_without_api.review',
        ));
      }

      usageWithoutApi(
        'NSPhotoLibrary',
        const [
          'photo-full-library',
          'photo-asset',
          'photo-picker',
          'photos-ui',
        ],
      );
      usageWithoutApi('NSCamera', const ['camera']);
    }

    // ---- iOS 规则 A：完整照片库访问 + 未见更克制的输入路径 ----
    //
    // 与 Android 规则 A 同构（「广泛访问 + 未见明显业务用途」）。iOS 上的
    // 「更克制的路径」就是系统照片选择器：Apple 明确它**不需要**完整相册
    // 授权。因此「只有 PhotoKit、没有 PHPicker」才是值得复核的那一种。
    if (hasPhotoLibrary && !hasPhotoPicker) {
      findings.add(SecurityFinding(
        ruleId: 'IOS-RULE-A',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.photoAccess,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.suspected,
        finding: 'Found full photo library access (PhotoKit) clues, but no '
            'system photo picker (PHPickerViewController / PhotosUI) path, '
            'which would be the more restrained alternative. Listed as a '
            'medium-risk candidate for manual review — requesting full '
            'library access is not necessarily unreasonable (gallery '
            'management apps genuinely need it), but it is worth confirming '
            'whether a lower-privilege alternative exists.',
        messageCode: 'ios.rule_a',
        evidence: _clueEvidence(clues, const [
          'photo-full-library',
          'photo-asset',
        ]),
        relationship: '"The picker path is missing" is a **static '
            'inference**: the picker may also be used through the SwiftUI '
            '`PhotosPicker` or loaded dynamically, and those do not '
            'necessarily leave a scannable symbol.',
        relationshipCode: 'ios.rule_a.relationship',
        limitation: 'The presence of a symbol does not mean it is called at '
            'runtime, and the absence of a symbol does not mean the feature '
            'is missing (dynamic loading, reflection, SwiftUI wrappers).',
        limitationCode: 'ios.rule_a.limitation',
        recommendation: 'Manual review: can the system photo picker replace '
            'full library access? This item is a candidate for review, not a '
            'malicious verdict.',
        recommendationCode: 'ios.rule_a.manual_review',
      ));
    }

    // ---- OCR ----
    if (hasOcr) {
      findings.add(SecurityFinding(
        ruleId: 'IOS-OCR-CAPABILITY',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.ocrImage,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.independentCapability,
        finding: 'Image text recognition capability found: the Vision '
            'framework text recognition API. This only reports a capability; '
            'it is not a malicious verdict.',
        messageCode: 'ios.ocr_capability',
        evidence: _clueEvidence(clues, const ['ocr', 'ocr-image-request']),
        recommendation: 'Confirm the source of the input (user-provided / '
            'photo library) and where the result goes.',
        recommendationCode: 'ios.ocr_capability.confirm_input_and_sink',
      ));
    }

    // ---- iOS 规则 B：图像输入 + 文字识别 ----
    //
    // 与 Android 规则 B 同构：两段线索同现，但**没有**证实它们位于同一条
    // 调用路径上。这一步只到「疑似关联」。
    if ((hasPhotoLibrary || hasPhotoPicker || hasCamera) && hasOcr) {
      // 来源用**稳定 id**传给呈现层，本地化名字由呈现层组装 ——
      // 引擎不能产出中文（否则英文界面混中文），也不能自己拼一句话
      // 塞进参数（那等于把没本地化的句子藏进占位符里）。
      final imageSources = [
        if (hasPhotoLibrary) 'photo_library',
        if (hasPhotoPicker) 'photo_picker',
        if (hasCamera) 'camera',
      ];
      findings.add(SecurityFinding(
        ruleId: 'IOS-RULE-B',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.ocrImage,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.suspected,
        finding: 'Both an image input source and text recognition capability '
            'were found: input (${_sourceLabels(imageSources)}) and '
            'recognition (Vision text recognition). This combination may '
            'correspond to a normal feature (document scanning, translation, '
            'business card reading).',
        messageCode: 'ios.rule_b',
        messageArgs: {'sources': imageSources},
        evidence: [
          ..._clueEvidence(clues, const [
            'photo-full-library',
            'photo-asset',
            'photo-picker',
            'camera',
          ]),
          ..._clueEvidence(clues, const ['ocr', 'ocr-image-request']),
        ],
        relationship: 'Image input → text recognition: the two clues '
            'co-occur, but they are not proven to lie on the same call path.',
        relationshipCode: 'ios.rule_b.relationship',
        limitation: 'No disassembly was performed, so it cannot be '
            'determined whether the recognition module actually handles '
            'user-selected images or batch-scanned media files.',
        limitationCode: 'ios.rule_b.limitation',
        recommendation: 'Confirm the recognition input source and how the '
            'user authorises it (whether it goes through the system photo '
            'picker).',
        recommendationCode: 'ios.rule_b.confirm_pipeline',
      ));
    }

    // ---- iOS 规则 C：图像输入 + OCR + 网络 ----
    if ((hasPhotoLibrary || hasPhotoPicker || hasCamera) &&
        hasOcr &&
        hasUpload) {
      findings.add(SecurityFinding(
        ruleId: 'IOS-RULE-C',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p1,
        confidence: SecurityConfidence.suspected,
        finding: 'Image input, text recognition and network capability clues '
            'all appear together: a suspected path for sensitive data leaving '
            'the device. This is a high-risk candidate; static analysis could '
            'not prove that recognition results actually reach a network '
            'request.',
        messageCode: 'ios.rule_c',
        evidence: [
          ..._clueEvidence(clues, const [
            'photo-full-library',
            'photo-asset',
            'photo-picker',
            'camera',
          ]),
          ..._clueEvidence(clues, const ['ocr', 'ocr-image-request']),
          ..._clueEvidence(clues, const [
            'network-session',
            'network-upload',
            'network-alamofire',
            'network-afnetworking',
          ]),
        ],
        dataSource: '照片/媒体文件与其中的识别文本',
        dataSink: '网络请求（NSURLSession / 上传）',
        relationship: 'Image input → text recognition → network send: there '
            'is evidence for each of the three stages, but the hop "the '
            'recognition result enters the request body" is not proven.',
        relationshipCode: 'ios.rule_c.relationship',
        limitation: 'No disassembly and no traffic observation; a framework '
            'reference does not mean the code is called.',
        limitationCode: 'ios.rule_c.limitation',
        recommendation: 'Manual review; if necessary, capture and verify '
            'traffic in an isolated environment.',
        recommendationCode: 'ios.rule_c.manual_review',
      ));
    }

    // ---- iOS 规则 E：后台执行 + 敏感读取 + 回传 ----
    //
    // 与 Android 规则 E 同构（后台 + 敏感读取 + 上传）。iOS 的「后台」
    // 对应 `UIBackgroundModes` —— 它是**声明性事实**：申请了某个模式不等于
    // 运行时真的在后台跑。
    final backgroundModes = infoPlist.backgroundModes;
    final hasBackground =
        backgroundModes.hasValue && backgroundModes.value!.isNotEmpty;
    final hasSensitiveRead =
        hasPhotoLibrary || hasPhotoPicker || hasCamera || hasClipboard;
    if (hasBackground && hasSensitiveRead && hasUpload) {
      final sensitiveSources = [
        if (hasPhotoLibrary) 'photo_library',
        if (hasPhotoPicker) 'photo_picker',
        if (hasCamera) 'camera',
        if (hasClipboard) 'clipboard',
      ];
      findings.add(SecurityFinding(
        ruleId: 'IOS-RULE-E',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.suspected,
        finding: 'A background execution declaration, sensitive data read '
            'capability and network upload capability all appear together: '
            'background modes (${backgroundModes.value!.join(', ')}), '
            'sensitive reads (${_sourceLabels(sensitiveSources)}), network '
            '(NSURLSession / upload). This combination may correspond to a '
            'normal feature (background backup, message sync).',
        messageCode: 'ios.rule_e',
        messageArgs: {
          'modes': backgroundModes.value!.join(', '),
          'sources': sensitiveSources,
        },
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.infoPlist,
            location: '${infoPlist.bundle.path}/Info.plist / UIBackgroundModes',
            detail: backgroundModes.value!.join(', '),
          ),
          ..._clueEvidence(clues, const [
            'photo-full-library',
            'photo-asset',
            'photo-picker',
            'camera',
            'clipboard',
          ]),
          ..._clueEvidence(clues, const [
            'network-session',
            'network-upload',
            'network-alamofire',
            'network-afnetworking',
          ]),
        ],
        dataSource: '相册 / 相机 / 剪贴板中的敏感内容',
        dataSink: '网络请求（后台执行期间）',
        relationship: 'Background execution declaration → sensitive data '
            'read → network upload: there is evidence for each of the three '
            'stages, but **not a single hop is proven** — it is not shown '
            'that the sensitive read happens in the background, nor that '
            'what was read reaches the request body.',
        relationshipCode: 'ios.rule_e.relationship',
        limitation: '`UIBackgroundModes` is a **declaration** and does not '
            'equal actual background behaviour at runtime; no disassembly and '
            'no traffic observation.',
        limitationCode: 'ios.rule_e.limitation',
        recommendation: 'Manually review what is uploaded in the background '
            'and what triggers it; if necessary, observe network behaviour '
            'while the app is backgrounded in an isolated environment.',
        recommendationCode: 'ios.rule_e.manual_review',
      ));
    }

    // ---- ATS ----
    final ats = infoPlist.allowsArbitraryLoads;
    if (ats.hasValue && ats.value == true) {
      final withSensitive =
          hasPhotoLibrary || hasPhotoPicker || hasCamera || hasOcr || hasUpload;
      findings.add(SecurityFinding(
        ruleId: withSensitive ? 'IOS-RULE-D-ESCALATED' : 'IOS-RULE-D',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.configuration,
        severity: withSensitive ? SecuritySeverity.p1 : SecuritySeverity.p2,
        confidence: SecurityConfidence.confirmed,
        finding: withSensitive
            ? 'App Transport Security allows arbitrary cleartext traffic '
                '(NSAllowsArbitraryLoads=true), and image / recognition / '
                'network clues are present at the same time: sensitive data '
                'may travel over an unencrypted channel.'
            : 'App Transport Security allows arbitrary cleartext traffic '
                '(NSAllowsArbitraryLoads=true).',
        messageCode: withSensitive ? 'ios.rule_d_escalated' : 'ios.rule_d',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.infoPlist,
            location: '${infoPlist.bundle.path}/Info.plist / '
                'NSAppTransportSecurity',
            detail: 'NSAllowsArbitraryLoads = true',
          ),
        ],
        limitation: 'Allowing cleartext in the configuration is not the same '
            'as actually using cleartext; the per-domain exception settings '
            'are not expanded.',
        limitationCode: 'ios.rule_d.limitation',
        recommendation: 'Confirm whether cleartext requests exist, and turn '
            'the switch off if necessary.',
        recommendationCode: 'ios.rule_d.manual_review',
      ));
    }

    // ---- 隐私清单：声明性材料 ----
    final privacy = infoPlist.privacyInfo;
    if (privacy.hasValue) {
      final info = privacy.value!;
      findings.add(SecurityFinding(
        ruleId: 'IOS-PRIVACY-INFO',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: 'Found a privacy manifest (PrivacyInfo.xcprivacy); its '
            'declarations are listed below. Note: this is **declarative '
            'material** and does not equal actual data access proven by the '
            'system.',
        messageCode: 'ios.privacy_info',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.privacyInfo,
            location: '${infoPlist.bundle.path}/PrivacyInfo.xcprivacy',
            detail: [
              if (info.tracking != null) 'NSPrivacyTracking = ${info.tracking}',
              if (info.trackingDomains.isNotEmpty)
                'NSPrivacyTrackingDomains = '
                    '${info.trackingDomains.join(', ')}',
              if (info.collectedDataTypes.isNotEmpty)
                'NSPrivacyCollectedDataTypes = '
                    '${info.collectedDataTypes.join(', ')}',
            ].join('；'),
          ),
        ],
        limitation: 'The privacy manifest does not record actual behaviour; '
            'runtime data access would require the system App Privacy Report '
            '(not provided in this version).',
        limitationCode: 'ios.privacy_info.limitation',
        recommendation: 'Manually compare the declarations against the API '
            'clues and the privacy policy.',
        recommendationCode: 'ios.privacy_info.cross_check',
      ));
      if (info.tracking == true) {
        findings.add(SecurityFinding(
          ruleId: 'IOS-PRIVACY-TRACKING',
          platform: SecurityPlatform.ios,
          category: SecurityCategory.thirdPartySdk,
          severity: SecuritySeverity.p3,
          confidence: SecurityConfidence.confirmed,
          finding: 'The privacy manifest declares that the app tracks the '
              'user (NSPrivacyTracking=true).',
          messageCode: 'ios.privacy_tracking',
          evidence: [
            SecurityEvidence(
              source: SecurityEvidenceSource.privacyInfo,
              location: '${infoPlist.bundle.path}/PrivacyInfo.xcprivacy',
              detail: 'NSPrivacyTracking = true',
            ),
          ],
          recommendation: 'Confirm that the tracking purpose and the ATT '
              'authorisation flow match expectations.',
          recommendationCode: 'ios.privacy_tracking.confirm_att',
        ));
      }
    } else if (privacy.status == FieldStatus.failed) {
      limitations.add(AnalysisNote(
        'ios.privacy_info.unparsable',
        'A privacy manifest exists but failed to parse: '
            '${privacy.diagnostic ?? 'reason not recorded'}. The '
            'declarations cannot be cross-checked.',
        {'reason': privacy.diagnostic ?? 'reason not recorded'},
      ));
    } else {
      limitations.add(AnalysisNote(
        'ios.privacy_info.absent',
        'No privacy manifest (PrivacyInfo.xcprivacy) was found: this is not '
            'anomalous by itself (only some apps provide one), but it means '
            'the declared data collection types cannot be cross-checked.',
      ));
    }

    // ---- 规则 F：未发现上传/网络特征 ----
    if (!hasUpload) {
      findings.add(SecurityFinding(
        ruleId: 'IOS-RULE-F',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.info,
        confidence: executableBytes == null || executableBytes.isEmpty
            ? SecurityConfidence.unknown
            : SecurityConfidence.confirmed,
        finding: 'No network upload characteristics were found within the '
            'current analysis scope (no hits for NSURLSession, multipart or '
            'common networking library markers). This does not mean the app '
            'has no network behaviour; it only means this scan found none.',
        messageCode: 'ios.rule_f',
        evidence: const [],
        limitation: 'Only ASCII strings from the main executable are '
            'scanned; network implementations inside Frameworks and the '
            'shared cache are outside the coverage.',
        limitationCode: 'ios.rule_f.limitation',
        recommendation: 'To confirm, combine this with runtime traffic '
            'observation (not provided in this version).',
        recommendationCode: 'ios.rule_f.runtime_traffic',
      ));
    }

    limitations.add(AnalysisNote(
      'ios.offline_static_analysis',
      'This is an offline static analysis: the app was not installed, not '
          'run, and no network traffic was observed. Runtime evidence '
          '(includesRuntimeEvidence) is always false.',
    ));
    if (truncated) {
      // 已在上面记录具体截断信息，这里只做归类提示。
      limitations.add(AnalysisNote(
        'ios.scan.truncated',
        'Some scan ranges were truncated because of the budget, so the '
            'conclusions are not complete.',
      ));
    }

    // ---- 原生符号（Mach-O 的 LC_SYMTAB）----
    //
    // 与 Android 侧读 ELF `.dynsym` 对应：C/C++ 代码不经过 Objective-C /
    // Swift 运行时，字符串扫描看不到它导入了哪些系统能力。
    final nativeResult = IosNativeSymbolAudit.scan(
      executableBytes: executableBytes,
      executablePath: executablePath,
    );
    final nativeReport = IosNativeSymbolAudit.report(
      result: nativeResult,
      executablePath: executablePath,
    );
    findings.addAll(nativeReport.findings);
    limitations.addAll(nativeReport.limitations);

    // ---- 结构化覆盖 ----
    //
    // 与 Android 侧同一套模型：把「覆盖了什么」从 limitations 的句子里收敛成
    // 带稳定 id 的数据，UI 与报告读同一份。
    // 覆盖说明用「三件套」：稳定 code + 英文回退 + 占位符实参（见
    // `CoverageEntry.noted`）。此前这里写的是中文，而本包不依赖 slang，
    // 于是英文/日文/韩文报告里会混进中文。
    final coverage = AnalysisCoverage(entries: [
      CoverageEntry.noted(
        id: 'ios.infoPlist',
        status: usage.hasValue || infoPlist.raw != null
            ? CoverageStatus.covered
            : CoverageStatus.notCovered,
        note: usage.hasValue || infoPlist.raw != null
            ? null
            : (
                'ios.info_plist.unparsed',
                'Info.plist could not be parsed',
                const <String, Object>{},
              ),
      ),
      CoverageEntry.noted(
        id: 'ios.usageDescriptions',
        status:
            usage.hasValue ? CoverageStatus.covered : CoverageStatus.notCovered,
        // 覆盖量 = 主应用的用途说明 + 嵌套 bundle 的用途说明。
        // 只算主应用会让「扩展声明了 5 条相册用途」在覆盖率上完全看不见。
        covered: usage.hasValue
            ? usage.value!.length + nestedDescriptionCount
            : null,
        note: usage.hasValue
            ? null
            : (
                'ios.usage_descriptions.not_read',
                'Info.plist not parsed; usage descriptions were not read',
                const <String, Object>{},
              ),
      ),
      CoverageEntry.noted(
        id: 'ios.privacyManifest',
        status: infoPlist.privacyInfo.hasValue
            ? CoverageStatus.covered
            : CoverageStatus.notApplicable,
        note: infoPlist.privacyInfo.hasValue
            ? null
            : (
                'ios.privacy_manifest.absent',
                'No PrivacyInfo.xcprivacy in this bundle '
                    '(not required before iOS 17)',
                const <String, Object>{},
              ),
      ),
      CoverageEntry.noted(
        id: 'ios.executables',
        status: targets.isEmpty
            ? CoverageStatus.notCovered
            : (scannedPaths.length == targets.length
                ? CoverageStatus.covered
                : (scannedPaths.isEmpty
                    ? CoverageStatus.notCovered
                    : CoverageStatus.partial)),
        covered: scannedPaths.length,
        limit: targets.length,
        note: unscanned.isEmpty
            ? null
            : (
                'ios.executables.unscanned',
                '${unscanned.length} executable(s) were not scanned',
                {'count': unscanned.length},
              ),
      ),
      CoverageEntry.noted(
        id: 'ios.macho.strings',
        status: scannedPaths.isEmpty
            ? CoverageStatus.notCovered
            : (truncated ? CoverageStatus.partial : CoverageStatus.covered),
        covered: scanned,
        note: scannedPaths.isEmpty
            ? (
                'ios.macho.no_content',
                'No Mach-O executable content could be read',
                const <String, Object>{},
              )
            : (truncated
                ? (
                    'ios.macho.truncated',
                    'Some executables exceeded the per-file scan budget',
                    const <String, Object>{},
                  )
                : null),
      ),
      CoverageEntry.noted(
        id: 'ios.nativeSymbols',
        status: nativeResult.scannedImages == 0
            ? CoverageStatus.notCovered
            : (nativeResult.unreadableImages.isNotEmpty ||
                    nativeResult.hasImageWithoutSymtab
                ? CoverageStatus.partial
                : CoverageStatus.covered),
        covered: nativeResult.scannedImages,
        note: nativeResult.scannedImages == 0
            ? (
                'ios.native_symbols.no_symtab',
                'No Mach-O image with a readable symbol table',
                const <String, Object>{},
              )
            : (nativeResult.unreadableImages.isNotEmpty
                ? (
                    'ios.native_symbols.unreadable',
                    '${nativeResult.unreadableImages.length} image(s) had an '
                        'out-of-range symbol table',
                    {'count': nativeResult.unreadableImages.length},
                  )
                : (nativeResult.hasImageWithoutSymtab
                    ? (
                        'ios.native_symbols.stripped',
                        'Some images have no LC_SYMTAB '
                            '(symbol table stripped)',
                        const <String, Object>{},
                      )
                    : null)),
      ),
      CoverageEntry.noted(
        id: 'ios.signature',
        // 签名验证由 codesign 在**主 isolate** 单独执行，不在本审计里 ——
        // 标 notApplicable 而不是 notCovered，避免报告凭空多出一个假缺口。
        status: CoverageStatus.notApplicable,
        note: (
          'ios.signature.separate_step',
          'Signature verification is performed separately by codesign; '
              'see the signature card',
          const <String, Object>{},
        ),
      ),
    ]);

    return SecurityAnalysisResult(
      engineVersion: engineVersion,
      rulesVersion: rulesVersion,
      findings: findings,
      limitations: limitations,
      coverage: coverage,
    );
  }

  static List<SecurityEvidence> _clueEvidence(
    Map<String, _MachOClue> clues,
    List<String> ids,
  ) {
    final evidence = <SecurityEvidence>[];
    for (final id in ids) {
      final clue = clues[id];
      if (clue == null) continue;
      evidence.add(SecurityEvidence(
        source: SecurityEvidenceSource.machoSymbol,
        location: clue.sources.isEmpty
            ? 'Mach-O executable strings'
            : clue.sources.join(', '),
        detail: '${clue.markerId}: ${clue.samples.join(' | ')}',
      ));
    }
    return evidence;
  }

  /// 扫描范围的**人话**描述 —— 让读者知道「没有符号」是在多大范围里得出的。
  ///
  /// 不写「全包」：预算截断、读取失败都可能让范围变小，那属于覆盖不足，
  /// 由 `IOS-SCAN-COVERAGE` 单独说明。
  static String _scannedScopeLabel({
    required bool hasMain,
    required int nestedCount,
  }) {
    if (hasMain && nestedCount > 0) {
      return 'main executable + $nestedCount nested executable(s)';
    }
    if (hasMain) return 'main executable only';
    return '$nestedCount nested executable(s)';
  }

  static SecurityCategory _categoryForKey(String key) {
    if (key.contains('Photo')) return SecurityCategory.photoAccess;
    if (key.contains('Camera')) return SecurityCategory.photoAccess;
    if (key.contains('Location')) return SecurityCategory.deviceData;
    if (key.contains('Contacts')) return SecurityCategory.deviceData;
    if (key.contains('Microphone')) return SecurityCategory.deviceData;
    return SecurityCategory.other;
  }
}

/// 英文回退里的来源名。
///
/// 呈现层用**同一组 id** 组装本地化名字（`AnalysisReport.findingText`），
/// 因此这里的措辞要与 `assets/i18n/*.json` 的 `security.sources.*` 对齐 ——
/// 否则「回退」与「本地化」会说出两种不同的东西。
String _sourceLabels(List<String> ids) => ids
    .map((id) => switch (id) {
          'photo_library' => 'full photo library (PhotoKit)',
          'photo_picker' => 'system photo picker',
          'camera' => 'camera',
          'clipboard' => 'clipboard',
          _ => id,
        })
    .join(', ');
