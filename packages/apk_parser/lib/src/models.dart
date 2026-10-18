import 'package:analysis_model/analysis_model.dart';

import 'security/network_security_config.dart';

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

  /// `android:allowBackup`；未声明为 `null`（平台默认为 **true**）。
  ///
  /// 只报**显式写了 true** 的情况：默认值 true 是平台行为，把它当成应用的
  /// 选择会冤枉所有没写这个属性的包。
  bool? applicationAllowBackup;

  List<String> permissions = [];
  List<String> features = [];
  List<String> featuresNotRequired = [];
  List<String> screenSizes = [];
  List<String> nativeCodes = [];
  List<String> locales = [];
  List<int> densities = [];

  /// 从 `resources.arsc` 字符串池里找到的 **ICP 备案号**（可能不止一条）。
  ///
  /// 空列表表示**没找到** —— 界面据此不显示这一行。`AndroidManifest.xml` 里
  /// 没有标准字段放它，因此只能扫字符串池，详见 `IcpFilingScanner`。
  List<String> icpFilings = [];

  /// 资源表里是否有夜间模式变体；`null` 表示**没读到资源表**（无法判断）。
  ///
  /// 三态而非 bool：资源表缺失或解析失败时，`false` 会被读成「这个应用没有
  /// 夜间资源」，而事实是「我们不知道」。与 [locales] / [densities] 的区别
  /// 在于那两者为空列表时语义已经够清楚（没有多语言 / 没有密度变体），
  /// 而「没有夜间资源」是一个会被用户当作结论的事实。
  bool? hasNightMode;

  /// 资源表里出现过的 `uiMode` 设备类型，已排序。
  ///
  /// 是稳定标识符（`car` / `television` / `watch` …），不是原始数字 ——
  /// 与加固线索的枚举名同理，要能与代码和日志对照。未指定不包含。
  List<String> uiModeTypes = [];

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

  /// `<manifest android:sharedUserId>` —— 与其它应用共享 UID。
  ///
  /// 未声明为 `null`。非空意味着**同一 UID 下的应用共享沙箱**
  /// （文件目录、偏好、数据库都互相可见），只要签名相同。
  String? sharedUserId;

  /// `<application android:fullBackupContent>`（API 23–30 的备份规则）。
  ///
  /// 三种形态，必须分开：
  /// - `null` —— 未声明；
  /// - `"false"` —— **彻底关闭**自动备份（即使 `allowBackup="true"`）；
  /// - `@res/0x...` —— 指向一份 XML 规则（我们不展开内容，只在说明里讲清）。
  String? applicationFullBackupContent;

  /// `<application android:dataExtractionRules>`（API 31+ 的备份规则，
  /// 语义同上）。声明了它之后 `fullBackupContent` 被平台忽略。
  String? applicationDataExtractionRules;

  /// 本包**自己声明**的权限（`<permission>`），含 `protectionLevel`。
  ///
  /// 为什么需要它：判断「导出组件有没有被保护」时，只看 `android:permission`
  /// 非空是不够的 —— 一个 `protectionLevel="normal"` 的自定义权限**任何应用
  /// 都能申请**，等于没保护。而框架权限（`android.permission.X`）或别的包声明
  /// 的权限，我们看不到级别，只能保守地当成受保护。
  List<AndroidDeclaredPermission> declaredPermissions = [];

  /// `<application android:networkSecurityConfig>` 的**原始属性值**。
  ///
  /// 引用类型时形如 `@res/0x7f17001c`（这是本解析器的引用表示法），
  /// 直接展示给用户没有意义 —— 界面应当用
  /// [networkSecurityConfigInfo]?.path（真实路径，如
  /// `res/xml/network_security_config.xml`）。
  String? networkSecurityConfig;

  /// [networkSecurityConfig] 解析出的资源 id；未声明或不是引用时为 `null`。
  ///
  /// 有它才能去 `resources.arsc` 里查这条资源对应的**文件路径**。
  int? networkSecurityConfigResId;

  /// `res/xml/network_security_config.xml` 的解析结果。
  ///
  /// **这个字段很关键**：API 24 起，只要声明了 NSC，
  /// `android:usesCleartextTraffic` 就被平台忽略，明文策略完全由它决定。
  /// 不展开它，规则 D 在真实包上要么误报、要么静默失效。
  ///
  /// 三种状态必须区分：
  /// - `null` —— 没有声明 NSC，明文策略看 [applicationUsesCleartextTraffic]；
  /// - `info.parsed == true` —— 拿到了真实结论；
  /// - `info.parsed == false` —— 声明了但读不出来，此时是「不知道」。
  NetworkSecurityConfigInfo? networkSecurityConfigInfo;

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

  /// [manifestLayoutAnomalies] 的**结构化版本**（同一批事实，带 code + 参数）。
  ///
  /// 两者顺序一一对应：`manifestLayoutAnomalies[i]` 就是
  /// `manifestLayoutNotes[i].fallback`。保留字符串版是因为
  /// `HardeningObservation.evidence` 与日志仍需要一句可直接读的英文。
  List<AnalysisNote> manifestLayoutNotes = [];

  /// `AndroidManifest.xml` **解析失败**的原因；成功时为 `null`。
  ///
  /// 与「清单里什么都没有」是两件相反的事：后者是事实（这份清单确实没声明
  /// 任何东西），前者意味着**我们没读到**，据此得出的任何结论都不可靠。
  /// 没有这个字段时，解析失败只能靠抛异常表达，而调用方看到的只有一个
  /// 空 `ApkMeta` —— 两者长得一模一样。
  String? manifestParseFailure;

  /// 清单是否解析失败。
  bool get manifestUnparsed => manifestParseFailure != null;

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
/// 本包声明的一条自定义权限（`<permission>`）。
class AndroidDeclaredPermission {
  /// 权限全名，例如 `com.example.permission.CALL`。
  final String name;

