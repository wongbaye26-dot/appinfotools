import 'dart:async';

import 'package:apk_info_tool/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConfigItem<T> {
  final String key;
  T _value;

  T get value => _value;

  ConfigItem(this.key, this._value);

  Timer? _applyTimer;

  /// 立即把当前值写入持久化存储。
  ///
  /// 写入失败（磁盘满、权限不足、preferences 后端异常）时记录日志，
  /// 避免用户以为设置已保存。
  Future<bool> _applyValue() async {
    final value = _value;
    try {
      bool ok;
      if (value is String) {
        ok = await Config.gPrefs.setString(key, value);
      } else if (value is bool) {
        ok = await Config.gPrefs.setBool(key, value);
      } else if (value is int) {
        ok = await Config.gPrefs.setInt(key, value);
      } else if (value is double) {
        ok = await Config.gPrefs.setDouble(key, value);
      } else {
        return false;
      }
      if (!ok) {
        log.warning('failed to persist config "$key": storage rejected write');
      }
      return ok;
    } catch (e) {
      log.warning('failed to persist config "$key": $e');
      return false;
    }
  }

  Future<void> updateValue(T value) async {
    _value = value;
    _applyTimer?.cancel();
    _applyTimer = Timer(const Duration(milliseconds: 100), () {
      _applyTimer = null;
      unawaited(_applyValue());
    });
  }

  /// 取消待执行的防抖写入，并立即同步当前值。
  ///
  /// 应用退出前调用，避免最后 100ms 内的设置变更丢失。
  Future<bool> flush() async {
    _applyTimer?.cancel();
    _applyTimer = null;
    return _applyValue();
  }

  /// 是否存在尚未落盘的待写入变更。
  bool get hasPendingWrite => _applyTimer != null;

  void loadValue() {
    if (_value is String) {
      _value = (Config.gPrefs.getString(key) ?? _value) as T;
    } else if (value is bool) {
      _value = (Config.gPrefs.getBool(key) ?? _value) as T;
    } else if (value is int) {
      _value = (Config.gPrefs.getInt(key) ?? _value) as T;
    } else if (value is double) {
      _value = (Config.gPrefs.getDouble(key) ?? _value) as T;
    }
  }
}

class Config {
  static late SharedPreferences gPrefs;

  static const kLanguageAuto = "auto";
  static const kToolSourceSystem = "system";
  static const kToolSourceBuiltin = "builtin";
  static const kToolSourceCustom = "custom";

  static final aapt2Path = ConfigItem("aapt2_path", "");
  static final apksignerPath = ConfigItem("apksigner_path", "");
  static final adbPath = ConfigItem("adb_path", "");
  static final aapt2Source = ConfigItem("aapt2_source", kToolSourceBuiltin);
  static final apksignerSource =
      ConfigItem("apksigner_source", kToolSourceBuiltin);
  static final adbSource = ConfigItem("adb_source", kToolSourceBuiltin);

  /// Java 运行时（`apksigner` 的依赖）。
  ///
  /// 与另外三个工具同一套「内置 / 系统环境 / 自定义」语义：
  /// - 内置 = 我们下载的 JRE（`<数据目录>/bin/jre`）
  /// - 系统环境 = 自动探测（`JAVA_HOME` → `PATH` → 各平台常见安装目录）
  /// - 自定义 = 用户指定的 `java` 可执行文件
  ///
  /// 默认「内置」与其它三项一致：没下载时自动退回系统探测，不会因为
  /// 用户没点过下载就变成「未找到」。
  static final javaPath = ConfigItem("java_path", "");
  static final javaSource = ConfigItem("java_source", kToolSourceBuiltin);

  static final downloadDir = ConfigItem("download_dir", "");
  static final enableSignature = ConfigItem("enable_signature", false);
  static final enableHash = ConfigItem("enable_hash", true);
  static final enableSecurityAudit = ConfigItem("enable_security_audit", true);
  static final enableDebug = ConfigItem("enable_debug", false);

  /// 是否在启动时自动注册「系统文件图标」（Windows Shell 缩略图处理器）。
  ///
  /// 默认**开**：装完就该看到每个包自己的图标，而不是所有 `.apk` 长一个样。
  /// 设置页的「停用」会把它写成 false —— 下次启动不会再自动打开，
  /// 否则那个开关等于没关。
  static final systemIconEnabled = ConfigItem("system_icon_enabled", true);

  static const kParserBuiltin = "builtin";
  static const kParserAapt2 = "aapt2";
  static final parserEngine = ConfigItem("parser_engine", kParserBuiltin);
  static final maxLines = ConfigItem("max_lines", 6);
  // 注意：`Color.value` 已废弃（Flutter 3.27+），`toARGB32()` 返回等值的
  // 32 位 ARGB int，与既有持久化数据兼容。
  static final themeColor = ConfigItem("theme_color", Colors.blue.toARGB32());
  static final titleWidth = ConfigItem("title_width", 100.0);
  static final language = ConfigItem("language", kLanguageAuto);

  // 主题模式：light / dark / system（默认跟随系统）
  static const kThemeModeLight = "light";
  static const kThemeModeDark = "dark";
  static const kThemeModeSystem = "system";
  static final themeMode = ConfigItem("theme_mode", kThemeModeSystem);

  /// 最近分析过的文件列表，JSON 数组字符串。
  static final recentFiles = ConfigItem("recent_files", "[]");

  static final List<ConfigItem> _globalItems = [
    aapt2Path,
    apksignerPath,
    adbPath,
    aapt2Source,
    apksignerSource,
    adbSource,
    javaPath,
    javaSource,
    downloadDir,
    enableSignature,
    enableHash,
    enableSecurityAudit,
    enableDebug,
    systemIconEnabled,
    maxLines,
    themeColor,
    titleWidth,
    language,
    parserEngine,
    themeMode,
    recentFiles,
  ];

  static Future<void> init() async {
    gPrefs = await SharedPreferences.getInstance();
  }

  static Future<void> loadConfig() async {
    for (final item in _globalItems) {
      item.loadValue();
    }

    await LoggerInit.initLogger();

    for (final item in _globalItems) {
      log.info("loadConfig: ${item.key}=${item.value}");
    }
  }

  /// 把所有待写入的配置立即落盘。
  ///
  /// 退出前调用，确保防抖窗口内的最后几次修改不会丢失。
  /// 返回是否有任何一项写入失败。
  static Future<bool> flushAll() async {
    var allOk = true;
    for (final item in _globalItems) {
      if (!await item.flush()) {
        allOk = false;
      }
    }
    return allOk;
  }
}
