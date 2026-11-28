// 安装页的 IPA 元数据读取：只读 Info.plist，失败降级为空值。
//
// 用现造的 IPA（`ZipEncoder`）而不是真实样本：仓库里没有 IPA 容器夹具，
// 而这里要验的正是「从 Payload/*.app/Info.plist 取四个字段」这一段。

import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/utils/ipa_install_metadata.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Demo App</string>
  <key>CFBundleIdentifier</key><string>com.example.demo</string>
  <key>CFBundleShortVersionString</key><string>1.2.3</string>
  <key>CFBundleVersion</key><string>45</string>
  <key>CFBundleExecutable</key><string>Demo</string>
</dict>
</plist>
''';

Future<String> _makeIpa(Directory dir, {String? plist}) async {
  final archive = Archive()
    ..add(ArchiveFile(
      'Payload/Demo.app/Info.plist',
      utf8.encode(plist ?? _plist).length,
      utf8.encode(plist ?? _plist),
    ))
    ..add(ArchiveFile.bytes('Payload/Demo.app/Demo', [0xCF, 0xFA, 0xED, 0xFE]));
  final path = '${dir.path}/demo.ipa';
  await File(path).writeAsBytes(ZipEncoder().encode(archive));
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('读取 Info.plist 的四个字段', () async {
    final dir = await Directory.systemTemp.createTemp('ipa-meta');
    addTearDown(() => dir.delete(recursive: true));
    final meta = await IpaInstallMetadata.read(await _makeIpa(dir));

    expect(meta.displayName, 'Demo App');
    expect(meta.bundleIdentifier, 'com.example.demo');
    expect(meta.version, '1.2.3');
    expect(meta.buildNumber, '45');
    expect(meta.hasAny, isTrue);
  });

  test('没有 Info.plist 时返回空值而不是抛', () async {
    final dir = await Directory.systemTemp.createTemp('ipa-meta-empty');
    addTearDown(() => dir.delete(recursive: true));
    final archive = Archive()
      ..add(
          ArchiveFile.bytes('Payload/Demo.app/Demo', [0xCF, 0xFA, 0xED, 0xFE]));
    final path = '${dir.path}/no-plist.ipa';
    await File(path).writeAsBytes(ZipEncoder().encode(archive));

    final meta = await IpaInstallMetadata.read(path);
    expect(meta.hasAny, isFalse);
  });

  test('不是 IPA 的文件、不存在的路径都降级为空', () async {
    final dir = await Directory.systemTemp.createTemp('ipa-meta-bad');
    addTearDown(() => dir.delete(recursive: true));
    final notZip = File('${dir.path}/bad.ipa');
    await notZip.writeAsString('not a zip');

    expect((await IpaInstallMetadata.read(notZip.path)).hasAny, isFalse);
    expect(
      (await IpaInstallMetadata.read('${dir.path}/missing.ipa')).hasAny,
      isFalse,
    );
  });
}
