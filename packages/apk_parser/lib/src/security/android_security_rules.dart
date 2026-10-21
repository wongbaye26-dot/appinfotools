import 'package:analysis_model/analysis_model.dart';

import '../apk_signing_block.dart';
import '../native/elf_hardening.dart';
import 'sdk_inventory_scanner.dart';
import '../models.dart';
import 'dex_clue_scanner.dart';
import 'dex_method_scanner.dart';
import 'native_crypto_scan.dart';

/// 组合规则用到的**事实**：扫描结果的一次性归纳。
///
/// 抽这张表的直接动因是「顺序隐式依赖」：抽表前，规则 B 里算出的
/// `hasImageInput` 被规则 C / D / E 读取，于是**规则的书写顺序成了语义的一部分** ——
/// 调换两段就会改变结论，而读代码看不出来。
///
/// 现在每条规则只从**事实**里取输入，规则之间互不读取对方的产物，
/// 因此表里的顺序只影响输出顺序，不影响结论。
class AndroidRuleFacts {
  const AndroidRuleFacts({
    required this.meta,
    required this.scan,
    required this.methodScan,
    required this.effectivePhotoAccess,
    required this.broadStorage,
    required this.backgroundPermissions,
    required this.photoClues,
    required this.ocrClues,
    required this.uploadClues,
    required this.backgroundClues,
    required this.ocrCodeRefs,
    required this.uploadCodeRefs,
    required this.hasOcrCapability,
    required this.hasUploadCapability,
    required this.hasDexContent,
    required this.sensitiveSourceClues,
    required this.sensitiveSourceCodeRefs,
    required this.hasSensitiveSource,
    required this.hasDynamicLoading,
    required this.specialAccessKinds,
    required this.webViewClues,
    required this.webViewCodeRefs,
    required this.allClues,
    required this.allCodeRefs,
    required this.unusedPermissionNames,
    required this.nativeHardening,
    required this.sdkInventory,
    required this.nativeCrypto,
  });

  final ApkMeta meta;
  final DexScanResult scan;
  final DexMethodScanResult methodScan;

  /// 在当前 `targetSdk` 下**仍然生效**的相册 / 存储权限。
  final List<AndroidPermissionRequest> effectivePhotoAccess;

  /// 其中属于「广泛存储访问」的那部分（规则 A 的输入）。
  final List<AndroidPermissionRequest> broadStorage;

  final List<AndroidPermissionRequest> backgroundPermissions;

  final List<CodeClue> photoClues;
  final List<CodeClue> ocrClues;
  final List<CodeClue> uploadClues;
  final List<CodeClue> backgroundClues;

  final List<CodeReference> ocrCodeRefs;
  final List<CodeReference> uploadCodeRefs;

  final bool hasOcrCapability;
  final bool hasUploadCapability;

  /// 本次是否读到了 DEX 内容。影响规则 F 的置信度。
  final bool hasDexContent;

  /// 设备标识 / 通讯录的字符串线索。
  final List<CodeClue> sensitiveSourceClues;

  /// 同一批标记在**代码引用**层面的命中（比字符串强，但仍不等于调用）。
  final List<CodeReference> sensitiveSourceCodeRefs;

  /// 是否存在「非图片」的敏感数据来源（设备标识 / 通讯录）。
  final bool hasSensitiveSource;

  /// 原生库（`lib/**.so`）字符串里的「盗 U」信号。
  ///
  /// 钱包的密码学实现常被静态链接进 `.so` 且不导出符号 —— 符号表看不到，
  /// 但 `.rodata` 里的字符串还在。见 `native_crypto_scan.dart`。
  final NativeCryptoScanResult nativeCrypto;

  /// 第三方**服务类** SDK 的盘点结果（含覆盖情况）。
  ///
  /// 用 `string_ids` 精确索引扫的（`SdkInventoryScanner`），
  /// 不复用 `DexClueScanner` 的字节扫描 —— 后者的单 DEX 8 MiB 上限会
  /// 把 `string_data` 整段截掉，在大包上返回 0。
  final SdkInventory sdkInventory;

  /// 本次**真正解析了加固属性**的原生库（只含 `parsed == true` 的）。
  final List<ElfHardening> nativeHardening;

  /// 栈可执行的库（真正的缺陷：栈上数据能被当代码跑）。
  List<ElfHardening> get executableStackLibraries => [
        for (final h in nativeHardening)
          if (h.stackExecutable == true) h,
      ];

  /// 缺少 `PT_GNU_STACK` 的库。
  ///
  /// 旧工具链的产物；内核在部分架构上会按「可执行」处理。属于**未知**，
  /// 与「可执行栈」分开报 —— 前者是缺陷，后者是我们看不出来。
  List<ElfHardening> get unknownStackLibraries => [
        for (final h in nativeHardening)
          if (h.stackExecutable == null) h,
      ];

  /// 缺 RELRO 的库。
  ///
  /// **不单独报**：实测 121 个真实 .so 里只有 1 个缺（Flutter 的
  /// `libapp.so`，Dart AOT 快照，合法的构建选择）。逐库报等于给所有
  /// Flutter 应用刷一条噪声。
  List<ElfHardening> get noRelroLibraries => [
        for (final h in nativeHardening)
          if (h.relro == false) h,
      ];

  /// WebView / JS 桥的字符串线索（`addJavascriptInterface` 等）。
  final List<CodeClue> webViewClues;

  /// 同一批标记在代码引用层面的命中。
  final List<CodeReference> webViewCodeRefs;

  /// **全部**字符串线索（`DexClueScanner` 的结果）。
  ///
  /// 与 [allCodeRefs] 是两级证据：字符串命中只能说明「这个词出现过」，
  /// 代码引用说明「字节码引用了这个方法」。规则要分别陈述，不能混为一谈。
  final List<CodeClue> allClues;

  /// **全部**代码引用（`method_ids` / 调用点层面的命中）。
  ///
  /// 规则里要按标记 id 自由筛选时用它 —— 为每个新规则都加一个专用字段
  /// 会让 facts 无限膨胀。
  final List<CodeReference> allCodeRefs;

  /// 是否把 JS 桥暴露给了网页内容。
  bool get hasWebViewBridge =>
      webViewClues.any((c) => c.markerId == 'webview-js-bridge') ||
      webViewCodeRefs.any((r) => r.markerId == 'webview-js-bridge');

  /// 声明了「有代码证据才对得上」的权限，但在代码里**找不到**对应 API。
  ///
  /// 只在真的扫过 DEX 时才有意义（没扫过就无从判断）。
  final List<String> unusedPermissionNames;

  /// 是否存在运行时 DEX 加载线索（被加载的代码静态分析看不到）。
  final bool hasDynamicLoading;

  /// 声明了哪些特殊访问能力（`accessibility` / `device_admin` /
  /// `notification_listener`）。
  ///
  /// **来自清单层的组件权限**，不是 DEX 字面量 —— 后者会被 UI 库误伤。
  final List<String> specialAccessKinds;

  /// 是否存在图像输入来源（权限或代码线索）。
  bool get hasImageInput =>
      effectivePhotoAccess.isNotEmpty || photoClues.isNotEmpty;

  /// 是否存在后台入口：后台权限、后台线索，或声明了 service / receiver 组件。
  bool get hasBackground =>
      backgroundPermissions.isNotEmpty ||
      backgroundClues.isNotEmpty ||
      meta.components.any((c) =>
          c.type == ComponentType.service || c.type == ComponentType.receiver);

  /// 明文流量策略：`true` 允许、`false` 禁止、`null` **不知道**。
  ///
  /// **`android:networkSecurityConfig` 存在时 `usesCleartextTraffic` 被平台忽略。**
  /// AOSP 的 `ApplicationInfo` 写得很清楚：API 24 起，只要声明了 NSC，
  /// 这个标志就不再生效，一切由 NSC 决定。
  ///
  /// 所以三种来源按优先级取：
  /// 1. NSC **已展开** → 以 NSC 的 `base-config` / `domain-config` 为准；
  /// 2. NSC **声明了但没展开**（资源表缺失、路径解不出、条目被预算拒绝）
  ///    → `null`，**不是 false** —— 「不知道」与「不允许」是两件事；
  /// 3. 没有 NSC → 看 `usesCleartextTraffic`；**未声明时取平台的默认值**，
  ///    而默认值取决于 `targetSdk`：API 28 起默认禁止，之前默认放行。
  ///    `targetSdk` 也不知道时才是 `null`。
  ///
  /// 第 3 条曾写成「未声明时为 `false`」，那是**假阴性**：`targetSdk < 28`
  /// 的应用不声明就等于允许，判成 `false` 会让规则 D 静默不报，而且覆盖表
  /// 还会把这一维标成「已覆盖」（2026-10-19 审计 P2-10）。
  ///
  /// 实测（5 个真实包）：4 个 `usesCleartextTraffic=true`，其中 3 个同时声明了
  /// NSC。展开那 3 份 NSC 后，`base-config cleartextTrafficPermitted="true"`
  /// —— **它们确实允许明文**，所以规则 D 报得对。
  ///
  /// 这一条记录的是「差点走错的一步」：曾经因为「NSC 会覆盖清单属性」就
  /// 直接**不判定**，那会让这 3 个包的真发现被静默吞掉（假阴性）。
  /// 「属性被忽略」不等于「策略不成立」，必须去看 NSC 里到底写了什么。
  bool? get cleartextPolicy {
    final nsc = meta.networkSecurityConfigInfo;
    if (nsc != null) {
      return nsc.resolvedAllowsCleartext(
        targetSdkVersion: meta.targetSdkVersion,
      );
    }
    if (meta.networkSecurityConfig != null) return null;
    final declared = meta.applicationUsesCleartextTraffic;
    if (declared != null) return declared;
    // 未声明 → 平台的默认值。**API 28 是分水岭**：从 28 起
    // `usesCleartextTraffic` 的默认值才变成 false。
    final targetSdk = meta.targetSdkVersion;
    if (targetSdk == null) return null;
    return targetSdk < 28;
  }

  /// 明文策略**未判定**的原因 code；`null` 表示已判定。
  ///
  /// 覆盖表要按原因给不同的说明 —— 此前两种原因共用一句
  /// 「networkSecurityConfig 存在但没展开」，于是 `targetSdk` 缺失的情况
  /// 会显示一句**与事实不符**的解释。
  String? get cleartextPolicyUnknownReason {
    if (cleartextPolicy != null) return null;
    if (meta.networkSecurityConfig != null) return 'nsc_not_expanded';
    return 'target_sdk_unknown';
  }

  /// 备份规则是否**彻底关闭**了自动备份。
  ///
  /// `allowBackup="true"` 与「数据真的会被备份」不是一回事：
  /// `android:fullBackupContent="false"`（API 23–30）或
  /// `android:dataExtractionRules="false"`（API 31+）会把备份整个关掉。
  /// 只读 allowBackup 就会报一条**事实上不成立**的发现。
  bool get backupDisabledByRules {
    final full = meta.applicationFullBackupContent?.trim().toLowerCase();
    final extraction =
        meta.applicationDataExtractionRules?.trim().toLowerCase();
    return full == 'false' || extraction == 'false';
  }

  /// 明文策略是否确定允许。
  bool get allowsCleartext => cleartextPolicy == true;

  /// 声明了 NSC 却没能得出结论 → 这一维**未判定**，覆盖率要如实标出。
  bool get cleartextPolicyUnknown => cleartextPolicy == null;

  /// 规则 D 的升级条件：明文流量**同时**存在图像 / 识别 / 上传 / 域名线索。
  bool get hasSensitiveAlongsideCleartext =>
      hasImageInput ||
      hasOcrCapability ||
      hasUploadCapability ||
      scan.domains.isNotEmpty;
}

/// 一条 Android 组合规则。
///
/// 规则是**数据**：`matches` 决定命中，`build` 构造发现项。加一条规则 =
/// 往 [androidSecurityRules] 里加一项，不需要动 `audit()` 的编排代码 ——
/// 与 [PermissionCatalog] 同一思路（那边是权限表，这边是组合规则表）。
///
/// **判定与构造分开**，是因为测试要能「逐条驱动」：对一份事实，
/// 可以直接问「哪几条规则命中」，而不必先把发现项造出来再按 id 去翻。
class AndroidSecurityRule {
  /// 稳定的规则 id。与 `SecurityFinding.ruleId` 一致（三元变体另见各规则注释）。
  final String id;

