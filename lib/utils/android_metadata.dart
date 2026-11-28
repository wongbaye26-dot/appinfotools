import 'dart:convert';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:flutter/services.dart';

/// 权限的基本保护级别（`android:protectionLevel` 的低 4 位）。
///
/// 与参考实现 `Protection::base` 完全一致：1=dangerous、2=signature、
/// 3=signatureOrSystem、4=internal，其余（含 0）都按 normal 处理。
enum AndroidProtectionBase {
  normal,
  dangerous,
  signature,
  signatureOrSystem,
  internal,
}

/// 面向用户的风险分级。
///
/// 这是**应用自己的分级策略**，不是 Android 平台的分类：平台的 dangerous 只表示
/// 「运行时要用户授权」，相机、存储、通知都在里面，直接当「危险」显示会让大多数
/// 应用满屏红色。只有能直接读走通讯/隐私数据、或能产生费用/接管设备的才算高风险。
///
/// 声明顺序即显示优先级（风险高的排前面）。
enum AndroidPermissionRisk { high, sensitive, normal, system, unknown }

/// 一条框架权限的保护级别：原始位掩码 + 解析出的基本级别与附加标志。
class AndroidProtection {
  const AndroidProtection({
    required this.raw,
    required this.base,
    required this.flags,
  });

  /// `android:protectionLevel` 的原始值（AOSP 的位掩码）。
  final int raw;
  final AndroidProtectionBase base;

  /// 附加标志名（privileged、runtime、appop…），按位序。
  final List<String> flags;

  /// 位定义与 AOSP `R.attr#protectionLevel` 同名；已废弃的两项（wellbeing、
  /// documenter）仍然占着位，别因为「没人用」就把它们删掉 —— 删了会让高位整体错位。
  static const _flagBits = <int, String>{
    0x10: 'privileged',
    0x20: 'development',
    0x40: 'appop',
    0x80: 'pre23',
    0x100: 'installer',
    0x200: 'verifier',
    0x400: 'preinstalled',
    0x800: 'setup',
    0x1000: 'instant',
    0x2000: 'runtime',
    0x4000: 'oem',
    0x8000: 'vendorPrivileged',
    0x10000: 'textClassifier',
    0x20000: 'wellbeing',
    0x40000: 'documenter',
    0x80000: 'configurator',
    0x100000: 'incidentReportApprover',
    0x200000: 'appPredictor',
    0x400000: 'module',
    0x800000: 'companion',
    0x1000000: 'retailDemo',
    0x2000000: 'recents',
    0x4000000: 'role',
    0x8000000: 'knownSigner',
  };

  /// 从原始位掩码解析。
  factory AndroidProtection.parse(int raw) {
    final base = switch (raw & 0xf) {
      1 => AndroidProtectionBase.dangerous,
      2 => AndroidProtectionBase.signature,
      3 => AndroidProtectionBase.signatureOrSystem,
      4 => AndroidProtectionBase.internal,
      _ => AndroidProtectionBase.normal,
    };
    final flags = [
      for (final entry in _flagBits.entries)
        if (raw & entry.key != 0) entry.value,
    ];
    return AndroidProtection(raw: raw, base: base, flags: flags);
  }
}

/// 一个语言标签拆出来的各段名称（都可能是 null —— 数据里没有就不编）。
class AndroidLocaleNames {
  const AndroidLocaleNames({
    this.language,
    this.script,
    this.region,
    this.autonym,
  });

  final String? language;
  final String? script;
  final String? region;

  /// 自称（`ja` → 日本語），与界面语言无关。
  final String? autonym;
}

/// Android 平台元数据（Dart 侧访问层）。
///
/// 数据来自 AOSP 的 `android.jar`（权限保护级别）与平台 i18n 文案，由参考项目
/// ApkInfoPlus 的 `scripts/gen-android-data.py` 导出后转成 JSON 资产。这里只做
/// 「查表 + 解析」，不做任何猜测：表里没有的权限就是 `null` / `unknown`。
///
/// 为什么资产里是 JSON 而不是 Dart 常量：6 种语言的权限文案 + 语言名称合计约
/// 430KB，编进 Dart 会显著拖慢编译；JSON 只在启动时解析一次。
class AndroidMetadata {
  AndroidMetadata._();

  static final AndroidMetadata instance = AndroidMetadata._();

