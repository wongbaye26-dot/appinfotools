// iOS 授权项（Entitlements）：`get-task-allow` 与 `aps-environment`。
//
// ## 为什么补这一块
//
// `ios_signature.dart` 早就把描述文件里的 `Entitlements` 解析成了
// `List<IosEntitlement>`，但 `security/` 下**零消费** —— 数据躺在那里没人用。
//
// 其中 `get-task-allow=true` 就是 **iOS 的 `debuggable`**：调试器可以附加
// 进程、读内存、替换代码。Android 侧这条是 P1，iOS 侧此前完全没有对应物，
// 于是同一个包在两侧的结论不对称 —— 用户会以为 iOS 包「更安全」。
//
// ## 为什么只收两条
//
// `keychain-access-groups` / `application-groups` / `associated-domains`
// 在正常应用里极其常见（几乎每个带登录或分享的都有）。一律报会让读者
// 学会忽略整个面板 —— 而「读者忽略」比「漏报一条」更糟。
//
// ## 覆盖率为什么是 notApplicable 而不是 covered
//
// App Store 分发的 IPA **不含 `embedded.mobileprovision`**（授权项在签名里）。
// 那时我们**没看到**授权项，不能说「已覆盖、没问题」，只能标「不适用」。

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

IpaInfoPlist _plist() {
  const plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
</dict></plist>
''';
  final archive = Archive();
  final bytes = const Utf8Encoder().convert(plist);
  archive.addFile(ArchiveFile('$_bundlePath/Info.plist', bytes.length, bytes));
  final macho = const Utf8Encoder().convert('unrelated\n');
  archive.addFile(ArchiveFile('$_bundlePath/Example', macho.length, macho));
  return IpaInfoPlistReader.read(archive, _bundle());
}

IosEntitlement _ent(String key, PlistValue value) =>
    IosEntitlement(key: key, value: value);

SecurityAnalysisResult _audit(
  List<IosEntitlement> entitlements, {
  bool profilePresent = true,
}) =>
    IosPrivacyAudit.audit(
      infoPlist: _plist(),
      executableBytes: const Utf8Encoder().convert('unrelated\n'),
      executablePath: '$_bundlePath/Example',
      entitlements: entitlements,
      provisioningProfilePresent: profilePresent,
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

  group('get-task-allow（iOS 的 debuggable）', () {
    test('= true → 一条 P1/confirmed', () {
      final result = _audit([_ent('get-task-allow', const PlistBoolean(true))]);
      final finding = _byId(result, 'IOS-GET-TASK-ALLOW');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p1);
      expect(finding.single.confidence, SecurityConfidence.confirmed);
      expect(finding.single.evidence.single.location, contains('Entitlements'));
    });

    test('= false → 不报', () {
      final result =
          _audit([_ent('get-task-allow', const PlistBoolean(false))]);
      expect(_byId(result, 'IOS-GET-TASK-ALLOW'), isEmpty);
    });

    test('没有这个键 → 不报', () {
      expect(_byId(_audit(const []), 'IOS-GET-TASK-ALLOW'), isEmpty);
    });

    test('值不是布尔（写成字符串 "true"）→ 不报，不猜', () {
      // 平台写的是布尔；字符串形态不是平台产物，当成「读不懂」更安全。
      final result =
          _audit([_ent('get-task-allow', const PlistString('true'))]);
      expect(_byId(result, 'IOS-GET-TASK-ALLOW'), isEmpty);
    });

    test('中文界面下正文是中文', () {
      final result = _audit([_ent('get-task-allow', const PlistBoolean(true))]);
      final text = AnalysisReport.findingText(
          _byId(result, 'IOS-GET-TASK-ALLOW').single, t);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue, reason: text);
      expect(text, contains('调试'));
    });
  });

  group('aps-environment（推送环境）', () {
    test('= development → 一条 P3', () {
      final result =
          _audit([_ent('aps-environment', const PlistString('development'))]);
      final finding = _byId(result, 'IOS-PUSH-SANDBOX');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p3);
    });

    test('= production → 不报', () {
      final result =
          _audit([_ent('aps-environment', const PlistString('production'))]);
      expect(_byId(result, 'IOS-PUSH-SANDBOX'), isEmpty);
    });
  });

  group('刻意不报的常见授权项', () {
    // 它们在正常应用里极其常见，一律报会让读者学会忽略整个面板。
    test('keychain-access-groups / application-groups 不产出发现项', () {
      final result = _audit([
        _ent(
            'keychain-access-groups', const PlistArray([PlistString('ABCDE')])),
        _ent('com.apple.security.application-groups',
            const PlistArray([PlistString('group.example')])),
        _ent('com.apple.developer.associated-domains',
            const PlistArray([PlistString('applinks:example.com')])),
      ]);
      // 审计总会产出 IOS-SCAN-COVERAGE / IOS-RULE-F 这类「覆盖与边界」的
      // 说明项，所以不能断言 findings 为空 —— 断言「没有因为这几个键多出发现」。
      expect(_byId(result, 'IOS-GET-TASK-ALLOW'), isEmpty);
      expect(_byId(result, 'IOS-PUSH-SANDBOX'), isEmpty);
      final mentions = result.findings
          .expand((f) => f.evidence)
          .map((e) => '${e.location} ${e.detail}')
          .join('\n');
      expect(mentions, isNot(contains('keychain-access-groups')));
      expect(mentions, isNot(contains('application-groups')));
      expect(mentions, isNot(contains('associated-domains')));
    });
  });

  group('覆盖率：没看到 vs 没问题', () {
    test('读到了描述文件 → covered，covered 数是授权项条数', () {
      final entry = _audit([
        _ent('get-task-allow', const PlistBoolean(false)),
        _ent('aps-environment', const PlistString('production')),
      ]).coverage.entry('ios.entitlements');
      expect(entry, isNotNull);
      expect(entry!.status, CoverageStatus.covered);
      expect(entry.covered, 2);
      expect(entry.noteCode, isNull);
    });

    test('没有描述文件（App Store 分发）→ notApplicable，并说明原因', () {
      final entry = _audit(const [], profilePresent: false)
          .coverage
          .entry('ios.entitlements');
      expect(entry!.status, CoverageStatus.notApplicable,
          reason: '「没看到」不能说成「已覆盖、没问题」');
      expect(entry.noteCode, 'ios.entitlements.no_profile');
    });

    test('有描述文件但没有任何授权项 → partial', () {
      final entry = _audit(const [], profilePresent: true)
          .coverage
          .entry('ios.entitlements');
      expect(entry!.status, CoverageStatus.partial);
      expect(entry.noteCode, 'ios.entitlements.empty');
    });

    test('维度名是本地化的，不是机器 id', () {
      final label =
          AnalysisReport.coverageDimensionLabel('ios.entitlements', t);
      expect(label, isNot('ios.entitlements'));
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(label), isTrue,
          reason: '中文界面下应当显示中文维度名：$label');
    });
  });
}