  /// 这条规则在**报告里**的说明（英文回退；本地化在呈现层按 ruleId 取）。
  ///
  /// 抽表前这段说明只存在于注释里，表化之后它成了可被测试读取的数据 ——
  /// 测试可以断言「每条规则都写了说明」，避免新加的规则只有代码没有解释。
  final String summary;

  final bool Function(AndroidRuleFacts facts) matches;

  final SecurityFinding Function(AndroidRuleFacts facts) build;

  const AndroidSecurityRule({
    required this.id,
    required this.summary,
    required this.matches,
    required this.build,
  });
}

/// 全部组合规则。**顺序即报告里的输出顺序**，与抽表前一致。
const List<AndroidSecurityRule> androidSecurityRules = [
  // **清单配置类缺陷排在最前**：它们是完全可判定的事实（清单里写了就是写了），
  // 而且后果最直接（debuggable 等于把应用交给任何人）。线索推断类规则排在后面。
  AndroidSecurityRule(
    id: 'ANDROID-DEBUGGABLE',
    summary: '发布包声明了 android:debuggable="true" —— 任何拿到设备的人都能调试它。',
    matches: _matchesDebuggable,
    build: _buildDebuggable,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-EXPORTED-COMPONENT',
    summary: '组件导出但没有 android:permission 保护（启动页除外）。',
    matches: _matchesExportedComponent,
    build: _buildExportedComponent,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-ALLOW-BACKUP',
    summary: '显式声明 android:allowBackup="true" —— adb backup 可整包导出应用数据。',
    matches: _matchesAllowBackup,
    build: _buildAllowBackup,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-SHARED-USER-ID',
    summary: '声明了 android:sharedUserId —— 与同签名的其它应用共享 UID 与沙箱。',
    matches: _matchesSharedUserId,
    build: _buildSharedUserId,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-NATIVE-EXEC-STACK',
    summary: '原生库把栈标记为可执行（PT_GNU_STACK 含 PF_X）。',
    matches: _matchesExecStack,
    build: _buildExecStack,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-V1-ONLY-SIGNING',
    summary: '只有 v1（JAR）签名，没有 v2+ 签名块 —— 归档结构不受保护。',
    matches: _matchesV1OnlySigning,
    build: _buildV1OnlySigning,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-UNSIGNED',
    summary: '归档里没有任何签名材料（v1 与 v2+ 都没有）—— 这个包无法直接安装。',
    matches: _matchesUnsigned,
    build: _buildUnsigned,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-WEBVIEW-BRIDGE',
    summary: '向 WebView 暴露了 JavaScript 桥（addJavascriptInterface）。',
    matches: _matchesWebViewBridge,
    build: _buildWebViewBridge,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-MALWARE-INDICATORS',
    summary: '命令执行 / 无文件 DEX 加载 / 静默安装等恶意代码常见能力同现。',
    matches: _matchesMalwareIndicators,
    build: _buildMalwareIndicators,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-CRYPTO-THEFT-RISK',
    summary: '钱包能力（助记词/私钥、剪贴板、链上地址字面量）与高危通道同现。',
    matches: _matchesCryptoTheftRisk,
    build: _buildCryptoTheftRisk,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-PROVIDER-EXPOSED',
    summary: '导出的 ContentProvider 没有有效权限保护 —— 别的应用可以直接查询它的数据。',
    matches: _matchesExportedProvider,
    build: _buildExportedProvider,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-PERMISSION-WITHOUT-API',
    summary: '声明了敏感权限，但代码里找不到对应的 API 调用。',
    matches: _matchesUnusedPermission,
    build: _buildUnusedPermission,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-A',
    summary: '广泛相册 / 存储访问，但未见对应的图片业务用途线索。',
    matches: _matchesRuleA,
    build: _buildRuleA,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-B',
    summary: '图像输入来源与文字识别能力同现。',
    matches: _matchesRuleB,
    build: _buildRuleB,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-C',
    summary: '图像输入 + 文字识别 + 上传调用三段同现，疑似外传链路。',
    matches: _matchesRuleC,
    build: _buildRuleC,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-D',
    summary: '允许明文流量；同时存在敏感线索时升级（ruleId 加 `-ESCALATED`）。',
    matches: _matchesRuleD,
    build: _buildRuleD,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-E',
    summary: '后台入口 + 敏感数据 + 上传三者齐备。',
    matches: _matchesRuleE,
    build: _buildRuleE,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-G',
    summary: '设备标识 / 通讯录来源与上传能力同现（非图片类敏感数据外传候选）。',
    matches: _matchesRuleG,
    build: _buildRuleG,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-SPECIAL-ACCESS',
    summary: '声明了特殊访问能力（无障碍 / 设备管理器 / 通知监听）—— 高权限事实。',
    matches: _matchesSpecialAccess,
    build: _buildSpecialAccess,
  ),
  // SDK 盘点排在**所有**风险规则之后（它在 info 级，是清单不是结论）。
  AndroidSecurityRule(
    id: 'ANDROID-DEEPLINK',
    summary: '声明了可被外部唤起的链接入口（scheme）。',
    matches: _matchesDeeplink,
    build: _buildDeeplink,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-THIRD-PARTY-SDK',
    summary: '代码里出现第三方服务类 SDK（统计 / 推送 / 验证码 / 登录 / 地图…）。',
    matches: _matchesThirdPartySdk,
    build: _buildThirdPartySdk,
  ),
  AndroidSecurityRule(
    id: 'ANDROID-RULE-F',
    summary: '未发现上传特征时的显式「未发现」结论（不得读成「安全」）。',
    matches: _matchesRuleF,
    build: _buildRuleF,
  ),
];

// ---------------------------------------------------------------------------
// 清单配置类缺陷（完全可判定，不靠推断）
// ---------------------------------------------------------------------------

bool _matchesDebuggable(AndroidRuleFacts f) =>
    f.meta.applicationDebuggable == true;

SecurityFinding _buildDebuggable(AndroidRuleFacts f) => SecurityFinding(
      ruleId: 'ANDROID-DEBUGGABLE',
      platform: SecurityPlatform.android,
      category: SecurityCategory.configuration,
      // P1：这不是「疑似」——`debuggable` 打开后，任何能连上设备的人都可以
      // `run-as` 进应用目录、读内存、替换代码。发布包出现这一条就是硬缺陷。
      severity: SecuritySeverity.p1,
      confidence: SecurityConfidence.confirmed,
      finding: 'The application declares android:debuggable="true". Anyone '
          'with access to the device can debug the app, read its memory and '
          'replace its code. Release builds must not set this.',
      messageCode: 'android.debuggable',
      evidence: const [
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'AndroidManifest.xml / application[@android:debuggable]',
          detail: 'android:debuggable="true"',
        ),
      ],
      limitation: 'This is a manifest attribute; it is reported as declared. '
          'Whether the build was actually shipped to users cannot be '
          'determined statically.',
      limitationCode: 'android.debuggable.limitation',
      recommendation: 'Remove android:debuggable from the release build (it is '
          'normally injected by debug tooling / build variants).',
      recommendationCode: 'android.debuggable.remove',
    );

/// 导出且没有 `android:permission` 保护的组件，**排除启动页**。
///
/// 启动页必须导出（否则桌面图标点不开），报它等于每个应用都报一条。
/// `exported` 为 `null` 时不判 —— 默认值取决于有没有 intent-filter 与
/// targetSdk，静态猜它就是在编造。
/// 为什么这个组件「没有被真正保护」。
enum _UnprotectedReason {
  /// 完全没有 `android:permission`。
  noPermission,

  /// 声明了 `android:permission`，但那个权限是**本包自己声明**的，
  /// 且 `protectionLevel` 不是 `signature` —— 任何应用都能申请到它。
  weakPermission,

  /// 仅 provider：`readPermission` / `writePermission` 只声明了一个。
  /// 另一个方向仍然对任何应用敞开。
  partialPermission,
}

/// 一个导出且未受保护的组件，连同原因。
typedef _Unprotected = ({
  AndroidComponent component,
  _UnprotectedReason reason
});

/// 本包自己声明的权限名 → 声明（含 protectionLevel）。
Map<String, AndroidDeclaredPermission> _ownPermissions(ApkMeta meta) => {
      for (final p in meta.declaredPermissions) p.name: p,
    };

/// 导出且没有有效权限保护的组件。
///
/// **provider 不在这里**：它由 `ANDROID-PROVIDER-EXPOSED` 单独负责。
/// 混在「导出组件」的汇总里，159 个组件的列表会把 provider 这条最重要的
/// 信号稀释掉，读者也看不到具体暴露的是哪个 authority。
List<_Unprotected> _unprotectedExported(AndroidRuleFacts f) =>
    _unprotectedOf(f, (c) => c.type != ComponentType.provider);

/// 导出且没有有效权限保护的 ContentProvider。
List<_Unprotected> _unprotectedProviders(AndroidRuleFacts f) =>
    _unprotectedOf(f, (c) => c.type == ComponentType.provider);

List<_Unprotected> _unprotectedOf(
  AndroidRuleFacts f,
  bool Function(AndroidComponent) keep,
) {
  final launchers = {for (final a in f.meta.launchableActivities) a.name};
  final own = _ownPermissions(f.meta);
  final result = <_Unprotected>[];
  for (final c in f.meta.components) {
    if (!keep(c)) continue;
    if (c.exported != true) continue;
    if (launchers.contains(c.name)) continue;
    final permission = c.permission;
    if (permission == null || permission.isEmpty) {
      // provider 还可能靠 readPermission / writePermission 保护：
      // 两个都声明才算「两个方向都关上」；只声明一个仍是半开。
      if (c.type == ComponentType.provider) {
        final read = c.readPermission;
        final write = c.writePermission;
        final hasRead = read != null && read.isNotEmpty;
        final hasWrite = write != null && write.isNotEmpty;
        if (hasRead && hasWrite) {
          // 两个方向都有权限：按 android:permission 的同一套判据看强弱。
          final readDecl = own[read];
          final writeDecl = own[write];
          final weak = (readDecl != null && !readDecl.signatureProtected) ||
              (writeDecl != null && !writeDecl.signatureProtected);
          if (weak) {
            result
                .add((component: c, reason: _UnprotectedReason.weakPermission));
          }
          continue;
        }
        result.add((
          component: c,
          reason: hasRead || hasWrite
              ? _UnprotectedReason.partialPermission
              : _UnprotectedReason.noPermission,
        ));
        continue;
      }
      result.add((component: c, reason: _UnprotectedReason.noPermission));
      continue;
    }
    // 只对**本包声明**的权限下判断：框架权限与别包声明的权限看不到级别，
    // 保守当成受保护 —— 猜错的方向必须偏向「不误报」。
    final declared = own[permission];
    if (declared != null && !declared.signatureProtected) {
      result.add((component: c, reason: _UnprotectedReason.weakPermission));
    }
  }
  return result;
}

/// 权限保护是否**名存实亡**（`normal` / `dangerous` 级自定义权限）。
bool _hasWeakPermission(AndroidRuleFacts f) => _unprotectedExported(f)
    .any((e) => e.reason == _UnprotectedReason.weakPermission);

bool _matchesExportedComponent(AndroidRuleFacts f) =>
    _unprotectedExported(f).isNotEmpty;

/// 一条发现里最多点名几个组件。
///
/// 真实包上这个数字很大：抖音有 **159 个**导出且无 `android:permission`
/// 的组件。全列出来会变成一段 6 KB 的文字 + 159 行证据，读者只会跳过它 ——
/// 而「读者跳过」正是安全面板最该避免的结局。
///
/// 截断是**显示层**的取舍：`count` 永远是真实总数，正文里也明写省略了多少，
/// 所以不会让人误以为只有这 12 个。
const int _kMaxNamedExportedComponents = 12;

/// 证据行最多列几条（比点名多给一些，便于核对）。
const int _kMaxExportedEvidence = 20;

/// 组件类型的危险程度排序：provider 直接暴露数据，排在前面。
int _exportedTypeRank(ComponentType type) => switch (type) {
      ComponentType.provider => 0,
      ComponentType.service => 1,
      ComponentType.receiver => 2,
      ComponentType.activity => 3,
      _ => 4,
    };

/// 导出组件发现的正文。
///
/// 四种组合（是否省略 / 是否「权限名存实亡」）必须分开说，否则会自相矛盾：
/// 正文写「没有 android:permission」而那个组件明明声明了 permission。
String _exportedFindingText({
  required int total,
  required List<String> shown,
  required int omitted,
  required bool weak,
}) {
  final guard = weak
      ? 'without an effective android:permission guard'
      : 'without an android:permission guard';
  if (omitted > 0) {
    return '$total component(s) are exported $guard, including '
        '${shown.join(', ')} and $omitted more. Other apps on the device can '
        'invoke them.';
  }
  return '$total component(s) are exported $guard: ${shown.join(', ')}. '
      'Other apps on the device can invoke them.';
}

