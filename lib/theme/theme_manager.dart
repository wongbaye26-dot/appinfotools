import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

String? getFontFamily() {
  if (Platform.isWindows) {
    final locale = LocaleSettings.currentLocale;
    return switch (locale) {
      AppLocale.ja => 'Yu Gothic UI',
      AppLocale.ko => 'Malgun Gothic',
      AppLocale.zhCn => 'Microsoft YaHei UI',
      AppLocale.zhHk || AppLocale.zhTw => 'Microsoft JhengHei UI',
      _ => 'Segoe UI Variable Display',
    };
  } else {
    return null;
  }
}

/// 解析持久化字符串为 [ThemeMode]。
ThemeMode _parseThemeMode(String value) => switch (value) {
      Config.kThemeModeLight => ThemeMode.light,
      Config.kThemeModeDark => ThemeMode.dark,
      _ => ThemeMode.system,
    };

/// 主题状态。
///
/// 同时持有种子色与明暗模式，为 [MaterialApp] 提供：
/// - [lightTheme] / [darkTheme]：按种子色生成的完整主题
/// - [mode]：当前明暗模式策略（system / light / dark）
class ThemeState {
  final int themeColor;
  final ThemeMode mode;

  const ThemeState({required this.themeColor, required this.mode});

  Color get _seed => Color(themeColor);

  ThemeData get lightTheme => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: getFontFamily(),
      );

  ThemeData get darkTheme => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: getFontFamily(),
      );
}

class ThemeManager extends Notifier<ThemeState> {
  @override
  ThemeState build() => ThemeState(
        themeColor: Config.themeColor.value,
        mode: _parseThemeMode(Config.themeMode.value),
      );

  void updateThemeColor(Color color) {
    final argb = color.toARGB32();
    state = ThemeState(themeColor: argb, mode: state.mode);
    Config.themeColor.updateValue(argb);
  }

  void setThemeMode(ThemeMode mode) {
    final value = switch (mode) {
      ThemeMode.light => Config.kThemeModeLight,
      ThemeMode.dark => Config.kThemeModeDark,
      ThemeMode.system => Config.kThemeModeSystem,
    };
    state = ThemeState(themeColor: state.themeColor, mode: mode);
    Config.themeMode.updateValue(value);
  }
}

final themeManagerProvider =
    NotifierProvider<ThemeManager, ThemeState>(ThemeManager.new);
