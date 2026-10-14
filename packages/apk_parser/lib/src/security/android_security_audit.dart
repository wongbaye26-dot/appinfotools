import 'package:analysis_model/analysis_model.dart';

import '../dex/dex_structure.dart';
import '../models.dart';
import 'dex_clue_scanner.dart';
import 'dex_method_scanner.dart';
import 'native_symbol_scanner.dart';
import 'permission_catalog.dart';

/// Android 侧的安全审计编排。
///
/// 输入是**已经解析好的** [ApkMeta] 与 DEX 条目字节，不自己开归档 ——
/// 规格第六章要求「先检查现有代码组织，复用已有解析器」，因此这里只做
/// 规则匹配与定级，文件读取、ZIP 预算、解包都由调用方按既有管线完成。
///
/// 定级口径见 [PermissionCatalog] 与各规则的注释。总原则：**权限数量不决定
/// 等级**；未证实的数据流一律标 [SecurityConfidence.suspected] 并在
/// relationship 里写清哪个环节没被证实。
class AndroidSecurityAudit {
  AndroidSecurityAudit._();

  /// 引擎版本（与规则库版本分开：规则可以单独更新）。
  static const String engineVersion = 'android-security-1.1.0';

  static const String rulesVersion = PermissionCatalog.rulesVersion;

  /// [manifestParsed] 为 false 时必须给出原因（记入覆盖不足）。
  static SecurityAnalysisResult audit({
    required ApkMeta meta,
    required List<DexBytes> dexEntries,

    /// 原生库（`lib/**.so`）的名字与字节。空表示没有原生库或未提供。
    List<NativeLibraryBytes> nativeEntries = const [],
    bool manifestParsed = true,
    String? manifestFailureReason,
    List<String> containerAnomalies = const [],
  }) {
    final findings = <SecurityFinding>[];
    final limitations = <String>[];

    if (!manifestParsed) {
      limitations.add(
        'AndroidManifest.xml 未能解析（${manifestFailureReason ?? '原因未记录'}）：'
        '权限与组件审计无法进行，本次结果仅包含可读取的部分，'
        '不能作为完整结论。',
      );
    }

    final targetSdk = meta.targetSdkVersion;

    // ---- DEX 字符串扫描（第一层取证）----
    final scan = DexClueScanner.scan(dexEntries);
    for (final skipped in scan.skippedForBudget) {
      limitations.add('DEX 扫描预算：$skipped —— 该文件只扫描了部分内容，'
          '未覆盖的字节中可能存在未被发现的线索。');
    }
    if (dexEntries.isEmpty) {
      limitations.add('未读取到任何 classes.dex 内容：OCR、上传、网络域名等'
          '代码线索无法检查。权限与配置结论不受影响，但不构成完整分析。');
    } else {
      limitations.add('DEX 字符串扫描只覆盖 ${scan.scannedDexCount} 个文件、'
          '共 ${scan.scannedBytes} 字节，且仅提取可打印 ASCII 字符串：'
          '非 ASCII 字面量、原生库（lib/**.so）、资源文件与加固壳内的代码'
          '均不在覆盖范围内。');
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
        limitations.add(
          '${structure.name} 结构异常（${anomaly.code}）：${anomaly.message}',
        );
      }
      if (!structure.checksumVerified) {
        limitations.add('${structure.name} 超过 '
            '${kDexMaxChecksumBytes ~/ (1024 * 1024)} MiB，'
            '本次**未验证**校验和 —— 不要把「没报校验和异常」读成「校验和正确」。');
      }
    }
    final untraversable = [
      for (final s in structures)
        if (!s.isTraversable) s,
    ];
    if (untraversable.isNotEmpty) {
      limitations.add('${untraversable.length} 个 DEX 的结构不可信'
          '（${untraversable.map((s) => s.name).join('、')}）：'
          '这些文件上的字符串线索**不构成完整结论**，'
          '未覆盖的字节中可能存在未被发现的线索。');
    }