String _exportedMessageCode({required int omitted, required bool weak}) {
  if (weak) {
    return omitted > 0
        ? 'android.exported_component_weak_many'
        : 'android.exported_component_weak';
  }
  return omitted > 0
      ? 'android.exported_component_many'
      : 'android.exported_component';
}

SecurityFinding _buildExportedComponent(AndroidRuleFacts f) {
  final entries = _unprotectedExported(f);
  // ContentProvider 直接暴露数据，比 activity / service 更危险 → P2。
  final hasProvider =
      entries.any((e) => e.component.type == ComponentType.provider);
  final ordered = [...entries]..sort((a, b) {
      final byType = _exportedTypeRank(a.component.type)
          .compareTo(_exportedTypeRank(b.component.type));
      if (byType != 0) return byType;
      return (a.component.name ?? '').compareTo(b.component.name ?? '');
    });
  final names = [for (final e in ordered) e.component.name ?? '<unnamed>'];
  final shown = names.take(_kMaxNamedExportedComponents).toList();
  final omitted = names.length - shown.length;
  // 有「权限名存实亡」的组件时，措辞必须换 —— 否则正文说「没有
  // android:permission」，而那个组件明明写着 permission，读者会认为工具在乱报。
  final weak = _hasWeakPermission(f);

  return SecurityFinding(
    ruleId: 'ANDROID-EXPORTED-COMPONENT',
    platform: SecurityPlatform.android,
    category: SecurityCategory.configuration,
    severity: hasProvider ? SecuritySeverity.p2 : SecuritySeverity.p3,
    confidence: SecurityConfidence.confirmed,
    finding: _exportedFindingText(
      total: names.length,
      shown: shown,
      omitted: omitted,
      weak: weak,
    ),
    messageCode: _exportedMessageCode(omitted: omitted, weak: weak),
    messageArgs: {
      'count': names.length,
      'names': shown,
      if (omitted > 0) 'more': omitted,
      if (weak) 'weak': true,
    },
    // 证据的取舍：**弱权限的先列**。
    //
    // 证据上限 20 条，而按类型排序时 activity 排在最后 —— 实测抖音有 161 个
    // 未受保护组件，其中 2 个是「权限名存实亡」的 activity，正好被挤出上限。
    // 结果是正文说「without an effective guard」，而 20 条证据全写着
    // 「without android:permission」—— 读者会认为工具在乱说。
    // 正文声称了什么，证据里就必须有对应的一条。
    evidence: [
      for (final e in [
        ...ordered.where((e) => e.reason == _UnprotectedReason.weakPermission),
        ...ordered.where((e) => e.reason != _UnprotectedReason.weakPermission),
      ].take(_kMaxExportedEvidence))
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'AndroidManifest.xml / ${e.component.type.name}'
              '[@name="${e.component.name ?? '?'}"]',
          detail: switch (e.reason) {
            _UnprotectedReason.noPermission =>
              'android:exported="true" without android:permission',
            _UnprotectedReason.weakPermission =>
              'android:exported="true" guarded only by '
                  '${e.component.permission}, which this app declares as '
                  'protectionLevel="'
                  '${_ownPermissions(f.meta)[e.component.permission]?.protectionLevelText ?? 'normal'}" '
                  '— any app can request it',
            // provider 专属：只护住一个方向。这条分支到不了普通组件
            // （`_unprotectedExported` 已排除 provider）。
            _UnprotectedReason.partialPermission =>
              'android:exported="true" with only one of readPermission / '
                  'writePermission declared',
          },
        ),
    ],
    limitation: 'Exported is reported only when it is explicitly declared; '
        'components without the attribute are not judged (the default depends '
        'on the intent filters and targetSdk). A permission declared by this '
        'app with protectionLevel normal or dangerous is treated as no '
        'protection, because any app can request it; framework permissions '
        'and permissions declared elsewhere are assumed to protect, since '
        'their level is not visible here. Some exported components are '
        'intended to be called by other apps.',
    limitationCode: 'android.exported_component.limitation',
    recommendation: 'For each component: add android:permission, or set '
        'android:exported="false" if other apps do not need it.',
    recommendationCode: 'android.exported_component.review',
  );
}

bool _matchesAllowBackup(AndroidRuleFacts f) =>
    f.meta.applicationAllowBackup == true && !f.backupDisabledByRules;

bool _matchesThirdPartySdk(AndroidRuleFacts f) =>
    f.sdkInventory.hits.isNotEmpty;

bool _matchesExecStack(AndroidRuleFacts f) =>
    f.executableStackLibraries.isNotEmpty;

/// 只有 v1 签名。
///
/// **三个条件缺一不可**：
/// - `signingSchemes != null` 且 `parsed` —— 真的读到了结构，而不是「读不出」；
/// - `v1Only` —— 没有任何 v2+ 签名块；
/// - `hasV1Signature == true` —— **归档里确实有 `META-INF/*.SF` + 同名签名块**。
///
/// 少了第三条，「未签名」会被报成「只有 v1 签名」。实测项目自带的
/// `signed-v1-only.apk` 与 `signed-unsigned.apk` 在旧判据下产出**完全相同**
/// 的发现项 —— 而前者是「用了最弱的方案签过名」，后者是「根本没签」。
/// 未签名由 [ANDROID-UNSIGNED] 单独陈述，两条规则互斥。
bool _matchesV1OnlySigning(AndroidRuleFacts f) =>
    (f.meta.signingSchemes?.v1Only ?? false) && f.meta.hasV1Signature == true;

/// 归档里**完全没有签名材料**（既无 v1，也无 v2+）。
///
/// `hasV1Signature == false` 才算 —— `null`（未判定）不下结论。
bool _matchesUnsigned(AndroidRuleFacts f) =>
    (f.meta.signingSchemes?.v1Only ?? false) && f.meta.hasV1Signature == false;

bool _matchesWebViewBridge(AndroidRuleFacts f) => f.hasWebViewBridge;

/// 恶意代码常见能力的标记分组。
///
/// **强**：正常应用里很少见 —— `Runtime.exec` 要跑 shell，`ProcessBuilder`
/// 要起子进程，`InMemoryDexClassLoader` 是「不落盘的 DEX」。
/// **中**：热修复 / 插件化 / 应用市场类应用会有，单独出现不足以说明问题。
const Set<String> _malwareStrongMarkers = {
  'runtime-exec',
  'process-builder',
  'in-memory-dex',
};

const Set<String> _malwareMediumMarkers = {
  'dynamic-loading',
  'dynamic-loading-path',
  'package-installer',
};

typedef _MalwareSignals = ({
  List<String> strong,
  List<String> medium,
  bool reflection,
});

_MalwareSignals _malwareSignals(AndroidRuleFacts f) {
  // 引用与字符串线索都算命中：`Runtime.exec` 出现在字符串里也可能只是日志，
  // 但漏掉它比多报一条更糟 —— 证据行会区分两者。
  final ids = {
    for (final r in f.allCodeRefs) r.markerId,
    for (final c in f.allClues) c.markerId,
  };
  return (
    strong: [
      for (final id in _malwareStrongMarkers)
        if (ids.contains(id)) id,
    ],
    medium: [
      for (final id in _malwareMediumMarkers)
        if (ids.contains(id)) id,
    ],
    reflection: ids.contains('reflection-for-name'),
  );
}

/// 判级：强 + 任意中 → P2；只有强、或两个以上中 → P3；其余不报。
///
/// 反射（`Class.forName`）**不参与判级** —— 几乎每个应用都有，把它算进来
/// 等于让这条规则在所有包上出现。
bool _matchesMalwareIndicators(AndroidRuleFacts f) {
  final s = _malwareSignals(f);
  if (s.strong.isNotEmpty) return true;
  return s.medium.length >= 2;
}

/// 恶意代码常见能力的组合。
///
/// 这条**不是「判定为恶意」** —— 静态分析给不出那个结论。它做的是把
/// 「执行命令 / 不落盘加载 DEX / 静默安装」这类能力摆到台面上：单独出现
/// 都可能是正常功能（热修复、插件化、应用市场），凑在一起就值得人工核对。
SecurityFinding _buildMalwareIndicators(AndroidRuleFacts f) {
  final s = _malwareSignals(f);
  final all = [...s.strong, ...s.medium];
  final severity = s.strong.isNotEmpty && s.medium.isNotEmpty
      ? SecuritySeverity.p2
      : SecuritySeverity.p3;

  return SecurityFinding(
    ruleId: 'ANDROID-MALWARE-INDICATORS',
    platform: SecurityPlatform.android,
    category: SecurityCategory.other,
    severity: severity,
    // 一律 `independentCapability`：这条规则说的是「这些能力存在」，
    // 不是「我们怀疑它们被执行了」。用 suspected 会把「能力」说成「行为」。
    confidence: SecurityConfidence.independentCapability,
    finding: 'Capabilities that malware commonly combines are present: '
        '${all.join(', ')}'
        '${s.reflection ? ' (plus reflective class loading)' : ''}. '
        'Each one alone can be legitimate (hot-fix, plug-in hosts, app '
        'stores), so this is a **triage lead, not a verdict**.',
    messageCode: 'android.malware_indicators',
    messageArgs: {
      'signals': all,
      if (s.reflection) 'reflection': true,
    },
    evidence: [
      for (final reference in f.allCodeRefs)
        if (all.contains(reference.markerId))
          SecurityEvidence(
            source: SecurityEvidenceSource.dexMethodReference,
            location: reference.dexNames.join(', '),
            detail: '${reference.markerId} (code reference): '
                '${[
              ...reference.samples,
              ...reference.callSiteSamples
            ].take(3).join(' | ')}',
          ),
      // 没有代码引用、只有字符串线索时也要给证据 —— 否则读者看到「有信号」
      // 却找不到任何出处。
      for (final clue in f.allClues)
        if (all.contains(clue.markerId) &&
            !f.allCodeRefs.any((r) => r.markerId == clue.markerId))
          SecurityEvidence(
            source: SecurityEvidenceSource.dexString,
            location: clue.dexNames.join(', '),
            detail: '${clue.markerId} (string only): '
                '${clue.samples.take(3).join(' | ')}',
          ),
    ],
    limitation: 'Static evidence only: the code references these APIs, it '
        'does not follow that they run, or that what they load is malicious. '
        'Hot-fix frameworks, plug-in hosts and app stores use the same '
        'dynamic-loading APIs. The loaded code is not in the archive, so it '
        'cannot be inspected here.',
    limitationCode: 'android.malware_indicators.limitation',
    recommendation: 'Treat this as a lead: check what the app loads at '
        'runtime, where it comes from, and whether a shell command is '
        'reachable from external input. Dynamic analysis (running it in an '
        'isolated emulator) is the way to settle it.',
    recommendationCode: 'android.malware_indicators.review',
  );
}

/// 加密资产（钱包）相关标记分组。
///
/// 三组的含义不同：
/// - **钱包 SDK**：这个应用碰得到链上资产；
/// - **密钥材料**：代码里出现了助记词 / 私钥的处理；
/// - **剪贴板**：地址替换型盗 U 的必经之路。
///
/// 单看任何一组都不构成风险 —— 正规钱包三组都有。判级只看**组合**。
const Set<String> _walletSdkMarkers = {
  'wallet-web3j',
  'wallet-bitcoinj',
  'wallet-walletconnect',
  'wallet-tronweb',
  'wallet-metamask',
  'wallet-tokenpocket',
  'wallet-imtoken',
  'wallet-trust',
  'wallet-okx',
  'wallet-binance',
  'wallet-coinbase',
  // 下面几条主要来自**原生库字符串**（钱包逻辑在 `.so` 里时 DEX 是干净的）。
  'wallet-secp256k1',
  'wallet-keccak',
  'wallet-erc20',
  'wallet-trc20',
};

const Set<String> _keyMaterialMarkers = {
  'wallet-mnemonic',
  'wallet-private-key',
  // BIP39 / BIP32 是助记词与派生路径，同属「能签走资产的材料」。
  'wallet-bip39',
  'wallet-bip32',
};

const Set<String> _clipboardMarkers = {
  'clipboard-read',
  'clipboard-write',
};

