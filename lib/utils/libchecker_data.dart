import 'dart:convert';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter/services.dart';
import '../gen/strings.g.dart';
import 'libchecker_rules_import.dart';

/// LibChecker 规则数据的加载入口。
///
/// 数据是 756 KB 的 JSON：启动时加载会让每个用户都付一次解析成本，而「库」
/// 标签页只有打开 APK 详情才用得到 —— 因此按需加载，进程内只解析一次。
class LibCheckerData {
  LibCheckerData._();

  static const _assetPath = 'assets/libchecker/libchecker_v5.json';
  static const _iconsPath = 'assets/libchecker/icons.json';

  static LibCheckerRules? _rules;

  /// 当前规则是否来自用户导入（而不是随包内置）。
  static bool _usingOverride = false;

  static bool get usingImportedRules => _usingOverride;
  static Future<LibCheckerRules>? _pending;
  static Map<String, String>? _icons;
  static Future<Map<String, String>>? _iconsPending;

  /// 已加载的规则；未加载时为 `null`。
  static LibCheckerRules? get loaded => _rules;

  /// 仅供测试：注入自定义加载器（避免在纯 Dart 测试里依赖 asset bundle）。
  static Future<LibCheckerRules> Function()? debugLoader;

  /// 加载（并缓存）规则。加载失败会抛出 —— 上传者需要看见「规则没读到」，
  /// 而不是被当成「没有识别到任何 SDK」。
  static Future<LibCheckerRules> ensureLoaded({AssetBundle? bundle}) {
    final cached = _rules;
    if (cached != null) return Future.value(cached);
    final pending = _pending;
    if (pending != null) return pending;
    final future = _load(bundle ?? rootBundle);
    _pending = future;
    return future.whenComplete(() => _pending = null);
  }

  static Future<LibCheckerRules> _load(AssetBundle bundle) async {
    final debug = debugLoader;
    if (debug != null) {
      final rules = await debug();
      _rules = rules;
      return rules;
    }
    // 先看数据目录里有没有导入的规则包；坏数据由 store 吞掉并回退内置。
    final override = await LibCheckerRuleStore.loadRules();
    if (override != null) {
      _usingOverride = true;
      _rules = override;
      return override;
    }
    final raw = await bundle.loadString(_assetPath);
    final bundleMap = jsonDecode(raw) as Map<String, dynamic>;
    final rules = LibCheckerRules.fromBundle(bundleMap);
    _usingOverride = false;
    _rules = rules;
    return rules;
  }

  /// SDK 图标的 SVG 源码（iconId → svg）。缺失时返回 `null`，调用方退回字母牌。
  static String? iconSvg(String? iconId) {
    if (iconId == null || iconId.isEmpty) return null;
    return _icons?[iconId];
  }

  /// 加载图标表。图标缺一个不影响库识别本身，失败按「没有图标」处理。
  static Future<void> ensureIconsLoaded({AssetBundle? bundle}) {
    final cached = _icons;
    if (cached != null) return Future.value();
    final pending = _iconsPending;
    if (pending != null) return pending.then((_) {});
    final future = _loadIcons(bundle ?? rootBundle);
    _iconsPending = future;
    return future.then((_) {}).whenComplete(() => _iconsPending = null);
  }

  static Future<Map<String, String>> _loadIcons(AssetBundle bundle) async {
    final imported = await LibCheckerRuleStore.loadIcons();
    if (imported != null && imported.isNotEmpty) {
      _icons = imported;
      return _icons!;
    }
    try {
      final raw = await bundle.loadString(_iconsPath);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final icons = <String, String>{
        for (final entry in decoded.entries)
          if (entry.value is String) entry.key: entry.value as String,
      };
      _icons = icons;
      return icons;
    } catch (_) {
      _icons = const {};
      return _icons!;
    }
  }

  /// 详情语言：中文界面用上游的 `zh-Hans`，其余统一 `en`（上游只有这两种）。
  static String get detailLocale {
    final locale = LocaleSettings.currentLocale.languageCode;
    return locale == 'zh' ? 'zh-Hans' : 'en';
  }

  /// 导入 / 恢复规则后重新加载（下次 ensureLoaded 会重新读数据目录）。
  static void reload() {
    _rules = null;
    _pending = null;
    _icons = null;
    _iconsPending = null;
    _usingOverride = false;
  }

  /// 测试辅助：清空缓存。
  static void resetForTest() {
    _rules = null;
    _usingOverride = false;
    _pending = null;
    _icons = null;
    _iconsPending = null;
    debugLoader = null;
  }
}
