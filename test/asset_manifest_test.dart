// 资产清单一致性测试（审计 5.10）。
//
// `assets/` 下的文件分两类，规则完全不同：
//
// 1. **运行时资产** —— 必须逐条列在 `pubspec.yaml` 的 `flutter.assets` 里，
//    否则不会被打包；反过来声明了不存在的文件会让打包直接失败。
// 2. **构建期输入** —— `assets/i18n/*.json` 由 slang 在构建时编译成
//    `lib/gen/strings.g.dart`（见 build.yaml 的 input_directory）。
//    它们**不应**出现在运行时资产声明里，否则等于把源文件白白打进产物。
//
// 这条区分是写这个测试时才意识到的：最初的假设是「assets/ 下每个文件都必须
// 被声明」，被 `assets/i18n/` 直接推翻。规则按实际情况修正，而不是把
// i18n 目录硬编码排除掉了事 —— 那样下次有人把别的东西放进 assets/ 就漏掉了。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// slang 的输入目录，应当与 build.yaml 的 `input_directory` 一致。
const String _buildTimeInputDir = 'assets/i18n';

/// 该目录下的文件路径前缀（带尾斜杠，用于前缀匹配）。
const String _buildTimeInputPrefix = '$_buildTimeInputDir/';

/// 从 pubspec.yaml 的 `flutter.assets` 段提取声明项。
///
/// 只针对本项目这个文件形状的最小读取器：找 `assets:` 之后、缩进 4 空格开头的
/// `- ` 行，遇到第一个非缩进行即结束。解析不出任何内容时断言失败，
/// 而不是静默通过 —— 静默通过等于这个测试不存在。
List<String> _declaredAssets(String pubspec) {
  final declared = <String>[];
  var inAssets = false;

  for (final line in pubspec.split('\n')) {
    final trimmed = line.trim();

    if (trimmed == 'assets:') {
      inAssets = true;
      continue;
    }
    if (!inAssets) continue;

    if (line.startsWith('    - ')) {
      declared.add(line.substring(6).trim());
      continue;
    }
    // 缩进回到 4 空格以内说明已经离开 assets 段
    if (trimmed.isNotEmpty && !line.startsWith('    ')) break;
  }

  return declared;
}

void main() {
  test('build.yaml 里 slang 的输入目录与本测试的假设一致', () {
    final buildYaml = File('build.yaml').readAsStringSync();

    expect(buildYaml, contains('input_directory: $_buildTimeInputDir'),
        reason: 'slang 输入目录变了，本测试的假设需要同步更新');
  });

  test('assets/ 下的运行时资产与 pubspec 声明完全一致', () {
    final declared = _declaredAssets(File('pubspec.yaml').readAsStringSync());

    expect(declared, isNotEmpty,
        reason: '未能从 pubspec.yaml 解析出 assets 声明 —— 解析器或格式变了');

    final runtimeAssets = Directory('assets')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => !p.startsWith(_buildTimeInputPrefix))
        .toSet();

    for (final asset in declared) {
      expect(runtimeAssets, contains(asset),
          reason: 'pubspec 声明了不存在的资产: $asset');
    }
    for (final file in runtimeAssets) {
      expect(declared, contains(file),
          reason: 'assets/ 下的 $file 未在 pubspec.yaml 声明 —— 它不会被打包');
    }
  });

  test('构建期输入不得被声明为运行时资产', () {
    final declared = _declaredAssets(File('pubspec.yaml').readAsStringSync());

    expect(Directory(_buildTimeInputDir).existsSync(), isTrue,
        reason: 'i18n 输入目录应当存在');
    expect(declared.where((a) => a.startsWith(_buildTimeInputPrefix)), isEmpty,
        reason: 'i18n JSON 会被编译进 Dart 代码，不该再打进产物');
  });

  test('README 用的图片不在 assets/ 下，不会被误打包', () {
    final declared = _declaredAssets(File('pubspec.yaml').readAsStringSync());

    expect(File('docs/assets/icon_512.png').existsSync(), isTrue,
        reason: 'README 引用的图片应当存在');
    expect(declared, isNot(contains('docs/assets/icon_512.png')),
        reason: 'README 图片不是运行时资产，不该进包');
    expect(declared.where((a) => a.startsWith('docs/')), isEmpty);
  });
}
