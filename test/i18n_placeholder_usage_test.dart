// slang 占位符调用的静态守卫。
//
// 带 `{count}` 这类占位符的键会被 slang 生成为**方法**，不是 getter。漏传参数
// **不会编译报错** —— 函数对象本身就是个合法值 —— 但会把它插进字符串，界面上
// 出现 `Closure: (required Ordered object) => ...`。iOS 的「容器」卡片上真的
// 出现过这一串，而且 `flutter analyze` 完全看不见。
//
// 分析器帮不上忙，因此这里直接扫源码：把 `assets/i18n/` 里所有带占位符的键
// 找出来，再确认 `lib/` 下每一处引用后面都跟着实参列表。
//
// 只扫 `en.json`：它是 `base_locale`，键集合是其余语言的超集（其余语言缺键时
// 回退到它）。用别的语言当基准会漏掉只在 en 里存在的键。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// slang 的输入目录，与 `build.yaml` 的 `input_directory` 一致。
const String _i18nDir = 'assets/i18n';

/// 生成代码所在目录：里面全是 `t.<key>` 形式的定义，扫进来必然误报。
const String _generatedDir = 'lib/gen';

/// 收集 `{name}` 形式的占位符。
final RegExp _placeholder = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');

/// 递归收集所有「值里带占位符」的键路径（形如 `apk_info.structure_file_count`）。
void _collect(Map<String, Object?> node, List<String> prefix, Set<String> out) {
  for (final entry in node.entries) {
    final value = entry.value;
    final path = [...prefix, entry.key];
    if (value is Map<String, Object?>) {
      _collect(value, path, out);
    } else if (value is String && _placeholder.hasMatch(value)) {
      out.add(path.join('.'));
    }
  }
}

/// 按包根目录相对路径读取所有 Dart 源文件。
Map<String, String> _libSources() {
  final sources = <String, String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final normalized = entity.path.replaceAll(r'\', '/');
    if (normalized.startsWith('$_generatedDir/')) continue;
    sources[normalized] = entity.readAsStringSync();
  }
  return sources;
}

void main() {
  test('带占位符的本地化键一律要传参，不能把函数对象插进字符串', () {
    final enFile = File('$_i18nDir/en.json');
    expect(enFile.existsSync(), isTrue, reason: '缺少 $_i18nDir/en.json');

    final interpolated = <String>{};
    _collect(
      jsonDecode(enFile.readAsStringSync()) as Map<String, Object?>,
      const [],
      interpolated,
    );
    expect(interpolated, isNotEmpty, reason: '一个带占位符的键都没有，说明解析逻辑失效了，这个守卫等于不存在');

    final sources = _libSources();
    expect(sources, isNotEmpty, reason: '一个 Dart 源文件都没读到');

    final offenders = <String>[];
    for (final key in interpolated) {
      // `t.<路径>` 或 `translations.<路径>`，后面**不**跟实参列表。
      // 允许换行，因为格式化会把长调用折行。
      final pattern = RegExp(
        r'(?:\bt|translations)\.' + RegExp.escape(key) + r'\b(?!\s*\()',
      );
      for (final entry in sources.entries) {
        for (final match in pattern.allMatches(entry.value)) {
          final line =
              '\n'.allMatches(entry.value.substring(0, match.start)).length + 1;
          offenders.add('${entry.key}:$line  ${match.group(0)}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些引用漏传了占位符实参，界面上会显示 "Closure: ..."：\n'
          '${offenders.join('\n')}',
    );
  });
}
