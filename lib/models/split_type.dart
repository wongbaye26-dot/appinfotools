import 'package:apk_info_tool/gen/strings.g.dart';

enum SplitType {
  base,
  language,
  abi,
  density,
  unknown;

  /// 匹配裸语言/地区码，例如 `zh`、`en`、`fil`、`zh-rCN`。
  static final RegExp _localePattern = RegExp(r'^[a-z]{2,3}(?:-r[A-Z]{2})?$');

  /// 密度 split 必须以 `dpi` 结尾，例如 `hdpi`、`xxhdpi`、`480dpi`、
  /// `xxhdpi-v4`。
  static final RegExp _densityPattern = RegExp(r'^[a-z0-9]+dpi(?:-v[0-9]+)?$');

  /// ABI split，例如 `arm64_v8a`、`armeabi_v7a`、`x86_64`。
  static final RegExp _abiPattern = RegExp(
      r'^(?:armeabi|arm64|x86|x86_64|mips|mips64|riscv64|wasm)(?:_[a-z0-9]+)*$');

  static SplitType fromId(String id) {
    if (id == 'base' ||
        id.startsWith('base-') ||
        id.startsWith('base_') ||
        id.startsWith('base.')) {
      return SplitType.base;
    }

    // 剥掉可选的 `split_config.` / `config.` / `split_` 前缀，
    // 得到真正的 split 名称再判定类型。
    final name = _stripPrefix(id);

    if (_localePattern.hasMatch(name)) return SplitType.language;
    if (_densityPattern.hasMatch(name)) return SplitType.density;
    if (_abiPattern.hasMatch(name)) return SplitType.abi;

    return SplitType.unknown;
  }

  static String _stripPrefix(String id) {
    for (final prefix in const ['split_config.', 'config.', 'split_']) {
      if (id.startsWith(prefix)) return id.substring(prefix.length);
    }
    return id;
  }

  String getDisplayText(Translations t) {
    switch (this) {
      case SplitType.base:
        return t.install.split_type.base;
      case SplitType.language:
        return t.install.split_type.language;
      case SplitType.abi:
        return t.install.split_type.abi;
      case SplitType.density:
        return t.install.split_type.density;
      case SplitType.unknown:
        return t.install.split_type.unknown;
    }
  }
}
