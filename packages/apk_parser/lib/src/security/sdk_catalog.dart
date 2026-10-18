// 第三方 **服务类** SDK 的盘点。
//
// ## 这为什么不是「又一张关键词表」
//
// 表里的每一条都是在**真实样本上量过**的（4 个包，86 个 DEX，约 431 MiB）：
//
// | 前缀 | 4 个包里的命中数 |
// |---|---|
// | `okhttp3` | **4** |
// | `com/google/gson` | **4** |
// | `com/google/android/material` | **4** |
// | `com/airbnb/lottie` | **4** |
// | `com/geetest` | 1 |
// | `com/hcaptcha` | 1 |
// | `com/sensorsdata` | 1 |
// | `com/tencent/bugly` | 1 |
//
// 前四个是**基础工具库**：HTTP 客户端、JSON、UI 组件、动画。它们在几乎每个
// 应用里都有，列出来等于「每个应用都用了第三方库」—— 一句废话。
//
// 所以这张表**只收有服务含义的 SDK**：统计、归因、推送、验证码、风控、
// 社交登录、支付、地图、崩溃上报、对象存储。它们共同的特征是
// **会把数据发到第三方服务器**，而「这个应用的数据会去哪」正是用户想知道的事。
//
// ## 为什么不收「厂商加固」
//
// 规范 4.2 禁止据单一特征判定厂商。SDK 盘点不是厂商判定 —— 它是「这里有
// 一个已知的公开库」，判据是该库自己的包名。这与「这是某家加固壳」是两回事。
//
// ## 次数的含义
//
// [SdkHit.occurrences] 是**引用数**（DEX 里 `L<prefix>/` 出现的次数），
// 不是调用次数。它只有一个用途：区分「真的打包进来了」与「只在字符串里
// 提了一句」—— 后者通常是几个到几十，前者是几百到几千。
// 界面上要说清这一点，不能让它看起来像「被调用了 N 次」。

/// 一个 SDK 所属的**服务类别**。
///
/// 分类的目的不是学术，是让报告能按「数据会流向哪类服务」分组：
/// 统计与归因拿的是行为数据，推送拿的是设备标识，验证码拿的是交互数据。
enum SdkCategory {
  analytics('analytics', 'analytics / attribution'),
  push('push', 'push notifications'),
  captcha('captcha', 'CAPTCHA / bot defence'),
  social('social', 'social login / payment'),
  maps('maps', 'maps / location'),
  crash('crash', 'crash reporting'),
  storage('storage', 'object storage / CDN'),
  ads('ads', 'advertising'),

  /// 平台基础服务（Google Play services、Firebase）：不是单一产品，
  /// 而是一组 API（地图、认证、推送、Analytics）。归到 analytics 会误导。
  platform('platform', 'platform services'),
  rtc('rtc', 'real-time audio / video');

  const SdkCategory(this.id, this.label);

  /// 稳定 id，用于本地化查找与序列化。
  final String id;

  /// 英文说明（本地化文案按 [id] 取）。
  final String label;
}

/// 一条 SDK 目录项。
class SdkDescriptor {
  /// 稳定 id，例如 `adjust`。本地化文案按它查 `security.sdk_names.<id>`。
  final String id;

  /// 英文名（本地化缺失时的回退）。
  final String displayName;

  final SdkCategory category;

  /// 包名前缀（`/` 分隔，与 DEX 类型描述符一致）。
  ///
  /// 匹配时要求**边界**：`L<prefix>/` 或 `L<prefix>;` ——
  /// 否则 `com/tencent/mm` 会把 `com/tencent/mmkv` 也算进去。
  final String packagePrefix;

  const SdkDescriptor({
    required this.id,
    required this.displayName,
    required this.category,
    required this.packagePrefix,
  });
}

/// 一次命中的结果。
class SdkHit {
  final SdkDescriptor descriptor;

  /// DEX 里 `L<prefix>/` 的出现次数（**引用数，不是调用次数**）。
  final int occurrences;

  /// 命中的 DEX 文件名（最多留几个，供证据展示）。
  final List<String> dexNames;

  const SdkHit({
    required this.descriptor,
    required this.occurrences,
    this.dexNames = const [],
  });

  String get id => descriptor.id;
  String get displayName => descriptor.displayName;
  SdkCategory get category => descriptor.category;

  @override
  String toString() => 'SdkHit(${descriptor.id}, $occurrences, '
      '${dexNames.length} dex)';
}

