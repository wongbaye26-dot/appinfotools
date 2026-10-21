import 'dart:io';

import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// Android SDK 自动探测。
///
/// 背景：`aapt2` / `apksigner` / `adb` 随 Android Studio 装好，但**不会**自动
/// 进入 `PATH`。此前只查 `PATH`，于是「装了 SDK 的机器」在设置页上照样显示
/// 「未找到」，aapt2 解析引擎也用不上。
void main() {
  group('androidSdkRoots', () {
    test('ANDROID_HOME 优先于 ANDROID_SDK_ROOT', () {
      final roots = ToolPaths.androidSdkRoots(environment: {
        'ANDROID_HOME': '/opt/android-home',
        'ANDROID_SDK_ROOT': '/opt/android-root',
        'HOME': '/home/u',
      });

      expect(roots.first, '/opt/android-home');
      expect(roots, contains('/opt/android-root'));
    });

    test('重复路径只保留一份，空白项被丢弃', () {
      final roots = ToolPaths.androidSdkRoots(environment: {
        'ANDROID_HOME': '/opt/sdk',
        'ANDROID_SDK_ROOT': '  /opt/sdk  ',
        'HOME': '',
      });

      expect(roots.where((r) => r == '/opt/sdk'), hasLength(1));
      expect(roots, isNot(contains('')));
    });

    test('没有环境变量时退回平台默认位置', () {
      final roots = ToolPaths.androidSdkRoots(environment: {
        'HOME': '/home/u',
        'USERPROFILE': 'C:\\Users\\u',
        'LOCALAPPDATA': 'C:\\Users\\u\\AppData\\Local',
      });

      // 断言的是「至少包含本平台那个默认位置」，不锁死其它平台的分支。
      if (Platform.isMacOS) {
        expect(
            roots, contains(path.join('/home/u', 'Library', 'Android', 'sdk')));
      } else if (Platform.isWindows) {
        expect(
            roots,
            contains(
                path.join('C:\\Users\\u\\AppData\\Local', 'Android', 'Sdk')));
      } else {
        expect(roots, contains(path.join('/home/u', 'Android', 'Sdk')));
      }
    });
  });

  group('androidToolFileName', () {
    test('只认项目实际会执行的三个工具', () {
      expect(ToolPaths.androidToolFileName('aapt2'), isNotNull);
      expect(ToolPaths.androidToolFileName('apksigner'), isNotNull);
      expect(ToolPaths.androidToolFileName('adb'), isNotNull);
    });

    test('未知命令返回 null，不拿任意命令名去拼 SDK 路径', () {
      expect(ToolPaths.androidToolFileName('zipalign'), isNull);
      expect(ToolPaths.androidToolFileName('rm'), isNull);
      expect(ToolPaths.androidToolFileName(''), isNull);
    });
  });

  group('findInAndroidBuildTools', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sdk_probe_');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<void> touch(String relative) async {
      final file = File(path.join(tmp.path, relative));
      await file.parent.create(recursive: true);
      await file.writeAsString('');
    }

    test('在 build-tools 下找到工具', () async {
      await touch('build-tools/34.0.0/aapt2');

      final found =
          ToolPaths.findInAndroidBuildTools('aapt2', roots: [tmp.path]);

      expect(found, isNotNull);
      expect(found, endsWith(path.join('34.0.0', 'aapt2')));
    });

    test('多个版本时取版本号最大的（不是字典序）', () async {
      await touch('build-tools/9.0.0/aapt2');
      await touch('build-tools/34.0.0/aapt2');

      final found =
          ToolPaths.findInAndroidBuildTools('aapt2', roots: [tmp.path]);

      // 字典序会把 9.0.0 排在 34.0.0 后面 —— 必须按数值比较。
      expect(found, endsWith(path.join('34.0.0', 'aapt2')));
    });

    test('最新版本里没有该文件时不回退到旧版本', () async {
      await touch('build-tools/33.0.0/aapt2');
      await touch('build-tools/34.0.0/zipalign');

      // 现状是「只看最新版本」：apksigner 从 API 24 起才进 build-tools，
      // 混版本拼凑会造出「aapt2 与 apksigner 来自不同 SDK」的假象。
      final found =
          ToolPaths.findInAndroidBuildTools('aapt2', roots: [tmp.path]);
      expect(found, isNull);
    });

    test('目录不存在时返回 null，不抛异常', () {
      final missing = path.join(tmp.path, 'definitely-absent');
      expect(
          ToolPaths.findInAndroidBuildTools('aapt2', roots: [missing]), isNull);
      expect(ToolPaths.findInAndroidPlatformTools('adb', roots: [missing]),
          isNull);
    });

    test('多个根目录时按顺序取第一个命中的', () async {
      final other = await Directory.systemTemp.createTemp('sdk_probe2_');
      addTearDown(() async {
        if (other.existsSync()) await other.delete(recursive: true);
      });
      await touch('build-tools/30.0.0/aapt2');
      final second = File(path.join(other.path, 'build-tools/30.0.0/aapt2'));
      await second.parent.create(recursive: true);
      await second.writeAsString('');

      final found = ToolPaths.findInAndroidBuildTools('aapt2',
          roots: [tmp.path, other.path]);

      expect(found, startsWith(tmp.path));
    });
  });

  group('findInAndroidPlatformTools', () {
    test('在 platform-tools 下找到 adb', () async {
      final tmp = await Directory.systemTemp.createTemp('sdk_adb_');
      addTearDown(() async {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });
      final adb = File(path.join(tmp.path, 'platform-tools', 'adb'));
      await adb.parent.create(recursive: true);
      await adb.writeAsString('');

      final found =
          ToolPaths.findInAndroidPlatformTools('adb', roots: [tmp.path]);
      expect(found, isNotNull);
      expect(found, endsWith(path.join('platform-tools', 'adb')));
    });
  });
}
