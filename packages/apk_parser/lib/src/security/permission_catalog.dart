import 'package:analysis_model/analysis_model.dart';

/// Android 权限规则目录。
///
/// 规格 3.1 要求「权限名称、版本适用条件与风险映射应设计为可更新规则」——
/// 所以这里是**数据**而不是散落在代码里的 if 链：每条规则是一条
/// [PermissionRule]，加/改权限只动这张表，并升 [rulesVersion]。
///
/// 三条编目原则（都来自规格，不是偏好）：
///
/// 1. **权限本身大多不是恶意的**。大多数条目的 [PermissionRule.baseSeverity]
///    是 INFO —— 规格第五章明确等级不由权限数量决定；只有广泛存储访问
///    （MANAGE_EXTERNAL_STORAGE、旧版全盘存储）单独出现时才给 P2，且措辞是
///    「需人工复核」而不是「恶意」。
/// 2. **版本条件是一等公民**。`READ_MEDIA_IMAGES` 只在 targetSdk ≥ 33 时生效；
///    `READ_EXTERNAL_STORAGE` 在 targetSdk ≥ 33 后基本失效；`READ_MEDIA_VISUAL_USER_SELECTED`
///    是 Android 14 的部分照片授权机制，**绝不能与完整图库访问混为一类**。
/// 3. **未知权限不逐条刷屏**。未编目的权限汇总成一条 INFO，否则一个 40 项权限的
///    加固样本会产出 40 条噪音，真正的问题被埋掉。
///
/// [PermissionRule.description] 与 [PermissionRule.riskNote] 是**英文回退**：
/// 引擎层不依赖 slang，产不出本地化文案。呈现层按
/// [PermissionRule.name] 取本地化文本（`AnalysisReport` 里的
/// `_permissionRuleText`）—— **`name` 本身就是这张表的稳定 id**，
/// 因此不需要额外的 code 字段。
class PermissionCatalog {
  PermissionCatalog._();

  /// 规则库版本。改这张表必须升版本，否则两份报告无法对照。
  static const String rulesVersion = 'android-permissions-2026.10.2';

