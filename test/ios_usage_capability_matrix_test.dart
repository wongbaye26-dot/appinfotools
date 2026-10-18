// iOS「声明 vs 实现」的双向对照：通讯录 / 定位 / 麦克风（审计 §10 之后的广度缺口）。
//
// ## 两个方向的意义完全不同
//
// | 方向 | 含义 | 后果 |
// |---|---|---|
// | 有 API、没声明 | 应用会用到受保护资源却没写用途说明 | **运行时崩溃 / 上架被拒** |
// | 有声明、没 API | 声明可能是从模板复制的，实际并不使用 | **过度声明**（隐私标签不准确） |
//
// 相册与相机已有这两条（`IOS-PHOTO-LIBRARY-NO-USAGE` / `IOS-CAMERA-NO-USAGE`
// + `IOS-USAGE-WITHOUT-API`）。本文件把通讯录 / 定位 / 麦克风补齐。
//
// ## 标记只取「录制/读取专用」的类名
//
// 麦克风刻意**不收** `AVAudioSession` —— 播放音频也要用它，收了等于每个音视频
// 应用都会被报。只收 `AVAudioRecorder` / `AVAudioEngine`（录制或处理输入）。
// 这条判断来自上一轮的教训：`AccessibilityService` 匹配到
// `AccessibilityServiceInfo` 造成过误报。

import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const _bundlePath = 'Payload/Example.app';

IosBundle _bundle() => const IosBundle(
      kind: IosBundleKind.mainApp,
      path: _bundlePath,
      name: 'Example.app',
      infoPlistPath: '$_bundlePath/Info.plist',
      infoPlistSize: 512,
      fileCount: 3,
      uncompressedBytes: 4096,
    );

IpaInfoPlist _plist(String usageKeysXml) {
  final plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
  $usageKeysXml
</dict></plist>
''';
  final archive = Archive();
  final bytes = const Utf8Encoder().convert(plist);
  archive.addFile(ArchiveFile('$_bundlePath/Info.plist', bytes.length, bytes));
  final macho = const Utf8Encoder().convert('unrelated\n');
  archive.addFile(ArchiveFile('$_bundlePath/Example', macho.length, macho));
  return IpaInfoPlistReader.read(archive, _bundle());
}

SecurityAnalysisResult _audit(
  String usageKeysXml, {
  String macho = 'unrelated\n',
}) =>
    IosPrivacyAudit.audit(
      infoPlist: _plist(usageKeysXml),
      executableBytes: const Utf8Encoder().convert(macho),
      executablePath: '$_bundlePath/Example',
    );

List<SecurityFinding> _byId(SecurityAnalysisResult r, String ruleId) =>
    r.findings.where((f) => f.ruleId == ruleId).toList();

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('有 API、没声明 → 上架/运行时会出问题', () {
    for (final (api, key, label) in const [
      ('CNContactStore', 'NSContactsUsageDescription', '通讯录'),
      ('CLLocationManager', 'NSLocationWhenInUseUsageDescription', '定位'),
      ('AVAudioRecorder', 'NSMicrophoneUsageDescription', '麦克风'),
    ]) {
      test('$label：有 $api、没 $key → 一条 P2', () {
        final result = _audit('', macho: 'L$api;\n');
        final finding = _byId(result, 'IOS-USAGE-MISSING-FOR-API');
        expect(finding, hasLength(1), reason: '$label 缺失声明是硬缺陷');
        expect(finding.single.severity, SecuritySeverity.p2);
        expect(finding.single.messageArgs['key'], key);
        expect(finding.single.messageArgs['api'], api);
      });

      test('$label：有 $api、也有 $key → 不报', () {
        final result = _audit(
          '<key>$key</key><string>用于业务功能</string>',
          macho: 'L$api;\n',
        );
        expect(_byId(result, 'IOS-USAGE-MISSING-FOR-API'), isEmpty);
      });
    }

    test('定位的三个键都算「有声明」', () {
      for (final key in const [
        'NSLocationWhenInUseUsageDescription',
        'NSLocationAlwaysAndWhenInUseUsageDescription',
        'NSLocationAlwaysUsageDescription',
      ]) {
        final result = _audit(
          '<key>$key</key><string>x</string>',
          macho: 'LCLLocationManager;\n',
        );
        expect(_byId(result, 'IOS-USAGE-MISSING-FOR-API'), isEmpty,
            reason: '$key 应当被认作定位的用途说明');
      }
    });

    test('旧版通讯录 API（ABAddressBook）也算', () {
      final result = _audit('', macho: 'LABAddressBook;\n');
      expect(_byId(result, 'IOS-USAGE-MISSING-FOR-API'), hasLength(1));
    });
  });

  group('有声明、没 API → 过度声明（反向，info/unknown）', () {
    for (final (key, label) in const [
      ('NSContactsUsageDescription', '通讯录'),
      ('NSMicrophoneUsageDescription', '麦克风'),
    ]) {
      test('$label：只有声明、没有 API → 一条 info/unknown', () {
        final result = _audit(
          '<key>$key</key><string>用于业务功能</string>',
          macho: 'unrelated\n',
        );
        final finding = _byId(result, 'IOS-USAGE-WITHOUT-API');
        expect(finding, hasLength(1), reason: '$label 声明了却没用，值得看一眼');
        expect(finding.single.severity, SecuritySeverity.info);
        expect(finding.single.confidence, SecurityConfidence.unknown);
        expect(finding.single.messageArgs['key'], key);
      });
    }

    test('定位：只有声明、没有 CLLocationManager → 也报', () {
      final result = _audit(
        '<key>NSLocationWhenInUseUsageDescription</key><string>x</string>',
        macho: 'unrelated\n',
      );
      final finding = _byId(result, 'IOS-USAGE-WITHOUT-API');
      expect(finding, hasLength(1));
      expect(finding.single.messageArgs['key'],
          'NSLocationWhenInUseUsageDescription');
    });
  });

  group('两个方向不混', () {
    test('有 API 没声明 → 只报缺失，不报过度声明', () {
      final result = _audit('', macho: 'LCNContactStore;\n');
      expect(_byId(result, 'IOS-USAGE-MISSING-FOR-API'), hasLength(1));
      expect(_byId(result, 'IOS-USAGE-WITHOUT-API'), isEmpty);
    });

    test('有声明没 API → 只报过度声明，不报缺失', () {
      final result = _audit(
        '<key>NSContactsUsageDescription</key><string>x</string>',
        macho: 'unrelated\n',
      );
      expect(_byId(result, 'IOS-USAGE-WITHOUT-API'), hasLength(1));
      expect(_byId(result, 'IOS-USAGE-MISSING-FOR-API'), isEmpty);
    });

    test('`AVAudioSession` 单独出现**不算**麦克风（播放也要用）', () {
      final result = _audit('', macho: 'LAVAudioSession;\n');
      expect(_byId(result, 'IOS-USAGE-MISSING-FOR-API'), isEmpty,
          reason: '音频会话是播放与录制共用的，收了会误伤每个音视频应用');
    });
  });

  group('措辞', () {
    test('缺失声明的正文是中文，且说清「会出问题」而不是「有风险」', () {
      final result = _audit('', macho: 'LCNContactStore;\n');
      final text = AnalysisReport.findingText(
          _byId(result, 'IOS-USAGE-MISSING-FOR-API').single, t);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue,
          reason: '中文界面下不能显示英文回退：$text');
      expect(text, contains('NSContactsUsageDescription'));
      expect(text, isNot(contains('恶意')));
    });
  });
}
