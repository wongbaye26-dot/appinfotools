// 隐私清单里的**必需理由 API**（`NSPrivacyAccessedAPITypes`）。
//
// 背景（2026-10-19 审计 P2-9）：这一节全仓 0 处解析。而 iOS 17 起，用到
// UserDefaults / 文件时间戳 / 磁盘空间 / 系统启动时间这几类 API 的应用必须在
// 隐私清单里逐条声明理由，否则上架会被退 —— 也就是说「隐私清单审计」缺的
// 恰好是最容易被退的那一块。
//
// 顺带钉住一个连带 bug：`IosPrivacyInfo.isEmpty` 此前只看 tracking /
// trackingDomains / collectedDataTypes。**只声明了必需理由 API 的清单**
// （很常见的形态）会被判成 absent，于是报告说「没有隐私清单」。

import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _infoPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.demo</string>
  <key>CFBundleExecutable</key>
  <string>Demo</string>
</dict>
</plist>
''';

const _privacy = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array><string>CA92.1</string></array>
    </dict>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array><string>C617.1</string><string>3B52.1</string></array>
    </dict>
  </array>
</dict>
</plist>
''';

Archive _ipa({String? privacy}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('Payload/Demo.app/Info.plist', _infoPlist);
  if (privacy != null) add('Payload/Demo.app/PrivacyInfo.xcprivacy', privacy);
  return archive;
}

void main() {
  test('必需理由 API 被解析出来，理由码按序保留', () {
    final archive = _ipa(privacy: _privacy);
    final container = IpaContainerReader.read(archive);
    final plist = IpaInfoPlistReader.read(archive, container.mainApp!);

    final info = plist.privacyInfo;
    expect(info.hasValue, isTrue, reason: '只声明必需理由 API 的清单不能被判成 absent');
    final types = info.value!.accessedApiTypes;
    expect(types, hasLength(2));
    expect(types.first.type, 'NSPrivacyAccessedAPICategoryFileTimestamp');
    expect(types.first.reasons, ['3B52.1', 'C617.1']);
    expect(types.last.type, 'NSPrivacyAccessedAPICategoryUserDefaults');
    expect(types.last.reasons, ['CA92.1']);
  });

  test('没有隐私清单时仍是 absent（不伪造空清单）', () {
    final archive = _ipa();
    final container = IpaContainerReader.read(archive);
    final plist = IpaInfoPlistReader.read(archive, container.mainApp!);
    expect(plist.privacyInfo.status, FieldStatus.absent);
  });
}