  /// 目录里的全部规则。
  static const List<PermissionRule> rules = [
    // ---- 照片与视频（现代分区存储模型）----
    PermissionRule(
      name: 'READ_MEDIA_IMAGES',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      minApi: 33,
      description:
          'Read photos (the fine-grained media permission introduced in '
          'Android 13).',
      riskNote: 'A routine permission for image apps; on its own it is not a '
          'risk. But if the app has no visible image-related feature, it '
          'falls under "broad photo library access without a business '
          'purpose" (rule A).',
    ),
    PermissionRule(
      name: 'READ_MEDIA_VIDEO',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      minApi: 33,
      description:
          'Read videos (the fine-grained media permission introduced in '
          'Android 13).',
      riskNote: 'As above: a routine permission for video apps; judge whether '
          'the purpose is reasonable together with the app features.',
    ),
    PermissionRule(
      name: 'READ_MEDIA_AUDIO',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      minApi: 33,
      description: 'Read audio files (since Android 13).',
      riskNote: 'A routine permission for audio apps; when combined with '
          'image / OCR clues, look at the input source.',
    ),
    PermissionRule(
      name: 'READ_MEDIA_VISUAL_USER_SELECTED',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      minApi: 34,
      description:
          'Photos/videos the user explicitly selected (the partial photo '
          'access mechanism introduced in Android 14).',
      riskNote: 'This is the mechanism where the **user grants access to '
          'part of the media**, which is a different thing from full library '
          'access: its presence means the app only touches the photos the '
          'user ticked, and its absence is what suggests full access may be '
          'requested. It must not be lumped together with READ_MEDIA_IMAGES.',
    ),

    // ---- 旧版存储访问 ----
    PermissionRule(
      name: 'READ_EXTERNAL_STORAGE',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.p2,
      description:
          'Read shared storage (the whole-disk file access model on Android 12 '
          'and earlier).',
      riskNote: 'On apps with targetSdk ≤ 32 this is close to "whole-disk '
          'file access"; from targetSdk ≥ 33 it is largely superseded by '
          'scoped storage (a leftover declaration has little real effect). '
          'Real hardened samples declare it with maxSdkVersion=32, so the '
          'version condition must be taken into account.',
    ),
    PermissionRule(
      name: 'WRITE_EXTERNAL_STORAGE',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.p2,
      maxApiEffectiveAbove: 28,
      description: 'Write to shared storage.',
      riskNote: 'Writing to shared storage has largely stopped working since '
          'targetSdk ≥ 29; on its own it is not judged a risk, and only '
          'serves as corroboration in a broad-access combination.',
    ),
    PermissionRule(
      name: 'MANAGE_EXTERNAL_STORAGE',
      category: SecurityCategory.photoAccess,
      protection: PermissionProtection.special,
      baseSeverity: SecuritySeverity.p2,
      minApi: 30,
      description:
          'Manage external storage (whole-disk file access; a permission '
          'Google Play restricts strictly).',
      riskNote: 'Spec 3.1 lists it as a "high-attention permission": usually '
          'only file-manager apps need it. When present it is recorded as a '
          'medium-risk candidate for manual review, not a direct malicious '
          'verdict.',
    ),

    // ---- 相机 ----
    PermissionRule(
      name: 'CAMERA',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      description: 'Use the camera.',
      riskNote: 'Spec 3.1: judge it together with capture, image recognition '
          'and upload behaviour. When it co-occurs with OCR clues it is '
          'handled by rules B/C; on its own it is not escalated.',
    ),

    // ---- 网络 ----
    PermissionRule(
      name: 'INTERNET',
      category: SecurityCategory.network,
      baseSeverity: SecuritySeverity.info,
      description: 'Access the network.',
      riskNote: 'Spec 3.1: a network permission is not malicious by itself.',
    ),
    PermissionRule(
      name: 'ACCESS_NETWORK_STATE',
      category: SecurityCategory.network,
      baseSeverity: SecuritySeverity.info,
      description: 'View the network connection state.',
      riskNote: 'A routine permission; like the other network permissions '
          'below, it is recorded as fact only.',
    ),
    PermissionRule(
      name: 'ACCESS_WIFI_STATE',
      category: SecurityCategory.network,
      baseSeverity: SecuritySeverity.info,
      description: 'View the Wi-Fi state.',
      riskNote: 'A routine permission.',
    ),
    PermissionRule(
      name: 'CHANGE_WIFI_STATE',
      category: SecurityCategory.network,
      baseSeverity: SecuritySeverity.info,
      description: 'Change the Wi-Fi connection state.',
      riskNote: 'A routine permission.',
    ),

    // ---- 后台任务 ----
    PermissionRule(
      name: 'FOREGROUND_SERVICE',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      minApi: 28,
      description: 'Foreground service.',
      riskNote: 'On its own this is a routine capability; spec rule E only '
          'escalates when it co-occurs with sensitive data collection and '
          'upload.',
    ),
    PermissionRule(
      name: 'FOREGROUND_SERVICE_DATA_SYNC',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      minApi: 34,
      description: 'Data-sync foreground service.',
      riskNote: 'As above; when it co-occurs with sync and upload, look at '
          'its stated purpose.',
    ),
    PermissionRule(
      name: 'RECEIVE_BOOT_COMPLETED',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      description: 'Start on boot.',
      riskNote: 'A background entry-point clue and one of rule E\'s inputs; on '
          'its own it is not judged a risk.',
    ),
    PermissionRule(
      name: 'WAKE_LOCK',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      description: 'Keep the device awake.',
      riskNote: 'A clue for continuous background execution; on its own it is '
          'not judged a risk.',
    ),
    PermissionRule(
      name: 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      description: 'Request to ignore battery optimisations.',
      riskNote: 'A clue for staying resident in the background; on its own it '
          'is not judged a risk.',
    ),
    PermissionRule(
      name: 'SCHEDULE_EXACT_ALARM',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      description: 'Schedule exact alarms.',
      riskNote: 'A clue for scheduled tasks; on its own it is not judged a '
          'risk.',
    ),

    // ---- 其它敏感数据来源 ----
    PermissionRule(
      name: 'QUERY_ALL_PACKAGES',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      minApi: 30,
      description: 'Enumerate the list of installed apps.',
      riskNote: 'The app list is one of the sensitive data sources listed in '
          'spec 3.4; most apps do not need it, so its presence prompts a '
          'manual check of the purpose.',
    ),
    PermissionRule(
      name: 'READ_PHONE_STATE',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: 'Read the phone state (including device identifiers).',
      riskNote: 'A device-identifier data source; watch for it co-occurring '
          'with upload logic.',
    ),
    PermissionRule(
      name: 'ACCESS_FINE_LOCATION',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: 'Precise location.',
      riskNote: 'Location is sensitive data; judge it together with the app '
          'features and the upload behaviour.',
    ),
    PermissionRule(
      name: 'ACCESS_COARSE_LOCATION',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: 'Approximate location.',
      riskNote: 'As above.',
    ),
    PermissionRule(
      name: 'READ_CONTACTS',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: 'Read contacts.',
      riskNote: 'A sensitive information source listed in spec 3.4; watch for '
          'it co-occurring with upload logic.',
    ),
    PermissionRule(
      name: 'READ_CLIPBOARD',
      category: SecurityCategory.deviceData,
      // signature 级（AOSP `frameworks/base/core/res/AndroidManifest.xml`）：
      // 三方应用声明了也**拿不到**。按 P3 报是假阳性 —— 它不可能生效。
      // 仍然报，但改成「声明了但系统不会授予」，因为出现它本身说明代码
      // 来自系统应用、抄来的样本，或者混淆产物。
      protection: PermissionProtection.signature,
      baseSeverity: SecuritySeverity.info,
      description: 'Read the clipboard (signature-level permission).',
      riskNote: 'Signature-level: a third-party app cannot be granted this, '
          'so the declaration has no effect. Seeing it usually means the code '
          'came from a system app, a copy-pasted sample, or an obfuscated '
          'build.',
    ),
    // ---- 2026-10-19 审计补的 4 类（此前落进 UNCATEGORIZED 汇总桶）----
    //
    // 选择标准是「单独声明就值得看一眼、且在国内样本里常被滥用」。
    // 悬浮窗与「安装其他应用」此前与「读取传感器」同级 —— 都只是汇总桶里的
    // 一个名字，没有等级、没有用途说明、没有版本条件。
    PermissionRule(
      name: 'SYSTEM_ALERT_WINDOW',
      category: SecurityCategory.other,
      protection: PermissionProtection.special,
      baseSeverity: SecuritySeverity.p3,
      description: 'Draw over other apps (overlay windows).',
      riskNote: 'An overlay can cover the screen and capture taps — the '
          'classic "invisible overlay" abuse. Judge it together with where '
          'the overlay is shown; a floating ball or a call UI is normal.',
    ),
    PermissionRule(
      name: 'REQUEST_INSTALL_PACKAGES',
      category: SecurityCategory.other,
      protection: PermissionProtection.special,
      baseSeverity: SecuritySeverity.p2,
      description: 'Request installation of other app packages.',
      riskNote: 'Lets the app hand an APK to the system installer. This is the '
          'usual step for droppers and "update without a store" flows; an app '
          'distributed through a store rarely needs it.',
    ),
    PermissionRule(
      name: 'ACCESS_BACKGROUND_LOCATION',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      minApi: 29,
      description: 'Access location while the app is in the background '
          '(Android 10+).',
      riskNote: 'Background location is a continuous tracking capability; on '
          'Android 11+ it is granted from a separate settings page. Judge it '
          'with whether a foreground use case justifies it.',
    ),
    PermissionRule(
      name: 'RECORD_AUDIO',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: 'Record audio from the microphone.',
      riskNote: 'A sensitive source: judge it together with where the '
          'recording goes (upload) and whether a visible recording feature '
          'exists. Recording + upload is covered by rule G.',
    ),
  ];

