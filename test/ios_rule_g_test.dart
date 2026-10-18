// iOS「非图片类敏感来源 + 上传」组合规则（`IOS-RULE-G`）。
//
// ## 为什么补这条
//
// Android 侧有 `ANDROID-RULE-G`（通讯录 / 短信 / 录音 → 上传），iOS 侧此前
// 只有 A / B / C / E / F —— 缺的正是这一类：**不需要 OCR，也不需要后台**。
//
// 三条规则各自成立，不要合并：
//
// | 规则 | 条件 |
// |---|---|
// | C | 图片 → OCR → 上传（同一条链） |
// | E | 后台 + 敏感读取 + 上传（三个都要） |
// | G | 通讯录 / 麦克风 / 定位 → 上传（只要两段） |
//
// ## 分级按来源稀有度
//
// 通讯录 / 麦克风 → **P2**：正常应用里「读这些 + 上传」并不常见。
// 只有定位 → **P3**（`IOS-RULE-G-COMMON`）：几乎每个应用都有定位，
// 一律 P2 会让这条规则出现在九成应用上 —— 读者会学会忽略整个面板。

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

/// 把符号拼进可执行文件字节，模拟 Mach-O 里出现这些字符串。
///
/// 扫描器只看字面量，所以不需要真造 Mach-O —— 与本项目其它规则测试
/// （`android_sensitive_source_rule_test.dart`）同一套做法。
SecurityAnalysisResult _auditSymbols(List<String> symbols) =>
    IosPrivacyAudit.audit(
      infoPlist: _plist(),
      executableBytes: const Utf8Encoder().convert(symbols.join('\n')),
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

  group('通讯录 / 麦克风 → P2', () {
    test('contacts + 网络 → IOS-RULE-G，P2', () {
      final result = _auditSymbols(['CNContactStore', 'NSURLSession']);
      final finding = _byId(result, 'IOS-RULE-G');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p2);
      expect(finding.single.confidence, SecurityConfidence.suspected);
      expect(finding.single.messageArgs['sources'], contains('contacts'));
    });

    test('麦克风 + 网络 → IOS-RULE-G，P2', () {
      final result = _auditSymbols(['AVAudioRecorder', 'NSURLSession']);
      final finding = _byId(result, 'IOS-RULE-G');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p2);
      expect(finding.single.messageArgs['sources'], contains('microphone'));
    });

    test('通讯录 + 麦克风 + 网络 → 一条，两种来源都点名', () {
      final result = _auditSymbols([
        'CNContactStore',
        'AVAudioRecorder',
        'NSURLSession',
      ]);
      final finding = _byId(result, 'IOS-RULE-G');
      expect(finding, hasLength(1), reason: '不能按来源拆成两条');
      final sources =
          (finding.single.messageArgs['sources']! as List).cast<String>();
      expect(sources, containsAll(['contacts', 'microphone']));
    });
  });

  group('只有定位 → 降为 P3', () {
    test('location + 网络 → IOS-RULE-G-COMMON，P3', () {
      final result = _auditSymbols(['CLLocationManager', 'NSURLSession']);
      final common = _byId(result, 'IOS-RULE-G-COMMON');
      expect(common, hasLength(1));
      expect(common.single.severity, SecuritySeverity.p3,
          reason: '定位几乎每个应用都有，一律 P2 会让读者学会忽略');
      expect(_byId(result, 'IOS-RULE-G'), isEmpty);
    });

    test('定位 + 通讯录 → 升级回 P2（稀有来源优先）', () {
      final result = _auditSymbols([
        'CLLocationManager',
        'CNContactStore',
        'NSURLSession',
      ]);
      final escalated = _byId(result, 'IOS-RULE-G');
      expect(escalated, hasLength(1));
      expect(escalated.single.severity, SecuritySeverity.p2);
      expect(_byId(result, 'IOS-RULE-G-COMMON'), isEmpty);
      final sources =
          (escalated.single.messageArgs['sources']! as List).cast<String>();
      expect(sources, containsAll(['contacts', 'location']),
          reason: '升级时两种来源都要列出来');
    });
  });

  group('不该报的方向', () {
    test('只有敏感来源、没有网络 → 不报', () {
      expect(_byId(_auditSymbols(['CNContactStore']), 'IOS-RULE-G'), isEmpty);
      expect(_byId(_auditSymbols(['CNContactStore']), 'IOS-RULE-G-COMMON'),
          isEmpty);
    });

    test('只有网络、没有敏感来源 → 不报', () {
      expect(_byId(_auditSymbols(['NSURLSession']), 'IOS-RULE-G'), isEmpty);
    });

    test('相册不算这条的来源（那是规则 C 的领域）', () {
      final result = _auditSymbols(['PHPhotoLibrary', 'NSURLSession']);
      expect(_byId(result, 'IOS-RULE-G'), isEmpty,
          reason: '图片链归规则 C，混进来会让两条规则互相重复');
      expect(_byId(result, 'IOS-RULE-G-COMMON'), isEmpty);
    });
  });

  group('中文界面', () {
    test('P2 正文是中文，且点名来源', () {
      final result = _auditSymbols(['CNContactStore', 'NSURLSession']);
      final text =
          AnalysisReport.findingText(_byId(result, 'IOS-RULE-G').single, t);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue, reason: text);
      expect(text, contains('敏感'));
    });

    test('P3 的正文与 P2 不同（不是同一句降级）', () {
      final escalated = AnalysisReport.findingText(
          _byId(_auditSymbols(['CNContactStore', 'NSURLSession']), 'IOS-RULE-G')
              .single,
          t);
      final common = AnalysisReport.findingText(
          _byId(_auditSymbols(['CLLocationManager', 'NSURLSession']),
                  'IOS-RULE-G-COMMON')
              .single,
          t);
      expect(common, isNot(equals(escalated)),
          reason: 'P3 要说明「这两件事太常见，所以只按低等级报」');
    });
  });
}
