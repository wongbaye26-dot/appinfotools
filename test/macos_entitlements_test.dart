// macOS 的 entitlements 回归守卫。
//
// 背景（v2.4.1 修）：v2.4.0 发布后，概览页与版本对比页的「导出报告」**全部失败**，
// 用户看到的是一句 `PlatformException(ENTITLEMENT_REQUIRED_WRITE, The Read-Write
// entitlement is required for this action., null, null)`。
//
// 根因不在 Dart 侧：`file_picker`(>=10) 的 macOS 端在弹保存面板**之前**就用
// `SecTaskCreateFromSelf` 检查 `com.apple.security.files.user-selected.read-write`，
// 值为 true 才继续。本项目**刻意不开沙箱**（要在用户选中的文件旁边改名，而沙箱
// 只授予那一个文件、不含它所在的目录），因此从没声明过这个 key —— 于是保存面板
// 根本不弹出来，表现成「导出失败」。
//
// 这类问题**在 Dart 测试里完全看不出来**（插件在原生侧就被拦了），只能靠
// 直接校验 entitlements 文件本身。这一组就是为此存在的。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 两个 entitlements 文件都必须满足的约束。
///
/// `readWrite` 必须有且为 true；`appSandbox` 必须**不存在** —— 后者是本项目
///  deliberately 的取舍（见 Release.entitlements 里的长注释：沙箱会让
///  「在用户选中的文件旁边改名」必然 EPERM 失败）。
const _entitlementFiles = [
  'macos/Runner/Release.entitlements',
  'macos/Runner/DebugProfile.entitlements',
];

const _readWriteKey = 'com.apple.security.files.user-selected.read-write';
const _appSandboxKey = 'com.apple.security.app-sandbox';

Map<String, Object?> _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path 不存在');
  // entitlements 是 XML plist。用 dart:io 读原始文本 + 极简解析即可，
  // 不必引入 plist 依赖（本项目只在测试里需要它）。
  final text = file.readAsStringSync();
  expect(
    text.contains('<?xml'),
    isTrue,
    reason: '$path 不是 XML plist',
  );
  return _parsePlist(text);
}

/// 极简 plist 解析：只取顶层 `<key>X</key>` 与紧随的 `<true/>` / `<false/>`。
///
/// 这样写而不是引入依赖：本测试只关心几个布尔键，而且解析逻辑本身也该被
/// 看见（否则「测试有没有真的在读文件」要靠信任）。
Map<String, Object?> _parsePlist(String xml) {
  final result = <String, Object?>{};
  final pattern = RegExp(
    r'<key>([^<]+)</key>\s*<(true|false)\s*/>',
    dotAll: true,
  );
  for (final m in pattern.allMatches(xml)) {
    result[m.group(1)!] = m.group(2) == 'true';
  }
  return result;
}

void main() {
  group('macOS entitlements', () {
    test('Release 与 DebugProfile 都声明了 user-selected read-write', () {
      for (final path in _entitlementFiles) {
        final plist = _read(path);
        expect(
          plist[_readWriteKey],
          isTrue,
          reason: '$path 缺少 $_readWriteKey。\n'
              'file_picker 的 macOS 端会因此拒绝弹保存/打开面板，\n'
              '导出报告与「打开文件」按钮全部不可用（v2.4.0 的实际故障）。',
        );
      }
    });

    test('仍然不启用 App Sandbox（这是刻意的取舍，不能被顺手打开）', () {
      for (final path in _entitlementFiles) {
        final plist = _read(path);
        expect(
          plist.containsKey(_appSandboxKey),
          isFalse,
          reason: '$path 出现了 $_appSandboxKey。沙箱会把「在用户选中的文件旁边'
              '改名」变成必然的 EPERM 失败 —— 见 Release.entitlements 的注释。',
        );
      }
    });

    test('解析器真的读到了键（不是空表，别让测试自证）', () {
      // 这条是给上面两条兜底的：万一 plist 格式变了、正则不再匹配，
      // 上面两条会变成「空表上断言」而假绿。
      final plist = _read('macos/Runner/Release.entitlements');
      expect(plist, isNotEmpty, reason: '一个键都没解析到，正则大概失效了');
      expect(plist.keys, contains('com.apple.security.network.client'));
    });
  });
}
