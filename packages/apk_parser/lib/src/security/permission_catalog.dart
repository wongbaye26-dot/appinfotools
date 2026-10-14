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
///   是 INFO —— 规格第五章明确等级不由权限数量决定；只有广泛存储访问
///   （MANAGE_EXTERNAL_STORAGE、旧版全盘存储）单独出现时才给 P2，且措辞是
///   「需人工复核」而不是「恶意」。
/// 2. **版本条件是一等公民**。`READ_MEDIA_IMAGES` 只在 targetSdk ≥ 33 时生效；
///   `READ_EXTERNAL_STORAGE` 在 targetSdk ≥ 33 后基本失效；`READ_MEDIA_VISUAL_USER_SELECTED`
///   是 Android 14 的部分照片授权机制，**绝不能与完整图库访问混为一类**。
/// 3. **未知权限不逐条刷屏**。未编目的权限汇总成一条 INFO，否则一个 40 项权限的
///   加固样本会产出 40 条噪音，真正的问题被埋掉。
class PermissionCatalog {
  PermissionCatalog._();

  /// 规则库版本。改这张表必须升版本，否则两份报告无法对照。
  static const String rulesVersion = 'android-permissions-2026.10.1';

  /// 目录里的全部规则。
  static const List<PermissionRule> rules = [
    // ---- 照片与视频（现代分区存储模型）----
    PermissionRule(
      name: 'READ_MEDIA_IMAGES',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      minApi: 33,
      description: '读取照片（Android 13 起的细粒度媒体权限）。',
      riskNote: '图片类应用的常规权限，单独出现不构成风险；但如果应用没有可见的'
          '图片相关功能，则属于「广泛相册访问但缺少业务用途」（规则 A）。',
    ),
    PermissionRule(
      name: 'READ_MEDIA_VIDEO',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      minApi: 33,
      description: '读取视频（Android 13 起的细粒度媒体权限）。',
      riskNote: '同上：视频类应用的常规权限，需结合功能判断用途合理性。',
    ),
    PermissionRule(
      name: 'READ_MEDIA_AUDIO',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      minApi: 33,
      description: '读取音频文件（Android 13 起）。',
      riskNote: '音频类应用的常规权限；与图片/OCR 组合时关注输入来源。',
    ),
    PermissionRule(
      name: 'READ_MEDIA_VISUAL_USER_SELECTED',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      minApi: 34,
      description: '用户主动选中的照片/视频（Android 14 起的部分照片访问机制）。',
      riskNote: '这是**用户授予部分媒体**的机制，与完整图库访问是两件事：'
          '有它说明应用只碰用户勾选的照片，没有它才意味着可能申请完整访问。'
          '不得把它与 READ_MEDIA_IMAGES 一概而论。',
    ),

    // ---- 旧版存储访问 ----
    PermissionRule(
      name: 'READ_EXTERNAL_STORAGE',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.p2,
      description: '读取共享存储（Android 12 及更早的全盘文件访问模型）。',
      riskNote: '在 targetSdk ≤ 32 的应用上，它近似「全盘文件访问」；'
          'targetSdk ≥ 33 后基本被分区存储取代（残留声明的实际影响很小）。'
          '真实加固样本里它带 maxSdkVersion=32，必须结合版本条件判断。',
    ),
    PermissionRule(
      name: 'WRITE_EXTERNAL_STORAGE',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.p2,
      maxApiEffectiveAbove: 28,
      description: '写入共享存储。',
      riskNote: 'targetSdk ≥ 29 后写入共享存储已基本失效；单独出现不判风险，'
          '仅在广泛访问组合里作为佐证。',
    ),
    PermissionRule(
      name: 'MANAGE_EXTERNAL_STORAGE',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.p2,
      minApi: 30,
      description: '管理外部存储（全盘文件访问，Google Play 严格限制的权限）。',
      riskNote: '规格 3.1 列为「高关注权限」：只有文件管理器类应用才通常需要。'
          '出现时记录为需人工复核的中风险候选项，不直接判定恶意。',
    ),

    // ---- 相机 ----
    PermissionRule(
      name: 'CAMERA',
      category: SecurityCategory.photoAccess,
      baseSeverity: SecuritySeverity.info,
      description: '使用相机。',
      riskNote: '规格 3.1：需结合拍摄、图像识别及上传行为判断。与 OCR 线索同现时'
          '按规则 B/C 处理，单独出现不升级。',
    ),

    // ---- 网络 ----
    PermissionRule(
      name: 'INTERNET',
      category: SecurityCategory.network,
      baseSeverity: SecuritySeverity.info,
      description: '访问网络。',
      riskNote: '规格 3.1：网络权限本身不判定为恶意。',
    ),
    PermissionRule(
      name: 'ACCESS_NETWORK_STATE',
      category: SecurityCategory.network,
      baseSeverity: SecuritySeverity.info,
      description: '查看网络连接状态。',
      riskNote: '常规权限，连同下列网络类权限一律只作事实记录。',
    ),
    PermissionRule(
      name: 'ACCESS_WIFI_STATE',
      category: SecurityCategory.network,
      baseSeverity: SecuritySeverity.info,
      description: '查看 Wi-Fi 状态。',
      riskNote: '常规权限。',
    ),
    PermissionRule(
      name: 'CHANGE_WIFI_STATE',
      category: SecurityCategory.network,
      baseSeverity: SecuritySeverity.info,
      description: '改变 Wi-Fi 连接状态。',
      riskNote: '常规权限。',
    ),

    // ---- 后台任务 ----
    PermissionRule(
      name: 'FOREGROUND_SERVICE',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      minApi: 28,
      description: '前台服务。',
      riskNote: '单独出现是常规能力；规格规则 E 要求与敏感数据收集、回传关联同时'
          '存在时才升级。',
    ),
    PermissionRule(
      name: 'FOREGROUND_SERVICE_DATA_SYNC',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      minApi: 34,
      description: '数据同步类前台服务。',
      riskNote: '同上；与同步、上传同现时关注其用途说明。',
    ),
    PermissionRule(
      name: 'RECEIVE_BOOT_COMPLETED',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      description: '开机自启动。',
      riskNote: '后台入口线索，规则 E 的输入之一；单独出现不判风险。',
    ),
    PermissionRule(
      name: 'WAKE_LOCK',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      description: '保持设备唤醒。',
      riskNote: '后台持续运行线索，单独出现不判风险。',
    ),
    PermissionRule(
      name: 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      description: '请求忽略电池优化。',
      riskNote: '后台常驻线索，单独出现不判风险。',
    ),
    PermissionRule(
      name: 'SCHEDULE_EXACT_ALARM',
      category: SecurityCategory.backgroundTask,
      baseSeverity: SecuritySeverity.info,
      description: '设置精确闹钟。',
      riskNote: '定时任务线索，单独出现不判风险。',
    ),

    // ---- 其它敏感数据来源 ----
    PermissionRule(
      name: 'QUERY_ALL_PACKAGES',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      minApi: 30,
      description: '枚举已安装应用列表。',
      riskNote: '应用列表属于规格 3.4 列出的敏感数据来源；多数应用并不需要，'
          '出现时提示人工确认用途。',
    ),
    PermissionRule(
      name: 'READ_PHONE_STATE',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: '读取电话状态（含设备标识等）。',
      riskNote: '设备标识类数据来源，关注是否与上传逻辑同现。',
    ),
    PermissionRule(
      name: 'ACCESS_FINE_LOCATION',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: '精确位置。',
      riskNote: '位置属于敏感数据；需结合功能与上传行为判断。',
    ),
    PermissionRule(
      name: 'ACCESS_COARSE_LOCATION',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: '粗略位置。',
      riskNote: '同上。',
    ),
    PermissionRule(
      name: 'READ_CONTACTS',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: '读取联系人。',
      riskNote: '规格 3.4 列出的敏感信息来源，关注是否与上传逻辑同现。',
    ),
    PermissionRule(
      name: 'READ_CLIPBOARD',
      category: SecurityCategory.deviceData,
      baseSeverity: SecuritySeverity.p3,
      description: '读取剪贴板。',
      riskNote: '剪贴板可能含敏感文本，规格 3.4 列为关注来源。',
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
class PermissionRule {
  final String name;

  final SecurityCategory category;

  final SecuritySeverity baseSeverity;

  /// 该权限自哪个 API 级别引入；早于它的声明不生效。
  final int? minApi;

  /// 当设备/目标高于该 API 后，该权限的实际效果大幅削弱。
  ///
  /// 与 [minApi] 的区别：这是「曾经广泛、现在收权」的权限
  /// （例如 WRITE_EXTERNAL_STORAGE 在 API 29 后失效）。判定用 targetSdk
  /// 作代理，读不到 targetSdk 时该提示降级为「无法确认」。
  final int? maxApiEffectiveAbove;

  final String description;

  /// 风险说明：什么时候要关注、什么时候不必。
  ///
  /// 必须写成可读的判断依据而不是一句「高风险」—— 界面要把它直接展示给用户。
  final String riskNote;

  const PermissionRule({
    required this.name,
    required this.category,
    required this.baseSeverity,
    this.minApi,
    this.maxApiEffectiveAbove,
    required this.description,
    required this.riskNote,
  });
}