/// 短信权限：盗 U 样本常用它截获验证码，把「绑定手机号」这一步也拿下来。
const Set<String> _smsPermissions = {
  'android.permission.READ_SMS',
  'android.permission.RECEIVE_SMS',
};

typedef _CryptoTheftSignals = ({
  List<String> walletSdk,
  List<String> keyMaterial,
  List<String> clipboard,
  List<CryptoAddressHit> addresses,
  bool specialAccess,
  bool smsAccess,
  bool upload,
});

_CryptoTheftSignals _cryptoTheftSignals(AndroidRuleFacts f) {
  final ids = {
    for (final r in f.allCodeRefs) r.markerId,
    for (final c in f.allClues) c.markerId,
    // 原生库字符串也算：逻辑在 native 里的样本，DEX 侧是干净的。
    ...f.nativeCrypto.samples.keys,
  };
  List<String> pick(Set<String> group) => [
        for (final id in group)
          if (ids.contains(id)) id,
      ];
  return (
    walletSdk: pick(_walletSdkMarkers),
    keyMaterial: pick(_keyMaterialMarkers),
    clipboard: pick(_clipboardMarkers),
    addresses: [...f.scan.cryptoAddresses, ...f.nativeCrypto.addresses],
    specialAccess: f.specialAccessKinds.isNotEmpty,
    smsAccess: f.meta.permissions.any(_smsPermissions.contains),
    upload: f.hasUploadCapability,
  );
}

/// 「能把东西送出去」的通道。
///
/// - 无障碍 / 短信：能读屏、能截验证码，是盗 U 样本的真实通道；
/// - **上传 + 写死的地址**：单纯「有上传能力」几乎每个应用都有（统计、日志），
///   单靠它判 P2 会让规则在九成应用上出现。配上「包里写死了一个链上地址」，
///   才算「有地方送、也准备好了收」。
bool _hasTheftChannel(_CryptoTheftSignals s) =>
    s.specialAccess || s.smsAccess || (s.upload && s.addresses.isNotEmpty);

/// 是否报「盗 U 风险」。
///
/// 两条**组合**判据，任一成立即报：
///
/// 1. **密钥材料 + 通道**：代码里出现助记词/私钥处理，同时具备能把它送出去的
///    通道（见 [_hasTheftChannel]）。
/// 2. **钱包 + 剪贴板 + 写死的地址**：地址替换型盗 U 的完整三件套。
///
/// 其余情况（只有钱包 SDK、只有地址字面量）只给 P3 —— 正规钱包与交易所都有
/// 这些，单独出现说明不了任何问题。
bool _matchesCryptoTheftRisk(AndroidRuleFacts f) {
  final s = _cryptoTheftSignals(f);
  final keyWithChannel = s.keyMaterial.isNotEmpty && _hasTheftChannel(s);
  final addressSwap = s.walletSdk.isNotEmpty &&
      s.clipboard.isNotEmpty &&
      s.addresses.isNotEmpty;
  if (keyWithChannel || addressSwap) return true;
  // P3 档：至少出现了「与资产相关」的东西，值得在报告里点名。
  return s.walletSdk.isNotEmpty ||
      s.keyMaterial.isNotEmpty ||
      s.addresses.isNotEmpty;
}

/// 「盗 U」风险：链上资产被窃取的可能性。
///
/// **这不是「判定为盗 U 木马」** —— 静态分析给不出那个结论，正规钱包应用同样
/// 具备这里列出的每一项能力。它做的是把「能签走资产的材料」与「能把它送出去
/// 的通道」摆在一起，让人工核对有落点。
SecurityFinding _buildCryptoTheftRisk(AndroidRuleFacts f) {
  final s = _cryptoTheftSignals(f);
  final keyWithChannel = s.keyMaterial.isNotEmpty && _hasTheftChannel(s);
  final addressSwap = s.walletSdk.isNotEmpty &&
      s.clipboard.isNotEmpty &&
      s.addresses.isNotEmpty;
  final severity =
      keyWithChannel || addressSwap ? SecuritySeverity.p2 : SecuritySeverity.p3;

  final signals = <String>[
    ...s.walletSdk,
    ...s.keyMaterial,
    if (s.clipboard.isNotEmpty) ...s.clipboard,
    if (s.specialAccess) 'special-access',
    if (s.smsAccess) 'sms',
    if (s.upload) 'upload',
  ];

  return SecurityFinding(
    ruleId: 'ANDROID-CRYPTO-THEFT-RISK',
    platform: SecurityPlatform.android,
    category: SecurityCategory.cryptoAsset,
    severity: severity,
    // 说的是「这些能力同现」，不是「我们看见它偷了」。用 suspected 会把
    // 能力说成行为 —— 正规钱包应用会被一并指认为窃贼。
    confidence: SecurityConfidence.independentCapability,
    finding: 'Crypto-wallet capabilities that theft samples combine are '
        'present: ${signals.join(', ')}'
        '${s.addresses.isNotEmpty ? ' (plus ${s.addresses.length} '
            'on-chain address literal${s.addresses.length == 1 ? '' : 's'})' : ''}. '
        'A legitimate wallet has the same capabilities, so this is a '
        '**triage lead, not a verdict**.',
    messageCode: 'crypto.theft_risk',
    messageArgs: {
      'signals': signals,
      'addresses': [
        for (final hit in s.addresses.take(8))
          '${hit.format.label}: ${hit.address}',
      ],
      'addressCount': s.addresses.length,
      if (addressSwap) 'addressSwap': true,
      if (keyWithChannel) 'keyWithChannel': true,
      // 「我们看不清」的地方。不改判级，只让读者知道结论可能偏保守。
      'blindSpots': [
        if (f.scan.skippedForBudget.isNotEmpty) 'dexPartial',
        if (f.nativeCrypto.skippedLibraries.isNotEmpty) 'nativePartial',
        if (f.nativeCrypto.looksPacked) 'nativePacked',
      ],
    },
    evidence: [
      for (final reference in f.allCodeRefs)
        if (signals.contains(reference.markerId))
          SecurityEvidence(
            source: SecurityEvidenceSource.dexMethodReference,
            location: reference.dexNames.join(', '),
            detail: '${reference.markerId} (code reference): '
                '${[
              ...reference.samples,
              ...reference.callSiteSamples
            ].take(3).join(' | ')}',
          ),
      for (final clue in f.allClues)
        if (signals.contains(clue.markerId) &&
            !f.allCodeRefs.any((r) => r.markerId == clue.markerId))
          SecurityEvidence(
            source: SecurityEvidenceSource.dexString,
            location: clue.dexNames.join(', '),
            detail: '${clue.markerId} (string only): '
                '${clue.samples.take(3).join(' | ')}',
          ),
      // 原生库字符串里的命中：位置是 `.so` 路径，来源标 `nativeString`。
      for (final id in signals)
        for (final sample
            in (f.nativeCrypto.samples[id] ?? const <String>{}).take(3))
          SecurityEvidence(
            source: SecurityEvidenceSource.nativeString,
            location:
                (f.nativeCrypto.sources[id] ?? const <String>{}).join(', '),
            detail: '$id (native string): $sample',
          ),
      // 地址字面量单独给证据：用户要能把它拿去链上查。
      for (final hit in s.addresses.take(8))
        SecurityEvidence(
          source: SecurityEvidenceSource.dexString,
          location: 'DEX string',
          detail: '${hit.format.label} address literal: ${hit.address}',
        ),
    ],
    limitation: 'Static evidence only: these APIs and literals exist in the '
        'archive. Whether they run, and what they do with the data, is not '
        'visible here. Legitimate wallets contain the same wallet SDKs, the '
        'same clipboard calls and the same address literals (merchant or '
        'contract addresses), so **presence is not theft**. Strings beyond the '
        'per-DEX scan budget were not examined.',
    limitationCode: 'crypto.theft_risk.limitation',
    recommendation: 'Check the wallet flow by hand: does the app ever replace '
        'a clipboard address, does it ask for the seed phrase outside its own '
        'wallet UI, and where do the address literals come from? Dynamic '
        'analysis in an isolated device settles it.',
    recommendationCode: 'crypto.theft_risk.review',
  );
}

bool _matchesExportedProvider(AndroidRuleFacts f) =>
    _unprotectedProviders(f).isNotEmpty;

/// 一个可被外部唤起的链接入口。
typedef _Deeplink = ({
  AndroidComponent component,
  List<String> schemes,
  List<String> actions,
});

/// 导出组件上声明的 `scheme`（不含启动页的 MAIN/LAUNCHER）。
///
/// 启动页也带 intent-filter，但它不是「链接入口」—— 把 `MAIN` 算进来会让
/// 每个应用都多出一条无意义的记录。
List<_Deeplink> _deeplinks(AndroidRuleFacts f) {
  final result = <_Deeplink>[];
  for (final c in f.meta.components) {
    if (!c.effectivelyExported) continue;
    final schemes = <String>[];
    final actions = <String>[];
    for (final filter in c.intentFilters) {
      final isLauncher = filter.actions.any((a) => a.endsWith('.MAIN')) &&
          filter.categories.any((cat) => cat.endsWith('.LAUNCHER'));
      if (isLauncher) continue;
      schemes.addAll(filter.schemes);
      actions.addAll(filter.actions);
    }
    if (schemes.isEmpty) continue;
    result.add((
      component: c,
      schemes: schemes.toSet().toList()..sort(),
      actions: actions.toSet().toList()..sort(),
    ));
  }
  result.sort((a, b) {
    final an = a.component.name ?? '';
    final bn = b.component.name ?? '';
    return an.compareTo(bn);
  });
  return result;
}

bool _matchesDeeplink(AndroidRuleFacts f) => _deeplinks(f).isNotEmpty;

/// 链接入口清单（**事实**，不是风险判定）。
///
/// 等级 info：一个 scheme 本身不代表有问题 —— 登录回调、分享回跳都靠它。
/// 有价值的是**清单**：这个应用能被哪些链接唤起、入口在哪个组件上。
/// 真正的风险（导出且无权限保护）由 `ANDROID-EXPORTED-COMPONENT` 负责。
SecurityFinding _buildDeeplink(AndroidRuleFacts f) {
  final entries = _deeplinks(f);
  final schemes = <String>{
    for (final e in entries) ...e.schemes,
  }.toList()
    ..sort();
  final shown = schemes.take(_kMaxNamedExportedComponents).toList();
  final omitted = schemes.length - shown.length;

  return SecurityFinding(
    ruleId: 'ANDROID-DEEPLINK',
    platform: SecurityPlatform.android,
    category: SecurityCategory.other,
    severity: SecuritySeverity.info,
    confidence: SecurityConfidence.confirmed,
    finding: '${schemes.length} link scheme(s) can launch this app from '
        'outside: ${shown.join(', ')}'
        '${omitted > 0 ? ' and $omitted more' : ''}, across '
        '${entries.length} exported component(s). A scheme by itself is '
        'normal (login callbacks, share returns); the risk is in what the '
        'target component does with the incoming parameters.',
    messageCode: 'android.deeplink',
    messageArgs: {
      'count': schemes.length,
      'schemes': shown,
      'components': entries.length,
      if (omitted > 0) 'more': omitted,
    },
    evidence: [
      for (final e in entries.take(_kMaxExportedEvidence))
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'AndroidManifest.xml / '
              '${e.component.type.name}[@name="${e.component.name ?? '?'}"]',
          detail: 'schemes=${e.schemes.join(', ')}'
              '${e.actions.isEmpty ? '' : '; actions=${e.actions.join(', ')}'}',
        ),
    ],
    limitation: 'Only the scheme is listed. Whether the target component '
        'validates the incoming host, path and parameters cannot be '
        'determined from the manifest — that would need the code.',
    limitationCode: 'android.deeplink.limitation',
    recommendation: 'Check that each scheme handler validates its input '
        '(host, path, parameters) before acting on it, and that the target '
        'component is the one you intended to expose.',
    recommendationCode: 'android.deeplink.review',
  );
}

