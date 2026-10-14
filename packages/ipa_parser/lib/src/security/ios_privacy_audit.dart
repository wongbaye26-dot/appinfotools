import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

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

  const _MachOClue(this.markerId, this.description, this.samples);
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
  }) {
    final findings = <SecurityFinding>[];
    final limitations = <String>[];

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
          finding: 'Info.plist 声明了 $entry.key（用途说明已提供）。'
              '用途说明的存在只表示应用**声称**会使用该能力，'
              '不证明运行时真的访问了对应数据。',
          evidence: [
            SecurityEvidence(
              source: SecurityEvidenceSource.infoPlist,
              location: '${infoPlist.bundle.path}/Info.plist / $entry.key',
              detail: entry.value.isEmpty ? '(value is empty)' : entry.value,
            ),
          ],
          recommendation: '与实际使用的 API 交叉核对：'
              '见本报告中对应的 API 线索条目。',
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
        finding: 'Info.plist 注册了 ${urlSchemes.value!.length} 个自定义 URL '
            'scheme：${urlSchemes.value!.join('、')}。'
            '这些是**外部可以唤起本应用**的入口，属于攻击面的事实描述；'
            '注册了 scheme 不代表处理逻辑有问题。',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.infoPlist,
            location: '${infoPlist.bundle.path}/Info.plist / CFBundleURLTypes',
            detail: urlSchemes.value!.join(', '),
          ),
        ],
        limitation: '本次未检查 scheme 的处理代码（未反汇编）；'
            '「入口存在」与「入口安全」是两件事。',
        recommendation: '如需评估攻击面，请人工检查 scheme 的处理逻辑是否'
            '校验来源、是否把参数直接拼进路径或 SQL。',
      ));
    } else if (urlSchemes.status == FieldStatus.wrongType ||
        urlSchemes.status == FieldStatus.failed) {
      // 读不出来就说出来 —— 不能让「读不到」长得像「没注册」。
      limitations.add('CFBundleURLTypes 读不出来'
          '（${urlSchemes.diagnostic ?? urlSchemes.status.name}）：'
          '注册的 URL scheme 未覆盖。');
    }

    // ---- Mach-O 符号线索 ----
    final clues = <String, _MachOClue>{};
    var scanned = 0;
    var truncated = false;
    if (executableBytes == null || executableBytes.isEmpty) {
      limitations.add('未能读取主 Mach-O 可执行文件的内容'
          '（${executablePath ?? '路径未知'}）：API 使用线索无法检查。'
          '用途说明与隐私清单结论不受影响，但不构成完整分析。');
    } else {
      if (executableBytes.length > _Budget.maxBytes) {
        truncated = true;
        limitations.add('主 Mach-O 文件 ${executableBytes.length} 字节，'
            '超过 ${_Budget.maxBytes} 字节扫描预算：'
            '只扫描了前 ${_Budget.maxBytes} 字节，未覆盖部分可能存在'
            '未被发现的线索。');
      }
      final limit = executableBytes.length < _Budget.maxBytes
          ? executableBytes.length
          : _Budget.maxBytes;
      scanned = limit;
      final byMarker = <String, List<String>>{};
      for (final str in AsciiStrings.extract(
        executableBytes,
        limit: limit,
        minLength: _Budget.minStringLength,
      )) {
        for (final (id, _, literal) in _markers) {
          if (str.contains(literal)) {
            (byMarker[id] ??= <String>[]).add(str);
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
        );
      }
      limitations.add('Mach-O 扫描只覆盖主可执行文件、共 $scanned 字节，'
          '且仅提取可打印 ASCII 字符串：Frameworks、动态库与 dyld 共享缓存'
          '中的符号不在覆盖范围内，非 ASCII 字面量也会漏掉。');
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
        finding: '发现系统照片选择器线索（PHPickerViewController / PhotosUI）：'
            '用户主动选取照片的路径**不需要**完整照片库授权，'
            '这与直接使用 PhotoKit 是两种不同的访问方式。',
        evidence: _clueEvidence(clues, const [
          'photo-picker',
          'photos-ui',
        ]),
        recommendation: '确认真实输入路径：是用户逐张选取，'
            '还是同时存在完整库访问。',
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
            ? '发现完整照片库访问 API 线索（PhotoKit），但 Info.plist 中'
                '没有找到 NSPhotoLibraryUsageDescription：授权说明缺失，'
                '访问会在运行时被系统拒绝，同时也值得人工确认其来源。'
            : '发现完整照片库访问 API 线索（PhotoKit），且 Info.plist 提供了'
                'NSPhotoLibraryUsageDescription 用途说明。',
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
        limitation: 'API 符号存在不等于运行时会调用；'
            '符号也可能来自未使用的框架引用。',
        recommendation: missingUsage
            ? '人工核查调用来源与构建配置；'
                '按 Apple 要求补充用途说明或移除该能力。'
            : '确认识别/上传链路中照片的实际用途与用户授权方式。',
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
            ? '发现相机 API 线索，但 Info.plist 中没有 NSCameraUsageDescription。'
            : '发现相机 API 线索，且 Info.plist 提供了相机用途说明。',
        evidence: _clueEvidence(clues, const ['camera']),
        recommendation:
            missingUsage ? '人工核查调用来源；按 Apple 要求补充用途说明。' : '结合拍摄、识别与上传行为判断是否合理。',
      ));
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
        finding: '发现完整照片库访问（PhotoKit）线索，'
            '但**没有**发现系统照片选择器（PHPickerViewController / PhotosUI）'
            '这条更克制的路径。列为待人工复核的中风险候选项 —— '
            '申请完整库访问不一定不合理（相册管理类应用确实需要），'
            '但值得确认是否有更小权限的替代方案。',
        evidence: _clueEvidence(clues, const [
          'photo-full-library',
          'photo-asset',
        ]),
        relationship: '「缺少选择器路径」是**静态推断**：选择器也可能通过'
            'SwiftUI 的 `PhotosPicker` 或动态加载使用，'
            '而它们不一定会留下可扫描的符号。',
        limitation: '符号存在不等于运行时会调用；'
            '符号缺失也不等于功能不存在（动态加载、反射、SwiftUI 包装）。',
        recommendation: '人工复核：是否可以用系统照片选择器替代完整库访问；'
            '本项为待复核候选项，不是恶意判定。',
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
        finding: '发现图像文字识别能力：Vision 框架文本识别 API。'
            '仅发现能力，不判定恶意。',
        evidence: _clueEvidence(clues, const ['ocr', 'ocr-image-request']),
        recommendation: '确认识别输入来源（用户主动提供 / 相册）与结果去向。',
      ));
    }

    // ---- iOS 规则 B：图像输入 + 文字识别 ----
    //
    // 与 Android 规则 B 同构：两段线索同现，但**没有**证实它们位于同一条
    // 调用路径上。这一步只到「疑似关联」。
    if ((hasPhotoLibrary || hasPhotoPicker || hasCamera) && hasOcr) {
      findings.add(SecurityFinding(
        ruleId: 'IOS-RULE-B',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.ocrImage,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.suspected,
        finding: '同时发现图像输入来源与文字识别能力：'
            '输入（${[
          if (hasPhotoLibrary) '完整照片库（PhotoKit）',
          if (hasPhotoPicker) '系统照片选择器',
          if (hasCamera) '相机',
        ].join('、')}）与识别能力（Vision 文本识别）。'
            '该组合可能对应正常功能（文档扫描、翻译、名片识别）。',
        evidence: [
          ..._clueEvidence(clues, const [
            'photo-full-library',
            'photo-asset',
            'photo-picker',
            'camera',
          ]),
          ..._clueEvidence(clues, const ['ocr', 'ocr-image-request']),
        ],
        relationship: '图像输入 → 文字识别：两段线索同现，但未被证实位于'
            '同一条调用路径上。',
        limitation: '未反汇编，无法确认识别模块实际处理的是用户主动选择的'
            '图片还是批量扫描的媒体文件。',
        recommendation: '确认识别的输入来源与用户授权方式'
            '（是否走系统照片选择器）。',
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
        finding: '发现「图像输入 + 文字识别 + 网络能力」三段线索同现，'
            '存在敏感数据外传的疑似链路。这是高风险候选项，'
            '静态分析未能证实识别结果确实进入网络请求。',
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
        relationship: '图像输入 → 文字识别 → 网络发送：三段分别有证据，'
            '「识别结果进入请求体」这一跳未被证实。',
        limitation: '未反汇编、未观察流量；框架引用不等于被调用。',
        recommendation: '人工复核，必要时在隔离环境抓包验证。',
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
      findings.add(SecurityFinding(
        ruleId: 'IOS-RULE-E',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.suspected,
        finding: '同时发现后台执行声明、敏感数据读取能力与网络回传能力：'
            '后台模式（${backgroundModes.value!.join('、')}）、'
            '敏感读取（${[
          if (hasPhotoLibrary) '完整照片库',
          if (hasPhotoPicker) '照片选择器',
          if (hasCamera) '相机',
          if (hasClipboard) '剪贴板',
        ].join('、')}）、网络（NSURLSession / 上传）。'
            '这个组合可能对应正常功能（后台上传备份、消息同步）。',
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
        relationship: '后台执行声明 → 敏感数据读取 → 网络回传：三段分别有'
            '证据，但**没有任何一跳被证实** —— 既没有证明敏感读取发生在后台，'
            '也没有证明读取的内容进入了请求体。',
        limitation: '`UIBackgroundModes` 是**声明**，不等于运行时的实际后台'
            '行为；未反汇编、未观察流量。',
        recommendation: '人工复核后台上传的内容与触发条件；'
            '必要时在隔离环境中观察后台期间的网络行为。',
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
            ? 'App Transport Security 允许任意明文流量'
                '（NSAllowsArbitraryLoads=true），且同时存在图像/识别/网络'
                '相关线索：敏感数据可能经未加密链路传输。'
            : 'App Transport Security 允许任意明文流量'
                '（NSAllowsArbitraryLoads=true）。',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.infoPlist,
            location: '${infoPlist.bundle.path}/Info.plist / '
                'NSAppTransportSecurity',
            detail: 'NSAllowsArbitraryLoads = true',
          ),
        ],
        limitation: '配置允许明文不等同于实际使用明文；'
            '例外域内的具体例外设置未展开。',
        recommendation: '确认是否存在明文请求，必要时关闭该开关。',
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
        finding: '发现隐私清单（PrivacyInfo.xcprivacy），声明内容如下。'
            '注意：这是**声明性材料**，不等于系统已证实的实际数据访问行为。',
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
        limitation: '隐私清单不记录实际行为；'
            '运行时的数据访问需依赖系统的 App Privacy Report（本版本不提供）。',
        recommendation: '将声明内容与 API 线索、隐私政策人工比对。',
      ));
      if (info.tracking == true) {
        findings.add(SecurityFinding(
          ruleId: 'IOS-PRIVACY-TRACKING',
          platform: SecurityPlatform.ios,
          category: SecurityCategory.thirdPartySdk,
          severity: SecuritySeverity.p3,
          confidence: SecurityConfidence.confirmed,
          finding: '隐私清单声明应用会跟踪用户（NSPrivacyTracking=true）。',
          evidence: [
            SecurityEvidence(
              source: SecurityEvidenceSource.privacyInfo,
              location: '${infoPlist.bundle.path}/PrivacyInfo.xcprivacy',
              detail: 'NSPrivacyTracking = true',
            ),
          ],
          recommendation: '确认跟踪用途与 ATT 授权流程是否符合预期。',
        ));
      }
    } else if (privacy.status == FieldStatus.failed) {
      limitations.add('隐私清单存在但解析失败：${privacy.diagnostic}。'
          '声明性内容无法核对。');
    } else {
      limitations.add('未发现隐私清单（PrivacyInfo.xcprivacy）：'
          '这本身不是异常（仅部分应用提供），但意味着无法核对声明的'
          '数据收集类型。');
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
        finding: '当前分析范围内未发现网络上传相关特征'
            '（未命中 NSURLSession、multipart、常见网络库等标记）。'
            '这不表示应用没有网络行为，只说明本次扫描没有发现。',
        evidence: const [],
        limitation: '只扫描主可执行文件的 ASCII 字符串；'
            'Frameworks 与共享缓存内的网络实现不在覆盖范围内。',
        recommendation: '如需确认，请结合运行时流量观察（本版本不提供）。',
      ));
    }

    limitations.add('本次为离线静态分析：未安装、未运行、未观察网络流量。'
        '运行时证据（includesRuntimeEvidence）恒为 false。');
    if (truncated) {
      // 已在上面记录具体截断信息，这里只做归类提示。
      limitations.add('存在因预算被截断的扫描范围，结论完整性受影响。');
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

    return SecurityAnalysisResult(
      engineVersion: engineVersion,
      rulesVersion: rulesVersion,
      findings: findings,
      limitations: limitations,
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
        location: 'main Mach-O executable strings',
        detail: '${clue.markerId}: ${clue.samples.join(' | ')}',
      ));
    }
    return evidence;
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
