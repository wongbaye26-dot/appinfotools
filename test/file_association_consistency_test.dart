// Windows 文件关联：Dart 侧与 native 侧必须说同一套扩展名。
//
// ## 为什么需要这个测试
//
// 关联注册的扩展名写在**两个地方**：
//
// - `windows/runner/file_association_channel.cpp` 的 `kSupportedExtensions`
//   与 `associations` 数组（决定注册哪些扩展名、命令行收哪些文件）；
// - `lib/utils/package_file_type.dart` 的 `kPickableExtensions`
//   （决定应用**愿意分析**哪些类型）。
//
// 两处不一致会出现最难查的那种故障：**关联建立了，双击也启动了应用，
// 但应用拒收**，用户看到的是「打开失败」而不是「没有关联」。
//
// 所以这里直接读 C++ 源文件做断言。这不是「优雅」的测法，
// 但它拦得住真正会出问题的那件事 —— 而且源码路径变了会立刻红。
//
// ## 本机测不了的边界
//
// 这个测试**不验**注册表写入本身（本机是 macOS，无法运行 Windows 代码）。
// 注册逻辑的正确性只能由 CI 的 Windows job 编译 + 手工在 Windows 上验证。

import 'dart:io';

import 'package:apk_info_tool/utils/file_association.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:flutter_test/flutter_test.dart';

const String _cppPath = 'windows/runner/file_association_channel.cpp';

String _readCpp() {
  final file = File(_cppPath);
  expect(file.existsSync(), isTrue, reason: '找不到 $_cppPath —— 文件被移动了，这个守卫要跟着改');
  return file.readAsStringSync();
}

/// 从 C++ 源码的 `kSupportedExtensions` 数组里抓扩展名。
///
/// **只解析那一个数组**，不是整个文件 —— 第一版抓全文时，`associations`
/// 里恰好也有同样的字面量，于是「把 kSupportedExtensions 里的某项删掉」
/// 这个真实的破坏**测不出来**（守卫自己骗自己）。
Set<String> _extensionsInCpp(String source) {
  final start = source.indexOf('kSupportedExtensions[] = {');
  expect(start, greaterThan(0),
      reason: '找不到 kSupportedExtensions 数组 —— 它被重命名或挪走了');
  final end = source.indexOf('};', start);
  expect(end, greaterThan(start), reason: 'kSupportedExtensions 数组没有收尾');
  final block = source.substring(start, end);
  return RegExp(r'L"(\.[a-z]{2,5})"')
      .allMatches(block)
      .map((m) => m.group(1)!)
      .toSet();
}

/// 从 `associations` 数组里抓 ProgID 后缀（`AppInfoTool.apk` → `.apk`）。
Set<String> _progIdSuffixesInCpp(String source) {
  return RegExp(r'L"AppInfoTool(\.[a-z]{2,5})"')
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  group('扩展名：Dart 与 native 说同一套', () {
    test('native 注册的扩展名 == Dart 愿意分析的扩展名', () {
      final inCpp = _extensionsInCpp(_readCpp());

      // Dart 侧：去掉多段后缀（`apk.1` 这类不是可注册类型）。
      final inDart = {
        for (final extension in kPickableExtensions)
          if (!extension.contains('.')) '.$extension',
      };

      expect(inCpp, inDart,
          reason: '两处不一致会导致「关联了但应用拒收」。'
              'C++ 里多出的：${inCpp.difference(inDart)}；'
              'Dart 里多出的：${inDart.difference(inCpp)}');
    });

    test('`FileAssociationManager.extensions` 就是从 Dart 侧派生的那一套', () {
      final expected = {
        for (final extension in kPickableExtensions)
          if (!extension.contains('.')) '.$extension',
      };
      expect(FileAssociationManager.extensions.toSet(), expected);
      expect(FileAssociationManager.extensions, contains('.apk'));
      expect(FileAssociationManager.extensions, contains('.ipa'),
          reason: '用户明确要求在 Windows 上也能关联 .ipa');
      expect(FileAssociationManager.extensions, contains('.apkm'),
          reason: 'APKMirror 的 .apkm 是常见格式，漏掉会显得关联不完整');
    });

    test('扩展名都带点、都是小写、都不含多段', () {
      for (final extension in FileAssociationManager.extensions) {
        expect(extension.startsWith('.'), isTrue, reason: extension);
        expect(extension, extension.toLowerCase(), reason: extension);
        expect(extension.split('.').length, 2,
            reason: '$extension 是多段后缀，不该注册为文件类型');
      }
    });
  });

  group('native 侧的关键约定', () {
    test('每个注册的扩展名都有对应的 ProgID 条目', () {
      final source = _readCpp();
      final declared = _extensionsInCpp(source);
      final progIds = _progIdSuffixesInCpp(source);
      expect(progIds, declared,
          reason: 'kSupportedExtensions 与 associations 数组必须一一对应。'
              '命令行靠前者接文件，注册表靠后者建 ProgID —— '
              '缺一半就是「收得下但注册不上」');
    });

    test('不碰已有 UserChoice（那是系统保护的用户选择）', () {
      final source = _readCpp();
      expect(source, contains('HasUserChoice'),
          reason: '改写 UserChoice 是非法的，代码必须显式避开');
      expect(source, contains('SHChangeNotify'),
          reason: '写完注册表要通知外壳，否则「打开方式」里要等注销才出现');
    });

    test('取启动文件时排除命令行开关', () {
      final source = _readCpp();
      // `--foo` 这类开关不是路径，必须跳过。
      expect(source, contains("L'-'"),
          reason: '不排除开关的话，`--enable-dart-profiling` 会被当成文件路径');
    });
  });
}