  /// `android:protectionLevel` 的**原始值**，例如 `signature|privileged`、
  /// `dangerous`；未声明为 `null`（平台默认 `normal`）。
  final String? protectionLevel;

  const AndroidDeclaredPermission({required this.name, this.protectionLevel});

  /// `protectionLevel` 的**数字值**（`normal`=0、`dangerous`=1、
  /// `signature`=2、`signatureOrSystem`=3，高位是附加标志）。
  ///
  /// **aapt2 写进 AXML 的是整数，不是字符串。** `aapt2 dump xmltree` 显示
  /// `protectionLevel(0x01010009)=0x00000002` —— 实测确认。所以按字符串
  /// 找 `"signature"` 永远找不到，规则会静默不生效（与属性表错位同一类坑）。
  int? get protectionLevelValue {
    final raw = protectionLevel?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('0x') || raw.startsWith('0X')) {
      return int.tryParse(raw.substring(2), radix: 16);
    }
    final numeric = int.tryParse(raw);
    if (numeric != null) return numeric;
    // 文本形态（少数工具/手写清单里出现）
    final lower = raw.toLowerCase();
    if (lower.contains('signatureorsystem')) return 3;
    if (lower.contains('signature')) return 2;
    if (lower.contains('dangerous')) return 1;
    if (lower.contains('normal')) return 0;
    return null;
  }

  /// 是否只有**同签名**的应用才能持有。
  ///
  /// 只有 `signature`(2) / `signatureOrSystem`(3) 才真正构成保护；
  /// `normal`(0) 与 `dangerous`(1) 任何应用都能申请（`dangerous` 只是需要
  /// 用户点同意），所以它们**保护不了**一个导出组件。
  ///
  /// 未声明时为 `false` —— 平台默认是 `normal`，同样不构成保护。
  bool get signatureProtected {
    final value = protectionLevelValue;
    if (value == null) return false;
    return (value & 0x3) >= 2;
  }

  /// 给人看的 `protectionLevel` 文本（`0x00000012` → `signature|privileged`）。
  ///
  /// 直接显示 `0x12` 对读者没有意义，而证据行里必须能看懂「这条权限是什么级别」。
  String get protectionLevelText {
    final value = protectionLevelValue;
    if (value == null) {
      return protectionLevel == null || protectionLevel!.trim().isEmpty
          ? 'normal (default)'
          : protectionLevel!;
    }
    const names = <int, String>{
      0x0: 'normal',
      0x1: 'dangerous',
      0x2: 'signature',
      0x3: 'signatureOrSystem',
      0x10: 'privileged',
      0x20: 'development',
      0x40: 'appop',
      0x80: 'pre23',
      0x100: 'installer',
      0x200: 'verifier',
      0x400: 'preinstalled',
      0x800: 'setup',
      0x1000: 'instant',
      0x2000: 'ephemeral',
      0x4000: 'runtime',
      0x8000: 'oem',
      0x10000: 'vendorPrivileged',
      0x20000: 'textClassifier',
      0x40000: 'wellKnownSigner',
    };
    final parts = <String>[];
    final base = value & 0x3;
    parts.add(names[base] ?? '0x${base.toRadixString(16)}');
    for (final entry in names.entries) {
      if (entry.key <= 0x3) continue;
      if (value & entry.key != 0) parts.add(entry.value);
    }
    return parts.join('|');
  }

  @override
  String toString() =>
      'AndroidDeclaredPermission($name, ${protectionLevel ?? 'normal'})';
}

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