  /// 按权限名（完整名或短名）查规则；未编目返回 `null`。
  static PermissionRule? lookup(String permission) {
    for (final rule in rules) {
      if (rule.name == permission) return rule;
      if ('android.permission.${rule.name}' == permission) return rule;
    }
    return null;
  }
}

/// 一条权限规则。
///
/// [baseSeverity] 是**单独出现时**的等级；组合规则（A/B/C/D/E）会在其上调整，
/// 这正是规格「等级不由权限数量决定、要考虑证据强度与关联」的落地方式。
/// 权限的保护级别。
///
/// 只影响**能否被授予**这一件事，不影响风险定级 —— 那是 `baseSeverity` 的事。
/// 之所以需要它：`signature` 级的权限三方应用声明了也拿不到，按普通权限
/// 报一条 P3 是**假阳性**（2026-10-19 审计）。
enum PermissionProtection {
  /// 安装即授予。
  normal,

  /// 运行时弹窗授予。
  dangerous,

  /// 需要到设置页单独授权（悬浮窗、装应用、全文件访问）。
  special,

  /// 只有同签名或系统应用能拿到 —— 三方应用声明了也无效。
  signature,
}

class PermissionRule {
  /// 权限短名。它同时是这张表的**稳定 id**：本地化文案按它取
  /// （见 `AnalysisReport` 的 `_permissionRuleText`）。
  final String name;

  final SecurityCategory category;

  final SecuritySeverity baseSeverity;

  /// 保护级别。默认 [PermissionProtection.dangerous] 过于武断，因此显式
  /// 写在需要的条目上；未标注的按 [PermissionProtection.normal] 处理。
  final PermissionProtection protection;

  /// 该权限自哪个 API 级别引入；早于它的声明不生效。
  final int? minApi;

  /// 当设备/目标高于该 API 后，该权限的实际效果大幅削弱。
  ///
  /// 与 [minApi] 的区别：这是「曾经广泛、现在收权」的权限
  /// （例如 WRITE_EXTERNAL_STORAGE 在 API 29 后失效）。判定用 targetSdk
  /// 作代理，读不到 targetSdk 时该提示降级为「无法确认」。
  final int? maxApiEffectiveAbove;

  /// 面向用户的权限说明（**英文回退**，本地化文案按 [name] 取）。
  final String description;

  /// 风险说明：什么时候要关注、什么时候不必。
  ///
  /// 必须写成可读的判断依据而不是一句「高风险」—— 界面要把它直接展示给用户。
  ///
  /// 同样是**英文回退**。
  final String riskNote;

  const PermissionRule({
    required this.name,
    required this.category,
    required this.baseSeverity,
    this.protection = PermissionProtection.normal,
    this.minApi,
    this.maxApiEffectiveAbove,
    required this.description,
    required this.riskNote,
  });
}
