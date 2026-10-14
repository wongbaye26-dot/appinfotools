/// manifest 中声明的一条权限请求。
///
/// [maxSdkVersion] 是 Android 平台的「版本适用条件」：超过该 API 级别后
/// 这项请求不再生效。它不是可省略的细节 —— 权限审计必须结合 targetSdk
/// 判断「这项请求现在到底生不生效」，否则会把旧版遗留声明当成当前风险。
class AndroidPermissionRequest {
  /// 完整权限名，例如 `android.permission.READ_MEDIA_IMAGES`。
  final String name;

  /// `android:maxSdkVersion`；未声明为 `null`。
  ///
  /// 与 [sdk23Only] 的区别：前者约束的是**设备 API 级别**的上限
  /// （系统在 `maxSdkVersion` 之上直接忽略该请求），判断时以设备实际
  /// 系统版本为准，targetSdk 只是近似代理。
  final int? maxSdkVersion;

  /// 是否来自 `<uses-permission-sdk-23>`：该声明只在**设备 API < 23** 时授予。
  ///
  /// 不能拿 targetSdk 代替设备版本判断 —— 两者可能不同（targetSdk 34 的
  /// 应用也可能装在 Android 10 上）。这种情况下静态分析无法确定该请求
  /// 当前是否生效，审计必须输出「无法确认」而不是替用户下结论。
  final bool sdk23Only;

  const AndroidPermissionRequest(
    this.name, {
    this.maxSdkVersion,
    this.sdk23Only = false,
  });

  /// 短名（去掉 `android.permission.` 前缀），便于展示与规则匹配。
  String get shortName =>
      name.startsWith('android.permission.') ? name.substring(19) : name;

  @override
  String toString() {
    final suffix = sdk23Only
        ? ' (sdk-23: device API < 23 only)'
        : (maxSdkVersion == null ? '' : ' (maxSdkVersion=$maxSdkVersion)');
    return '$name$suffix';
  }
}

/// APK 解析结果数据模型
class ApkMeta {
  String? packageName;
  int? versionCode;
  String? versionName;
  int? minSdkVersion;
  int? targetSdkVersion;

  /// `<uses-sdk android:maxSdkVersion>`。绝大多数应用不声明，此时为 `null`
  /// —— 不要把它当成「无上限」以外的任何含义。
  int? maxSdkVersion;
  int? compileSdkVersion;
  String? compileSdkVersionCodename;
  String? platformBuildVersionName;
  int? platformBuildVersionCode;

  String? label;
  Map<String, String> labels = {};

  String? applicationName;
  String? applicationIcon;
  Map<int, String> iconPaths = {};

  /// `<application android:debuggable>`。未声明时为 `null`。
  bool? applicationDebuggable;

  List<String> permissions = [];
  List<String> features = [];
  List<String> featuresNotRequired = [];
  List<String> screenSizes = [];
  List<String> nativeCodes = [];
  List<String> locales = [];
  List<int> densities = [];

  /// `<uses-permission>` 的结构化形式：权限名 + `android:maxSdkVersion`。
  ///
  /// **不能只用 [permissions]**：`maxSdkVersion` 是版本适用条件，而
  /// `READ_EXTERNAL_STORAGE` 在真实样本里就带 `maxSdkVersion=32`
  /// （targetSdk 34 的应用在 Android 13 上根本拿不到它）。丢掉这个条件，
  /// 就会把「只在旧系统生效的广泛存储访问」与「当前照常生效」混为一谈。
  ///
  /// [permissions] 保留原样（只有名字），应用层与既有测试不受影响。
  List<AndroidPermissionRequest> permissionRequests = [];

  /// `<application android:usesCleartextTraffic>`。
  ///
  /// 三态而非 bool：未声明时系统有默认值（targetSdk ≥ 28 默认 false），
  /// 但那与「应用显式声明了 false」是两回事，规则引擎需要区分。
  bool? applicationUsesCleartextTraffic;

  /// `<application android:networkSecurityConfig>` 引用的资源路径；
  /// 未声明为 `null`。存在该属性意味着 ATS 行为被自定义配置覆盖，
  /// 静态层面只能记录，不能展开资源表里那份 XML 的每条配置。
  String? networkSecurityConfig;

  List<ActivityInfo> launchableActivities = [];

  /// manifest 中声明的全部组件（activity / activity-alias / service /
  /// receiver / provider），含 `exported` 与 `permission` 声明。
  List<AndroidComponent> components = [];

  /// 解析时观察到的**非标准 AXML 布局**特征，每项是一句可读的说明。
  ///
  /// 这不是解析错误，而是「这份 manifest 被刻意做得不像标准 AXML」——
  /// 例如属性区之前塞了诱饵字节、chunk 类型不在标准范围内。如实记下来，
  /// 因为它直接影响「这个包为什么看起来不正常」的判断。
  List<String> manifestLayoutAnomalies = [];

  @override
  String toString() {
    return 'ApkMeta{packageName: $packageName, versionCode: $versionCode, '
        'versionName: $versionName, label: $label, '
        'minSdk: $minSdkVersion, targetSdk: $targetSdkVersion, '
        'maxSdk: $maxSdkVersion, '
        'permissions: ${permissions.length}, features: ${features.length}, '
        'components: ${components.length}, '
        'nativeCodes: $nativeCodes, locales: ${locales.length}}';
  }
}

/// Android 组件类型。
enum ComponentType {
  activity,
  activityAlias,
  service,
  receiver,
  provider;

