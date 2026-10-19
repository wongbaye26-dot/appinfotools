import 'package:analysis_model/analysis_model.dart';

import '../dex/dex_structure.dart';
import '../models.dart';
import '../native/elf_hardening.dart';
import 'android_security_rules.dart';
import 'dex_clue_scanner.dart';
import 'dex_method_scanner.dart';
import 'native_symbol_scanner.dart';
import 'permission_catalog.dart';
import 'sdk_inventory_scanner.dart';

/// Android 侧的安全审计编排。
///
/// 输入是**已经解析好的** [ApkMeta] 与 DEX 条目字节，不自己开归档 ——
/// 规格第六章要求「先检查现有代码组织，复用已有解析器」，因此这里只做
/// 规则匹配与定级，文件读取、ZIP 预算、解包都由调用方按既有管线完成。
///
/// 定级口径见 [PermissionCatalog] 与各规则的注释。总原则：**权限数量不决定
/// 等级**；未证实的数据流一律标 [SecurityConfidence.suspected] 并在
/// relationship 里写清哪个环节没被证实。
/// 「这条权限必须有对应的 API 调用」的编目。
///
/// 只收**判据明确**的权限：读通讯录必然碰 `ContactsContract`、读短信必然碰
/// `SmsManager`、定位必然碰 `LocationManager`。反过来，`WRITE_EXTERNAL_STORAGE`
/// 这类可能只走 `java.io.File` 的权限**不编目** —— 硬判会误报。
///
/// 值是「任一命中即算用过」的标记集合：`RECORD_AUDIO` 两个入口
/// （`MediaRecorder` 与 `AudioRecord`）都要算，否则用后者的应用会被误判。
const Map<String, Set<String>> _permissionApiMarkers = {
  'android.permission.READ_CONTACTS': {'contacts'},
  'android.permission.WRITE_CONTACTS': {'contacts'},
  'android.permission.READ_SMS': {'sms'},
  'android.permission.SEND_SMS': {'sms'},
  'android.permission.RECEIVE_SMS': {'sms'},
  'android.permission.ACCESS_FINE_LOCATION': {'location'},
  'android.permission.ACCESS_COARSE_LOCATION': {'location'},
  'android.permission.RECORD_AUDIO': {'recording', 'recording-audiorecord'},
  'android.permission.CAMERA': {'camera1', 'camera2'},
  'android.permission.READ_PHONE_STATE': {'device-id'},
};

class AndroidSecurityAudit {
  AndroidSecurityAudit._();

  /// 引擎版本（与规则库版本分开：规则可以单独更新）。
  static const String engineVersion = 'android-security-1.1.0';

  static const String rulesVersion = PermissionCatalog.rulesVersion;

  /// [manifestParsed] 为 false 时必须给出原因（记入覆盖不足）。
  /// 从组件声明里认出**特殊访问能力**。
  ///
  /// 判据是组件上的 `android:permission`：提供这些能力的组件**必须**声明
  /// 对应的 BIND 权限，否则系统不会把它们当作服务。这比在 DEX 里找类名可靠
  /// 得多 —— 后者会被 UI 库的正常调用误伤（`AccessibilityServiceInfo`）。
  static List<String> specialAccessFromComponents(
    List<AndroidComponent> components,
  ) {
    const bindPermissions = {
      'android.permission.BIND_ACCESSIBILITY_SERVICE': 'accessibility',
      'android.permission.BIND_DEVICE_ADMIN': 'device_admin',
      'android.permission.BIND_NOTIFICATION_LISTENER_SERVICE':
          'notification_listener',
    };
    final kinds = <String>{};
    for (final component in components) {
      final kind = bindPermissions[component.permission];
      if (kind != null) kinds.add(kind);
    }
    return kinds.toList()..sort();
  }

  /// 去掉**精确重复**的权限声明（名字 + maxSdkVersion + sdk23Only 三项全同）。
  ///
  /// 只去精确重复：同名但 `maxSdkVersion` 不同的是两条不同的声明
  /// （一条可能已过期、一条仍然生效），合并会把版本条件吃掉。
  static List<AndroidPermissionRequest> _dedupePermissions(
    List<AndroidPermissionRequest> input,
  ) {
    final seen = <String>{};
    final out = <AndroidPermissionRequest>[];
    for (final request in input) {
      final key = '${request.name}\u0000${request.maxSdkVersion}'
          '\u0000${request.sdk23Only}';
      if (seen.add(key)) out.add(request);
    }
    return out;
  }

