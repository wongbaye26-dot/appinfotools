// 「只读名字 + 版本」的轻量读取器。
//
// 覆盖的重点不是「能读出来」，而是**批量重命名真正会遇到的三类文件**：
// 普通 APK、iOS IPA、以及下载渠道加了 `.1` 后缀的 APK。后两类此前在批量
// 重命名里完全读不到名字（走的是 `getApkInfo`，IPA 根本不在它的支持范围），
// 于是界面显示「成功 N 个」而实际什么都没改。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/package_identity.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _infoPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.demo</string>
  <key>CFBundleDisplayName</key><string>示例应用</string>
  <key>CFBundleShortVersionString</key><string>2.3.4</string>
  <key>CFBundleVersion</key><string>234</string>
</dict></plist>
''';

/// 造一个最小可用的 IPA（只有 `Info.plist`）。
Uint8List _ipaBytes({bool withInfoPlist = true}) {
  final archive = Archive();
  if (withInfoPlist) {
    final bytes = const Utf8Encoder().convert(_infoPlist);
    archive.addFile(
      ArchiveFile('Payload/Example.app/Info.plist', bytes.length, bytes),
    );
  }
  final executable = const Utf8Encoder().convert('not a real mach-o\n');
  archive.addFile(
    ArchiveFile('Payload/Example.app/Example', executable.length, executable),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('package_identity');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String write(String name, List<int> bytes) {
    final path = p.join(dir.path, name);
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  test('APK：读应用名与版本（label 来自资源表）', () async {
    final path = p.join('test', 'fixtures', 'apk', 'icon-png.apk');
    final identity = await readPackageIdentityInIsolate(path);
    expect(identity.platform, PackageIdentityPlatform.android);
    expect(identity.appName, 'Icon Fixture');
    expect(identity.version, '1.0');
    expect(identity.failure, isNull);
  });

  test('IPA：读 CFBundleDisplayName 与版本', () async {
    final path = write('demo.ipa', _ipaBytes());
    final identity = await readPackageIdentityInIsolate(path);
    expect(identity.platform, PackageIdentityPlatform.ios);
    expect(identity.appName, '示例应用');
    expect(identity.version, '2.3.4');
    expect(identity.hasAppName, isTrue);
  });

  test('IPA：没有 Info.plist 时不抛异常，只标记失败', () async {
    final path = write('broken.ipa', _ipaBytes(withInfoPlist: false));
    final identity = await readPackageIdentityInIsolate(path);
    expect(identity.platform, PackageIdentityPlatform.ios);
    expect(identity.hasAppName, isFalse);
    expect(identity.failure, isNotNull);
  });

  test('`.apk.1` 这种下载后缀也按 APK 读', () async {
    final source = File(p.join('test', 'fixtures', 'apk', 'icon-png.apk'));
    final path = write('icon-png.apk.1', source.readAsBytesSync());
    final identity = await readPackageIdentityInIsolate(path);
    expect(identity.platform, PackageIdentityPlatform.android);
    expect(identity.appName, 'Icon Fixture');
  });

  test('不是包的文件：返回失败而不是抛', () async {
    final path = write('not-a-package.apk', utf8.encode('hello world'));
    final identity = await readPackageIdentityInIsolate(path);
    expect(identity.hasAppName, isFalse);
    expect(identity.failure, isNotNull);
  });

  test('不存在的路径：返回失败而不是抛', () async {
    final identity = await readPackageIdentityInIsolate(
      p.join(dir.path, 'missing.apk'),
    );
    expect(identity.hasAppName, isFalse);
    expect(identity.failure, isNotNull);
  });
}