  /// AndroidManifest 中的元素名。
  String get elementName => switch (this) {
        ComponentType.activity => 'activity',
        ComponentType.activityAlias => 'activity-alias',
        ComponentType.service => 'service',
        ComponentType.receiver => 'receiver',
        ComponentType.provider => 'provider',
      };

  /// 从元素名解析类型；非组件元素返回 `null`。
  static ComponentType? fromElementName(String name) => switch (name) {
        'activity' => ComponentType.activity,
        'activity-alias' => ComponentType.activityAlias,
        'service' => ComponentType.service,
        'receiver' => ComponentType.receiver,
        'provider' => ComponentType.provider,
        _ => null,
      };
}

/// 一个 `<intent-filter>` 的解析结果。
///
/// 安全审计关心的是「这个组件能被谁唤起」—— 只有 action 与 data 能回答，
/// 光有一个布尔「有没有 filter」回答不了。例如
/// `android.intent.action.VIEW` + `scheme=https` 意味着可被浏览器打开，
/// 而 `android.intent.category.LAUNCHER` 只说明它是启动入口。
///
/// **只取 scheme，不取 host / path**：scheme 是判断「能否被外部唤起」的
/// 关键，而 host / path 对安全判断的边际价值低、且会显著膨胀模型。
class IntentFilterInfo {
  /// `<action android:name>` 列表。
  final List<String> actions;

  /// `<category android:name>` 列表。
  final List<String> categories;

  /// `<data android:scheme>` 列表。
  final List<String> schemes;

  const IntentFilterInfo({
    this.actions = const [],
    this.categories = const [],
    this.schemes = const [],
  });

  bool get isEmpty => actions.isEmpty && categories.isEmpty && schemes.isEmpty;

  @override
  String toString() =>
      'IntentFilterInfo(actions: $actions, categories: $categories, '
      'schemes: $schemes)';
}

/// manifest 中声明的一个组件。
///
/// [exported] 是**三态**，刻意不用 `bool`：
/// - `true` / `false` 对应 manifest 里的显式声明；
/// - `null` 表示**未声明**。
///
/// 把「未声明」当成「未导出」是常见误判 —— Android 12 之前大量应用省略该
/// 属性，其真实语义由是否有 intent-filter 决定（见 [effectivelyExported]）。
class AndroidComponent {
  final ComponentType type;

  /// 组件类名。混淆的 manifest 可能取不到，此时为 `null`（不做猜测）。
  final String? name;

  /// manifest 中显式声明的 `android:exported`；未声明为 `null`。
  final bool? exported;

  /// `android:permission` —— 访问该组件所需的权限。
  final String? permission;

  final bool hasIntentFilter;

  /// `<intent-filter>` 明细。为空表示没有 filter 或 filter 里没有任何
  /// action / category / scheme。
  final List<IntentFilterInfo> intentFilters;

  /// manifest 中显式声明的 `android:enabled`；未声明为 `null`。
  ///
  /// 未声明时平台默认为 `true`。**单独保留 `null`** 而不是折成 `true`：
  /// 「显式写了 true」与「没写、平台默认 true」在排查配置问题时是两件事。
  final bool? enabled;

  /// 仅 provider 有：`android:authorities`。
  final String? authorities;

  const AndroidComponent({
    required this.type,
    this.name,
    this.exported,
    this.permission,
    this.hasIntentFilter = false,
    this.intentFilters = const [],
    this.enabled,
    this.authorities,
  });

  /// 按平台默认规则推导的「是否对外可见」。
  ///
  /// Android 的规则：`android:exported` 未声明时，若组件声明了至少一个
  /// intent-filter 则默认为 `true`，否则为 `false`。
  ///
  /// 注意这是**平台默认规则**，不是我们编造的值 —— [exported] 始终保留原始
  /// 声明，UI 应优先展示原始值。
  bool get effectivelyExported => exported ?? hasIntentFilter;

  /// 按平台默认规则推导的「是否启用」。
  ///
  /// 与 [effectivelyExported] 同样的道理：[enabled] 保留原始声明，
  /// 这里只给推导值。
  bool get effectivelyEnabled => enabled ?? true;

  /// 该组件声明了哪些可被外部唤起的 scheme。
  ///
  /// 用于安全审计判断「能否被浏览器 / 其他应用直接打开」。
  List<String> get declaredSchemes => [
        for (final f in intentFilters) ...f.schemes,
      ];

  @override
  String toString() => 'AndroidComponent{${type.elementName}, name: $name, '
      'exported: $exported, permission: $permission, '
      'hasIntentFilter: $hasIntentFilter, enabled: $enabled}';
}

/// 资源表条目信息（用于将 ArscParser 数据导出给图标渲染器等外部使用）
class ResourceInfo {
  final int resourceId;
  final String typeName;
  final String keyName;
  final List<String> filePaths;
  final List<String> colors;
  final List<int> references;

  ResourceInfo({
    required this.resourceId,
    required this.typeName,
    required this.keyName,
    List<String>? filePaths,
    List<String>? colors,
    List<int>? references,
  })  : filePaths = filePaths ?? [],
        colors = colors ?? [],
        references = references ?? [];

  String get name => '$typeName/$keyName';

  String get idHex => '0x${resourceId.toRadixString(16).padLeft(8, '0')}';
}

class ActivityInfo {
  String? name;
  String? label;
  String? icon;

  ActivityInfo({this.name, this.label, this.icon});

  @override
  String toString() => 'ActivityInfo{name: $name, label: $label, icon: $icon}';
}
