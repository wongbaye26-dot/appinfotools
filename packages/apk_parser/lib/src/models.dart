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

  /// 仅 provider 有：`android:authorities`。
  final String? authorities;

  const AndroidComponent({
    required this.type,
    this.name,
    this.exported,
    this.permission,
    this.hasIntentFilter = false,
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

  @override
  String toString() => 'AndroidComponent{${type.elementName}, name: $name, '
      'exported: $exported, permission: $permission, '
      'hasIntentFilter: $hasIntentFilter}';
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