/// 导出且无有效保护的 ContentProvider。
///
/// 与「导出组件」分开单列，理由有三：
/// 1. provider **直接暴露数据**（query / insert / delete），不是「能被唤起」；
/// 2. 需要说清暴露的是哪个 `authorities`，而不是一个类名；
/// 3. `grantUriPermissions` 让「没有权限」不再等于「拿不到数据」，要一起说。
///
/// 等级 P2：需要另一侧真的来访问，且 provider 可能返回空 —— 但一旦返回，
/// 泄漏的就是应用私有数据（数据库、文件、偏好）。
SecurityFinding _buildExportedProvider(AndroidRuleFacts f) {
  final entries = _unprotectedProviders(f);
  final ordered = [...entries]..sort((a, b) {
      final an = a.component.authorities ?? a.component.name ?? '';
      final bn = b.component.authorities ?? b.component.name ?? '';
      return an.compareTo(bn);
    });
  final names = [
    for (final e in ordered)
      e.component.authorities ?? e.component.name ?? '<unnamed>',
  ];
  final shown = names.take(_kMaxNamedExportedComponents).toList();
  final omitted = names.length - shown.length;
  final grantUri = ordered.any((e) => e.component.grantUriPermissions == true);
  final partial =
      ordered.any((e) => e.reason == _UnprotectedReason.partialPermission);
  final weak =
      ordered.any((e) => e.reason == _UnprotectedReason.weakPermission);

  return SecurityFinding(
    ruleId: 'ANDROID-PROVIDER-EXPOSED',
    platform: SecurityPlatform.android,
    category: SecurityCategory.deviceData,
    severity: SecuritySeverity.p2,
    confidence: SecurityConfidence.confirmed,
    finding: '${names.length} ContentProvider(s) are exported without an '
        'effective permission guard: ${shown.join(', ')}'
        '${omitted > 0 ? ' and $omitted more' : ''}. Other apps on the device '
        'can query, and possibly modify, the data behind these authorities.'
        '${grantUri ? ' At least one of them also sets '
            'grantUriPermissions, so it can hand out per-URI access even to '
            'apps without the declared permission.' : ''}'
        '${partial ? ' Some providers guard only one direction '
            '(readPermission or writePermission), leaving the other open.' : ''}'
        '${weak ? ' Some are guarded by a permission this app declares itself '
            'at normal/dangerous level, which any app can request.' : ''}',
    messageCode: 'android.provider_exposed',
    messageArgs: {
      'count': names.length,
      'names': shown,
      if (omitted > 0) 'more': omitted,
      if (grantUri) 'grantUri': true,
      if (partial) 'partial': true,
      if (weak) 'weak': true,
    },
    evidence: [
      for (final e in ordered.take(_kMaxExportedEvidence))
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'AndroidManifest.xml / <provider>',
          detail: _providerDetail(e, f),
        ),
    ],
    limitation: 'A provider with no permission is reachable by any app on '
        'the device, but whether it returns anything depends on the data it '
        'holds. Providers disabled by android:enabled=false are still listed '
        'here — check the evidence.',
    limitationCode: 'android.provider_exposed.limitation',
    recommendation: 'Guard the provider with a signature-level permission, '
        'or set android:exported="false" if no other app needs it. If URI '
        'grants are required, keep grantUriPermissions but make sure the '
        'URIs handed out are scoped.',
    recommendationCode: 'android.provider_exposed.review',
  );
}

String _providerDetail(_Unprotected e, AndroidRuleFacts f) {
  final c = e.component;
  final own = _ownPermissions(f.meta);
  final guarded = c.permission ?? c.readPermission ?? c.writePermission;
  final parts = <String>[
    'authorities=${c.authorities ?? '<none>'}',
    'class=${c.name ?? '<unnamed>'}',
    if (c.permission != null) 'permission=${c.permission}',
    if (c.readPermission != null) 'readPermission=${c.readPermission}',
    if (c.writePermission != null) 'writePermission=${c.writePermission}',
    if (c.grantUriPermissions != null)
      'grantUriPermissions=${c.grantUriPermissions}',
    'guard=${e.reason.name}',
    // 弱权限时把级别写进证据：读者要能看懂「为什么这条权限不算保护」，
    // 而不是看到一个权限名去自己查。
    if (e.reason == _UnprotectedReason.weakPermission && guarded != null)
      'protectionLevel='
          '${own[guarded]?.protectionLevelText ?? 'normal'}',
  ];
  return parts.join(', ');
}

/// 只有**真的扫过 DEX** 才判 —— 没扫过的时候「找不到调用」只是我们没看。
bool _matchesUnusedPermission(AndroidRuleFacts f) =>
    f.hasDexContent && f.unusedPermissionNames.isNotEmpty;

bool _matchesSharedUserId(AndroidRuleFacts f) {
  final id = f.meta.sharedUserId;
  return id != null && id.trim().isNotEmpty;
}

SecurityFinding _buildAllowBackup(AndroidRuleFacts f) => SecurityFinding(
      ruleId: 'ANDROID-ALLOW-BACKUP',
      platform: SecurityPlatform.android,
      category: SecurityCategory.configuration,
      severity: SecuritySeverity.p3,
      confidence: SecurityConfidence.confirmed,
      finding: 'The application declares android:allowBackup="true": '
          '`adb backup` can export its private data on devices that still '
          'honour it.',
      messageCode: 'android.allow_backup',
      evidence: [
        const SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'AndroidManifest.xml / application[@android:allowBackup]',
          detail: 'android:allowBackup="true"',
        ),
        // 有例外清单时必须点出来 —— 否则读者会以为整包数据都会被备份。
        //
        // 只列**引用形态**（`@res/0x...`）。`true` 不是这个属性的合法值
        // （合法值是 `false` 或一份 XML 资源），实测飞牛写了 `true`，
        // 把它当成「有规则清单」列出来等于替平台解释了一个无效值。
        if (_isRuleFileRef(f.meta.applicationDataExtractionRules))
          SecurityEvidence(
            source: SecurityEvidenceSource.manifest,
            location: 'AndroidManifest.xml / '
                'application[@android:dataExtractionRules]',
            detail: 'dataExtractionRules = '
                '${f.meta.applicationDataExtractionRules} (exclusion rules '
                'file, contents not expanded)',
          ),
        if (_isRuleFileRef(f.meta.applicationFullBackupContent))
          SecurityEvidence(
            source: SecurityEvidenceSource.manifest,
            location: 'AndroidManifest.xml / '
                'application[@android:fullBackupContent]',
            detail: 'fullBackupContent = '
                '${f.meta.applicationFullBackupContent} (exclusion rules '
                'file, contents not expanded)',
          ),
      ],
      limitation: 'Only an explicit allowBackup="true" is reported; the '
          'platform default is also true, but treating an absent attribute as '
          'the app\'s choice would flag every package. Android 12+ restricts '
          'adb backup further.',
      limitationCode: 'android.allow_backup.limitation',
      recommendation: 'If the app stores sensitive data, set '
          'android:allowBackup="false" or provide explicit backup rules.',
      recommendationCode: 'android.allow_backup.review',
    );

/// 原生库把栈标记为可执行。
///
/// `PT_GNU_STACK` 的 `p_flags` 含 `PF_X` —— 栈上的数据可以被当成代码执行。
/// 这是**没有正当理由**的配置：没有哪种正常构建需要它，只有手写汇编的
/// 老代码或刻意规避 NX 的壳会这么做。
///
/// 等级 P2 + `confirmed`：这是文件里的结构事实，没有推断成分。
/// 但它只说明「这个库允许执行栈」，不说明「已经被利用」。
///
/// ## 为什么这一维只有这一条规则
///
/// 实测 4 个真实包的 121 个 arm64 `.so`：可执行栈 **0**、缺 RELRO **1**
/// （Flutter 的 `libapp.so`，Dart AOT 快照的合法选择）、未 strip **0**。
/// NDK 默认就带 `-z relro -z now` 与 NX 栈，所以逐库报「缺 RELRO」是噪声 ——
/// 它会稳定命中所有 Flutter 应用。只有「可执行栈」值得单独一条。
SecurityFinding _buildExecStack(AndroidRuleFacts f) {
  final libs = f.executableStackLibraries;
  final names = [for (final h in libs) h.name]..sort();
  const shown = 5;
  final listed = names.take(shown).join(', ');
  return SecurityFinding(
    ruleId: 'ANDROID-NATIVE-EXEC-STACK',
    platform: SecurityPlatform.android,
    category: SecurityCategory.configuration,
    severity: SecuritySeverity.p2,
    confidence: SecurityConfidence.confirmed,
    finding: names.length > shown
        ? '${names.length} native libraries mark the stack as executable '
            '(PT_GNU_STACK with PF_X), including $listed and '
            '${names.length - shown} more: data on the stack can be executed '
            'as code.'
        : '${names.length} native libraries mark the stack as executable '
            '(PT_GNU_STACK with PF_X): $listed. Data on the stack can be '
            'executed as code.',
    messageCode: names.length > shown
        ? 'android.native_exec_stack_many'
        : 'android.native_exec_stack',
    messageArgs: {
      'count': names.length,
      'names': names.take(shown).toList(),
      if (names.length > shown) 'more': names.length - shown,
    },
    evidence: [
      for (final h in libs.take(8))
        SecurityEvidence(
          source: SecurityEvidenceSource.nativeSymbol,
          location: h.name,
          detail: 'PT_GNU_STACK has PF_X (executable stack)',
        ),
    ],
    limitation: 'Only the native libraries that were actually read are '
        'judged; libraries skipped for budget are not covered. An executable '
        'stack does not by itself mean the library is malicious — it only '
        'removes the NX barrier.',
    limitationCode: 'android.native_exec_stack.limitation',
    recommendation: 'Rebuild the library without -z execstack '
        '(the NDK default is a non-executable stack) and ask the vendor for '
        'a fixed build.',
    recommendationCode: 'android.native_exec_stack.review',
  );
}

/// 只有 v1（JAR）签名。
///
/// v1 只对 ZIP **条目内容**做摘要，**不保护 ZIP 结构** —— 往归档里塞入
/// 额外条目（额外的 dex、额外的资源、额外的 so）不会让 v1 签名失效。
/// 这正是重打包最常见的形态：改完内容再重签 v1 当然也会失效，但「塞入
/// 一个不被任何清单引用的条目」这类改动在 v1-only 包上尤其容易蒙混过关。
///
/// 等级 P3 + `independentCapability`：确认的是**签名方案事实**，
/// **不是**「已被篡改」。v1-only 的包完全可以是合法有效的签名 ——
/// 真正的有效性判断只属于 `apksigner`。
SecurityFinding _buildV1OnlySigning(AndroidRuleFacts f) {
  final schemes = f.meta.signingSchemes!;
  return SecurityFinding(
    ruleId: 'ANDROID-V1-ONLY-SIGNING',
    platform: SecurityPlatform.android,
    category: SecurityCategory.configuration,
    severity: SecuritySeverity.p3,
    confidence: SecurityConfidence.independentCapability,
    finding: 'The APK carries no v2 or later signature block: only the v1 '
        '(JAR) signature is present (META-INF holds a matching .SF and '
        'signature block). v1 protects the digest of each entry but not the '
        'archive structure, so entries can be added without breaking it.',
    messageCode: 'android.v1_only_signing',
    evidence: [
      SecurityEvidence(
        source: SecurityEvidenceSource.zipEntry,
        location: 'ZIP / APK Signing Block (before the central directory)',
        detail: schemes.parsed
            ? 'no APK Signing Block was found; pairs seen: '
                '${schemes.pairIds.map(ApkSignatureBlockId.describe).toList()}'
            : 'signing block could not be read: ${schemes.failure}',
      ),
    ],
    limitation: 'This only reports which signature schemes are present in '
        'the archive structure; it does not verify any signature and does '
        'not imply the package was tampered with. A v1-only APK can be '
        'perfectly validly signed. Whether the signature is valid must come '
        'from apksigner.',
    limitationCode: 'android.v1_only_signing.limitation',
    recommendation: 'Sign with v2 (and v3 where key rotation is needed) — '
        'any modern build tool does this by default. If the package is '
        'v1-only, check where it came from.',
    recommendationCode: 'android.v1_only_signing.review',
  );
}