  /// 全语言共享的数据只加载一次。
  Map<String, int>? _protection;
  Map<String, String>? _autonyms;

  /// 每种界面语言一份文案。
  final Map<String, Map<String, dynamic>> _texts = {};

  bool get isLoaded => _protection != null;

  static const _localeIds = <AppLocale, String>{
    AppLocale.en: 'en',
    AppLocale.ja: 'ja',
    AppLocale.ko: 'ko',
    AppLocale.zhCn: 'zh-CN',
    AppLocale.zhHk: 'zh-HK',
    AppLocale.zhTw: 'zh-TW',
  };

  /// 启动时调用一次。单个文件失败只记日志、不抛异常 —— 元数据是**锦上添花**，
  /// 缺了它页面应该照常渲染（最多不显示官方说明），而不是打不开。
  Future<void> ensureLoaded() async {
    if (_protection != null) return;
    _protection = await _loadProtection();
    _autonyms = await _loadAutonyms();
    for (final id in _localeIds.values.toSet()) {
      await _loadText(id);
    }
  }

  Future<Map<String, int>> _loadProtection() async {
    try {
      final raw = jsonDecode(
        await rootBundle.loadString('assets/data/android/protection.json'),
      );
      final permissions = (raw as Map)['permissions'] as Map;
      return {
        for (final entry in permissions.entries)
          entry.key as String: (entry.value as num).toInt(),
      };
    } catch (e) {
      log.warning('AndroidMetadata: protection.json 加载失败: $e');
      return const {};
    }
  }

  Future<Map<String, String>> _loadAutonyms() async {
    try {
      final raw = jsonDecode(
        await rootBundle.loadString('assets/data/android/autonyms.json'),
      );
      return {
        for (final entry in (raw as Map).entries)
          entry.key as String: entry.value as String,
      };
    } catch (e) {
      log.warning('AndroidMetadata: autonyms.json 加载失败: $e');
      return const {};
    }
  }

  Future<Map<String, dynamic>> _loadText(String localeId) async {
    final cached = _texts[localeId];
    if (cached != null) return cached;
    try {
      final raw = jsonDecode(
        await rootBundle.loadString('assets/data/android/text.$localeId.json'),
      );
      final text = raw as Map<String, dynamic>;
      _texts[localeId] = text;
      return text;
    } catch (e) {
      log.warning('AndroidMetadata: text.$localeId.json 加载失败: $e');
      return const {};
    }
  }

  /// 当前界面语言对应的文案；当前语言缺文件时退回英文，再缺就空表。
  Map<String, dynamic> get _currentText {
    final id = _localeIds[LocaleSettings.currentLocale];
    if (id != null && _texts.containsKey(id)) return _texts[id]!;
    return _texts['en'] ?? const {};
  }

  Map<String, dynamic> _section(String name) {
    final section = _currentText[name];
    return section is Map<String, dynamic> ? section : const {};
  }

  /// 框架权限的保护级别；非框架权限（应用自定义、厂商权限）返回 null。
  AndroidProtection? protectionOf(String permission) {
    final raw = _protection?[permission];
    return raw == null ? null : AndroidProtection.parse(raw);
  }

  /// 风险分级；保护级别表里没有的权限一律 unknown，不猜。
  AndroidPermissionRisk riskOf(String permission) {
    final short = _shortName(permission);
    if (short == null) return AndroidPermissionRisk.unknown;
    final protection = protectionOf(permission);
    if (protection == null) return AndroidPermissionRisk.unknown;
    if (_highRisk.contains(short)) return AndroidPermissionRisk.high;
    if (_sensitiveSpecial.contains(short)) {
      return AndroidPermissionRisk.sensitive;
    }
    return switch (protection.base) {
      AndroidProtectionBase.dangerous => AndroidPermissionRisk.sensitive,
      AndroidProtectionBase.normal => AndroidPermissionRisk.normal,
      AndroidProtectionBase.signature ||
      AndroidProtectionBase.signatureOrSystem ||
      AndroidProtectionBase.internal => AndroidPermissionRisk.system,
    };
  }