    // ---- DEX 方法引用（第三层取证：把「代码引用了」与「字符串提到了」分开）----
    //
    // `method_ids` 的条目只可能来自字节码的 invoke 指令、方法签名或方法句柄，
    // 不会来自字符串字面量。因此「命中」的含义比字符串线索强一档 ——
    // 但**仍然不等于「调用了」**：那要遍历 code_item 里的指令。
    final methodScan = DexMethodScanner.scan(dexEntries);
    if (methodScan.notTraversable.isNotEmpty) {
      limitations.add('${methodScan.notTraversable.length} 个 DEX 结构不可信，'
          '未做方法引用分析（${methodScan.notTraversable.join('、')}）：'
          '这些文件上的「没发现代码引用」是「没查到」，不是「没有」。');
    }
    if (methodScan.truncatedForBudget.isNotEmpty) {
      limitations.add('方法引用遍历达到预算上限，'
          '${methodScan.truncatedForBudget.join('、')} 只分析了部分条目。');
    }
    if (methodScan.skippedEntries > 0) {
      limitations.add('方法引用遍历中有 ${methodScan.skippedEntries} 个 '
          'method_ids 条目解析不出来（索引越界或字符串读不出来），'
          '这些条目里的引用未被看到。');
    }
    if (methodScan.desyncedBodies.isNotEmpty) {
      limitations.add('有 ${methodScan.desyncedBodies.length} 个方法体的指令'
          '遍历没有正好走到末尾（${methodScan.desyncedBodies.take(3).join('、')}'
          '${methodScan.desyncedBodies.length > 3 ? ' …' : ''}）：'
          '这些方法体上的**调用点不可信**，宽度表或载荷长度可能与该文件的'
          '实际形态不符。');
    }
    if (dexEntries.isNotEmpty && methodScan.scannedDexCount > 0) {
      limitations.add('方法引用来自 method_ids（证明代码**引用**了这些方法），'
          '调用点来自 code_item 里的 invoke 指令（证明**存在调用指令**）。'
          '两者都**不证明运行时执行过** —— 本次没有数据流分析，'
          '因此不知道参数与返回值是怎么传递的。');
    }
    if (methodScan.invokeCustomCount > 0) {
      limitations.add('有 ${methodScan.invokeCustomCount} 条 invoke-custom 指令：'
          '它们引用 call_site_ids 而不是 method_ids，本次未解析，'
          '因此这些调用**不在**调用点覆盖范围内。');
    }

    // 加固特征直接转化为覆盖不足说明（HardeningScanner 的输出）。
    for (final anomaly in containerAnomalies) {
      limitations.add('容器/解析异常可能影响覆盖完整性：$anomaly');
    }

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
    final networkClues = scan.clues
        .where((c) => c.category == SecurityCategory.network)
        .toList();
    final networkCodeRefs = methodScan.references
        .where((r) => r.category == SecurityCategory.network)
        .toList();

    // 规则输入用「能力是否存在」而不是「有没有字符串线索」：只看字符串会漏掉
    // 「代码引用了 MultipartBody，但字面量 multipart/form-data 从未出现」这类
    // 情况。两者分开保存，陈述时也要分开。
    final hasOcrCapability = ocrClues.isNotEmpty || ocrCodeRefs.isNotEmpty;
    final hasUploadCapability =
        uploadClues.isNotEmpty || uploadCodeRefs.isNotEmpty;

    // ---- 权限逐条审计 ----
    final effectivePhotoAccess = <AndroidPermissionRequest>[];
    final broadStorage = <AndroidPermissionRequest>[];
    final backgroundPermissions = <AndroidPermissionRequest>[];