/// 归档里完全没有签名材料 —— 既没有 v1（`META-INF` 两件套），也没有 v2+ 块。
///
/// ## 为什么这是一条**独立**规则而不是「v1-only 的一个变体」
///
/// 两者对用户的意义相反：v1-only 是「按最弱的方案签过名，仍然可安装」，
/// 未签名是「这个包根本装不上，更像构建产物或被剥过签名的中间件」。
/// 旧判据只看「有没有 v2+ 块」，于是两者产出完全相同的发现项 ——
/// 一个从未签名的包会被描述成「用了 v1 签名」。
///
/// 等级 INFO：这是**结构事实**（可以完全判定），不是风险判断。它本身不说明
/// 恶意 —— 调试包、`aapt2 link` 的中间产物、以及从某些分发渠道解出来的
/// 裸包都是这个样子。
SecurityFinding _buildUnsigned(AndroidRuleFacts f) {
  final schemes = f.meta.signingSchemes!;
  return SecurityFinding(
    ruleId: 'ANDROID-UNSIGNED',
    platform: SecurityPlatform.android,
    category: SecurityCategory.configuration,
    severity: SecuritySeverity.info,
    confidence: SecurityConfidence.confirmed,
    finding: 'The archive carries no signature material at all: there is no '
        'APK Signing Block, and META-INF holds no matching .SF plus signature '
        'block. A package in this state cannot be installed as-is; it is '
        'typically a build artifact or a package whose signature was '
        'stripped.',
    messageCode: 'android.unsigned',
    evidence: [
      SecurityEvidence(
        source: SecurityEvidenceSource.zipEntry,
        location: 'ZIP / APK Signing Block (before the central directory)',
        detail: 'no APK Signing Block was found; pairs seen: '
            '${schemes.pairIds.map(ApkSignatureBlockId.describe).toList()}',
      ),
      const SecurityEvidence(
        source: SecurityEvidenceSource.zipEntry,
        location: 'META-INF/',
        detail: 'no matching .SF + .RSA/.DSA/.EC pair at the top level of '
            'META-INF',
      ),
    ],
    limitation: 'This only reports the absence of signature material in the '
        'archive structure. It does not judge the package malicious, and it '
        'does not replace apksigner, which is the only authority on whether a '
        'signature is valid.',
    limitationCode: 'android.unsigned.limitation',
    recommendation: 'Confirm where this file came from. If it is meant for '
        'distribution, sign it with v2/v3 before installing; if it was '
        'extracted from a signed package, the original signature was lost in '
        'the process.',
    recommendationCode: 'android.unsigned.review',
  );
}

/// `addJavascriptInterface` —— 把 Java 对象注入网页的 JS 上下文。
///
/// 后果：网页里**任何脚本**都能调用被注入对象的公开方法。只要这个 WebView
/// 加载过攻击者可控的内容（深链参数、第三方页面、被劫持的 http 资源），
/// 就等于把本应用的能力交给了对方。
///
/// ## 为什么是 P3 而不是 P2
///
/// 真实样本上 5 个包有 **4 个**命中，而证据显示调用点**全部来自第三方 SDK**：
///
/// | 样本 | 调用点来自 |
/// |---|---|
/// | `49af6cnn` | Adjust、极验 Geetest、hCaptcha、神策 |
/// | `app.apk` | 极光推送、Facebook AppEvents、网易易盾 |
/// | `抖音` | 字节 webx / 小程序容器 |
/// | `飞牛` | flutter_inappwebview 插件 |
///
/// 验证码、统计、社交分享这类 SDK 必须用 JS 桥才能工作 —— 它几乎是
/// 每个现代应用的标配。按 P2 报等于在 80% 的应用上出现，读者会学会
/// 忽略整块面板。**这是「能力事实」，不是「应用自己的选择」**，
/// 所以 P3 + `independentCapability`，并在限制里说清这一点。
SecurityFinding _buildWebViewBridge(AndroidRuleFacts f) {
  final bridgeRefs = f.webViewCodeRefs
      .where((r) => r.markerId == 'webview-js-bridge')
      .toList();
  final bridgeClues =
      f.webViewClues.where((c) => c.markerId == 'webview-js-bridge').toList();
  bool has(String id) =>
      f.webViewClues.any((c) => c.markerId == id) ||
      f.webViewCodeRefs.any((r) => r.markerId == id);

  // 同一个 WebView 还开了哪些开关。**只传 id**，由呈现层按语言取文案 ——
  // 此前把英文句子直接拼进 `finding`，中文界面里就会出现
  // 「Also observed: JavaScript enabled」。
  final extras = <String>[
    if (has('webview-js-enabled')) 'js-enabled',
    if (has('webview-file-access')) 'universal-file-access',
    if (has('webview-file-url-access')) 'file-url-access',
  ];
  // 桥 + 任一 file:// 跨域开关 = 「本地文件 → 页面 → 外传」的完整通路，
  // 这时才升 P2。单有桥仍是 P3（见上面的样本表）。
  final unsafe = has('webview-file-access') || has('webview-file-url-access');

  return SecurityFinding(
    ruleId: 'ANDROID-WEBVIEW-BRIDGE',
    platform: SecurityPlatform.android,
    category: SecurityCategory.other,
    // 单有桥 → P3（第三方 SDK 普遍这么干）；桥 + file:// 跨域 → P2。
    severity: unsafe ? SecuritySeverity.p2 : SecuritySeverity.p3,
    confidence: unsafe
        ? SecurityConfidence.suspected
        : SecurityConfidence.independentCapability,
    finding: unsafe
        ? 'A JavaScript bridge (addJavascriptInterface) is combined with '
            'file:// cross-origin access: any page loaded into that WebView '
            'can read local files and call the injected object, which is the '
            'classic local-file exfiltration path.'
        : 'A JavaScript bridge is exposed to WebView content '
            '(addJavascriptInterface): scripts running in that WebView can '
            'call the injected object. CAPTCHA, analytics and social-sharing '
            'SDKs use this routinely, so its presence does not mean the app '
            'itself defined a bridge.',
    messageCode:
        unsafe ? 'android.webview_bridge_unsafe' : 'android.webview_bridge',
    messageArgs: {if (extras.isNotEmpty) 'extras': extras},
    evidence: [
      ...referenceEvidence(bridgeRefs),
      ...clueEvidence(bridgeClues),
      // 开关本身也是证据：读者要能核对「到底开了哪个」。
      ...clueEvidence([
        for (final c in f.webViewClues)
          if (c.markerId != 'webview-js-bridge') c,
      ]),
      ...referenceEvidence([
        for (final r in f.webViewCodeRefs)
          if (r.markerId != 'webview-js-bridge') r,
      ]),
    ],
    limitation: 'This reports that the API is used, not that it is '
        'reachable from untrusted content: the URL loaded into the WebView '
        'and any navigation allow-list are not evaluated. Most hits in real '
        'apps come from third-party SDKs (CAPTCHA, analytics, social '
        'sharing) — check the call sites in the evidence before treating it '
        'as the app\'s own design.',
    limitationCode: 'android.webview_bridge.limitation',
    recommendation: 'Remove the JavaScript bridge unless it is required; '
        'otherwise restrict navigation to an allow-list of trusted origins '
        'and never load http:// or deep-link parameters into that WebView.',
    recommendationCode: 'android.webview_bridge.review',
  );
}

/// 声明了敏感权限，但代码里找不到对应 API。
///
/// 这是 iOS 侧 `IOS-USAGE-WITHOUT-API`（声明了用途但没实现）的 Android 对应物：
/// 过度声明会让权限清单失真，也让「这个应用为什么要通讯录」这类问题没法回答。
///
/// 等级 P3 + `suspected`：代码可能在**没扫到的**地方 —— 原生库、动态加载的
/// DEX、或者用了我们没编目的第三方 SDK 类名。所以这是「值得核对」，
/// 不是「一定没用」。
SecurityFinding _buildUnusedPermission(AndroidRuleFacts f) {
  final names = [...f.unusedPermissionNames]..sort();
  return SecurityFinding(
    ruleId: 'ANDROID-PERMISSION-WITHOUT-API',
    platform: SecurityPlatform.android,
    category: SecurityCategory.configuration,
    severity: SecuritySeverity.p3,
    confidence: SecurityConfidence.suspected,
    finding: 'These permissions are declared but no matching API call was '
        'found in the scanned code: ${names.join(', ')}. The declaration may '
        'be left over from older code, or the code may live somewhere this '
        'scan did not reach.',
    messageCode: 'android.permission_without_api',
    messageArgs: {'names': names},
    evidence: [
      for (final name in names)
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'AndroidManifest.xml / uses-permission[@name="$name"]',
          detail: 'declared; no matching API marker found in the scanned DEX',
        ),
    ],
    limitation: 'Only the code that was actually scanned counts: native '
        'libraries, dynamically loaded DEX and third-party SDKs with unknown '
        'class names are not covered. A missing marker is therefore not '
        'proof that the permission is unused.',
    limitationCode: 'android.permission_without_api.limitation',
    recommendation: 'Check whether the permission is still needed; removing '
        'an unused dangerous permission reduces both the permission list and '
        'the review burden.',
    recommendationCode: 'android.permission_without_api.review',
  );
}

/// 备份规则属性是否指向一份 XML 规则文件（本解析器的引用表示法是 `@res/`）。
bool _isRuleFileRef(String? value) =>
    value != null && value.trim().startsWith('@res/');

/// 第三方**服务类** SDK 的盘点结果。
///
/// 这是 **info 级**的清单，不是风险结论 —— 构造逻辑在
/// `sdk_catalog.dart` 里（与目录表放在一起，改了表就能看到措辞）。
SecurityFinding _buildThirdPartySdk(AndroidRuleFacts f) =>
    buildSdkInventoryFinding(f.sdkInventory);

/// `android:sharedUserId` —— 与同签名的其它应用共享 UID。
///
/// 后果很具体：同一 UID 下的应用**共享沙箱**，彼此的私有目录、偏好、
/// 数据库互相可读。只要其中一个包被替换成旧版本或被攻破，另一个的数据
/// 也就跟着暴露。
///
/// 等级 P2 而不是 P1：共享 UID 需要**相同签名**，正常情况下是同一开发者
/// 自己的应用之间共享；它是「配置上不该有」的味道，不是可被任意利用的洞。
/// 这个属性在 Android 10 起已被标记为废弃。
SecurityFinding _buildSharedUserId(AndroidRuleFacts f) {
  final id = f.meta.sharedUserId!;
  return SecurityFinding(
    ruleId: 'ANDROID-SHARED-USER-ID',
    platform: SecurityPlatform.android,
    category: SecurityCategory.configuration,
    severity: SecuritySeverity.p2,
    confidence: SecurityConfidence.confirmed,
    finding: 'The manifest declares android:sharedUserId="$id": this app '
        'shares a UID (and therefore a sandbox) with any other app signed '
        'with the same key and declaring the same sharedUserId.',
    messageCode: 'android.shared_user_id',
    messageArgs: {'id': id},
    evidence: [
      SecurityEvidence(
        source: SecurityEvidenceSource.manifest,
        location: 'AndroidManifest.xml / manifest[@android:sharedUserId]',
        detail: 'android:sharedUserId="$id"',
      ),
    ],
    limitation: 'Whether another app with the same sharedUserId is actually '
        'installed on the device cannot be determined from this package; '
        'only the declaration is reported. sharedUserId is deprecated since '
        'Android 10.',
    limitationCode: 'android.shared_user_id.limitation',
    recommendation: 'Remove android:sharedUserId unless the data sharing is '
        'genuinely required, and review every app that declares the same '
        'value.',
    recommendationCode: 'android.shared_user_id.review',
  );
}

// ---------------------------------------------------------------------------
// 各规则的判定
// ---------------------------------------------------------------------------

bool _matchesRuleA(AndroidRuleFacts f) => f.broadStorage.isNotEmpty;

bool _matchesRuleB(AndroidRuleFacts f) => f.hasImageInput && f.hasOcrCapability;

bool _matchesRuleC(AndroidRuleFacts f) =>
    f.hasImageInput && f.hasOcrCapability && f.hasUploadCapability;

bool _matchesRuleD(AndroidRuleFacts f) => f.allowsCleartext;

bool _matchesRuleE(AndroidRuleFacts f) =>
    f.hasBackground &&
    (f.hasImageInput || f.hasOcrCapability) &&
    f.hasUploadCapability;

/// 特殊访问能力：**不需要**「+上传」也报。
///
/// 无障碍（读屏/自动点击）、设备管理器（防卸载/锁屏/抹除）、通知监听
/// （读通知里的验证码）这三类能力一旦被滥用，危害远大于普通权限；而它们
/// 在正常应用里也确实存在（自动化、密码管理器、手表应用），所以只到 P3 +
/// confirmed（确认的是**声明事实**，不是风险）。
bool _matchesSpecialAccess(AndroidRuleFacts f) =>
    f.specialAccessKinds.isNotEmpty;

/// 规则 G：非图片类敏感数据来源（设备标识 / 通讯录）**同时**存在上传能力。
///
/// 与规则 C 分开：C 说的是「图片 → OCR → 上传」这条链，G 说的是
/// 「设备标识 / 通讯录 → 上传」。两者的数据来源不同，各自成立。
bool _matchesRuleG(AndroidRuleFacts f) =>
    f.hasSensitiveSource && f.hasUploadCapability;