/// SDK 目录。
///
/// **只收服务类 SDK**。判据见文件头：基础工具库（OkHttp / Gson / Lottie /
/// Material / RxJava / protobuf / Chromium 支持库）一律不收 —— 它们不是
/// 「数据流向了谁」，而是「代码怎么写」。
const List<SdkDescriptor> sdkCatalog = [
  // ---- 统计 / 归因 ----
  SdkDescriptor(
    id: 'adjust',
    displayName: 'Adjust',
    category: SdkCategory.analytics,
    packagePrefix: 'com/adjust/sdk',
  ),
  SdkDescriptor(
    id: 'appsflyer',
    displayName: 'AppsFlyer',
    category: SdkCategory.analytics,
    packagePrefix: 'com/appsflyer',
  ),
  SdkDescriptor(
    id: 'sensorsdata',
    displayName: 'Sensors Data (神策)',
    category: SdkCategory.analytics,
    packagePrefix: 'com/sensorsdata',
  ),
  SdkDescriptor(
    id: 'umeng',
    displayName: 'Umeng (友盟)',
    category: SdkCategory.analytics,
    packagePrefix: 'com/umeng',
  ),
  // Firebase 同理：Crashlytics / Messaging / Analytics / Remote Config 都在
  // 同一个前缀下，归到 analytics 会盖住真正的分析 SDK。
  SdkDescriptor(
    id: 'firebase',
    displayName: 'Firebase',
    category: SdkCategory.platform,
    packagePrefix: 'com/google/firebase',
  ),
  // `com/google/android/gms` 是**一组** API（地图 / 认证 / 推送 / Analytics），
  // 不是「一个分析 SDK」。实测 49af6cnn 里 4,276 个类 —— 归到 analytics 会
  // 让「分析 SDK」这一栏永远排第一，而读者真正想看的是 Adjust 那 211 个。
  SdkDescriptor(
    id: 'gms',
    displayName: 'Google Play services',
    category: SdkCategory.platform,
    packagePrefix: 'com/google/android/gms',
  ),
  // ---- 推送 ----
  SdkDescriptor(
    id: 'jpush',
    displayName: 'JPush (极光推送)',
    category: SdkCategory.push,
    packagePrefix: 'cn/jpush',
  ),
  SdkDescriptor(
    id: 'getui',
    displayName: 'GeTui (个推)',
    category: SdkCategory.push,
    packagePrefix: 'com/igexin',
  ),
  SdkDescriptor(
    id: 'xiaomi-push',
    displayName: 'Xiaomi Push',
    category: SdkCategory.push,
    packagePrefix: 'com/xiaomi/push',
  ),
  SdkDescriptor(
    id: 'huawei-hms',
    displayName: 'Huawei HMS',
    category: SdkCategory.push,
    packagePrefix: 'com/huawei/hms',
  ),
  SdkDescriptor(
    id: 'oppo-push',
    displayName: 'OPPO Push (HeyTap)',
    category: SdkCategory.push,
    packagePrefix: 'com/heytap/msp',
  ),
  // ---- 验证码 / 风控 ----
  SdkDescriptor(
    id: 'geetest',
    displayName: 'Geetest (极验)',
    category: SdkCategory.captcha,
    packagePrefix: 'com/geetest',
  ),
  SdkDescriptor(
    id: 'hcaptcha',
    displayName: 'hCaptcha',
    category: SdkCategory.captcha,
    packagePrefix: 'com/hcaptcha',
  ),
  SdkDescriptor(
    id: 'netease-nis',
    displayName: 'NetEase YiDun (网易易盾)',
    category: SdkCategory.captcha,
    packagePrefix: 'com/netease/nis',
  ),
  // ---- 社交登录 / 支付 ----
  SdkDescriptor(
    id: 'wechat-opensdk',
    displayName: 'WeChat OpenSDK',
    category: SdkCategory.social,
    packagePrefix: 'com/tencent/mm/opensdk',
  ),
  SdkDescriptor(
    id: 'qq-login',
    displayName: 'QQ / WeChat login (tauth)',
    category: SdkCategory.social,
    packagePrefix: 'com/tencent/tauth',
  ),
  SdkDescriptor(
    id: 'alipay',
    displayName: 'Alipay SDK',
    category: SdkCategory.social,
    packagePrefix: 'com/alipay/sdk',
  ),
  SdkDescriptor(
    id: 'facebook',
    displayName: 'Facebook SDK',
    category: SdkCategory.social,
    packagePrefix: 'com/facebook',
  ),
  // ---- 地图 ----
  SdkDescriptor(
    id: 'amap',
    displayName: 'AMap (高德地图)',
    category: SdkCategory.maps,
    packagePrefix: 'com/amap/api',
  ),
  SdkDescriptor(
    id: 'baidu-map',
    displayName: 'Baidu Map',
    category: SdkCategory.maps,
    packagePrefix: 'com/baidu/mapapi',
  ),
  // ---- 崩溃上报 ----
  SdkDescriptor(
    id: 'bugly',
    displayName: 'Bugly (腾讯)',
    category: SdkCategory.crash,
    packagePrefix: 'com/tencent/bugly',
  ),
  // ---- 对象存储 ----
  SdkDescriptor(
    id: 'qiniu',
    displayName: 'Qiniu (七牛)',
    category: SdkCategory.storage,
    packagePrefix: 'com/qiniu',
  ),
  SdkDescriptor(
    id: 'tencent-cos',
    displayName: 'Tencent Cloud COS',
    category: SdkCategory.storage,
    packagePrefix: 'com/tencent/cos',
  ),
  // ---- 实时音视频 ----
  SdkDescriptor(
    id: 'agora',
    displayName: 'Agora',
    category: SdkCategory.rtc,
    packagePrefix: 'io/agora',
  ),
  SdkDescriptor(
    id: 'tencent-trtc',
    displayName: 'Tencent TRTC',
    category: SdkCategory.rtc,
    packagePrefix: 'com/tencent/liteav',
  ),
];

/// 按类别分组（报告里按「数据流向哪类服务」呈现）。
Map<SdkCategory, List<SdkHit>> groupByCategory(List<SdkHit> hits) {
  final grouped = <SdkCategory, List<SdkHit>>{};
  for (final hit in hits) {
    (grouped[hit.category] ??= <SdkHit>[]).add(hit);
  }
  for (final list in grouped.values) {
    list.sort((a, b) => b.occurrences.compareTo(a.occurrences));
  }
  return grouped;
}