    for (final request in meta.permissionRequests) {
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
          finding: '${request.shortName}：${verdict.note}',
          evidence: [_manifestEvidence(request)],
          limitation: '版本条件按 targetSdk=$targetSdk 判定；'
              '若实际设备版本不同，生效情况以设备为准。',
          recommendation: '该声明在当前目标版本下不构成实际访问能力，可保留观察。',
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
          finding: '${request.shortName}：${verdict.note}',
          evidence: [_manifestEvidence(request)],
          recommendation: '确认应用是否仍依赖该权限的旧行为；'
              '高 targetSdk 下它通常已被分区存储取代。',
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
          finding:
              '${rule.description}${verdict.note.isEmpty ? '' : '（${verdict.note}）'}',
          evidence: [_manifestEvidence(request)],
          limitation: '权限声明本身只是意图，不证明运行时一定访问了对应数据。',
          recommendation: rule.riskNote,
        ));
      }
    }

    // 未编目权限：汇总一条，不逐条刷屏。
    final uncatalogued = meta.permissionRequests
        .where((r) => !r.sdk23Only && PermissionCatalog.lookup(r.name) == null)
        .toList();
    if (uncatalogued.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-PERMISSION-UNCATEGORIZED',
        platform: SecurityPlatform.android,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: '另有 ${uncatalogued.length} 项权限未纳入风险目录，'
            '仅作事实记录：${uncatalogued.map((r) => r.shortName).take(20).join(', ')}'
            '${uncatalogued.length > 20 ? ' …' : ''}',
        evidence:
            uncatalogued.take(20).map((r) => _manifestEvidence(r)).toList(),
        recommendation: '未编目不等于无风险：如需评估这些权限，'
            '请对照 Android 权限文档人工确认。',
      ));
    }
    for (final request in meta.permissionRequests.where((r) => r.sdk23Only)) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-PERMISSION-SDK23-CONDITIONAL',
        platform: SecurityPlatform.android,
        category: PermissionCatalog.lookup(request.name)?.category ??
            SecurityCategory.other,
        severity: SecuritySeverity.unknown,
        confidence: SecurityConfidence.unknown,
        finding: '${request.shortName} 声明于 <uses-permission-sdk-23>，'
            '只在设备 API < 23 时授予；设备版本无法从安装包静态判定。',
        evidence: [_manifestEvidence(request)],
        limitation: 'targetSdk 不能代替设备 API 级别：两者可能不同。',
        recommendation: '如需结论，请在目标系统版本的设备上验证。',
      ));
    }

    // ---- 原生库符号（第四层取证：C/C++ 代码不经过 Java 层）----
    //
    // DEX 的 method_ids 里看不到原生代码调用了什么。ELF 的 `.dynsym` 能补上
    // 这一块：导入的符号是精确的标识符，比字符串命中确定得多。
    final nativeScan = NativeSymbolScanner.scan(nativeEntries);
    for (final skipped in nativeScan.skippedForBudget) {
      limitations.add('原生库扫描预算：$skipped —— 该库未参与分析。');
    }
    if (nativeScan.notTraversable.isNotEmpty) {
      limitations.add('${nativeScan.notTraversable.length} 个原生库的结构不可信，'
          '未读取符号表（${nativeScan.notTraversable.take(3).join('、')}'
          '${nativeScan.notTraversable.length > 3 ? ' …' : ''}）：'
          '这些库上的「没发现符号」是「没查到」，不是「没有」。');
    }
    if (nativeScan.skippedSymbols > 0) {
      limitations.add('原生符号表里有 ${nativeScan.skippedSymbols} 个条目读不出来'
          '（名字越界或条目跨出节外），这些条目里的符号未被看到。');
    }
    if (nativeScan.truncated) {
      limitations.add('部分原生库的符号表读取达到预算上限，只分析了部分条目。');
    }
    if (nativeEntries.isNotEmpty) {
      limitations.add('原生符号来自 ELF 的 `.dynsym` 节：它说明这个库**导入**'
          '了哪些系统能力，**不说明**这些能力被调用过、更不说明调用的参数。'
          '本次未反汇编原生代码。');
    }
    if (nativeScan.unstrippedLibraries.isNotEmpty) {
      limitations.add('${nativeScan.unstrippedLibraries.length} 个原生库**没有剥离**'
          '符号表（${nativeScan.unstrippedLibraries.take(3).map((l) => l.name).join('、')}'
          '${nativeScan.unstrippedLibraries.length > 3 ? ' …' : ''}）：'
          '能读到内部函数名。发布版本通常会剥离，这是一条事实，不是风险判定。');
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
        finding: '原生库导入了 ${nativeScan.symbols.length} 项有具体含义的系统能力：'
            '${nativeScan.symbols.map((s) => s.description).join('、')}。'
            '只证明这些库**有能力**使用它们，不证明被调用过，'
            '也不说明调用的参数。',
        evidence: [
          for (final hit in nativeScan.symbols)
            SecurityEvidence(
              source: SecurityEvidenceSource.nativeSymbol,
              location: hit.libraryNames.join(', '),
              detail: '${hit.symbol}（导入）: ${hit.description}',
            ),
        ],
        relationship: '符号来自 ELF `.dynsym` 的**未定义**（导入）条目 —— '
            '它们由动态链接器在加载时解析。库自己定义一个同名函数不会被算进来。',
        limitation: '导入不等于调用：未反汇编原生代码，'
            '因此不知道这些函数在哪些代码路径上被调用。'
            '使用 `syscall()` 直接发起系统调用、或经 libc 内部间接调用的'
            '实现不会出现在符号表里。',
        recommendation: '如需确认实际行为，请在隔离环境中动态分析'
            '（`strace` / Frida 等）；仅凭导入 `system` / `dlopen` '
            '不构成风险判定 —— 崩溃上报、热修复、插件化框架都会用到它们。',
      ));
    }

    // ---- OCR / 上传 / 网络 등能力发现（每条都带证据原文）----
    //
    // 证据分两种来源，**必须分开标注**：`dexString` 是字符串字面量命中，
    // `dexMethodReference` 是 method_ids 命中。后者强得多（字符串常量可以
    // 随便写），但两者都**不等于**「调用发生了」。
    if (ocrClues.isNotEmpty || ocrCodeRefs.isNotEmpty) {
      final sources = <String>[
        if (ocrCodeRefs.isNotEmpty)
          '代码引用 ${ocrCodeRefs.map((r) => r.description).join('、')}',
        if (ocrClues.isNotEmpty)
          '字符串提及 ${ocrClues.map((c) => c.description).join('、')}',
      ];
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-OCR-CAPABILITY',
        platform: SecurityPlatform.android,
        category: SecurityCategory.ocrImage,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.independentCapability,
        finding: '发现图像文字识别能力：${sources.join('；')}。'
            '仅发现能力本身，不判定恶意。',
        evidence: [
          ..._referenceEvidence(ocrCodeRefs),
          ..._clueEvidence(ocrClues),
        ],
        relationship: ocrCodeRefs.isNotEmpty
            ? '「代码引用」来自 method_ids：字节码引用过这些方法，'
                '但不证明它们在运行时被调用（未遍历 code_item 的指令）。'
            : '全部命中只出现在字符串里，没有任何 method_ids 条目引用它们。',
        limitation: '代码引用与字符串命中都**不等于调用发生**：'
            '代码路径未被反汇编验证。',
        recommendation: '确认识别功能的输入来源（用户主动提供 / 相册扫描）'
            '与结果去向（本地处理 / 网络发送）。',
      ));
    }

    if (uploadClues.isNotEmpty || uploadCodeRefs.isNotEmpty) {
      final sources = <String>[
        if (uploadCodeRefs.isNotEmpty)
          '代码引用 ${uploadCodeRefs.map((r) => r.description).join('、')}',
        if (uploadClues.isNotEmpty)
          '字符串提及 ${uploadClues.map((c) => c.description).join('、')}',
      ];
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-UPLOAD-API',
        platform: SecurityPlatform.android,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.independentCapability,
        finding: '发现上传相关 API 或代码：${sources.join('；')}。'
            '只证明存在上传能力，不证明上传了敏感数据。',
        evidence: [
          ..._referenceEvidence(uploadCodeRefs),
          ..._clueEvidence(uploadClues),
        ],
        relationship: uploadCodeRefs.isNotEmpty
            ? '「代码引用」来自 method_ids：字节码引用过这些方法/类型，'
                '但不证明它们在运行时被调用。'
            : '全部命中只出现在字符串里（例如 multipart/form-data 是请求头的'
                '取值，本来就只会以字面量形式出现）。',
        recommendation: '人工确认上传的内容、触发条件与目的地。',
      ));
    }

    if (scan.domains.isNotEmpty || scan.ips.isNotEmpty) {
      final parts = <String>[
        if (scan.domains.isNotEmpty)
          '域名 ${scan.domains.length} 个：${scan.domains.take(12).join(', ')}'
              '${scan.domains.length > 12 ? ' …' : ''}',
        if (scan.ips.isNotEmpty)
          'IP ${scan.ips.length} 个：${scan.ips.take(8).join(', ')}'
              '${scan.ips.length > 8 ? ' …' : ''}',
      ];
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-NETWORK-ENDPOINTS',
        platform: SecurityPlatform.android,
        category: SecurityCategory.network,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: '从静态字符串中提取到 ${parts.join('；')}。'
            '静态提取不等于运行时实际访问过 —— 域名出现在字符串里'
            '可能是配置项、SDK 地址或从未连接的备用端点。',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.dexString,
            location: '${scan.scannedDexCount} 个 DEX 的字符串',
            detail: [...scan.domains.take(12), ...scan.ips.take(8)].join(', '),
          ),
        ],
        limitation: '字符串表不包含全部构造式 URL（拼接、加密配置）'
            '，也不反映实际连接。',
        recommendation: '对陌生域名结合证书固定、流量观察进一步核实；'
            '仅凭域名陌生、使用 CDN 或加密不构成恶意证据。',
      ));
    }

    // ---- 网络客户端库：字符串线索与代码引用分开陈述 ----
    //
    // 这一条同时补上了两处「只产出不消费」：网络类别的字符串线索此前没有任何
    // 规则读取，而方法引用是本次新增的产出。
    if (networkClues.isNotEmpty || networkCodeRefs.isNotEmpty) {
      final parts = <String>[
        if (networkCodeRefs.isNotEmpty)
          '代码引用：'
              '${networkCodeRefs.map((r) => r.description).join('、')}',
        if (networkClues.isNotEmpty)
          '仅字符串提及：'
              '${networkClues.map((c) => c.description).join('、')}',
      ];
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
        finding: '发现网络客户端相关代码（${parts.join('；')}）。'
            '只证明存在网络通信能力，不证明发生过数据传输，'
            '也不说明数据去向。',
        evidence: [
          ..._referenceEvidence(networkCodeRefs),
          ..._clueEvidence(networkClues),
        ],
        relationship: networkCodeRefs.isNotEmpty
            ? '「代码引用」来自 method_ids：它证明字节码引用过这些方法/类型，'
                '但不证明它们在运行时被调用（未遍历 code_item 的指令）。'
                '「仅字符串提及」可能是配置项、注释式字面量或从未使用的 SDK。'
            : '全部命中都只出现在字符串里，没有任何 method_ids 条目引用它们 —— '
                '存在这些字面量不等于存在对应实现。',
        limitation: '使用反射、动态加载或加固壳的 HTTP 实现不会出现在 '
            'method_ids 里，因此「没有代码引用」不等于「没有网络通信」。',
        recommendation: '如需确认实际外联，请结合证书固定、网络抓包或'
            '企业侧流量审计；仅凭使用了某个网络库不构成风险判定。',
      ));
    }

    // ---- 规则 A：广泛相册访问 + 未见明显业务用途 ----
    if (broadStorage.isNotEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-RULE-A',
        platform: SecurityPlatform.android,
        category: SecurityCategory.photoAccess,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.suspected,
        finding: '发现广泛存储/相册访问：'
            '${broadStorage.map((r) => r.shortName).join('、')}，'
            '列为待人工复核的中风险候选项。'
            '本次分析未从安装包中发现与之对应的明显图片业务功能线索'
            '（如系统照片选择器调用、图片列表界面等）。',
        evidence: [
          for (final request in broadStorage) _manifestEvidence(request),
        ],
        limitation: '「缺少业务用途」是静态推断：业务代码可能位于未扫描的'
            '原生库、加固外壳或动态加载模块中。',
        recommendation: '人工复核该应用是否真的需要全盘文件访问；'
            '如不需要，建议改用系统照片选择器（Photo Picker）。'
            '本项为待复核候选项，不是恶意判定。',
      ));
    }

    // ---- 规则 B：相册访问 + OCR ----
    final hasImageInput =
        effectivePhotoAccess.isNotEmpty || photoClues.isNotEmpty;
    if (hasImageInput && hasOcrCapability) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-RULE-B',
        platform: SecurityPlatform.android,
        category: SecurityCategory.ocrImage,
        severity: SecuritySeverity.p2,
        confidence: SecurityConfidence.suspected,
        finding: '同时发现图像输入来源与文字识别能力：'
            '权限/代码线索（${[
          ...effectivePhotoAccess.map((r) => r.shortName),
          ...photoClues.map((c) => c.description),
        ].join('、')}）与识别能力（${ocrClues.map((c) => c.description).join('、')}）。'
            '该组合可能对应正常功能（文档扫描、翻译、名片识别）。',
        evidence: [
          for (final request in effectivePhotoAccess)
            _manifestEvidence(request),
          ..._referenceEvidence(ocrCodeRefs),
          ..._clueEvidence([...photoClues, ...ocrClues]),
        ],
        relationship: '图像输入 → 文字识别：两段线索同现，但未被证实位于'
            '同一条调用路径上。',
        limitation: '未反汇编，无法确认识别模块实际处理的是用户主动选择的'
            '图片还是批量扫描的媒体文件。',
        recommendation: '确认识别的输入来源与用户授权方式（是否走系统'
            '照片选择器）。',
      ));
    }

    // ---- 规则 C：相册 + OCR + 上传 ----
    if (hasImageInput && hasOcrCapability && hasUploadCapability) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-RULE-C',
        platform: SecurityPlatform.android,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p1,
        confidence: SecurityConfidence.suspected,
        finding: '发现「图像输入 + 文字识别 + 上传调用」三段线索同现，'
            '存在敏感数据外传的疑似链路。这是高风险**候选项**，'
            '静态分析未能证实数据确实流入上传请求。',
        evidence: [
          for (final request in effectivePhotoAccess)
            _manifestEvidence(request),
          ..._referenceEvidence([...ocrCodeRefs, ...uploadCodeRefs]),
          ..._clueEvidence([...ocrClues, ...uploadClues]),
        ],
        dataSource: '照片/媒体文件与其中的识别文本',
        dataSink: '上传请求（multipart / upload API）',
        relationship:
            '${_coOccurrenceNote(methodScan, ocrCodeRefs, uploadCodeRefs)}'
            '读取照片 → 图像文字识别 → 构建上传请求：三段分别有证据，'
            '但「同一代码路径上的数据流」未被证实 —— 未证实的环节是'
            '识别结果进入上传请求这一跳。',
        limitation: '关联来自多标记同现，不是调用图分析；反射、动态加载与'
            '加固均可能使真实链路不同。',
        recommendation: '优先人工复核；可在隔离环境中抓包验证实际外联内容'
            '（需动态测试，本版本不提供）。',
      ));
    }

    // ---- 规则 D：敏感数据 + 明文通信 ----
    if (meta.applicationUsesCleartextTraffic == true) {
      final withSensitive = hasImageInput ||
          hasOcrCapability ||
          hasUploadCapability ||
          scan.domains.isNotEmpty;
      findings.add(SecurityFinding(
        ruleId: withSensitive ? 'ANDROID-RULE-D-ESCALATED' : 'ANDROID-RULE-D',
        platform: SecurityPlatform.android,
        category: SecurityCategory.configuration,
        severity: withSensitive ? SecuritySeverity.p1 : SecuritySeverity.p2,
        confidence: SecurityConfidence.confirmed,
        finding: withSensitive
            ? '应用允许明文流量（usesCleartextTraffic=true），且同时存在'
                '图像/识别/上传相关线索：敏感数据可能经未加密链路传输。'
            : '应用允许明文流量（usesCleartextTraffic=true）。',
        evidence: [
          SecurityEvidence(
            source: SecurityEvidenceSource.manifest,
            location: 'AndroidManifest.xml / manifest / application',
            detail: 'android:usesCleartextTraffic="true"',
          ),
        ],
        limitation: '配置允许明文不等同于实际使用了明文；具体请求需抓包确认'
            '。networkSecurityConfig 的例外域未被展开。',
        recommendation: '确认是否存在明文传输的实际请求；'
            '如无必要应关闭该开关。',
      ));
    }

    // ---- 规则 E：后台 + 敏感数据 + 回传 ----
    final hasBackground = backgroundPermissions.isNotEmpty ||
        backgroundClues.isNotEmpty ||
        meta.components.any((c) =>
            c.type == ComponentType.service ||
            c.type == ComponentType.receiver);
    if (hasBackground &&
        (hasImageInput || hasOcrCapability) &&
        hasUploadCapability) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-RULE-E',
        platform: SecurityPlatform.android,
        category: SecurityCategory.backgroundTask,
        severity: SecuritySeverity.p1,
        confidence: SecurityConfidence.suspected,
        finding: '后台任务、敏感数据访问与上传调用三类线索同时存在，'
            '且相互印证：需在运行时进一步验证。仅发现后台任务或网络权限'
            '不构成恶意证据。',
        evidence: [
          for (final clue in backgroundClues)
            SecurityEvidence(
              source: SecurityEvidenceSource.dexString,
              location: clue.dexNames.join(', '),
              detail: '${clue.markerId}: ${clue.samples.join(' | ')}',
            ),
          if (backgroundPermissions.isNotEmpty)
            SecurityEvidence(
              source: SecurityEvidenceSource.manifest,
              location: 'AndroidManifest.xml / manifest / uses-permission',
              detail: backgroundPermissions
                  .map((r) => r.shortName)
                  .take(8)
                  .join(', '),
            ),
          for (final request in effectivePhotoAccess)
            _manifestEvidence(request),
        ],
        relationship: '后台入口 + 敏感数据来源 + 上传去路：三类证据同现，'
            '「后台是否实际处理并上传媒体数据」未获证实。',
        limitation: '未运行动态分析，后台任务的真实触发与执行无法观察。',
        recommendation: '在隔离环境执行并观察网络行为后确认。',
      ));
    }

    // ---- 规则 F：未发现上传特征 ----
    //
    // 规格规则 F：只能输出「当前分析范围内未发现相关特征」，不能输出
    // 「确认不存在恶意行为」。因此没有上传线索时**必须显式产出这一条**，
    // 而不是留一个空列表让人以为查过了就等于安全。
    if (uploadClues.isEmpty) {
      findings.add(SecurityFinding(
        ruleId: 'ANDROID-RULE-F',
        platform: SecurityPlatform.android,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.info,
        confidence: dexEntries.isEmpty
            ? SecurityConfidence.unknown
            : SecurityConfidence.confirmed,
        finding: '当前分析范围内未发现上传相关代码特征'
            '（未命中 multipart 上传、文件上传接口等标记）。'
            '这不表示应用不存在上传行为 —— 只说明本次静态扫描没有发现。',
        evidence: const [],
        limitation: dexEntries.isEmpty
            ? '本次未读取到 DEX 内容，「未发现」的置信度是不完整的。'
            : '字符串扫描不覆盖原生库、资源与加固壳内代码。',
        recommendation: '如需排除上传行为，请结合动态流量观察（本版本不提供）。',
      ));
    }

    limitations.add('本次为离线静态分析：未安装、未运行、未观察网络流量。'
        '运行时证据（includesRuntimeEvidence）恒为 false，'
        '报告不得据此声称已完成行为确认。');
    limitations.add('OCR / 上传 / 后台的判定基于字符串标记同现，'
        '未做反汇编与跨方法数据流还原；混淆与动态加载可能改变结论。');

    return SecurityAnalysisResult(
      engineVersion: engineVersion,
      rulesVersion: rulesVersion,
      // 逐条去掉 finding **内部**完全相同的证据（缺陷 D9：同一份 DEX 标记
      // 可能被同一规则重复收集）。跨 finding 的重复保留，理由见
      // `SecurityFinding.withDedupedEvidence` 的注释。
      findings: [for (final f in findings) f.withDedupedEvidence()],
      limitations: limitations,
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
          note: '该权限声明了 maxSdkVersion=$max，而应用 targetSdk=$targetSdk，'
              '系统不再授予（在 Android ${max + 1}+ 上不生效）。',
        );
      }
      return const _Verdict(effective: true, partial: false, note: '');
    }
    if (rule.minApi != null && targetSdk != null && targetSdk < rule.minApi!) {
      return _Verdict(
        effective: true,
        partial: false,
        note: '面向 API ${rule.minApi}+ 的权限，应用 targetSdk=$targetSdk：'
            '实际生效的可能是旧版访问模型，需结合 minSdk 判断。',
      );
    }
    if (rule.maxApiEffectiveAbove != null && targetSdk != null) {
      if (targetSdk > rule.maxApiEffectiveAbove!) {
        return _Verdict(
          effective: true,
          partial: true,
          note: 'targetSdk=$targetSdk 高于 API ${rule.maxApiEffectiveAbove}，'
              '该权限的实际效果已被分区存储大幅削弱。',
        );
      }
    }
    return const _Verdict(effective: true, partial: false, note: '');
  }

  static SecurityEvidence _manifestEvidence(AndroidPermissionRequest request) {
    return SecurityEvidence(
      source: SecurityEvidenceSource.manifest,
      location: 'AndroidManifest.xml / manifest / uses-permission'
          '[@name="${request.name}"]',
      detail: '$request',
    );
  }

  /// 描述「识别与上传的调用指令是否位于同一个方法体内」。
  ///
  /// 这是调用点分析带来的新信息：字符串同现只能说「两个词都出现在这个包里」。
  /// 但措辞必须守住界线 —— **同一个方法里既有识别又有上传，不等于识别结果被
  /// 送进了上传请求**，那要看寄存器与参数传递，属于数据流分析。
  static String _coOccurrenceNote(
    DexMethodScanResult scan,
    List<CodeReference> ocrReferences,
    List<CodeReference> uploadReferences,
  ) {
    final occurrence = scan.firstCoOccurrenceAcross(
      ocrReferences.map((r) => r.markerId),
      uploadReferences.map((r) => r.markerId),
    );
    if (occurrence == null) {
      return '文字识别与上传的调用指令**不在同一个方法体内**'
          '（同现发生在整个包的层面）。';
    }
    return '文字识别与上传的调用指令出现在**同一个方法体内**'
        '（${occurrence.callerDisplayName}）；'
        '但同一方法内共现不等于数据流：识别结果是否被送进上传请求'
        '未被证实。';
  }

  /// 把方法引用转成证据条目。
  ///
  /// **引用与调用点分成两条证据**，因为它们回答的不是同一个问题：
  /// - 「引用」来自 `method_ids`，只说明字节码引用过这个方法（也可能只是
  ///   方法签名）；
  /// - 「调用点」来自 `code_item` 的 `invoke-*` 指令，能落到具体方法名与
  ///   指令偏移。
  ///
  /// 合成一条会丢掉「是引用还是真的有一条调用指令」这个区别。
  static List<SecurityEvidence> _referenceEvidence(
    List<CodeReference> references,
  ) {
    return [
      for (final reference in references) ...[
        if (reference.samples.isNotEmpty)
          SecurityEvidence(
            source: SecurityEvidenceSource.dexMethodReference,
            location: reference.dexNames.join(', '),
            detail: '${reference.markerId}（引用）: '
                '${reference.samples.join(' | ')}',
          ),
        if (reference.callSiteSamples.isNotEmpty)
          SecurityEvidence(
            source: SecurityEvidenceSource.dexMethodReference,
            location: reference.dexNames.join(', '),
            detail: '${reference.markerId}（调用点）: '
                '${reference.callSiteSamples.join(' | ')}',
          ),
      ],
    ];
  }

  /// 把字符串线索转成证据条目。
  static List<SecurityEvidence> _clueEvidence(List<CodeClue> clues) {
    return [
      for (final clue in clues)
        SecurityEvidence(
          source: SecurityEvidenceSource.dexString,
          location: clue.dexNames.join(', '),
          detail: '${clue.markerId}: ${clue.samples.join(' | ')}',
        ),
    ];
  }
}

class _Verdict {
  final bool effective;
  final bool partial;
  final String note;

  const _Verdict({
    required this.effective,
    required this.partial,
    required this.note,
  });
}