  static SecurityAnalysisResult audit({
    required ApkMeta meta,
    required List<DexBytes> dexEntries,

    /// 原生库（`lib/**.so`）的名字与字节。空表示没有原生库或未提供。
    List<NativeLibraryBytes> nativeEntries = const [],
    bool manifestParsed = true,
    String? manifestFailureReason,

    /// 容器/清单层的结构异常，**结构化**（code + 参数）。
    ///
    /// V2.4.11 之前这里是 `List<String>`，界面只能拼出
    /// 「容器/解析异常可能影响覆盖完整性：21 elements declare a non-standard…」
    /// 这种半中半英的句子。现在每条自带 code，界面按 code 查本地化模板。
    List<AnalysisNote> containerAnomalyNotes = const [],

    /// 全包里**唯一库名**的数量（含未被选中扫描的）。
    ///
    /// 为什么需要它：`nativeEntries` 只是「传进来准备扫描的那几个」。
    /// 用它当覆盖率的 `limit`，会让「266 个唯一库只扫了 24 个」显示成
    /// 「24/24 已覆盖」—— 读者据此以为原生层全查过了。
    ///
    /// 不传时退回旧口径（`limit = nativeEntries.length`），不编造总数。
    int? nativeLibraryTotal,

    /// 因预算 / 数量上限**未被选中扫描**的库（`selectLibraries` 的 `skipped`）。
    ///
    /// 必须进 `limitations`：`selectLibraries` 挑剩下的那些，此前在报告里
    /// **完全不可见**（`grep -rn "\.skipped" lib/` 零命中）。
    List<String> nativeSkipped = const [],

    /// `resources.arsc` **实际读到的资源条目数**；读不到时为 `null`。
    ///
    /// 为什么不能靠 `meta.locales` / `meta.densities` 反推（旧实现的判据）：
    /// 那两项只有在资源表带多语言 / 多密度变体时才非空。一个单语言、单密度的
    /// 正常应用，资源表被完整解析了却会被报成「资源表缺失或无法解析」——
    /// 实测 7 个夹具全部命中，包括有 4 个资源的 `night-mode-resources.apk`。
    ///
    /// `null` 表示**调用方没能提供**（`resources.arsc` 不存在、被预算拒绝或
    /// 解析失败）。此时标 `notCovered` 是对的：那确实是「我们没读到」。
    int? arscEntryCount,
  }) {
    final findings = <SecurityFinding>[];
    final limitations = <AnalysisNote>[];

    // **精确重复的权限声明只审一次。**
    //
    // 实测（抖音）：manifest 把 `ACCESS_COARSE_LOCATION` 声明了两次，审计产出
    // 两张完全一样的卡片 —— 用户会以为「这里有两个问题」。
    //
    // 只去**精确重复**（名字 + maxSdkVersion + sdk23Only 三项全同）：同名但
    // maxSdkVersion 不同的是两条不同的声明（一条可能已过期、一条仍然生效），
    // 合并会把版本条件吃掉。
    final permissionRequests = _dedupePermissions(meta.permissionRequests);

    if (!manifestParsed) {
      limitations.add(AnalysisNote(
        'android.manifest.unparsed',
        'AndroidManifest.xml could not be parsed '
            '(${manifestFailureReason ?? 'reason not recorded'}): the permission '
            'and component audit cannot run, so this result only contains the '
            'readable part and is not a complete conclusion.',
        {'reason': manifestFailureReason ?? 'reason not recorded'},
      ));
    }

    final targetSdk = meta.targetSdkVersion;

    // ---- 签名块的可读性 ----
    //
    // 读不出签名块时**必须说出来**：此时 `v1Only` 与 `hasV1Signature` 都推不出
    // 结论，两条签名规则都不报，覆盖表里若也没有对应维度，「我们没读到」
    // 就变成了「没有问题」。签名块结构被破坏本身还是重打包的典型痕迹。
    if (meta.signingSchemes case final schemes? when !schemes.parsed) {
      limitations.add(AnalysisNote(
        'android.signing_block.unreadable',
        'The APK Signing Block could not be read '
            '(${schemes.failure ?? 'reason not recorded'}): the v2+ signature '
            'schemes are unknown, so "no signature block found" is not a '
            'conclusion this run can make. This is **not** a verdict that the '
            'signature is invalid.',
        {'reason': schemes.failure ?? 'reason not recorded'},
      ));
    }

    // ---- DEX 字符串扫描（第一层取证）----
    final scan = DexClueScanner.scan(dexEntries);
    for (final skip in scan.skippedForBudget) {
      // 参数分开给：界面要按语言拼「只扫了前 8 MiB（共 17.5 MB，约 47%）」，
      // 而拼接好的整句没法再拆回数字。
      limitations.add(AnalysisNote(
        'android.dex.budget',
        'DEX scan budget: ${skip.name} was only scanned for '
            '${skip.scannedBytes} of ${skip.totalBytes} bytes '
            '(${skip.percent}%) — the remaining bytes were not searched, so '
            'clues inside them were not found.',
        {
          'name': skip.name,
          'scannedBytes': skip.scannedBytes,
          'totalBytes': skip.totalBytes,
          'percent': skip.percent,
        },
      ));
    }
    if (dexEntries.isEmpty) {
      limitations.add(AnalysisNote(
        'android.dex.no_content',
        'No classes.dex content was read: OCR, upload and network-domain code '
            'clues cannot be checked. The permission and configuration '
            'conclusions are unaffected, but this is not a complete analysis.',
      ));
    } else {
      limitations.add(AnalysisNote(
        'android.dex.scan_summary',
        'The DEX string scan only covered ${scan.scannedDexCount} file(s), '
            '${scan.scannedBytes} bytes in total, and only extracted printable '
            'ASCII strings: non-ASCII literals, native libraries (lib/**.so), '
            'resource files and code inside a hardened shell are all outside the '
            'coverage.',
        {
          'dexCount': scan.scannedDexCount,
          'bytes': scan.scannedBytes,
        },
      ));
    }

    // ---- DEX 结构（第二层取证：先看结构是否可信）----
    //
    // 顺序很关键：**先看结构，再信内容**。一个 file_size 与段表对不上的 DEX，
    // 它上面的字符串线索不能当作完整结论 —— 没扫到的地方可能是结构本身
    // 就没覆盖到，而不是「确实没有」。
    final structures = [
      for (final entry in dexEntries)
        DexStructure.read(entry.name, entry.bytes),
    ];
    for (final structure in structures) {
      for (final anomaly in structure.anomalies) {
        limitations.add(AnalysisNote(
          'android.dex.structure_anomaly',
          '${structure.name} has a structural anomaly (${anomaly.code}): '
              '${anomaly.message}',
          {
            'name': structure.name,
            'code': anomaly.code,
            'message': anomaly.message,
          },
        ));
      }
      if (!structure.checksumVerified) {
        limitations.add(AnalysisNote(
          'android.dex.checksum_not_verified',
          '${structure.name} is over '
              '${kDexMaxChecksumBytes ~/ (1024 * 1024)} MiB, so the checksum was '
              '**not verified** — do not read "no checksum anomaly reported" as '
              '"the checksum is correct".',
          {
            'name': structure.name,
            'limitMiB': kDexMaxChecksumBytes ~/ (1024 * 1024),
          },
        ));
      }
    }
    final untraversable = [
      for (final s in structures)
        if (!s.isTraversable) s,
    ];
    if (untraversable.isNotEmpty) {
      limitations.add(AnalysisNote(
        'android.dex.structure_untrusted',
        '${untraversable.length} DEX file(s) have an untrustworthy structure '
            '(${untraversable.map((s) => s.name).join(', ')}): the string clues '
            'from these files **are not a complete conclusion**, and the '
            'uncovered bytes may contain clues that were not found.',
        {
          'count': untraversable.length,
          'names': untraversable.map((s) => s.name).toList(),
        },
      ));
    }

    // ---- DEX 方法引用（第三层取证：把「代码引用了」与「字符串提到了」分开）----
    //
    // `method_ids` 的条目只可能来自字节码的 invoke 指令、方法签名或方法句柄，
    // 不会来自字符串字面量。因此「命中」的含义比字符串线索强一档 ——
    // 但**仍然不等于「调用了」**：那要遍历 code_item 里的指令。
    final methodScan = DexMethodScanner.scan(dexEntries);
    if (methodScan.notTraversable.isNotEmpty) {
      limitations.add(AnalysisNote(
        'android.dex.method_not_traversable',
        '${methodScan.notTraversable.length} DEX file(s) have an untrustworthy '
            'structure, so no method reference analysis was done '
            '(${methodScan.notTraversable.join(', ')}): "no code reference found" '
            'on these files means "not looked at", not "none".',
        {
          'count': methodScan.notTraversable.length,
          'names': methodScan.notTraversable,
        },
      ));
    }
    if (methodScan.truncatedForBudget.isNotEmpty) {
      limitations.add(AnalysisNote(
        'android.dex.method_budget',
        'The method reference walk hit the budget limit; '
            '${methodScan.truncatedForBudget.join(', ')} were only partially '
            'analysed.',
        {'names': methodScan.truncatedForBudget},
      ));
    }
    if (methodScan.skippedEntries > 0) {
      limitations.add(AnalysisNote(
        'android.dex.method_entries_unreadable',
        '${methodScan.skippedEntries} method_ids entries could not be parsed '
            'during the method reference walk (index out of bounds or the string '
            'could not be read), so the references in those entries were not '
            'seen.',
        {'count': methodScan.skippedEntries},
      ));
    }
    if (methodScan.desyncedBodies.isNotEmpty) {
      limitations.add(AnalysisNote(
        'android.dex.desynced_bodies',
        '${methodScan.desyncedBodies.length} method body(ies) were not '
            'instruction-aligned (${[
          ...methodScan.desyncedBodies.take(3),
          if (methodScan.desyncedBodies.length > 3) '…',
        ].join(', ')}): the **call sites in these method bodies are not '
            'trustworthy** — the width table or the payload length may not match '
            'the actual shape of the file.',
        {
          'count': methodScan.desyncedBodies.length,
          'names': [
            ...methodScan.desyncedBodies.take(3),
            if (methodScan.desyncedBodies.length > 3) '…',
          ],
        },
      ));
    }
    if (dexEntries.isNotEmpty && methodScan.scannedDexCount > 0) {
      limitations.add(AnalysisNote(
        'android.dex.method_semantics',
        'Method references come from method_ids (proving the code **references** '
            'these methods) and call sites come from the invoke instructions in '
            'code_item (proving a **call instruction exists**). Neither **proves '
            'it ran at runtime** — no data flow analysis was done, so how '
            'arguments and return values are passed is unknown.',
      ));
    }
    if (methodScan.invokeCustomCount > 0) {
      limitations.add(AnalysisNote(
        'android.dex.invoke_custom',
        'There are ${methodScan.invokeCustomCount} invoke-custom instruction(s): '
            'they reference call_site_ids rather than method_ids and were not '
            'parsed, so these calls are **not** within call-site coverage.',
        {'count': methodScan.invokeCustomCount},
      ));
    }

    // 加固特征直接转化为覆盖不足说明（HardeningScanner 的输出）。
    //
    // 已经是 `AnalysisNote`，**原样并入** —— 再包一层会让它退回通用 code，
    // 白丢了结构化。
    limitations.addAll(containerAnomalyNotes);

    final ocrClues = scan.clues
        .where((c) => c.category == SecurityCategory.ocrImage)
        .toList();
    final uploadClues = scan.clues
        .where((c) =>
            c.markerId == 'multipart' ||
            c.markerId == 'multipartbody' ||
            c.markerId == 'uploadfile' ||
            c.markerId == 'uploadimage')
        .toList();
    final backgroundClues = scan.clues
        .where((c) => c.category == SecurityCategory.backgroundTask)
        .toList();
    final photoClues = scan.clues
        .where((c) => c.category == SecurityCategory.photoAccess)
        .toList();

    // 同一批标记在**代码引用**层面的命中。与字符串线索刻意分开保存：
    // 规则里要把「代码引用了」与「字符串里提到了」分开陈述。
    List<CodeReference> codeRefsOf(Set<String> markerIds) =>
        methodScan.references
            .where((r) => markerIds.contains(r.markerId))
            .toList();

    const uploadMarkerIds = {
      'multipart',
      'multipartbody',
      'uploadfile',
      'uploadimage',
    };
    final uploadCodeRefs = codeRefsOf(uploadMarkerIds);
    final ocrCodeRefs = methodScan.references
        .where((r) => r.category == SecurityCategory.ocrImage)
        .toList();
    // 录屏能力：单列，不并进 OCR（录屏抓画面，不是识别文字）。
    final screenCaptureClues =
        scan.clues.where((c) => c.markerId == 'media-projection').toList();
    final screenCaptureCodeRefs = codeRefsOf(const {'media-projection'});

    final networkClues = scan.clues
        .where((c) => c.category == SecurityCategory.network)
        .toList();
    final networkCodeRefs = methodScan.references
        .where((r) => r.category == SecurityCategory.network)
        .toList();

    // 规则输入用「能力是否存在」而不是「有没有字符串线索」：只看字符串会漏掉
    // 「代码引用了 MultipartBody，但字面量 multipart/form-data 从未出现」这类
    // 情况。两者分开保存，陈述时也要分开。
    // ---- 非图片类敏感数据来源（B：审计报告 P2-2）----
    const sensitiveSourceMarkers = {
      'device-id',
      'contacts',
      'sms',
      'location',
      'recording',
      'recording-audiorecord',
      'clipboard',
    };
    final sensitiveSourceClues = scan.clues
        .where((c) => sensitiveSourceMarkers.contains(c.markerId))
        .toList();
    final sensitiveSourceCodeRefs = codeRefsOf(sensitiveSourceMarkers);

    // 特殊访问能力：**从清单层判**，不从 DEX 字面量判。
    //
    // 试过 DEX 字面量（`AccessibilityService` 等），真实样本立刻误报：
    // 飞牛TV 的「无障碍」来自 Material 的 `MaterialAutoCompleteTextView`
    // 查询 `AccessibilityServiceInfo` —— 子串匹配把 UI 库的正常调用算成了
    // 无障碍服务。可靠判据是组件上的 `android:permission`。
    final specialAccessKinds = specialAccessFromComponents(meta.components);
    final hasSensitiveSource =
        sensitiveSourceClues.isNotEmpty || sensitiveSourceCodeRefs.isNotEmpty;

    // 运行时 DEX 加载：被加载的代码不在 DEX 里，静态分析**看不到**。
    // 这不是风险结论，是覆盖范围的说明。
    // 两个入口都要：`DexClassLoader` 与 `PathClassLoader` 是同一类东西。
    const dynamicLoadingMarkers = {'dynamic-loading', 'dynamic-loading-path'};
    final hasDynamicLoading =
        scan.clues.any((c) => dynamicLoadingMarkers.contains(c.markerId)) ||
            methodScan.references
                .any((r) => dynamicLoadingMarkers.contains(r.markerId));

    // WebView / JS 桥：`addJavascriptInterface` 是 Android 最经典的 RCE 面。
    const webViewMarkers = {
      'webview-js-bridge',
      'webview-js-enabled',
      'webview-file-access',
    };
    final webViewClues =
        scan.clues.where((c) => webViewMarkers.contains(c.markerId)).toList();
    final webViewCodeRefs = codeRefsOf(webViewMarkers);

    // 「声明了权限但代码里没有对应 API」。
    //
    // 只对**有明确代码证据**的权限做这个判断：读通讯录必然要碰
    // `ContactsContract`，读短信必然要碰 `SmsManager`。反过来，
    // 有些权限的用法太杂（如 `WRITE_EXTERNAL_STORAGE` 可能只走
    // `File` API），硬判会误报，所以**不编目的一律不判**。
    final unusedPermissionNames = <String>[];
    if (dexEntries.isNotEmpty) {
      final usedMarkerIds = <String>{
        for (final c in scan.clues) c.markerId,
        for (final r in methodScan.references) r.markerId,
      };
      for (final request in permissionRequests) {
        // sdk-23 声明是否生效无法静态判定，不参与这个判断。
        if (request.sdk23Only) continue;
        final markers = _permissionApiMarkers[request.name];
        if (markers == null) continue;
        if (markers.any(usedMarkerIds.contains)) continue;
        if (unusedPermissionNames.contains(request.shortName)) continue;
        unusedPermissionNames.add(request.shortName);
      }
    }

    final hasOcrCapability = ocrClues.isNotEmpty || ocrCodeRefs.isNotEmpty;
    final hasUploadCapability =
        uploadClues.isNotEmpty || uploadCodeRefs.isNotEmpty;

    // ---- 权限逐条审计 ----
    final effectivePhotoAccess = <AndroidPermissionRequest>[];
    final broadStorage = <AndroidPermissionRequest>[];
    final backgroundPermissions = <AndroidPermissionRequest>[];

    for (final request in permissionRequests) {
      // sdk-23 声明单独在下面处理（它的生效条件无法静态判定），
      // 不走常规目录，否则同一条权限会产出两份重复的发现。
      if (request.sdk23Only) continue;
      final rule = PermissionCatalog.lookup(request.name);
      if (rule == null) continue; // 未编目的稍后汇总
      if (rule.category == SecurityCategory.backgroundTask) {
        backgroundPermissions.add(request);
      }
      final verdict = _versionVerdict(request, rule, targetSdk);
      if (!verdict.effective) {
        // 版本条件不满足：只作事实记录，不计入组合规则的输入。
        findings.add(SecurityFinding(
          ruleId: 'ANDROID-PERMISSION-EXPIRED',
          platform: SecurityPlatform.android,
          category: rule.category,
          severity: SecuritySeverity.info,
          confidence: SecurityConfidence.confirmed,
          finding: '${request.shortName}: ${verdict.note}',
          messageCode: 'android.permission_expired',
          messageArgs: {
            'name': request.shortName,
            'noteCode': verdict.noteCode,
            'noteArgs': verdict.noteArgs,
          },
          evidence: [manifestEvidence(request)],
          limitation: 'The version condition is judged against '
              'targetSdk=$targetSdk; if the actual device version differs, '
              'the device is authoritative.',
          limitationCode: 'android.permission_expired.limitation',
          limitationArgs: {'targetSdk': '$targetSdk'},
          recommendation: 'This declaration does not grant actual access '
              'capability under the current target version; keep it under '
              'observation.',
          recommendationCode: 'android.permission_expired.keep_observing',
        ));
        continue;
      }
      if (verdict.partial) {
        // 生效但效果被削弱（例如 Android 13 后的旧版存储权限）。
        findings.add(SecurityFinding(
          ruleId: 'ANDROID-PERMISSION-INERT',
          platform: SecurityPlatform.android,
          category: rule.category,
          severity: SecuritySeverity.p3,
          confidence: SecurityConfidence.confirmed,
          finding: '${request.shortName}: ${verdict.note}',
          messageCode: 'android.permission_inert',
          messageArgs: {
            'name': request.shortName,
            'noteCode': verdict.noteCode,
            'noteArgs': verdict.noteArgs,
          },
          evidence: [manifestEvidence(request)],
          recommendation: 'Confirm whether the app still relies on the legacy '
              'behaviour of this permission; on a high targetSdk it is '
              'usually superseded by scoped storage.',
          recommendationCode: 'android.permission_inert.check_legacy',
        ));
      }

      if (rule.category == SecurityCategory.photoAccess) {
        effectivePhotoAccess.add(request);
        if (rule.name == 'MANAGE_EXTERNAL_STORAGE' ||
            (rule.name == 'READ_EXTERNAL_STORAGE' &&
                (targetSdk == null || targetSdk <= 32) &&
                !verdict.partial)) {
          broadStorage.add(request);
        }
      }

      if (!verdict.partial) {
        findings.add(SecurityFinding(
          ruleId: 'ANDROID-PERMISSION-${rule.name}',
          platform: SecurityPlatform.android,
          category: rule.category,
          severity: rule.baseSeverity,
          confidence: SecurityConfidence.confirmed,
          finding: verdict.note.isEmpty
              ? rule.description
              : '${rule.description} (${verdict.note})',
          // 有版本说明时用带 note 的变体。呈现层按 `noteCode` 能否解析出
          // 本地化文本来决定用哪个 —— 解析不出就整条回退，不渲染半句话。
          messageCode: verdict.note.isEmpty
              ? 'android.permission_rule'
              : 'android.permission_rule_with_note',
          messageArgs: {
            'name': rule.name,
            'noteCode': verdict.noteCode,
            'noteArgs': verdict.noteArgs,
          },
          evidence: [manifestEvidence(request)],
          limitation: 'A permission declaration is only an intent; it does '
              'not prove the app actually accessed the corresponding data at '
              'runtime.',
          limitationCode: 'android.permission_rule.limitation',
          recommendation: rule.riskNote,
          recommendationCode: 'android.permission_rule.risk_note',
        ));
      }
    }

    // 未编目权限：汇总一条，不逐条刷屏。
    final uncatalogued = permissionRequests
        .where((r) => !r.sdk23Only && PermissionCatalog.lookup(r.name) == null)
        .toList();
    if (uncatalogued.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-PERMISSION-UNCATEGORIZED',
        platform: SecurityPlatform.android,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: 'Another ${uncatalogued.length} permission(s) are not in the '
            'risk catalogue. Recorded as fact only: ${[
          ...uncatalogued.take(20).map((r) => r.shortName),
          if (uncatalogued.length > 20) '…',
        ].join(', ')}',
        messageCode: 'android.permission_uncategorized',
        messageArgs: {
          'count': uncatalogued.length,
          'names': [
            ...uncatalogued.take(20).map((r) => r.shortName),
            if (uncatalogued.length > 20) '…',
          ],
        },
        evidence:
            uncatalogued.take(20).map((r) => manifestEvidence(r)).toList(),
        recommendation: 'Not being catalogued does not mean there is no '
            'risk: to assess these permissions, check them against the '
            'Android permission documentation manually.',
        recommendationCode: 'android.permission_uncategorized.manual_review',
      ));
    }
    for (final request in permissionRequests.where((r) => r.sdk23Only)) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-PERMISSION-SDK23-CONDITIONAL',
        platform: SecurityPlatform.android,
        category: PermissionCatalog.lookup(request.name)?.category ??
            SecurityCategory.other,
        severity: SecuritySeverity.unknown,
        confidence: SecurityConfidence.unknown,
        finding: '${request.shortName} is declared with '
            '<uses-permission-sdk-23>, so it is only granted on devices '
            'running API < 23; the device version cannot be determined '
            'statically from the package.',
        messageCode: 'android.permission_sdk23_conditional',
        messageArgs: {'name': request.shortName},
        evidence: [manifestEvidence(request)],
        limitation: 'targetSdk is not a substitute for the device API level: '
            'the two can differ.',
        limitationCode: 'android.permission_sdk23_conditional.limitation',
        recommendation: 'For a conclusion, verify on a device running the '
            'target system version.',
        recommendationCode: 'android.permission_sdk23_conditional.verify',
      ));
    }

    // ---- 原生库符号（第四层取证：C/C++ 代码不经过 Java 层）----
    //
    // DEX 的 method_ids 里看不到原生代码调用了什么。ELF 的 `.dynsym` 能补上
    // 这一块：导入的符号是精确的标识符，比字符串命中确定得多。
    final nativeScan = NativeSymbolScanner.scan(nativeEntries);

    // ---- 原生库的二进制加固属性 ----
    //
    // 只看**传进来的那些**库（与符号扫描同一批预算），并如实报出条数。
    // 不逐库产出发现项 —— 一个应用可能有上百个 .so，逐库报会把面板刷满，
    // 而绝大多数库的加固都是一样的（NDK 默认就对）。
    final hardening = <ElfHardening>[
      for (final entry in nativeEntries)
        readElfHardening(entry.name, entry.bytes),
    ];

    // ---- 第三方服务类 SDK 的盘点 ----
    //
    // **单独一条扫描路径**，不复用 `DexClueScanner`：
    // 后者是暴力扫全部字节、单 DEX 上限 8 MiB，而 DEX 的 `string_data`
    // 在文件后半部分 —— 实测抖音（55 DEX / 437 MiB）在默认预算下命中 **0**。
    // 这里按 `string_ids` 精确索引，只受 64 MiB/文件的硬上限约束。
    final dexByName = {for (final entry in dexEntries) entry.name: entry.bytes};
    final sdkInventory = SdkInventoryScanner.scan(
      [for (final entry in dexEntries) entry.name],
      (name) => dexByName[name],
    );

    // 资源表覆盖量由调用方给**实际读到的条目数**（`arscEntryCount`）。
    //
    // 旧实现用 `meta.locales.length + meta.densities.length` 反推，理由写在
    // 这里的历史注释里：「两个都空既可能是没有多语言/密度变体，也可能是没读到」。
    // 但那个歧义的方向搞反了 —— 单语言单密度的正常应用**必然**两项都空，
    // 于是「已解析」被稳定地报成「缺失」。判「读没读到」要用读取方的结果，
    // 不能用内容的形状去猜。
    for (final skipped in nativeScan.skippedForBudget) {
      limitations.add(AnalysisNote(
        'android.native_symbols.budget',
        'Native library scan budget: $skipped — this library was not analysed.',
        {'name': skipped},
      ));
    }
    if (nativeScan.notTraversable.isNotEmpty) {
      limitations.add(AnalysisNote(
        'android.native_symbols.not_traversable',
        '${nativeScan.notTraversable.length} native library(ies) have an '
            'untrustworthy structure, so their symbol tables were not read '
            '(${[
          ...nativeScan.notTraversable.take(3),
          if (nativeScan.notTraversable.length > 3) '…',
        ].join(', ')}): "no symbols found" on these libraries means "not looked '
            'at", not "none".',
        {
          'count': nativeScan.notTraversable.length,
          'names': [
            ...nativeScan.notTraversable.take(3),
            if (nativeScan.notTraversable.length > 3) '…',
          ],
        },
      ));
    }
    if (hasDynamicLoading) {
      // **必须说出来**：DexClassLoader 加载进来的代码不在归档里，
      // 静态分析的结论对那部分代码**不成立**。
      limitations.add(const AnalysisNote(
        'android.dex.dynamic_loading',
        'Runtime DEX loading clues (DexClassLoader) were found: code loaded '
            'at runtime is not inside the archive, so this analysis does not '
            'cover it.',
      ));
    }
    if (nativeSkipped.isNotEmpty) {
      // **这些库连打开都没打开过。** 此前 `selectLibraries` 挑剩下的那些
      // 在报告里完全不可见（`skipped` 字段没有消费者），于是读者看到
      // 「24/24 已覆盖」就以为原生层全查过了。
      limitations.add(AnalysisNote(
        'android.native_symbols.not_scanned',
        '${nativeSkipped.length} native library(ies) were not scanned at all '
            '(the selection cap is 24 libraries / 96 MiB): '
            '${nativeSkipped.take(3).join(', ')}'
            '${nativeSkipped.length > 3 ? ', …' : ''}',
        {'count': nativeSkipped.length},
      ));
    }
    if (nativeScan.skippedSymbols > 0) {
      limitations.add(AnalysisNote(
        'android.native_symbols.skipped',
        '${nativeScan.skippedSymbols} entries in the native symbol tables could '
            'not be read (name out of bounds or the entry crosses outside its '
            'section), so the symbols in those entries were not seen.',
        {'count': nativeScan.skippedSymbols},
      ));
    }
    if (nativeScan.truncated) {
      limitations.add(AnalysisNote(
        'android.native_symbols.truncated',
        'Reading the symbol tables of some native libraries hit the budget '
            'limit, so only part of the entries were analysed.',
      ));
    }
    if (nativeEntries.isNotEmpty) {
      limitations.add(AnalysisNote(
        'android.native_symbols.semantics',
        'The native symbols come from the ELF `.dynsym` section: they show which '
            'system capabilities the library **imports**, and **do not show** '
            'that those capabilities were called, let alone with what arguments. '
            'The native code was not disassembled.',
      ));
    }
    if (nativeScan.unstrippedLibraries.isNotEmpty) {
      limitations.add(AnalysisNote(
        'android.native_symbols.unstripped',
        '${nativeScan.unstrippedLibraries.length} native library(ies) have **not '
            'stripped** their symbol table (${[
          ...nativeScan.unstrippedLibraries.take(3).map((l) => l.name),
          if (nativeScan.unstrippedLibraries.length > 3) '…',
        ].join(', ')}): internal function names can be read. Release builds are '
            'usually stripped; this is a fact, not a risk verdict.',
        {
          'count': nativeScan.unstrippedLibraries.length,
          'names': [
            ...nativeScan.unstrippedLibraries.take(3).map((l) => l.name),
            if (nativeScan.unstrippedLibraries.length > 3) '…',
          ],
        },
      ));
    }

    // ---- 原生库导入的系统能力 ----
    if (nativeScan.symbols.isNotEmpty) {
      // 命令执行 / 动态加载 / 反调试归到一组：它们都是「这个库能做到什么」
      // 的直接证据，值得比纯网络能力多看一眼，但**都不构成恶意判定**。
      const elevated = {
        'system',
        'popen',
        'execl',
        'execlp',
        'execle',
        'execv',
        'execvp',
        'execvpe',
        'fork',
        'vfork',
        'posix_spawn',
        'dlopen',
        'android_dlopen_ext',
        'dlsym',
        'dladdr',
        'ptrace',
      };
      final elevatedHits =
          nativeScan.symbols.where((s) => elevated.contains(s.symbol)).toList();
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-NATIVE-SYMBOLS',
        platform: SecurityPlatform.android,
        category: elevatedHits.isNotEmpty
            ? SecurityCategory.backgroundTask
            : SecurityCategory.network,
        // p3 而不是 info：命令执行 / 动态加载 / 反调试是「库能做到什么」的
        // 直接证据，值得人工看一眼；但它们同样**不是**恶意判定。
        severity: elevatedHits.isNotEmpty
            ? SecuritySeverity.p3
            : SecuritySeverity.info,
        confidence: SecurityConfidence.independentCapability,
        finding: 'The native libraries import '
            '${nativeScan.symbols.length} system capabilities with a '
            'specific meaning: '
            '${nativeScan.symbols.map((s) => s.description).join(', ')}. This '
            'only proves these libraries **have the ability** to use them; '
            'it does not prove they are called, nor does it say anything '
            'about the arguments used.',
        messageCode: 'android.native_symbols',
        messageArgs: {
          'count': nativeScan.symbols.length,
          'symbols': nativeScan.symbols.map((s) => s.symbol).toList(),
        },
        evidence: [
          for (final hit in nativeScan.symbols)
            SecurityEvidence(
              source: SecurityEvidenceSource.nativeSymbol,
              location: hit.libraryNames.join(', '),
              detail: '${hit.symbol} (imported): ${hit.description}',
              detailCode: 'native_symbol.imported',
              detailArgs: {'symbol': hit.symbol},
            ),
        ],
        relationship: 'The symbols come from **undefined** (imported) '
            'entries in the ELF `.dynsym` — the dynamic linker resolves them '
            'at load time. A function the library defines itself under the '
            'same name is not counted.',
        relationshipCode: 'android.native_symbols.relationship',
        limitation: 'Import does not mean call: the native code was not '
            'disassembled, so it is unknown which code paths call these '
            'functions. Implementations that issue system calls directly via '
            '`syscall()` or call indirectly inside libc do not appear in the '
            'symbol table.',
        limitationCode: 'android.native_symbols.limitation',
        recommendation: 'To confirm the actual behaviour, analyse dynamically '
            'in an isolated environment (`strace` / Frida and similar). '
            'Importing `system` / `dlopen` alone is not a risk verdict — '
            'crash reporting, hot-fix and plugin frameworks all use them.',
        recommendationCode: 'android.native_symbols.manual_review',
      ));
    }

    // ---- OCR / 上传 / 网络 등能力发现（每条都带证据原文）----
    //
    // 证据分两种来源，**必须分开标注**：`dexString` 是字符串字面量命中，
    // `dexMethodReference` 是 method_ids 命中。后者强得多（字符串常量可以
    // 随便写），但两者都**不等于**「调用发生了」。
    if (screenCaptureClues.isNotEmpty || screenCaptureCodeRefs.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-SCREEN-CAPTURE',
        platform: SecurityPlatform.android,
        category: SecurityCategory.other,
        severity: SecuritySeverity.p3,
        confidence: SecurityConfidence.independentCapability,
        finding: 'Screen capture capability found '
            '(${_sourceParts(screenCaptureCodeRefs, screenCaptureClues)}). '
            'MediaProjection captures the whole screen content, which may '
            'include verification codes, chat messages and other sensitive '
            'information. This reports the capability only; it is not a '
            'malicious verdict.',
        messageCode: 'android.screen_capture',
        messageArgs: {
          'parts': {
            'codeRefs':
                screenCaptureCodeRefs.map((r) => r.description).toList(),
            'stringClues':
                screenCaptureClues.map((c) => c.description).toList(),
          },
        },
        evidence: [
          ...referenceEvidence(screenCaptureCodeRefs),
          ...clueEvidence(screenCaptureClues),
        ],
        limitation: 'MediaProjection requires an explicit per-session user '
            'consent dialog, so the presence of the API does not mean the app '
            'records the screen; it may only be prepared for a screen-sharing '
            'feature.',
        limitationCode: 'android.screen_capture.limitation',
        recommendation: 'Check what is captured and whether the user is told '
            'about it. Screen sharing / recording are legitimate features in '
            'many apps.',
        recommendationCode: 'android.screen_capture.review',
      ));
    }

    if (ocrClues.isNotEmpty || ocrCodeRefs.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-OCR-CAPABILITY',
        platform: SecurityPlatform.android,
        category: SecurityCategory.ocrImage,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.independentCapability,
        finding: 'Image text recognition capability found: '
            '${_sourceParts(ocrCodeRefs, ocrClues)}. This only reports the '
            'capability itself; it is not a malicious verdict.',
        messageCode: 'android.ocr_capability',
        // 只传**名字列表**：标签与分隔符都取自语言包。标记说明本来就是英文
        // （`codeMarkers` 里就是英文），因此不需要再查表。
        messageArgs: {
          'parts': {
            'codeRefs': ocrCodeRefs.map((r) => r.description).toList(),
            'stringClues': ocrClues.map((c) => c.description).toList(),
          },
        },
        evidence: [
          ...referenceEvidence(ocrCodeRefs),
          ...clueEvidence(ocrClues),
        ],
        relationship: ocrCodeRefs.isNotEmpty
            ? 'The "code reference" comes from method_ids: the bytecode '
                'references these methods, but that does not prove they are '
                'called at runtime (the instructions in code_item were not '
                'walked).'
            : 'All hits appear only in strings; no method_ids entry '
                'references them.',
        relationshipCode: ocrCodeRefs.isNotEmpty
            ? 'android.ocr_capability.relationship_code_refs'
            : 'android.ocr_capability.relationship_strings_only',
        limitation: 'Both code references and string hits **are not the same '
            'as a call happening**: the code paths were not verified by '
            'disassembly.',
        limitationCode: 'android.ocr_capability.limitation',
        recommendation: 'Confirm the input source of the recognition feature '
            '(user-provided / library scan) and where the result goes '
            '(processed locally / sent over the network).',
        recommendationCode: 'android.ocr_capability.check_pipeline',
      ));
    }

    if (uploadClues.isNotEmpty || uploadCodeRefs.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-UPLOAD-API',
        platform: SecurityPlatform.android,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.independentCapability,
        finding: 'Upload-related APIs or code found: '
            '${_sourceParts(uploadCodeRefs, uploadClues)}. This only proves '
            'the upload capability exists; it does not prove sensitive data '
            'was uploaded.',
        messageCode: 'android.upload_api',
        messageArgs: {
          'parts': {
            'codeRefs': uploadCodeRefs.map((r) => r.description).toList(),
            'stringClues': uploadClues.map((c) => c.description).toList(),
          },
        },
        evidence: [
          ...referenceEvidence(uploadCodeRefs),
          ...clueEvidence(uploadClues),
        ],
        relationship: uploadCodeRefs.isNotEmpty
            ? 'The "code reference" comes from method_ids: the bytecode '
                'references these methods/types, but that does not prove they '
                'are called at runtime.'
            : 'All hits appear only in strings (for example '
                'multipart/form-data is a request-header value, so it can '
                'only ever appear as a literal).',
        relationshipCode: uploadCodeRefs.isNotEmpty
            ? 'android.upload_api.relationship_code_refs'
            : 'android.upload_api.relationship_strings_only',
        recommendation: 'Manually confirm what is uploaded, what triggers it '
            'and the destination.',
        recommendationCode: 'android.upload_api.manual_review',
      ));
    }

    if (scan.domains.isNotEmpty || scan.ips.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-NETWORK-ENDPOINTS',
        platform: SecurityPlatform.android,
        category: SecurityCategory.network,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: 'Extracted from static strings: '
            '${_endpointParts(scan.domains, scan.ips)}. Static extraction '
            'does not mean these were actually visited at runtime — a domain '
            'in a string may be a configuration value, an SDK address or a '
            'fallback endpoint that is never contacted.',
        messageCode: 'android.network_endpoints',
        messageArgs: {
          'parts': {
            'domains': [
              ...scan.domains.take(12),
              if (scan.domains.length > 12) '…',
            ],
            'domainCount': scan.domains.length,
            'ips': [
              ...scan.ips.take(8),
              if (scan.ips.length > 8) '…',
            ],
            'ipCount': scan.ips.length,
          },
        },
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.dexString,
            location: 'strings of ${scan.scannedDexCount} DEX file(s)',
            locationCode: 'dex.strings',
            locationArgs: {'count': scan.scannedDexCount},
            detail: [...scan.domains.take(12), ...scan.ips.take(8)].join(', '),
          ),
        ],
        limitation: 'The string table does not contain every constructed URL '
            '(concatenation, encrypted configuration), nor does it reflect '
            'actual connections.',
        limitationCode: 'android.network_endpoints.limitation',
        recommendation: 'For unfamiliar domains, verify further with '
            'certificate pinning and traffic observation; an unfamiliar '
            'domain, the use of a CDN or encryption is not malicious '
            'evidence by itself.',
        recommendationCode: 'android.network_endpoints.verify',
      ));
    }

    // ---- 网络客户端库：字符串线索与代码引用分开陈述 ----
    //
    // 这一条同时补上了两处「只产出不消费」：网络类别的字符串线索此前没有任何
    // 规则读取，而方法引用是本次新增的产出。
    if (networkClues.isNotEmpty || networkCodeRefs.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-NETWORK-CLIENT',
        platform: SecurityPlatform.android,
        category: SecurityCategory.network,
        severity: SecuritySeverity.info,
        // 刻意**不用** `confirmed`：该枚举的语义是「同一可追踪路径上的证据」，
        // 而这里只证明「存在网络客户端代码」，没有任何数据流被追踪到。
        // 代码引用比字符串强，但那是**证据来源**上的差别，由 evidence 的
        // source 与 relationship 陈述，不靠抬高置信度来表达。
        confidence: SecurityConfidence.independentCapability,
        finding: 'Network client related code found '
            '(${_sourceParts(networkCodeRefs, networkClues)}). This only '
            'proves the network communication capability exists; it does not '
            'prove data was transferred, nor does it say where the data '
            'went.',
        messageCode: 'android.network_client',
        messageArgs: {
          'parts': {
            'codeRefs': networkCodeRefs.map((r) => r.description).toList(),
            'stringCluesOnly': networkClues.map((c) => c.description).toList(),
          },
        },
        evidence: [
          ...referenceEvidence(networkCodeRefs),
          ...clueEvidence(networkClues),
        ],
        relationship: networkCodeRefs.isNotEmpty
            ? 'The "code reference" comes from method_ids: it proves the '
                'bytecode references these methods/types, but not that they '
                'are called at runtime (the instructions in code_item were '
                'not walked). "String mention only" may be a configuration '
                'value, a commented-out literal or an SDK that is never used.'
            : 'All hits appear only in strings; no method_ids entry '
                'references them — the presence of these literals does not '
                'mean the implementation exists.',
        relationshipCode: networkCodeRefs.isNotEmpty
            ? 'android.network_client.relationship_code_refs'
            : 'android.network_client.relationship_strings_only',
        limitation: 'HTTP implementations using reflection, dynamic loading '
            'or a hardened shell do not appear in method_ids, so "no code '
            'reference" does not mean "no network communication".',
        limitationCode: 'android.network_client.limitation',
        recommendation: 'To confirm actual outbound traffic, combine this '
            'with certificate pinning, packet capture or enterprise-side '
            'traffic auditing; using some networking library is not a risk '
            'verdict by itself.',
        recommendationCode: 'android.network_client.manual_review',
      ));
    }

    // ---- 组合规则（数据驱动的规则表）----
    //
    // 规则本身在 `android_security_rules.dart`：**判定与构造分开**，
    // 每条只从 `AndroidRuleFacts` 取输入，互不读取对方的产物 ——
    // 抽表前「规则 B 里算出 `hasImageInput`，再由 C / D / E 读取」那种
    // 隐式顺序依赖没有了：调换表里两行的顺序只改变输出顺序，不改变结论。
    final facts = AndroidRuleFacts(
      meta: meta,
      scan: scan,
      methodScan: methodScan,
      effectivePhotoAccess: effectivePhotoAccess,
      broadStorage: broadStorage,
      backgroundPermissions: backgroundPermissions,
      photoClues: photoClues,
      ocrClues: ocrClues,
      uploadClues: uploadClues,
      backgroundClues: backgroundClues,
      ocrCodeRefs: ocrCodeRefs,
      uploadCodeRefs: uploadCodeRefs,
      hasOcrCapability: hasOcrCapability,
      hasUploadCapability: hasUploadCapability,
      hasDexContent: dexEntries.isNotEmpty,
      sensitiveSourceClues: sensitiveSourceClues,
      sensitiveSourceCodeRefs: sensitiveSourceCodeRefs,
      hasSensitiveSource: hasSensitiveSource,
      hasDynamicLoading: hasDynamicLoading,
      specialAccessKinds: specialAccessKinds,
      webViewClues: webViewClues,
      webViewCodeRefs: webViewCodeRefs,
      unusedPermissionNames: unusedPermissionNames,
      nativeHardening: [
        for (final h in hardening)
          if (h.parsed) h,
      ],
      sdkInventory: sdkInventory,
    );
    for (final rule in androidSecurityRules) {
      if (rule.matches(facts)) findings.add(rule.build(facts));
    }

    limitations.add(AnalysisNote(
      'android.offline_static_analysis',
      'This is an offline static analysis: the app was not installed, not run, '
          'and no network traffic was observed. Runtime evidence '
          '(includesRuntimeEvidence) is always false, and the report must not '
          'claim that behaviour has been confirmed on this basis.',
    ));
    limitations.add(AnalysisNote(
      'android.analysis.based_on_cooccurrence',
      'The OCR / upload / background conclusions are based on string markers '
          'co-occurring; no disassembly or cross-method data flow recovery was '
          'done, and obfuscation or dynamic loading may change the conclusions.',
    ));

    // ---- 结构化覆盖 ----
    //
    // 此前「覆盖了什么」散在 limitations 的句子里，UI 与报告只能各自去猜。
    // 这里收敛成带稳定 id 的数据，两者读同一份。
    // 覆盖说明用「三件套」：稳定 code + 英文回退 + 占位符实参。
    //
    // 引擎层不依赖 slang，产不出本地化文案，因此这里给的是**可映射的 id**；
    // 呈现层（`AnalysisReport.coverageNote`）按它取本地化文案，认不出来才回退
    // 到英文。英文是机器/日志语言，与 `CoverageStatus.label`、各 `failure`
    // 原因一致 —— 此前这里写的是中文，于是英文/日文/韩文报告里会混进中文。
    final coverage = AnalysisCoverage(entries: [
      CoverageEntry.noted(
        id: 'android.manifest',
        status:
            manifestParsed ? CoverageStatus.covered : CoverageStatus.notCovered,
        note: manifestParsed
            ? null
            : (
                'android.manifest.unparsed',
                'AndroidManifest.xml could not be parsed '
                    '(${manifestFailureReason ?? 'reason not recorded'})',
                {'reason': manifestFailureReason ?? 'reason not recorded'},
              ),
      ),
      CoverageEntry.noted(
        id: 'android.permissions',
        status:
            manifestParsed ? CoverageStatus.covered : CoverageStatus.notCovered,
        covered: manifestParsed ? permissionRequests.length : null,
        note: manifestParsed
            ? null
            : (
                'android.permissions.manifest_unparsed',
                'Manifest not parsed; the permission audit cannot run',
                const <String, Object>{},
              ),
      ),
      CoverageEntry.noted(
        id: 'android.dex.structure',
        status: dexEntries.isEmpty
            ? CoverageStatus.notCovered
            : (untraversable.isEmpty
                ? CoverageStatus.covered
                : CoverageStatus.partial),
        covered: structures.length - untraversable.length,
        limit: structures.length,
        note: dexEntries.isEmpty
            ? (
                'android.dex.no_content',
                'No classes.dex content was read',
                const <String, Object>{},
              )
            : (untraversable.isEmpty
                ? null
                : (
                    'android.dex.structure_untrusted',
                    '${untraversable.length} DEX file(s) have an '
                        'untrustworthy structure',
                    {'count': untraversable.length},
                  )),
      ),
      CoverageEntry.noted(
        id: 'android.dex.strings',
        status: dexEntries.isEmpty
            ? CoverageStatus.notCovered
            : (scan.skippedForBudget.isEmpty
                ? CoverageStatus.covered
                : CoverageStatus.partial),
        covered: scan.scannedBytes,
        // `limit` = 所有 DEX 的字节数之和。没有它，`covered` 只是一个孤立
        // 的大数字（实测 50,648,616），读者算不出「那是 437 MiB 的 11%」。
        limit: dexEntries.isEmpty
            ? null
            : dexEntries.fold<int>(0, (sum, e) => sum + e.bytes.length),
        note: dexEntries.isEmpty
            ? (
                'android.dex.no_content',
                'No classes.dex content was read',
                const <String, Object>{},
              )
            : (scan.skippedForBudget.isEmpty
                ? null
                : (
                    'android.dex.strings_not_fully_scanned',
                    '${scan.skippedForBudget.length} DEX file(s) were not '
                        'fully scanned',
                    {'count': scan.skippedForBudget.length},
                  )),
      ),
      CoverageEntry.noted(
        id: 'android.dex.methodReferences',
        status: methodScan.scannedDexCount == 0
            ? CoverageStatus.notCovered
            : ((methodScan.skippedEntries > 0 ||
                    methodScan.truncatedForBudget.isNotEmpty)
                ? CoverageStatus.partial
                : CoverageStatus.covered),
        covered: methodScan.scannedDexCount,
        limit: dexEntries.length,
        note: methodScan.scannedDexCount == 0
            ? (
                'android.dex.no_traversable_dex',
                'No DEX with a trustworthy structure; method references were '
                    'not analysed',
                const <String, Object>{},
              )
            : (methodScan.skippedEntries > 0
                ? (
                    'android.dex.method_entries_unreadable',
                    '${methodScan.skippedEntries} method_ids entries could not '
                        'be read',
                    {'count': methodScan.skippedEntries},
                  )
                : null),
      ),
      CoverageEntry.noted(
        id: 'android.dex.callSites',
        status: methodScan.walkedDexCount == 0
            ? CoverageStatus.notCovered
            : (methodScan.desyncedBodies.isEmpty
                ? CoverageStatus.covered
                : CoverageStatus.partial),
        covered: methodScan.callSiteCount,
        note: methodScan.walkedDexCount == 0
            ? (
                'android.dex.no_traversable_bodies',
                'No DEX method bodies to walk',
                const <String, Object>{},
              )
            : (methodScan.desyncedBodies.isEmpty
                ? null
                : (
                    'android.dex.desynced_bodies',
                    '${methodScan.desyncedBodies.length} method body(ies) were '
                        'not instruction-aligned',
                    {'count': methodScan.desyncedBodies.length},
                  )),
      ),
      CoverageEntry.noted(
        id: 'android.nativeSymbols',
        status: nativeEntries.isEmpty
            ? CoverageStatus.notApplicable
            : ((nativeScan.skippedForBudget.isNotEmpty ||
                    nativeScan.notTraversable.isNotEmpty ||
                    nativeScan.truncated ||
                    // **被选中阶段跳过的库也算未覆盖** —— 它们根本没被打开过。
                    nativeSkipped.isNotEmpty)
                ? CoverageStatus.partial
                : CoverageStatus.covered),
        covered: nativeScan.libraries.length,
        // `limit` 用**全包唯一库名数**，不是「传进来几个」。用后者会让
        // 「266 个唯一库只扫了 24 个」显示成「24/24 已覆盖」。
        limit: nativeLibraryTotal ?? nativeEntries.length,
        note: nativeEntries.isEmpty
            ? (
                'android.native_symbols.not_provided',
                'No native library content was provided '
                    '(no lib/**.so, or none was read)',
                const <String, Object>{},
              )
            : (nativeScan.skippedForBudget.isNotEmpty
                ? (
                    'android.native_symbols.skipped_for_budget',
                    '${nativeScan.skippedForBudget.length} native library(ies) '
                        'were skipped due to the budget',
                    {'count': nativeScan.skippedForBudget.length},
                  )
                : null),
      ),
      // 明文流量策略：**只有真的判不出来时才标 partial**。
      //
      // `android:usesCleartextTraffic` 只在没有 `android:networkSecurityConfig`
      // 时生效；声明了 NSC 之后平台只看 NSC（那份 XML 会被展开，
      // `NetworkSecurityConfig.resolvedAllowsCleartext` 给出结论）。
      // 未声明该属性时取**平台默认值**（API 28 起默认禁止），
      // 只有连 targetSdk 都不知道时才「判不了」。
      //
      // 不写这一条的话，规则 D 在 NSC 存在时会**静默消失** ——
      // 用户看到「没有明文流量问题」，而真相是「我们没看」。
      CoverageEntry.noted(
        id: 'android.cleartextPolicy',
        status: facts.cleartextPolicyUnknown
            ? CoverageStatus.partial
            : CoverageStatus.covered,
        covered: facts.cleartextPolicyUnknown ? 0 : 1,
        limit: 1,
        // 两种「判不了」的原因要分开说：一个是 NSC 没展开，一个是连
        // targetSdk 都没有、推不出平台默认值。共用一句会让后者显示一句
        // 与事实不符的解释。
        note: switch (facts.cleartextPolicyUnknownReason) {
          null => null,
          'nsc_not_expanded' => (
              'android.cleartext_policy_unknown',
              'android:networkSecurityConfig is present, so '
                  'android:usesCleartextTraffic is ignored; the config '
                  'itself could not be expanded, so the cleartext policy is '
                  'not judged',
              const <String, Object>{},
            ),
          _ => (
              'android.cleartext_policy_target_sdk_unknown',
              'Neither android:usesCleartextTraffic nor targetSdkVersion '
                  'could be read, so the platform default for cleartext '
                  'traffic cannot be derived',
              const <String, Object>{},
            ),
        },
      ),
      // 原生库二进制加固：**数字比逐库列举有用**。
      //
      // 「121 个库里 120 个是 Full RELRO」一眼就知道整体状况；
      // 而列 120 条「已加固」只会让人滚很久才看到那 1 个例外。
      //
      // `limit` 用**真正读过加固属性的库数**（不是传进来的条目数）——
      // 与 `android.nativeSymbols` 同一个口径问题：用后者会把
      // 「266 个库只看了 24 个」显示成「24/24 已覆盖」。
      // SDK 盘点：**这条盘点是独立于 DEX 字符串扫描的**，所以覆盖率要单列。
      //
      // 用 `string_ids` 精确索引（`SdkInventory.scannedDexCount`），
      // 不受 `android.dex.strings` 那个 48 MiB 总预算的约束 —— 这也是它
      // 能在抖音（55 DEX / 437 MiB）上扫到东西的原因。
      CoverageEntry.noted(
        id: 'android.sdkInventory',
        status: facts.sdkInventory.totalDexCount == 0
            ? CoverageStatus.notApplicable
            : (facts.sdkInventory.complete
                ? CoverageStatus.covered
                : CoverageStatus.partial),
        covered: facts.sdkInventory.scannedDexCount,
        limit: facts.sdkInventory.totalDexCount,
        note: facts.sdkInventory.totalDexCount == 0
            ? (
                'android.sdk_inventory.no_dex',
                'No DEX content was provided, so the third-party SDK '
                    'inventory was not built',
                const <String, Object>{},
              )
            : (facts.sdkInventory.complete
                ? null
                : (
                    'android.sdk_inventory.incomplete',
                    '${facts.sdkInventory.truncated.length} DEX file(s) were '
                        'truncated and ${facts.sdkInventory.failures.length} '
                        'could not be read; SDKs that only appear in those '
                        'regions are not listed',
                    {
                      'truncated': facts.sdkInventory.truncated.length,
                      'failed': facts.sdkInventory.failures.length,
                    },
                  )),
      ),
      CoverageEntry.noted(
        id: 'android.nativeHardening',
        // `status` 与 `covered/limit` 必须回答**同一个问题**，否则面板上那行
        // 「部分覆盖 … 8/10」会被读成「覆盖了 80%」。
        //
        // 这里的问题是「原生库的加固属性读到了多少」，所以两个数字都是
        // **库数**：已解析 / 全包唯一库。此前 `covered` 数的是「加固得好的
        // 库」（fullRelro 且不可执行栈），`limit` 是「已解析的库」——
        // 266 个库只解析 10 个时会显示 8/10，而真实覆盖率是 10/266。
        // 这与已修的 `android.nativeSymbols`、`android.arsc` 是同一类错误。
        // 加固**质量**留在 note 里（`some_without_relro`），那是另一个问题。
        status: facts.nativeHardening.isEmpty
            ? CoverageStatus.notApplicable
            : (facts.nativeHardening.length == nativeLibraryTotal ||
                    nativeLibraryTotal == null
                ? CoverageStatus.covered
                : CoverageStatus.partial),
        covered:
            facts.nativeHardening.isEmpty ? null : facts.nativeHardening.length,
        limit: facts.nativeHardening.isEmpty
            ? null
            : (nativeLibraryTotal ?? facts.nativeHardening.length),
        note: facts.nativeHardening.isEmpty
            ? (
                'android.native_hardening.not_provided',
                'No native library content was provided, so the binary '
                    'hardening attributes were not read',
                const <String, Object>{},
              )
            : (facts.noRelroLibraries.isNotEmpty
                ? (
                    'android.native_hardening.some_without_relro',
                    '${facts.noRelroLibraries.length} of '
                        '${facts.nativeHardening.length} native library(ies) '
                        'lack RELRO; this is not reported as a finding '
                        'because it is a legitimate build choice (for '
                        'example Flutter\'s libapp.so) and would otherwise '
                        'flag every Flutter app',
                    {
                      'count': facts.noRelroLibraries.length,
                      'total': facts.nativeHardening.length,
                    },
                  )
                : null),
      ),
      CoverageEntry.noted(
        id: 'android.arsc',
        // `null` = 没读到（文件不存在 / 被预算拒绝 / 解析失败）；
        // `0` 也是一个已读到的空表 —— 与「缺失」不同，但结论一样是「没有
        // 资源可用」，因此两者都标 notCovered，只是 note 不同。
        status: (arscEntryCount ?? 0) == 0
            ? CoverageStatus.notCovered
            : CoverageStatus.covered,
        covered: arscEntryCount,
        note: (arscEntryCount ?? 0) > 0
            ? null
            : (arscEntryCount == null
                ? (
                    'android.arsc.missing',
                    'Resource table missing or unparsable',
                    const <String, Object>{},
                  )
                : (
                    'android.arsc.empty',
                    'The resource table was parsed but contains no entries',
                    const <String, Object>{},
                  )),
      ),
      // 签名材料（APK Signing Block 的结构可读性）。
      //
      // 这一维此前**不存在**：签名块读不出来时，`v1Only` 与 `hasV1Signature`
      // 都推不出结论，于是 `ANDROID-V1-ONLY-SIGNING` 与 `ANDROID-UNSIGNED`
      // 两条都不报，覆盖表里也没有任何一格提到签名 —— 「我们没读到签名块」
      // 这件事在报告里完全不可见，只剩一行日志。而签名块结构被破坏恰恰是
      // 重打包的典型痕迹。
      //
      // 它回答的是**结构能不能读**，不是「签名有没有效」—— 后者只交给
      // apksigner（`SignatureStatus`），两者不能混为一谈。
      CoverageEntry.noted(
        id: 'android.signature',
        status: meta.signingSchemes == null
            ? CoverageStatus.notCovered
            : (!meta.signingSchemes!.parsed
                ? CoverageStatus.notCovered
                : (meta.hasV1Signature == null
                    ? CoverageStatus.partial
                    : CoverageStatus.covered)),
        covered: meta.signingSchemes?.parsed == true ? 1 : 0,
        limit: 1,
        note: switch (meta.signingSchemes) {
          null => (
              'android.signature.not_read',
              'The APK Signing Block was not examined, so the v2+ signature '
                  'schemes are unknown',
              const <String, Object>{},
            ),
          final s when !s.parsed => (
              'android.signature.unreadable',
              'The APK Signing Block could not be read '
                  '(${s.failure ?? 'reason not recorded'}): "no signature '
                  'block" cannot be concluded, and the signature schemes are '
                  'unknown',
              <String, Object>{'reason': s.failure ?? 'reason not recorded'},
            ),
          _ when meta.hasV1Signature == null => (
              'android.signature.v1_undetermined',
              'The v2+ signing block was read, but whether a v1 (JAR) '
                  'signature exists could not be determined',
              const <String, Object>{},
            ),
          _ => null,
        },
      ),
    ]);

    return SecurityAnalysisResult(
      engineVersion: engineVersion,
      rulesVersion: rulesVersion,
      // 逐条去掉 finding **内部**完全相同的证据（缺陷 D9：同一份 DEX 标记
      // 可能被同一规则重复收集）。跨 finding 的重复保留，理由见
      // `SecurityFinding.withDedupedEvidence` 的注释。
      findings: [for (final f in findings) f.withDedupedEvidence()],
      limitations: limitations,
      coverage: coverage,
      // 网络端点单列成一级字段：报告要能回答「包里写了哪些域名」，
      // 而不要求消费者去解析发现项的证据文本。
      network: NetworkFacts(domains: scan.domains, ips: scan.ips),
    );
  }

  /// 版本条件判定结果。
  ///
  /// - [effective]：该请求在 targetSdk 下是否仍然生效；
  /// - [partial]：生效但效果被大幅削弱（例如 Android 13 后的旧版存储权限）；
  /// - [note]：给用户看的原因说明。
  static _Verdict _versionVerdict(
    AndroidPermissionRequest request,
    PermissionRule rule,
    int? targetSdk,
  ) {
    if (request.sdk23Only) {
      return const _Verdict(effective: true, partial: false, note: '');
    }
    if (request.maxSdkVersion != null) {
      final max = request.maxSdkVersion!;
      if (targetSdk != null && targetSdk > max) {
        return _Verdict(
          effective: false,
          partial: false,
          note: 'The permission declares maxSdkVersion=$max, while the app '
              'targets targetSdk=$targetSdk, so the system no longer grants '
              'it (ineffective on Android ${max + 1}+).',
          noteCode: 'max_sdk',
          noteArgs: {
            'max': max,
            'targetSdk': targetSdk,
            'next': max + 1,
          },
        );
      }
      return const _Verdict(effective: true, partial: false, note: '');
    }
    if (rule.minApi != null && targetSdk != null && targetSdk < rule.minApi!) {
      return _Verdict(
        effective: true,
        partial: false,
        note: 'A permission aimed at API ${rule.minApi}+, while the app '
            'targets targetSdk=$targetSdk: the effective model may be the '
            'legacy one; judge it together with minSdk.',
        noteCode: 'min_api',
        noteArgs: {'minApi': rule.minApi!, 'targetSdk': targetSdk},
      );
    }
    if (rule.maxApiEffectiveAbove != null && targetSdk != null) {
      if (targetSdk > rule.maxApiEffectiveAbove!) {
        return _Verdict(
          effective: true,
          partial: true,
          note: 'targetSdk=$targetSdk is higher than API '
              '${rule.maxApiEffectiveAbove}, so the effective behaviour of '
              'this permission is largely reduced by scoped storage.',
          noteCode: 'max_api_effective_above',
          noteArgs: {
            'targetSdk': targetSdk,
            'maxApi': rule.maxApiEffectiveAbove!,
          },
        );
      }
    }
    return const _Verdict(effective: true, partial: false, note: '');
  }

  /// 描述「识别与上传的调用指令是否位于同一个方法体内」。
  ///
  /// 这是调用点分析带来的新信息：字符串同现只能说「两个词都出现在这个包里」。
  /// 但措辞必须守住界线 —— **同一个方法里既有识别又有上传，不等于识别结果被
  /// 送进了上传请求**，那要看寄存器与参数传递，属于数据流分析。
  /// 英文回退里的「代码引用 / 字符串提及」分项。
  ///
  /// 呈现层用**同一份列表**按语言包组装（见
  /// `AnalysisReport._evidencePartsText`），因此这里只需要保证**元素与顺序
  /// 一致**；标签与分隔符都在语言包里，不在引擎里。
  static String _sourceParts(
    List<CodeReference> references,
    List<CodeClue> clues,
  ) {
    final parts = <String>[
      if (references.isNotEmpty)
        'code references: ${references.map((r) => r.description).join(', ')}',
      if (clues.isNotEmpty)
        'string mentions: ${clues.map((c) => c.description).join(', ')}',
    ];
    return parts.join('; ');
  }

  /// 英文回退里的「域名 / IP」分项。
  static String _endpointParts(List<String> domains, List<String> ips) {
    final parts = <String>[
      if (domains.isNotEmpty)
        'domains (${domains.length}): ${[
          ...domains.take(12),
          if (domains.length > 12) '…',
        ].join(', ')}',
      if (ips.isNotEmpty)
        'IP addresses (${ips.length}): ${[
          ...ips.take(8),
          if (ips.length > 8) '…',
        ].join(', ')}',
    ];
    return parts.join('; ');
  }

  /// 把方法引用转成证据条目。
  ///
  /// **引用与调用点分成两条证据**，因为它们回答的不是同一个问题：
  /// - 「引用」来自 `method_ids`，只说明字节码引用过这个方法（也可能只是
  ///   方法签名）；
  /// - 「调用点」来自 `code_item` 的 `invoke-*` 指令，能落到具体方法名与
  ///   指令偏移。
  ///
}

class _Verdict {
  final bool effective;
  final bool partial;

  /// 给用户看的版本条件说明（**英文回退**）。
  ///
  /// 引擎层不依赖 slang，产不出本地化文案 —— 与 `SecurityFinding.finding`
  /// 同一套「稳定 code + 英文回退 + 参数」的做法。
  final String note;

  /// [note] 的稳定标识与参数；空字符串表示「没有额外说明」。
  final String noteCode;
  final Map<String, Object> noteArgs;

  const _Verdict({
    required this.effective,
    required this.partial,
    required this.note,
    this.noteCode = '',
    this.noteArgs = const {},
  });
}