/// 规格规则 F：**没有上传线索时必须显式产出这一条**，而不是留一个空列表
/// 让人以为查过了就等于安全。
bool _matchesRuleF(AndroidRuleFacts f) => f.uploadClues.isEmpty;

// ---------------------------------------------------------------------------
// 各规则的构造
// ---------------------------------------------------------------------------

SecurityFinding _buildRuleA(AndroidRuleFacts f) {
  final broadStorage = f.broadStorage;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-A',
    platform: SecurityPlatform.android,
    category: SecurityCategory.photoAccess,
    severity: SecuritySeverity.p2,
    confidence: SecurityConfidence.suspected,
    finding: 'Broad storage / photo library access found: '
        '${broadStorage.map((r) => r.shortName).join(', ')}, listed as a '
        'medium-risk candidate for manual review. This analysis found no '
        'obvious image-related feature clues in the package that would '
        'explain it (such as system photo picker calls or image list '
        'screens).',
    messageCode: 'android.rule_a',
    messageArgs: {
      'names': broadStorage.map((r) => r.shortName).toList(),
    },
    evidence: [
      for (final request in broadStorage) manifestEvidence(request),
    ],
    limitation: '"The business purpose is missing" is a static '
        'inference: the business code may live in unscanned native '
        'libraries, a hardened shell or a dynamically loaded module.',
    limitationCode: 'android.rule_a.limitation',
    recommendation: 'Manually check whether the app really needs '
        'whole-disk file access; if not, consider the system photo picker '
        '(Photo Picker) instead. This item is a candidate for review, not '
        'a malicious verdict.',
    recommendationCode: 'android.rule_a.manual_review',
  );
}

SecurityFinding _buildRuleB(AndroidRuleFacts f) {
  final effectivePhotoAccess = f.effectivePhotoAccess;
  final photoClues = f.photoClues;
  final ocrClues = f.ocrClues;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-B',
    platform: SecurityPlatform.android,
    category: SecurityCategory.ocrImage,
    severity: SecuritySeverity.p2,
    confidence: SecurityConfidence.suspected,
    finding: 'Both an image input source and text recognition capability '
        'were found: permission/code clues '
        '(${[
      ...effectivePhotoAccess.map((r) => r.shortName),
      ...photoClues.map((c) => c.description),
    ].join(', ')}) and recognition capability '
        '(${ocrClues.map((c) => c.description).join(', ')}). This '
        'combination may correspond to a normal feature (document '
        'scanning, translation, business card reading).',
    messageCode: 'android.rule_b',
    messageArgs: {
      'inputClues': [
        ...effectivePhotoAccess.map((r) => r.shortName),
        ...photoClues.map((c) => c.description),
      ],
      'ocrClues': ocrClues.map((c) => c.description).toList(),
    },
    evidence: [
      for (final request in effectivePhotoAccess) manifestEvidence(request),
      ...referenceEvidence(f.ocrCodeRefs),
      ...clueEvidence([...photoClues, ...ocrClues]),
    ],
    relationship: 'Image input → text recognition: the two clues '
        'co-occur, but they are not proven to lie on the same call path.',
    relationshipCode: 'android.rule_b.relationship',
    limitation: 'No disassembly was performed, so it cannot be determined '
        'whether the recognition module actually handles user-selected '
        'images or batch-scanned media files.',
    limitationCode: 'android.rule_b.limitation',
    recommendation: 'Confirm the recognition input source and how the '
        'user authorises it (whether it goes through the system photo '
        'picker).',
    recommendationCode: 'android.rule_b.confirm_pipeline',
  );
}

SecurityFinding _buildRuleC(AndroidRuleFacts f) {
  // 关联说明有两种措辞（同方法体 / 整包层面），因此先把 code 与回退
  // 一起算出来 —— 引擎不能只产出一句中文再让呈现层猜。
  final note = coOccurrenceNote(f.methodScan, f.ocrCodeRefs, f.uploadCodeRefs);
  // **等级跟着证据强度走**：同一方法体内两个调用点 → P1；只有整包层面的
  // 共现 → P2。此前两种情况都给 P1，于是「一个应用里既有 OCR SDK 又有
  // 上传库」这种极常见的组合也被顶到最高档，真正同方法体的样本反而淹没。
  // 等级跟证据强度走：同方法体（0 跳）与直接调用（1 跳）都算强证据，
  // 2 跳与整包层面降一档。**不再只看「是否同一方法体」** —— 那会把
  // 「识别方法直接调用上传方法」这种同样具体的证据埋进 P2。
  final strong = note.hops == 0 || note.hops == 1;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-C',
    platform: SecurityPlatform.android,
    category: SecurityCategory.dataExfiltration,
    severity: strong ? SecuritySeverity.p1 : SecuritySeverity.p2,
    confidence: SecurityConfidence.suspected,
    finding: 'Image input, text recognition and upload call clues all '
        'appear together: a suspected path for sensitive data leaving '
        'the device. This is a high-risk **candidate**; static analysis '
        'could not prove that data actually flows into an upload '
        'request.',
    messageCode: 'android.rule_c',
    evidence: [
      for (final request in f.effectivePhotoAccess) manifestEvidence(request),
      ...referenceEvidence([...f.ocrCodeRefs, ...f.uploadCodeRefs]),
      ...clueEvidence([...f.ocrClues, ...f.uploadClues]),
    ],
    dataSource: '照片/媒体文件与其中的识别文本',
    // 中间跳：同方法体时是那个方法；整包层面时留空（不编造）。
    dataTransform: note.caller ?? note.path,
    dataSink: '上传请求（multipart / upload API）',
    relationship: note.fallback,
    relationshipCode: note.code,
    relationshipArgs: note.args,
    // 找到调用链之后，再说「不是调用图分析」就是**说错了** —— 那正是它。
    limitation: note.hops < 1
        ? 'The association comes from multiple markers co-occurring, not '
            'from call-graph analysis; reflection, dynamic loading and '
            'hardening may all make the real path different.'
        : 'The chain comes from the call graph (shortest path, '
            '${note.hops} hop(s)), which is method-level only: the arguments '
            'passed along the chain are not tracked, so "the value flows from '
            'one to the other" is still unproven.',
    limitationCode: note.hops < 1
        ? 'android.rule_c.limitation'
        : (note.graphTruncated
            ? 'android.rule_c.limitation_graph_truncated'
            : 'android.rule_c.limitation_graph'),
    limitationArgs: {'hops': '${note.hops}'},
    recommendation: 'Review manually first; you can capture and verify '
        'the actual outbound content in an isolated environment '
        '(requires dynamic testing, not provided in this version).',
    recommendationCode: 'android.rule_c.manual_review',
  );
}

SecurityFinding _buildRuleG(AndroidRuleFacts f) {
  // 说清**是哪几类**来源：设备标识 / 通讯录 / 短信 / 定位 / 录音 / 剪贴板
  // 对用户的含义完全不同，混成一句「敏感数据」等于没说。
  bool has(String markerId) =>
      f.sensitiveSourceClues.any((c) => c.markerId == markerId) ||
      f.sensitiveSourceCodeRefs.any((r) => r.markerId == markerId);

  final sourceIds = <String>[
    if (has('device-id')) 'device_id',
    if (has('contacts')) 'contacts',
    if (has('sms')) 'sms',
    if (has('location')) 'location',
    if (has('recording')) 'recording',
    if (has('clipboard')) 'clipboard',
  ]..sort();

  // `dataSource` 是给界面/报告直接显示的一行字，用中文标签；
  // `{sources}` 走 i18n，两者说的是同一批来源。
  const sourceLabels = <String, String>{
    'device_id': '设备标识',
    'contacts': '通讯录',
    'sms': '短信',
    'location': '定位',
    'recording': '录音',
    'clipboard': '剪贴板',
  };
  final sourceText = sourceIds.map((id) => sourceLabels[id] ?? id).join(' / ');

  // **按来源的稀有度分级**，而不是一律 P2。
  //
  // 实测（5 个真实包）：「设备标识 → 上传」「定位 → 上传」几乎每个应用都有
  // （统计 SDK、地图），一律报 P2 会让这条规则在九成应用上出现 —— 那就成了
  // 噪音，读者会学会忽略它。而「通讯录 / 短信 / 录音 → 上传」在正常应用里
  // 并不常见，值得单独看一眼。
  const higherSignalSources = {'contacts', 'sms', 'recording'};
  final isHigherSignal = sourceIds.any(higherSignalSources.contains);

  return SecurityFinding(
    ruleId: 'ANDROID-RULE-G',
    platform: SecurityPlatform.android,
    category: SecurityCategory.dataExfiltration,
    // P1 从不给：单凭「同现」不足以说「数据被传走了」。规则 C 之所以是 P1，
    // 是因为「图片 → 识别 → 上传」这条链本身就更可疑。
    severity: isHigherSignal ? SecuritySeverity.p2 : SecuritySeverity.p3,
    confidence: SecurityConfidence.suspected,
    finding: 'A non-image sensitive data source (device identifier / contacts) '
        'and upload capability were both found. This is a suspected '
        'exfiltration path: static analysis could not prove that the data '
        'read here actually reaches an upload request.',
    messageCode: 'android.rule_g',
    messageArgs: {'sources': sourceIds},
    evidence: [
      ...clueEvidence(f.sensitiveSourceClues),
      ...referenceEvidence(f.sensitiveSourceCodeRefs),
      ...clueEvidence(f.uploadClues),
      ...referenceEvidence(f.uploadCodeRefs),
    ],
    dataSource: sourceText,
    dataSink: '上传请求（multipart / upload API）',
    // 这一条**没有** dataTransform：字符串线索没有方法上下文，
    // 拿不到「同一方法体」的定位。留空而不是编一个。
    relationship: 'The source API and the upload API both appear in the '
        'package, but they are not proven to lie on the same call path — '
        'whether the data actually flows into the request is **not '
        'established**.',
    relationshipCode: 'android.rule_g.relationship',
    limitation: 'Co-occurrence is not data flow: the source may be read for '
        'an unrelated feature (analytics, fraud detection), and the upload '
        'may carry something else entirely. No disassembly or taint '
        'analysis was performed.',
    limitationCode: 'android.rule_g.limitation',
    recommendation: 'Review manually: check whether the device identifier / '
        'contacts data is actually sent out, and whether the user was told '
        'about it. This item is a candidate for review, not a malicious '
        'verdict.',
    recommendationCode: 'android.rule_g.manual_review',
  );
}

/// 规则 D 的证据：**必须指向真正让它成立的那份配置**。
///
/// 明文策略有两个来源，说错来源比不说更糟：
/// - `android:usesCleartextTraffic="true"`（没有 NSC 时）；
/// - `res/xml/network_security_config.xml` 里的 `base-config` 或
///   `domain-config`（有 NSC 时 —— 此时清单属性**被平台忽略**，
///   拿它当证据等于指向一个不生效的地方）。
List<SecurityEvidence> _cleartextEvidence(AndroidRuleFacts f) {
  final nsc = f.meta.networkSecurityConfigInfo;
  if (nsc != null && nsc.parsed) {
    final evidence = <SecurityEvidence>[];
    if (nsc.baseCleartextPermitted == true) {
      evidence.add(SecurityEvidence(
        source: SecurityEvidenceSource.networkSecurityConfig,
        location: 'network security config (${nsc.path}) / base-config',
        detail: 'cleartextTrafficPermitted="true" (applies to all domains)',
      ));
    }
    final domains = nsc.cleartextDomains;
    if (domains.isNotEmpty) {
      const shown = 8;
      final listed = domains.take(shown).join(', ');
      evidence.add(SecurityEvidence(
        source: SecurityEvidenceSource.networkSecurityConfig,
        location: 'network security config (${nsc.path}) / domain-config',
        detail: domains.length > shown
            ? 'cleartextTrafficPermitted="true" for ${domains.length} '
                'domain(s), including $listed'
            : 'cleartextTrafficPermitted="true" for: $listed',
      ));
    }
    return evidence;
  }
  return const [
    SecurityEvidence(
      source: SecurityEvidenceSource.manifest,
      location: 'AndroidManifest.xml / manifest / application',
      detail: 'android:usesCleartextTraffic="true"',
    ),
  ];
}