  /// 官方标题（`CAMERA` → “take pictures and videos”）；只有框架权限、且当前
  /// 语言有这句文案时才返回，其余返回 null（由调用方决定显示什么，不要编）。
  String? permissionLabel(String permission) {
    final short = _shortName(permission);
    if (short == null) return null;
    final entry = _section('permissions')[short];
    if (entry is! Map) return null;
    return entry['label'] as String?;
  }

  /// 官方说明（缺这条文案时返回 null）。
  String? permissionDescription(String permission) {
    final short = _shortName(permission);
    if (short == null) return null;
    final entry = _section('permissions')[short];
    if (entry is! Map) return null;
    return entry['description'] as String?;
  }

  /// 硬件/软件特性说明（按完整名称查，例如 `android.hardware.camera`）。
  String? featureDescription(String feature) {
    final value = _section('features')[feature];
    return value is String ? value : null;
  }

  /// 语言自称；`zh-HK` 这类标签用其中的语言段查。
  String? autonymOf(String tag) {
    final parts = _parseTag(tag);
    final language = parts['language'];
    if (language == null) return null;
    return _autonyms?[language];
  }

  /// 语言标签各段的显示名（`zh-HK` → 中文 / 香港）。
  ///
  /// 拼成 `中文（香港）` 这种整串是 UI 的事：括号与分隔符随界面语言变
  /// （见 `detail_manifest.locale_name_with_variant` 等 i18n 键）。
  AndroidLocaleNames localeNames(String tag) {
    final parts = _parseTag(tag);
    final language = parts['language'];
    final script = parts['script'];
    final region = parts['region'];
    return AndroidLocaleNames(
      language: language == null ? null : _section('languages')[language],
      script: script == null ? null : _section('scripts')[script],
      region: region == null ? null : _section('regions')[region],
      autonym: language == null ? null : _autonyms?[language],
    );
  }

  /// 只处理框架权限：`com.example.permission.X` 没有平台文案（参考实现同样只查
  /// `android.permission.` 前缀）。
  static String? _shortName(String permission) {
    const prefix = 'android.permission.';
    if (!permission.startsWith(prefix)) return null;
    return permission.substring(prefix.length);
  }

  /// 按 BCP 47 的常见写法拆段：`sr-Latn-RS`、`es-419`、`zh_Hant` 都认。
  static Map<String, String> _parseTag(String tag) {
    final segments = tag.split(RegExp('[-_]')).where((s) => s.isNotEmpty);
    String? language;
    String? script;
    String? region;
    for (final segment in segments) {
      if (language == null) {
        language = segment.toLowerCase();
      } else if (script == null && segment.length == 4) {
        script = segment[0].toUpperCase() + segment.substring(1).toLowerCase();
      } else if (region == null &&
          (segment.length == 2 || segment.length == 3)) {
        region = segment.toUpperCase();
      }
    }
    return {
      if (language != null) 'language': language,
      if (script != null) 'script': script,
      if (region != null) 'region': region,
    };
  }

  /// 高风险权限（`android.permission.` 之后的部分）。
  static const _highRisk = {
    'ACCESS_BACKGROUND_LOCATION',
    'ANSWER_PHONE_CALLS',
    'BODY_SENSORS',
    'BODY_SENSORS_BACKGROUND',
    'CALL_PHONE',
    'MANAGE_EXTERNAL_STORAGE',
    'PROCESS_OUTGOING_CALLS',
    'READ_CALL_LOG',
    'READ_CELL_BROADCASTS',
    'READ_CONTACTS',
    'READ_PHONE_NUMBERS',
    'READ_SMS',
    'RECEIVE_MMS',
    'RECEIVE_SMS',
    'RECEIVE_WAP_PUSH',
    'SEND_SMS',
  };

  /// 不是运行时权限、但同样敏感的：用户可在「特殊应用权限」里单独授予的
  /// signature | appop 权限，以及能列出全部已装应用的 QUERY_ALL_PACKAGES。
  ///
  /// 为什么不直接按 appop 标志判断：带 appop 的还有安装即授予的 normal 权限和
  /// 普通应用拿不到的 privileged 权限，标志本身分不出敏感与否。
  static const _sensitiveSpecial = {
    'MANAGE_MEDIA',
    'PACKAGE_USAGE_STATS',
    'QUERY_ALL_PACKAGES',
    'REQUEST_INSTALL_PACKAGES',
    'SYSTEM_ALERT_WINDOW',
    'WRITE_SETTINGS',
  };
}
