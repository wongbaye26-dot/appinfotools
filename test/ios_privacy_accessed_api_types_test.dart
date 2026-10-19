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

const _infoPlistWithAts = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.demo</string>
  <key>CFBundleExecutable</key>
  <string>Demo</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSExceptionDomains</key>
    <dict>
      <key>legacy.example.com</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionIncludesSubdomains</key><true/>
      </dict>
      <key>api.example.com</key>
      <dict>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
      </dict>
      <key>old-tls.example.com</key>
      <dict>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.0</string>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
''';

const _infoPlistAtsBenign = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.demo</string>
  <key>CFBundleExecutable</key>
  <string>Demo</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSExceptionDomains</key>
    <dict>
      <key>api.example.com</key>
      <dict>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
''';

Archive _ipa({String? privacy, String infoPlist = _infoPlist}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('Payload/Demo.app/Info.plist', infoPlist);
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

  group('授权项分级', () {
    test('稀有能力授权项报 P3；常见项不报', () {
      final archive = _ipa(privacy: _privacy);
      final container = IpaContainerReader.read(archive);
      final plist = IpaInfoPlistReader.read(archive, container.mainApp!);

      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        provisioningProfilePresent: true,
        entitlements: const [
          IosEntitlement(
            key: 'com.apple.developer.healthkit',
            value: PlistString('true'),
          ),
          // 常见项：keychain 共享。**刻意不报** —— 几乎每个带登录的应用都有。
          IosEntitlement(
            key: 'keychain-access-groups',
            value: PlistString('com.example.demo'),
          ),
        ],
      );

      final capability = result.findings
          .where((f) => f.ruleId == 'IOS-ENTITLEMENT-CAPABILITY')
          .toList();
      expect(capability, hasLength(1));
      expect(capability.single.severity, SecuritySeverity.p3);
      expect(
        capability.single.messageArgs['name'],
        'com.apple.developer.healthkit',
      );
      // keychain 那一项不能顺带报出来。
      expect(
        capability.single.messageArgs['name'],
        isNot('keychain-access-groups'),
      );
    });
  });

  group('ATS 例外域名', () {
    test('逐域标志被解析出来，只有真的放宽的才算放宽', () {
      final archive = _ipa(infoPlist: _infoPlistWithAts);
      final container = IpaContainerReader.read(archive);
      final plist = IpaInfoPlistReader.read(archive, container.mainApp!);

      final exceptions = plist.atsExceptions;
      expect(exceptions.hasValue, isTrue);
      final byDomain = {
        for (final e in exceptions.value!) e.domain: e,
      };
      expect(byDomain.keys,
          ['api.example.com', 'legacy.example.com', 'old-tls.example.com']);

      // 允许明文 → 放宽。
      expect(byDomain['legacy.example.com']!.allowsInsecureHttpLoads, isTrue);
      expect(byDomain['legacy.example.com']!.weakensTransport, isTrue);
      // 只写 TLSv1.2 → 不放宽。
      expect(byDomain['api.example.com']!.weakensTransport, isFalse);
      // 降到 TLSv1.0 → 放宽。
      expect(byDomain['old-tls.example.com']!.weakensTransport, isTrue);
    });

    test('有放宽项时报 P3，证据逐域给出具体标志', () {
      final archive = _ipa(infoPlist: _infoPlistWithAts);
      final container = IpaContainerReader.read(archive);
      final plist = IpaInfoPlistReader.read(archive, container.mainApp!);

      final result = IosPrivacyAudit.audit(infoPlist: plist);
      final finding = result.findings
          .where((f) => f.ruleId == 'IOS-ATS-EXCEPTION')
          .toList();
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p3);
      expect(finding.single.messageArgs['count'], 3);
      expect(finding.single.messageArgs['weakened'], 2);
      expect(
        (finding.single.messageArgs['domains'] as List).cast<String>(),
        ['legacy.example.com', 'old-tls.example.com'],
      );
      expect(finding.single.evidence, hasLength(3));
      expect(
        finding.single.evidence.any(
          (e) => e.detail.contains('NSExceptionMinimumTLSVersion=TLSv1.0'),
        ),
        isTrue,
      );
    });

    test('只声明域名、不放宽任何标志 → info 而不是 P3', () {
      final archive = _ipa(infoPlist: _infoPlistAtsBenign);
      final container = IpaContainerReader.read(archive);
      final plist = IpaInfoPlistReader.read(archive, container.mainApp!);

      final result = IosPrivacyAudit.audit(infoPlist: plist);
      final finding =
          result.findings.where((f) => f.ruleId == 'IOS-ATS-EXCEPTION').single;
      // 域名例外本身是合规做法，没放宽就不该给 P3。
      expect(finding.severity, SecuritySeverity.info);
      expect(finding.messageArgs['count'], 1);
      expect(finding.messageArgs['weakened'], 0);
    });
  });

  test('没有隐私清单时仍是 absent（不伪造空清单）', () {
    final archive = _ipa();
    final container = IpaContainerReader.read(archive);
    final plist = IpaInfoPlistReader.read(archive, container.mainApp!);
    expect(plist.privacyInfo.status, FieldStatus.absent);
  });
}