SecurityFinding _buildRuleD(AndroidRuleFacts f) {
  final withSensitive = f.hasSensitiveAlongsideCleartext;
  return SecurityFinding(
    ruleId: withSensitive ? 'ANDROID-RULE-D-ESCALATED' : 'ANDROID-RULE-D',
    platform: SecurityPlatform.android,
    category: SecurityCategory.configuration,
    severity: withSensitive ? SecuritySeverity.p1 : SecuritySeverity.p2,
    confidence: SecurityConfidence.confirmed,
    // 正文**不点名**是清单属性还是 NSC —— 那是证据行的事。
    // 两个来源在措辞上分叉的话，每种来源都要两套文案，而读者真正需要
    // 知道的是「哪儿写的」，证据里就写着 `AndroidManifest.xml / ...` 或
    // `res/xml/network_security_config.xml / base-config`。
    finding: withSensitive
        ? 'The app permits cleartext (non-TLS) traffic, and image / '
            'recognition / upload clues are present at the same time: '
            'sensitive data may travel over an unencrypted channel.'
        : 'The app permits cleartext (non-TLS) traffic.',
    messageCode: withSensitive ? 'android.rule_d_escalated' : 'android.rule_d',
    evidence: _cleartextEvidence(f),
    limitation: 'Allowing cleartext in the configuration is not the same '
        'as actually using cleartext; the specific requests would need '
        'packet capture to confirm. Certificate pinning and trust anchors '
        'in the same config are not evaluated.',
    limitationCode: 'android.rule_d.limitation',
    recommendation: 'Confirm whether cleartext requests actually exist; '
        'turn the switch off if it is not needed.',
    recommendationCode: 'android.rule_d.manual_review',
  );
}

SecurityFinding _buildRuleE(AndroidRuleFacts f) {
  final backgroundClues = f.backgroundClues;
  final backgroundPermissions = f.backgroundPermissions;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-E',
    platform: SecurityPlatform.android,
    category: SecurityCategory.backgroundTask,
    severity: SecuritySeverity.p1,
    confidence: SecurityConfidence.suspected,
    finding: 'Background task, sensitive data access and upload call '
        'clues all appear together and corroborate each other: further '
        'verification at runtime is needed. Finding only a background '
        'task or a network permission is not malicious evidence.',
    messageCode: 'android.rule_e',
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
          detail:
              backgroundPermissions.map((r) => r.shortName).take(8).join(', '),
        ),
      for (final request in f.effectivePhotoAccess) manifestEvidence(request),
    ],
    relationship: 'Background entry point + sensitive data source + '
        'upload sink: the three kinds of evidence co-occur, but "whether '
        'the app actually processes and uploads media data in the '
        'background" is not proven.',
    relationshipCode: 'android.rule_e.relationship',
    limitation: 'No dynamic analysis was run, so the actual triggering '
        'and execution of background tasks cannot be observed.',
    limitationCode: 'android.rule_e.limitation',
    recommendation: 'Run it in an isolated environment and confirm after '
        'observing the network behaviour.',
    recommendationCode: 'android.rule_e.manual_review',
  );
}

/// 特殊访问能力：一条发现列出**全部**命中的能力（不刷屏）。
///
/// 等级只到 P3 + confirmed：确认的是「声明/引用了这个能力」这个事实，
/// 不是「这个应用在滥用它」。无障碍与通知监听在自动化、密码管理器、手表
/// 应用里都是正常需求。
SecurityFinding _buildSpecialAccess(AndroidRuleFacts f) {
  final ids = f.specialAccessKinds;
  // 证据指回清单里的那个组件 —— 读者能自己去 manifest 里核对。
  final evidence = <SecurityEvidence>[];
  for (final component in f.meta.components) {
    const bindPermissions = {
      'android.permission.BIND_ACCESSIBILITY_SERVICE': 'accessibility',
      'android.permission.BIND_DEVICE_ADMIN': 'device_admin',
      'android.permission.BIND_NOTIFICATION_LISTENER_SERVICE':
          'notification_listener',
    };
    final kind = bindPermissions[component.permission];
    if (kind == null) continue;
    evidence.add(SecurityEvidence(
      source: SecurityEvidenceSource.manifest,
      location: 'AndroidManifest.xml / ${component.type.name}'
          '[@name="${component.name ?? '?'}"]',
      detail: 'android:permission="${component.permission}"',
    ));
  }

  return SecurityFinding(
    ruleId: 'ANDROID-SPECIAL-ACCESS',
    platform: SecurityPlatform.android,
    category: SecurityCategory.backgroundTask,
    severity: SecuritySeverity.p3,
    confidence: SecurityConfidence.confirmed,
    finding: 'The manifest declares special-access capabilities: '
        '${ids.join(', ')}. These are high-privilege facts that the user '
        'should be told about; declaring them does not mean they are abused.',
    messageCode: 'android.special_access',
    messageArgs: {'sources': ids},
    evidence: evidence,
    limitation: 'This is a manifest declaration fact, not a behaviour '
        'finding: accessibility services, device admin and notification '
        'listeners all have legitimate uses (automation, password managers, '
        'watch companions). No runtime behaviour was observed.',
    limitationCode: 'android.special_access.limitation',
    recommendation: 'Check what the app does with this capability and whether '
        'the user is told about it. This is a fact to review, not a '
        'malicious verdict.',
    recommendationCode: 'android.special_access.review',
  );
}

SecurityFinding _buildRuleF(AndroidRuleFacts f) {
  final noDex = !f.hasDexContent;
  return SecurityFinding(
    ruleId: 'ANDROID-RULE-F',
    platform: SecurityPlatform.android,
    category: SecurityCategory.dataExfiltration,
    severity: SecuritySeverity.info,
    confidence:
        noDex ? SecurityConfidence.unknown : SecurityConfidence.confirmed,
    finding: 'No upload-related code characteristics were found within '
        'the current analysis scope (no hits for multipart upload, file '
        'upload APIs or similar markers). This does not mean the app has '
        'no upload behaviour — it only means this static scan found none.',
    messageCode: 'android.rule_f',
    // **否定结论也要有依据。** 空证据会让它与「根本没查」在数据上无法区分；
    // 这条证据回答「查了什么」：几个 DEX、多少个调用点、结论从哪来。
    evidence: [
      SecurityEvidence(
        source: SecurityEvidenceSource.dexMethodReference,
        location: 'classes*.dex (${f.methodScan.walkedDexCount} DEX)',
        detail: '${f.methodScan.walkedDexCount} DEX / '
            '${f.methodScan.callSiteCount} call site(s) scanned; no upload '
            'marker matched',
        detailCode: 'rule_f.scope',
        detailArgs: {
          'dex': f.methodScan.walkedDexCount,
          'callSites': f.methodScan.callSiteCount,
        },
      ),
    ],
    limitation: noDex
        ? 'No DEX content was read this time, so the confidence of the '
            '"not found" conclusion is incomplete.'
        : 'String scanning does not cover native libraries, resources or '
            'code inside a hardened shell.',
    limitationCode: noDex
        ? 'android.rule_f.limitation_no_dex'
        : 'android.rule_f.limitation_scope',
    recommendation: 'To rule out upload behaviour, combine this with '
        'dynamic traffic observation (not provided in this version).',
    recommendationCode: 'android.rule_f.runtime_traffic',
  );
}

// ---------------------------------------------------------------------------
// 证据构造（规则与编排共用，因此是**包内可见**的顶层函数）
// ---------------------------------------------------------------------------

/// 把一条权限请求转成证据条目。
SecurityEvidence manifestEvidence(AndroidPermissionRequest request) {
  return SecurityEvidence(
    source: SecurityEvidenceSource.manifest,
    location: 'AndroidManifest.xml / manifest / uses-permission'
        '[@name="${request.name}"]',
    detail: '$request',
  );
}

/// 把字符串线索转成证据条目。
List<SecurityEvidence> clueEvidence(List<CodeClue> clues) {
  return [
    for (final clue in clues)
      SecurityEvidence(
        source: SecurityEvidenceSource.dexString,
        location: clue.dexNames.join(', '),
        detail: '${clue.markerId}: ${clue.samples.join(' | ')}',
      ),
  ];
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
List<SecurityEvidence> referenceEvidence(List<CodeReference> references) {
  return [
    for (final reference in references) ...[
      if (reference.samples.isNotEmpty)
        SecurityEvidence(
          source: SecurityEvidenceSource.dexMethodReference,
          location: reference.dexNames.join(', '),
          detail: '${reference.markerId} (reference): '
              '${reference.samples.join(' | ')}',
          detailCode: 'code.reference',
          detailArgs: {
            'marker': reference.markerId,
            'samples': reference.samples.join(' | '),
          },
        ),
      if (reference.callSiteSamples.isNotEmpty)
        SecurityEvidence(
          source: SecurityEvidenceSource.dexMethodReference,
          location: reference.dexNames.join(', '),
          detail: '${reference.markerId} (call site): '
              '${reference.callSiteSamples.join(' | ')}',
          detailCode: 'code.call_site',
          detailArgs: {
            'marker': reference.markerId,
            'samples': reference.callSiteSamples.join(' | '),
          },
        ),
    ],
  ];
}

/// 描述「识别与上传的调用指令是否位于同一个方法体内」。
///
/// 这是调用点分析带来的新信息：字符串同现只能说「两个词都出现在这个包里」。
/// 但措辞必须守住界线 —— **同一个方法里既有识别又有上传，不等于识别结果被
/// 送进了上传请求**，那要看寄存器与参数传递，属于数据流分析。
///
/// 返回 `(code, fallback, args)` 三元组：引擎产不出本地化文案，只给稳定 id
/// 与英文回退，由呈现层按语言取文案。
({
  String code,
  String fallback,
  Map<String, Object> args,
  // 中间跳的**机器可读定位**：识别与上传的调用指令都落在哪个方法里。
  // 整包层面（不在同一方法体）时为 `null` —— 不编造一个「大概是这里」。
  String? caller,

  /// 证据强度：0 = 同一方法体，1 / 2 = 调用链跳数，-1 = 整包层面。
  int hops,

  /// 调用链路径（`A → X → B`），整包层面与同方法体时为 `null`。
  String? path,

  /// 调用图是否因上限被截断（链路可能因此找不到）。
  bool graphTruncated,
}) coOccurrenceNote(
  DexMethodScanResult scan,
  List<CodeReference> ocrReferences,
  List<CodeReference> uploadReferences,
) {
  final ocrIds = ocrReferences.map((r) => r.markerId);
  final uploadIds = uploadReferences.map((r) => r.markerId);
  final occurrence = scan.firstCoOccurrenceAcross(ocrIds, uploadIds);
  if (occurrence == null) {
    // 不在同一方法体，再看调用链：1 跳 = 直接调用，2 跳 = 经由一个中间方法。
    // 这一档比整包层面强得多 —— 至少能说「这两步在同一条调用路径上」。
    final chain = scan.firstChainBetween(ocrIds, uploadIds);
    if (chain != null) {
      return (
        code: 'android.rule_c.relationship_chain',
        fallback: 'The call sites for text recognition and upload are in '
            'different method bodies connected by a call chain '
            '(${chain.path}, ${chain.hops} hop(s)). Both stages have '
            'evidence and they lie on one call path, but "the value flows '
            'from one to the other" is still not proven: the arguments '
            'passed across the call are not tracked.',
        args: {'path': chain.path, 'hops': chain.hops},
        caller: null,
        hops: chain.hops,
        path: chain.path,
        graphTruncated: scan.deepGraphTruncated,
      );
    }
    return (
      code: 'android.rule_c.relationship_package',
      fallback: 'The call instructions for text recognition and upload are '
          '**not in the same method body** (the co-occurrence is at the '
          'whole-package level). Reading a photo → image text recognition → '
          'building an upload request: there is evidence for each of the '
          'three stages, but "the data flow along the same code path" is '
          'not proven — the unproven hop is the recognition result entering '
          'the upload request.',
      args: const {},
      caller: null,
      hops: -1,
      path: null,
      graphTruncated: scan.deepGraphTruncated,
    );
  }
  return (
    code: 'android.rule_c.relationship_method',
    fallback: 'The call instructions for text recognition and upload '
        'appear **in the same method body** '
        '(${occurrence.callerDisplayName}); but co-occurrence within one '
        'method is not data flow: whether the recognition result is fed '
        'into the upload request is not proven. Reading a photo → image '
        'text recognition → building an upload request: there is evidence '
        'for each of the three stages, but "the data flow along the same '
        'code path" is not proven.',
    args: {'caller': occurrence.callerDisplayName},
    caller: occurrence.callerDisplayName,
    hops: 0,
    path: null,
    graphTruncated: scan.deepGraphTruncated,
  );
}
