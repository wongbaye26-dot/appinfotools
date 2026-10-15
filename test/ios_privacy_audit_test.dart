// iOS 隐私审计测试（V1.1 规格 4.1–4.4 与第五章规则）。
//
// 重点同样是措辞与状态区分：
// - PHPicker（用户主动选择）与 PhotoKit（完整库）必须分开判定；
// - 隐私清单是声明性材料，报告不得说成「已证实收集」；
// - 有 API 没用途说明才升级；只有用途说明不判「已访问」。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
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

/// 用 XML plist 造一个 IPA 归档：[Info.plist] + [xcprivacy] + Mach-O。
Archive _archive({
  required String infoPlist,
  String? xcprivacy,
  String macho = '',
}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = const Utf8Encoder().convert(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('$_bundlePath/Info.plist', infoPlist);
  if (xcprivacy != null) {
    add('$_bundlePath/PrivacyInfo.xcprivacy', xcprivacy);
  }
  final machoBytes = const Utf8Encoder().convert(macho);
  archive.addFile(
      ArchiveFile('$_bundlePath/Example', machoBytes.length, machoBytes));
  return archive;
}

IpaInfoPlist _plist({
  required String infoPlist,
  String? xcprivacy,
  String macho = '',
}) {
  return IpaInfoPlistReader.read(
    _archive(infoPlist: infoPlist, xcprivacy: xcprivacy, macho: macho),
    _bundle(),
  );
}

SecurityFinding? _byId(SecurityAnalysisResult r, String ruleId) {
  for (final f in r.findings) {
    if (f.ruleId == ruleId) return f;
  }
  return null;
}

const _usageOnlyPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
  <key>NSPhotoLibraryUsageDescription</key><string>用于上传头像</string>
  <key>NSCameraUsageDescription</key><string>用于拍照识别</string>
</dict></plist>
''';

void main() {
  group('Info.plist 新字段提取', () {
    test('用途说明键被提取，含原文', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      expect(plist.privacyUsageDescriptions.hasValue, isTrue);
      expect(
          plist.privacyUsageDescriptions.value!
              .containsKey('NSPhotoLibraryUsageDescription'),
          isTrue);
      expect(
          plist.privacyUsageDescriptions
              .value!['NSPhotoLibraryUsageDescription'],
          '用于上传头像');
    });

    test('没有用途说明时是 absent，而不是空 map', () {
      final plist = _plist(infoPlist: '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
</dict></plist>
''');
      expect(plist.privacyUsageDescriptions.status, FieldStatus.absent);
    });

    test('ATS 开关三态：未声明 / true / false', () {
      final base = '<?xml version="1.0" encoding="UTF-8"?>'
          '<plist version="1.0"><dict>{}</dict></plist>';
      expect(_plist(infoPlist: base).allowsArbitraryLoads.status,
          FieldStatus.absent);

      final on = _plist(
          infoPlist: base.replaceFirst(
              '{}',
              '<key>NSAppTransportSecurity</key>'
                  '<dict><key>NSAllowsArbitraryLoads</key><true/></dict>'));
      expect(on.allowsArbitraryLoads.hasValue, isTrue);
      expect(on.allowsArbitraryLoads.value, isTrue);

      final off = _plist(
          infoPlist: base.replaceFirst(
              '{}',
              '<key>NSAppTransportSecurity</key>'
                  '<dict><key>NSAllowsArbitraryLoads</key><false/></dict>'));
      expect(off.allowsArbitraryLoads.value, isFalse);
    });

    test('隐私清单被解析：跟踪声明与收集类型', () {
      final plist = _plist(
        infoPlist: _usageOnlyPlist,
        xcprivacy: '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>NSPrivacyTracking</key><true/>
  <key>NSPrivacyTrackingDomains</key>
  <array><string>ads.example.com</string></array>
  <key>NSPrivacyCollectedDataTypes</key>
  <array>
    <dict>
      <key>NSPrivacyCollectedDataType</key>
      <string>NSPrivacyCollectedDataTypePhotos</string>
      <key>NSPrivacyCollectedDataTypePurposes</key>
      <array><string>App Functionality</string></array>
    </dict>
  </array>
</dict></plist>
''',
      );

      expect(plist.privacyInfo.hasValue, isTrue);
      final info = plist.privacyInfo.value!;
      expect(info.tracking, isTrue);
      expect(info.trackingDomains, ['ads.example.com']);
      expect(info.collectedDataTypes, ['NSPrivacyCollectedDataTypePhotos']);
    });

    test('没有隐私清单是 absent 且不算异常', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      expect(plist.privacyInfo.status, FieldStatus.absent);
    });
  });

  group('照片访问：完整库与用户主动选择分开', () {
    test('PHPicker 线索：INFO，且说明不需要完整授权', () {
      final plist = _plist(
        infoPlist: '<?xml version="1.0" encoding="UTF-8"?>'
            '<plist version="1.0"><dict></dict></plist>',
        macho: '__TtC11ExampleApp22PhotoPickerController\n'
            'PHPickerViewController\n',
      );

      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes:
            const Utf8Encoder().convert('PHPickerViewController\n'),
      );

      final picker = _byId(result, 'IOS-PHOTO-PICKER');
      expect(picker, isNotNull);
      expect(picker!.severity, SecuritySeverity.info);
      // 迁移后断言**本地化正文**，而不是英文回退（见 B11 第一批）。
      expect(
        AnalysisReport.findingText(picker, t),
        contains('does not require'),
      );
      // 只见到选择器时不得推出完整库访问结论。
      expect(_byId(result, 'IOS-PHOTO-LIBRARY'), isNull);
      expect(_byId(result, 'IOS-PHOTO-LIBRARY-NO-USAGE'), isNull);
    });

    test('PhotoKit 线索但缺少用途说明 → P2', () {
      final plist = _plist(
          infoPlist: '<?xml version="1.0" encoding="UTF-8"?>'
              '<plist version="1.0"><dict></dict></plist>');

      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('PHPhotoLibrary\n'),
      );

      final finding = _byId(result, 'IOS-PHOTO-LIBRARY-NO-USAGE');
      expect(finding, isNotNull);
      expect(finding!.severity, SecuritySeverity.p2);
      expect(finding.finding, contains('NSPhotoLibraryUsageDescription'));
      expect(
        finding.evidence
            .any((e) => e.source == SecurityEvidenceSource.machoSymbol),
        isTrue,
      );
    });

    test('PhotoKit 线索 + 用途说明 → P3，不升级', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);

      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('PHPhotoLibrary\n'),
      );

      final finding = _byId(result, 'IOS-PHOTO-LIBRARY');
      expect(finding, isNotNull);
      expect(finding!.severity, SecuritySeverity.p3);
      expect(_byId(result, 'IOS-PHOTO-LIBRARY-NO-USAGE'), isNull);
    });

    test('有用途说明但没有 API 线索：不得声称已访问相册', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('unrelated\n'),
      );

      // 只有「声明了什么」的事实记录。
      final usageFindings =
          result.findings.where((f) => f.ruleId == 'IOS-USAGE-DESCRIPTION');
      expect(usageFindings, hasLength(2));
      for (final f in usageFindings) {
        expect(f.severity, SecuritySeverity.info);
        // 迁移后要看**本地化后的正文**，而不是英文回退。
        expect(AnalysisReport.findingText(f, t), contains('does not prove'));
      }
      expect(_byId(result, 'IOS-PHOTO-LIBRARY-NO-USAGE'), isNull);
    });
  });

  group('OCR 与回传', () {
    test('OCR + 图像输入 + 网络 → P1 疑似链路', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert(
          'VNRecognizeTextRequest\nPHPickerViewController\nNSURLSession\n',
        ),
      );

      final ruleC = _byId(result, 'IOS-RULE-C');
      expect(ruleC, isNotNull);
      expect(ruleC!.severity, SecuritySeverity.p1);
      expect(ruleC.confidence, SecurityConfidence.suspected);
      expect(
        AnalysisReport.relationshipText(ruleC, t),
        contains('is not proven'),
      );
      expect(ruleC.dataSink, contains('网络'));
      expect(result.highestRiskFinding!.ruleId, 'IOS-RULE-C');
    });

    test('仅 OCR：能力记录，不判恶意', () {
      final plist = _plist(
          infoPlist: '<?xml version="1.0" encoding="UTF-8"?>'
              '<plist version="1.0"><dict></dict></plist>');
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert(
          'VNRecognizeTextRequest\nVNImageRequestHandler\n',
        ),
      );

      final ocr = _byId(result, 'IOS-OCR-CAPABILITY');
      expect(ocr, isNotNull);
      expect(ocr!.confidence, SecurityConfidence.independentCapability);
      expect(
        AnalysisReport.findingText(ocr, t),
        contains('not a malicious verdict'),
      );
      expect(_byId(result, 'IOS-RULE-C'), isNull);
    });

    test('规则 F：未发现网络特征时显式输出「未发现」', () {
      final plist = _plist(
          infoPlist: '<?xml version="1.0" encoding="UTF-8"?>'
              '<plist version="1.0"><dict></dict></plist>');
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('nothing here\n'),
      );

      final ruleF = _byId(result, 'IOS-RULE-F');
      expect(ruleF, isNotNull);
      final ruleFText = AnalysisReport.findingText(ruleF!, t);
      expect(ruleFText, contains('No network upload characteristics'));
      expect(ruleFText, contains('does not mean'));
      expect(ruleFText, isNot(contains('is safe')));
    });
  });

  group('ATS 与隐私清单措辞', () {
    test('ATS 放行 + 敏感线索 → P1', () {
      final plist = _plist(infoPlist: '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
''');
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes:
            const Utf8Encoder().convert('VNRecognizeTextRequest\n'),
      );

      final escalated = _byId(result, 'IOS-RULE-D-ESCALATED');
      expect(escalated, isNotNull);
      expect(escalated!.severity, SecuritySeverity.p1);
    });

    test('隐私清单发现必须标注为声明性材料', () {
      final plist = _plist(
        infoPlist: '<?xml version="1.0" encoding="UTF-8"?>'
            '<plist version="1.0"><dict></dict></plist>',
        xcprivacy: '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>NSPrivacyTracking</key><false/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array><dict>
    <key>NSPrivacyCollectedDataType</key>
    <string>NSPrivacyCollectedDataTypeDeviceID</string>
  </dict></array>
</dict></plist>
''',
      );
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('unrelated\n'),
      );

      final info = _byId(result, 'IOS-PRIVACY-INFO');
      expect(info, isNotNull);
      final infoText = AnalysisReport.findingText(info!, t);
      expect(infoText, contains('declarative material'));
      expect(infoText, contains('does not equal'));
      expect(info.evidence.single.source, SecurityEvidenceSource.privacyInfo);
      expect(info.evidence.single.detail,
          contains('NSPrivacyCollectedDataTypeDeviceID'));
      // 隐私清单不得触发跟踪告警（NSPrivacyTracking=false）。
      expect(_byId(result, 'IOS-PRIVACY-TRACKING'), isNull);
    });
  });

  group('覆盖不足', () {
    test('读不到可执行文件时记录覆盖不足，「未发现」置信度降级', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(infoPlist: plist);

      expect(result.hasCoverageGaps, isTrue);
      expect(
        // 措辞在阶段 5b 改成「任何」—— 扫描范围不再只有主应用。
        result.limitations.any((l) => l.code == 'ios.executable.none_readable'),
        isTrue,
        reason: '实际局限：${result.limitations}',
      );
      expect(
          _byId(result, 'IOS-RULE-F')!.confidence, SecurityConfidence.unknown);
    });
  });
  // ---- 阶段 5 新增：UIBackgroundModes / CFBundleURLTypes ----
  group('Info.plist：后台模式与 URL scheme', () {
    const plistWithBoth = """
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
  <key>UIBackgroundModes</key>
  <array><string>fetch</string><string>remote-notification</string></array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.example.app</string>
      <key>CFBundleURLSchemes</key>
      <array><string>example</string><string>ex2</string></array>
    </dict>
    <dict>
      <key>CFBundleURLName</key><string>com.example.other</string>
    </dict>
  </array>
</dict></plist>
""";

    test('UIBackgroundModes 被提取为字符串列表', () {
      final plist = _plist(infoPlist: plistWithBoth);

      expect(plist.backgroundModes.hasValue, isTrue);
      expect(plist.backgroundModes.value, ['fetch', 'remote-notification']);
    });

    test('CFBundleURLTypes 只取 scheme，形状不对的条目如实跳过', () {
      final plist = _plist(infoPlist: plistWithBoth);

      expect(plist.urlSchemes.hasValue, isTrue);
      expect(
        plist.urlSchemes.value,
        ['example', 'ex2'],
        reason: '第二个 dict 没有 CFBundleURLSchemes，应当被跳过而不是猜',
      );
    });

    test('没有注册 scheme 时是 absent（文件里确实没有），不是空列表', () {
      final plist = _plist(infoPlist: """
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
</dict></plist>
""");

      expect(plist.urlSchemes.status, FieldStatus.absent);
      expect(plist.backgroundModes.status, FieldStatus.absent);
    });

    test('CFBundleURLTypes 类型不符时记 wrongType，不猜', () {
      final plist = _plist(infoPlist: """
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleURLTypes</key><string>not-an-array</string>
</dict></plist>
""");

      expect(plist.urlSchemes.status, FieldStatus.wrongType);
      expect(plist.urlSchemes.diagnostic, contains('array'));
    });

    test('注册了 scheme 时记录为事实，并写明「入口存在 ≠ 入口安全」', () {
      final plist = _plist(infoPlist: plistWithBoth);
      final result = IosPrivacyAudit.audit(infoPlist: plist);

      final finding = _byId(result, 'IOS-URL-SCHEMES');
      expect(finding, isNotNull);
      expect(finding!.severity, SecuritySeverity.info);
      final schemeText = AnalysisReport.findingText(finding, t);
      expect(schemeText, contains('example'));
      expect(schemeText, contains('external callers'));
      expect(
        AnalysisReport.limitationText(finding, t),
        contains('no disassembly'),
      );
    });
  });

  group('规则 A：完整库访问但看不到更克制的路径', () {
    test('只有 PhotoKit、没有选择器 → P2 待复核', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('PHPhotoLibrary\n'),
      );

      final ruleA = _byId(result, 'IOS-RULE-A');
      expect(ruleA, isNotNull);
      expect(ruleA!.severity, SecuritySeverity.p2);
      expect(ruleA.confidence, SecurityConfidence.suspected);
      expect(
        AnalysisReport.findingText(ruleA, t),
        contains('more restrained path'),
      );
      expect(
        AnalysisReport.relationshipText(ruleA, t),
        contains('static inference'),
      );
      expect(
        AnalysisReport.recommendationText(ruleA, t),
        contains('not a malicious verdict'),
      );
    });

    test('同时有选择器时不触发规则 A', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert(
          'PHPhotoLibrary\nPHPickerViewController\n',
        ),
      );

      expect(
        _byId(result, 'IOS-RULE-A'),
        isNull,
        reason: '看到了更克制的路径，就不该报「缺少替代方案」',
      );
    });
  });

  group('规则 B：图像输入 + 文字识别', () {
    test('相册 + OCR → P2，且写明同现未被证实', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert(
          'PHPickerViewController\nVNRecognizeTextRequest\n',
        ),
      );

      final ruleB = _byId(result, 'IOS-RULE-B');
      expect(ruleB, isNotNull);
      expect(ruleB!.severity, SecuritySeverity.p2);
      expect(ruleB.confidence, SecurityConfidence.suspected);
      expect(
        AnalysisReport.relationshipText(ruleB, t),
        contains('not proven'),
      );
      expect(
        AnalysisReport.findingText(ruleB, t),
        contains('may correspond'),
      );
    });

    test('只有 OCR 时不触发规则 B', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes:
            const Utf8Encoder().convert('VNRecognizeTextRequest\n'),
      );

      expect(_byId(result, 'IOS-RULE-B'), isNull);
    });
  });

  group('规则 E：后台 + 敏感读取 + 回传', () {
    const backgroundPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
  <key>NSPhotoLibraryUsageDescription</key><string>用于上传头像</string>
  <key>UIBackgroundModes</key>
  <array><string>fetch</string></array>
</dict></plist>
""";

    test('三段同现 → P2，且写明没有任何一跳被证实', () {
      final plist = _plist(infoPlist: backgroundPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert(
          'PHPhotoLibrary\nNSURLSession\n',
        ),
      );

      final ruleE = _byId(result, 'IOS-RULE-E');
      expect(ruleE, isNotNull);
      expect(ruleE!.severity, SecuritySeverity.p2);
      expect(ruleE.confidence, SecurityConfidence.suspected);
      expect(ruleE.dataSource, contains('相册'));
      expect(ruleE.dataSink, contains('网络'));
      expect(
        AnalysisReport.relationshipText(ruleE, t),
        contains('not a single hop is proven'),
      );
      expect(
        AnalysisReport.limitationText(ruleE, t),
        contains('declaration'),
      );
      expect(
        ruleE.evidence.any((e) =>
            e.source == SecurityEvidenceSource.infoPlist &&
            e.detail.contains('fetch')),
        isTrue,
        reason: '证据里要能看到是哪个后台模式',
      );
    });

    test('没有后台模式时不触发规则 E', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert(
          'PHPhotoLibrary\nNSURLSession\n',
        ),
      );

      expect(_byId(result, 'IOS-RULE-E'), isNull);
    });

    test('有后台模式但没有敏感读取时不触发', () {
      final plist = _plist(infoPlist: backgroundPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('NSURLSession\n'),
      );

      expect(_byId(result, 'IOS-RULE-E'), isNull);
    });
  });
  // ---- 阶段 5b：按可执行文件的覆盖统计 ----
  group('扫描覆盖率：覆盖了 N 个中的 M 个', () {
    test('只有主可执行文件时覆盖率是 1/1', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes:
            const Utf8Encoder().convert('PHPickerViewController\n'),
        executablePath: 'Payload/Example.app/Example',
      );

      final coverage = _byId(result, 'IOS-SCAN-COVERAGE');
      expect(coverage, isNotNull);
      expect(coverage!.severity, SecuritySeverity.info);
      final covText = AnalysisReport.findingText(coverage, t);
      expect(covText, contains('covered 1 of 1 executables'));
      expect(covText, contains('Every executable was covered'));
    });

    test('嵌套可执行文件的字节参与扫描，并成为线索来源', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('nothing here\n'),
        executablePath: 'Payload/Example.app/Example',
        nestedExecutables: [
          IosNestedExecutableInput(
            path: 'Payload/Example.app/PlugIns/Scan.appex/Scan',
            bundlePath: 'Payload/Example.app/PlugIns/Scan.appex',
            kind: IosBundleKind.appExtension,
            bytes: const Utf8Encoder().convert(
              'VNRecognizeTextRequest\nNSURLSession\nPHPickerViewController\n',
            ),
          ),
        ],
      );

      final coverage = _byId(result, 'IOS-SCAN-COVERAGE')!;
      expect(
        AnalysisReport.findingText(coverage, t),
        contains('covered 2 of 2 executables'),
      );

      // 线索要能指出**来自哪个文件** —— 否则「扩展里有 OCR」无从核对。
      final ocr = _byId(result, 'IOS-OCR-CAPABILITY');
      expect(ocr, isNotNull, reason: '扩展里的 OCR 线索应当被发现');
      expect(
        ocr!.evidence.any((e) => e.location.contains('Scan.appex')),
        isTrue,
        reason: '实际证据：${ocr.evidence.map((e) => e.location).toList()}',
      );
    });

    test('拿不到字节的嵌套可执行文件计入「未覆盖」，不虚高覆盖率', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(
        infoPlist: plist,
        executableBytes: const Utf8Encoder().convert('nothing\n'),
        executablePath: 'Payload/Example.app/Example',
        nestedExecutables: const [
          IosNestedExecutableInput(
            path: 'Payload/Example.app/PlugIns/Big.appex/Big',
            bundlePath: 'Payload/Example.app/PlugIns/Big.appex',
            kind: IosBundleKind.appExtension,
            failure: 'bytes not retained (nested budget reached)',
          ),
        ],
      );

      final coverage = _byId(result, 'IOS-SCAN-COVERAGE')!;
      final gapText = AnalysisReport.findingText(coverage, t);
      expect(gapText, contains('covered 1 of 2 executables'));
      expect(gapText, contains('Executables not covered: 1'));
      expect(
        coverage.evidence.any((e) => e.detail == 'NOT scanned'),
        isTrue,
        reason: '未覆盖的要逐条列出，不能只报覆盖到的',
      );
      expect(
        result.limitations.any((l) => l.code == 'ios.executable.unscanned'),
        isTrue,
      );
      expect(
        result.limitations.any((l) => l.code == 'ios.executable.unscanned'),
        isTrue,
        reason: '「没查到」与「没有」结论相反',
      );
    });

    test('一个可执行文件都读不到时不报覆盖率，只报覆盖不足', () {
      final plist = _plist(infoPlist: _usageOnlyPlist);
      final result = IosPrivacyAudit.audit(infoPlist: plist);

      expect(_byId(result, 'IOS-SCAN-COVERAGE'), isNull);
      expect(result.hasCoverageGaps, isTrue);
    });
  });
  // iOS-A：嵌套 bundle 的用途说明。
  //
  // 扩展常常正是处理照片与 OCR 的地方，而主应用的 Info.plist 里可能
  // 一条相册用途都没有。只看主应用，这类声明完全看不见。
  group('嵌套 bundle 的用途说明（iOS-A）', () {
    const emptyPlist = '<?xml version="1.0" encoding="UTF-8"?>'
        '<plist version="1.0"><dict></dict></plist>';

    const cameraPlist = '<?xml version="1.0" encoding="UTF-8"?>'
        '<plist version="1.0"><dict>'
        '<key>NSCameraUsageDescription</key><string>拍照</string>'
        '</dict></plist>';

    test('扩展声明的用途说明成为独立 finding，并指向那个 bundle', () {
      final result = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: emptyPlist),
        nestedExecutables: const [
          IosNestedExecutableInput(
            path: 'Payload/Example.app/PlugIns/Photo.appex/Photo',
            bundlePath: 'Payload/Example.app/PlugIns/Photo.appex',
            kind: IosBundleKind.appExtension,
            usageDescriptions: {
              'NSPhotoLibraryUsageDescription': '用于选择照片',
            },
          ),
        ],
      );

      final finding = _byId(result, 'IOS-NESTED-USAGE-DESCRIPTION');
      expect(finding, isNotNull, reason: '扩展的用途说明必须被检出');
      expect(finding!.evidence.single.location,
          contains('PlugIns/Photo.appex/Info.plist'));
      expect(finding.evidence.single.location,
          contains('NSPhotoLibraryUsageDescription'));
      // 主应用一条用途说明都没有 —— 结论不该被嵌套 bundle 污染。
      expect(_byId(result, 'IOS-USAGE-DESCRIPTION'), isNull);
    });

    test('主应用与扩展的用途说明各自成条，互不覆盖', () {
      final result = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: cameraPlist),
        nestedExecutables: const [
          IosNestedExecutableInput(
            path: 'Payload/Example.app/PlugIns/X.appex/X',
            bundlePath: 'Payload/Example.app/PlugIns/X.appex',
            kind: IosBundleKind.appExtension,
            usageDescriptions: {
              'NSPhotoLibraryUsageDescription': '选择照片',
            },
          ),
        ],
      );

      final main = _byId(result, 'IOS-USAGE-DESCRIPTION');
      final nested = _byId(result, 'IOS-NESTED-USAGE-DESCRIPTION');
      expect(main, isNotNull);
      expect(nested, isNotNull);
      expect(
          main!.evidence.single.location, contains('NSCameraUsageDescription'));
      expect(main.evidence.single.location, isNot(contains('PlugIns/X.appex')));
      expect(nested!.evidence.single.location, contains('PlugIns/X.appex'));
    });

    test('嵌套 bundle 没读到 Info.plist 时记进局限，不静默', () {
      final result = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: emptyPlist),
        nestedExecutables: const [
          IosNestedExecutableInput(
            path: 'Payload/Example.app/PlugIns/X.appex/X',
            bundlePath: 'Payload/Example.app/PlugIns/X.appex',
            kind: IosBundleKind.appExtension,
            // usageDescriptions 刻意不传 = 没读到
          ),
        ],
      );

      expect(
          result.limitations.any((l) => l.code == 'ios.nested_plist.missing'),
          isTrue,
          reason: '「没读到」与「没有」必须分开');
    });

    test('没有嵌套 bundle 时不产生这类 finding（回归）', () {
      final result = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: emptyPlist),
      );
      expect(_byId(result, 'IOS-NESTED-USAGE-DESCRIPTION'), isNull);
    });
  });
  // B11 第一批：发现项文案本地化（机制 + iOS 用途说明两条）。
  //
  // 迁移是**增量**的：没填 messageCode 的发现项继续按原文渲染，
  // 因此不会出现「英文界面下一半中文一半英文」的中间态。
  group('发现项文案本地化（B11 第一批）', () {
    const cjk = r'[\u4e00-\u9fff]';

    const photoPlist = '<?xml version="1.0" encoding="UTF-8"?>'
        '<plist version="1.0"><dict>'
        '<key>NSPhotoLibraryUsageDescription</key><string>选择照片</string>'
        '</dict></plist>';

    test('已迁移的发现项带 messageCode，且英文回退里没有中文', () {
      final result =
          IosPrivacyAudit.audit(infoPlist: _plist(infoPlist: photoPlist));
      final finding = _byId(result, 'IOS-USAGE-DESCRIPTION')!;

      expect(finding.messageCode, 'ios.usage_description');
      expect(finding.messageArgs['key'], 'NSPhotoLibraryUsageDescription');
      expect(RegExp(cjk).hasMatch(finding.finding), isFalse,
          reason: '英文回退里不该有中文：${finding.finding}');

      expect(finding.recommendationCode, 'ios.usage_description.cross_check');
      expect(RegExp(cjk).hasMatch(finding.recommendation), isFalse,
          reason: '建议也要一起迁移，不能一句英文一句中文');
    });

    test('findingText 认得 code 时给出本地化文案，且不留占位符', () {
      final result =
          IosPrivacyAudit.audit(infoPlist: _plist(infoPlist: photoPlist));
      final finding = _byId(result, 'IOS-USAGE-DESCRIPTION')!;

      final text = AnalysisReport.findingText(finding, t);
      expect(text, contains('NSPhotoLibraryUsageDescription'));
      expect(text, isNot(contains('{')));
      expect(AnalysisReport.recommendationText(finding, t), isNotEmpty);
    });

    test('未知 code 回退到原文，不显示空白', () {
      const finding = SecurityFinding(
        ruleId: 'X',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.unknown,
        finding: 'fallback text',
        evidence: [],
        recommendation: 'fallback recommendation',
        messageCode: 'ios.future.something_new',
      );
      expect(AnalysisReport.findingText(finding, t), 'fallback text');
    });

    test('未迁移的发现项原样返回（迁移是增量的）', () {
      const finding = SecurityFinding(
        ruleId: 'X',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.unknown,
        finding: '尚未迁移的原文',
        evidence: [],
        recommendation: '尚未迁移的建议',
      );
      expect(AnalysisReport.findingText(finding, t), '尚未迁移的原文');
      expect(AnalysisReport.recommendationText(finding, t), '尚未迁移的建议');
    });
  });

  // B11 第二批：iOS 侧 5 条**无参数**的发现项连同各自的建议一起迁移。
  //
  // 选「无参数」的一批是因为它们不需要把分支/拼接挪进参数，是纯机械替换；
  // 带参数的（URL-SCHEMES / SCAN-COVERAGE / RULE-B / RULE-E）留到下一批。
  //
  // 注意本组断言的是**本地化正文**而不是英文回退：迁移的目的就是让
  // 「英文回退」不再是用户看到的东西。
  group('发现项文案本地化（B11 第二批：iOS 无参数 5 条）', () {
    const cjk = r'[\u4e00-\u9fff]';

    const emptyPlist = '<?xml version="1.0" encoding="UTF-8"?>'
        '<plist version="1.0"><dict></dict></plist>';

    /// 每条发现项应有的 (ruleId, messageCode, recommendationCode)。
    const migrated = [
      (
        rule: 'IOS-PHOTO-PICKER',
        message: 'ios.photo_picker',
        recommendation: 'ios.photo_picker.confirm_input_path',
      ),
      (
        rule: 'IOS-RULE-A',
        message: 'ios.rule_a',
        recommendation: 'ios.rule_a.manual_review',
      ),
      (
        rule: 'IOS-OCR-CAPABILITY',
        message: 'ios.ocr_capability',
        recommendation: 'ios.ocr_capability.confirm_input_and_sink',
      ),
      (
        rule: 'IOS-RULE-C',
        message: 'ios.rule_c',
        recommendation: 'ios.rule_c.manual_review',
      ),
      (
        rule: 'IOS-RULE-F',
        message: 'ios.rule_f',
        recommendation: 'ios.rule_f.runtime_traffic',
      ),
    ];

    /// 触发这 5 条规则的真实输入。
    ///
    /// 拆成两轮是因为规则 A 要求「有 PhotoKit 且**没有**选择器」，
    /// 而 PHOTO-PICKER 要求「有选择器」—— 同一次运行里两者互斥。
    /// 规则 F 要求「没有网络线索」，因此挂在没有 NSURLSession 的那一轮。
    SecurityAnalysisResult run({required String macho}) =>
        IosPrivacyAudit.audit(
          infoPlist: _plist(infoPlist: emptyPlist),
          executableBytes: const Utf8Encoder().convert(macho),
        );

    test('引擎真的把 code 挂上去了（否则等于没迁）', () {
      // 有 PhotoKit、有 OCR、有网络 → A / OCR / C；选择器缺席。
      final withLibrary = run(
        macho: 'PHPhotoLibrary\nVNRecognizeTextRequest\nNSURLSession\n',
      );
      // 有选择器、无网络 → PHOTO-PICKER / RULE-F。
      final withPicker = run(macho: 'PHPickerViewController\n');

      for (final m in migrated) {
        final finding = _byId(withLibrary, m.rule) ?? _byId(withPicker, m.rule);
        expect(finding, isNotNull, reason: '测试输入没有触发 ${m.rule}');
        expect(finding!.messageCode, m.message);
        expect(finding.recommendationCode, m.recommendation);

        // 英文回退里不该再有中文 —— 否则英文界面照样显示中文。
        expect(
          RegExp(cjk).hasMatch(finding.finding),
          isFalse,
          reason: '${m.rule} 的英文回退里还有中文：${finding.finding}',
        );
        expect(
          RegExp(cjk).hasMatch(finding.recommendation),
          isFalse,
          reason: '${m.rule} 的建议没有一起迁移：${finding.recommendation}',
        );
      }
    });

    test('四个维护中的语言包都能取到文案，且不留占位符', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await LocaleSettings.setLocaleRaw(locale);
        for (final m in migrated) {
          final finding = SecurityFinding(
            ruleId: m.rule,
            platform: SecurityPlatform.ios,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.unknown,
            finding: 'fallback finding',
            evidence: const [],
            recommendation: 'fallback recommendation',
            messageCode: m.message,
            recommendationCode: m.recommendation,
          );

          final text = AnalysisReport.findingText(finding, t);
          expect(text, isNot('fallback finding'),
              reason: '$locale 下 ${m.message} 没取到本地化文案');
          // 占位符没被替换会渲染成 `{...}`；本批 5 条都没有参数，
          // 出现花括号说明键被写成了带参数的形态。
          expect(text, isNot(contains('{')));
          expect(text, isNot(contains('}')));

          final rec = AnalysisReport.recommendationText(finding, t);
          expect(rec, isNot('fallback recommendation'),
              reason: '$locale 下 ${m.recommendation} 没取到本地化文案');
          expect(rec, isNot(contains('{')));
        }
      }
    });

    test('中文语言包里是中文，英文语言包里没有中文', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      final finding = SecurityFinding(
        ruleId: 'IOS-RULE-C',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p1,
        confidence: SecurityConfidence.suspected,
        finding: 'fallback finding',
        evidence: const [],
        recommendation: 'fallback recommendation',
        messageCode: 'ios.rule_c',
        recommendationCode: 'ios.rule_c.manual_review',
      );

      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.findingText(finding, t);
      expect(RegExp(cjk).hasMatch(zh), isTrue, reason: 'zh-CN 应当是中文：$zh');
      expect(zh, contains('敏感数据外传'));

      await LocaleSettings.setLocaleRaw('en');
      final en = AnalysisReport.findingText(finding, t);
      expect(RegExp(cjk).hasMatch(en), isFalse, reason: 'en 不该有中文：$en');
      expect(en, contains('suspected path'));
    });
  });

  // B11 第三批：iOS 侧剩余 9 处，含带参数的与 ruleId 是三元的。
  //
  // RULE-B / RULE-E 的参数是**来源 id 列表**：引擎不依赖 slang，产不出中文，
  // 也不能自己拼一句中文塞进占位符（那等于把没本地化的句子藏进参数里）。
  // 所以只传 id，名字与分隔符由 `AnalysisReport.findingText` 按语言包组装 ——
  // 与 `coverageDimensionLabel` 同一思路。
  group('发现项文案本地化（B11 第三批：iOS 剩余 9 处）', () {
    const cjk = r'[\u4e00-\u9fff]';

    const migrated = [
      (
        rule: 'IOS-URL-SCHEMES',
        message: 'ios.url_schemes',
        recommendation: 'ios.url_schemes.manual_review',
        args: <String, Object>{'count': 2, 'schemes': 'example, ex2'},
      ),
      (
        rule: 'IOS-SCAN-COVERAGE',
        message: 'ios.scan_coverage',
        recommendation: 'ios.scan_coverage.manual_review',
        args: <String, Object>{'total': 2, 'scanned': 1, 'bytes': 100},
      ),
      (
        rule: 'IOS-PHOTO-LIBRARY',
        message: 'ios.photo_library',
        recommendation: 'ios.photo_library.review',
        args: <String, Object>{},
      ),
      (
        rule: 'IOS-CAMERA',
        message: 'ios.camera',
        recommendation: 'ios.camera.check_purpose',
        args: <String, Object>{},
      ),
      (
        rule: 'IOS-RULE-B',
        message: 'ios.rule_b',
        recommendation: 'ios.rule_b.confirm_pipeline',
        args: <String, Object>{
          'sources': <String>['photo_library'],
        },
      ),
      (
        rule: 'IOS-RULE-E',
        message: 'ios.rule_e',
        recommendation: 'ios.rule_e.manual_review',
        args: <String, Object>{
          'modes': 'fetch',
          'sources': <String>['clipboard'],
        },
      ),
      (
        rule: 'IOS-RULE-D',
        message: 'ios.rule_d',
        recommendation: 'ios.rule_d.manual_review',
        args: <String, Object>{},
      ),
      (
        rule: 'IOS-PRIVACY-INFO',
        message: 'ios.privacy_info',
        recommendation: 'ios.privacy_info.cross_check',
        args: <String, Object>{},
      ),
      (
        rule: 'IOS-PRIVACY-TRACKING',
        message: 'ios.privacy_tracking',
        recommendation: 'ios.privacy_tracking.confirm_att',
        args: <String, Object>{},
      ),
    ];

    // URL scheme + 相册 + 相机 + OCR + ATS + 跟踪声明，一次触发大多数规则。
    const richPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
  <key>NSPhotoLibraryUsageDescription</key><string>用于上传头像</string>
  <key>NSCameraUsageDescription</key><string>用于拍照识别</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLSchemes</key>
    <array><string>example</string></array>
  </dict></array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
''';

    const trackingXcprivacy = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>NSPrivacyTracking</key><true/>
</dict></plist>
''';

    const backgroundPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
  <key>UIBackgroundModes</key>
  <array><string>fetch</string></array>
</dict></plist>
''';

    const atsOnlyPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
''';

    test('引擎真的把 code 挂上去了（否则等于没迁）', () {
      // 第一轮：相册 + 相机 + OCR + URL scheme + ATS + 跟踪声明，且**没有**网络
      // 线索 —— 这样规则 F 也出得来，而规则 E 需要上传，留给第二轮。
      final rich = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: richPlist, xcprivacy: trackingXcprivacy),
        executableBytes: const Utf8Encoder().convert(
          'PHPhotoLibrary\nAVCapture\nVNRecognizeText\n',
        ),
      );

      // 第二轮：后台模式 + 剪贴板 + 上传 → 规则 E。
      final background = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: backgroundPlist),
        executableBytes: const Utf8Encoder().convert(
          'UIPasteboard\nNSURLSession\n',
        ),
      );

      // 第三轮：只有 ATS，没有图像/识别/网络线索 → 非升级版的规则 D。
      final plainAts = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: atsOnlyPlist),
        executableBytes: const Utf8Encoder().convert('unrelated\n'),
      );

      for (final m in migrated) {
        final finding = _byId(rich, m.rule) ??
            _byId(background, m.rule) ??
            _byId(plainAts, m.rule);
        expect(finding, isNotNull, reason: '测试输入没有触发 ${m.rule}');
        expect(finding!.messageCode, m.message, reason: m.rule);
        expect(finding.recommendationCode, m.recommendation, reason: m.rule);
        expect(
          RegExp(cjk).hasMatch(finding.finding),
          isFalse,
          reason: '${m.rule} 的英文回退里还有中文：${finding.finding}',
        );
        expect(
          RegExp(cjk).hasMatch(finding.recommendation),
          isFalse,
          reason: '${m.rule} 的建议没有一起迁移：${finding.recommendation}',
        );
      }
    });

    test('四个维护中的语言包都能取到文案，且不留占位符', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await LocaleSettings.setLocaleRaw(locale);
        for (final m in migrated) {
          final finding = SecurityFinding(
            ruleId: m.rule,
            platform: SecurityPlatform.ios,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.unknown,
            finding: 'fallback finding',
            evidence: const [],
            recommendation: 'fallback recommendation',
            messageCode: m.message,
            messageArgs: m.args,
            recommendationCode: m.recommendation,
          );

          final text = AnalysisReport.findingText(finding, t);
          expect(text, isNot('fallback finding'),
              reason: '$locale 下 ${m.message} 没取到本地化文案');
          // 本批有 5 条带参数：出现花括号说明占位符没被替换。
          expect(text, isNot(contains('{')), reason: '$locale / ${m.message}');
          expect(text, isNot(contains('}')), reason: '$locale / ${m.message}');
          // 英文回退与英文语言包措辞刻意对齐，所以「不等于回退」在 en 下
          // 证明不了什么 —— 真正能证明走了本地化路径的是中文变体里得有中文。
          if (locale != 'en') {
            expect(RegExp(cjk).hasMatch(text), isTrue,
                reason: '$locale 下 ${m.message} 不是中文：$text');
          }

          final rec = AnalysisReport.recommendationText(finding, t);
          expect(rec, isNot('fallback recommendation'),
              reason: '$locale 下 ${m.recommendation} 没取到本地化文案');
          expect(rec, isNot(contains('{')),
              reason: '$locale / ${m.recommendation}');
        }
      }
    });

    test('来源列表按语言包组装：英文逗号、中文顿号', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      final result = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: richPlist),
        executableBytes: const Utf8Encoder().convert(
          'PHPhotoLibrary\nAVCapture\nVNRecognizeText\n',
        ),
      );
      final ruleB = _byId(result, 'IOS-RULE-B')!;
      // 引擎传的是 id，不是已经拼好的句子。
      expect(ruleB.messageArgs['sources'], ['photo_library', 'camera']);

      await LocaleSettings.setLocaleRaw('en');
      final en = AnalysisReport.findingText(ruleB, t);
      expect(en, contains('full photo library (PhotoKit), camera'));
      expect(en, isNot(contains('{')));

      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.findingText(ruleB, t);
      expect(zh, contains('完整照片库（PhotoKit）、相机'));
      expect(zh, isNot(contains('{')));
      expect(RegExp(cjk).hasMatch(zh), isTrue);
    });

    test('后台模式用 plist 里的原始字面量，不翻译', () {
      final result = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: backgroundPlist),
        executableBytes: const Utf8Encoder().convert(
          'UIPasteboard\nNSURLSession\n',
        ),
      );
      final ruleE = _byId(result, 'IOS-RULE-E')!;
      // `UIBackgroundModes` 的值是 Apple 定义的标识符（fetch / audio …），
      // 不是给人读的句子 —— 翻译它们反而会让人对不上 Info.plist。
      expect(ruleE.messageArgs['modes'], 'fetch');
      expect(ruleE.messageArgs['sources'], ['clipboard']);

      final text = AnalysisReport.findingText(ruleE, t);
      expect(text, contains('fetch'));
      expect(text, contains('clipboard'));
      expect(text, isNot(contains('{')));
    });
  });

  // B11 第四批：`relationship` / `limitation` 也纳入。
  //
  // 这两个字段**会渲染**（卡片展开区 + Markdown 报告），只迁 finding /
  // recommendation 的话，英文界面下的展开区仍然是中文 ——
  // 那等于「发现项文案已本地化」这句话只对正文成立。
  group('发现项文案本地化（B11 第四批：relationship / limitation）', () {
    const cjk = r'[\u4e00-\u9fff]';

    const limitationCodes = {
      'IOS-URL-SCHEMES': 'ios.url_schemes.limitation',
      'IOS-SCAN-COVERAGE': 'ios.scan_coverage.limitation',
      'IOS-PHOTO-LIBRARY': 'ios.photo_library.limitation',
      'IOS-RULE-A': 'ios.rule_a.limitation',
      'IOS-RULE-B': 'ios.rule_b.limitation',
      'IOS-RULE-C': 'ios.rule_c.limitation',
      'IOS-RULE-E': 'ios.rule_e.limitation',
      'IOS-RULE-D': 'ios.rule_d.limitation',
      'IOS-PRIVACY-INFO': 'ios.privacy_info.limitation',
      'IOS-RULE-F': 'ios.rule_f.limitation',
    };

    const relationshipCodes = {
      'IOS-RULE-A': 'ios.rule_a.relationship',
      'IOS-RULE-B': 'ios.rule_b.relationship',
      'IOS-RULE-C': 'ios.rule_c.relationship',
      'IOS-RULE-E': 'ios.rule_e.relationship',
    };

    const emptyPlist = '<?xml version="1.0" encoding="UTF-8"?>'
        '<plist version="1.0"><dict></dict></plist>';

    const atsOnlyPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
''';

    const backgroundPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>UIBackgroundModes</key>
  <array><string>fetch</string></array>
</dict></plist>
''';

    const urlSchemePlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLSchemes</key>
    <array><string>example</string></array>
  </dict></array>
</dict></plist>
''';

    test('引擎真的把 relationship / limitation 的 code 挂上去了', () {
      // 四轮输入，覆盖到全部 10 条 limitation 与 4 条 relationship。
      final scheme = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: urlSchemePlist),
        executableBytes: const Utf8Encoder().convert('unrelated\n'),
      );
      final photoOnly = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: _usageOnlyPlist),
        executableBytes:
            const Utf8Encoder().convert('PHPhotoLibrary\nVNRecognizeText\n'),
      );
      final exfil = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: _usageOnlyPlist),
        executableBytes: const Utf8Encoder().convert(
          'PHPhotoLibrary\nVNRecognizeText\nNSURLSession\n',
        ),
      );
      final background = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: backgroundPlist),
        executableBytes: const Utf8Encoder().convert(
          'UIPasteboard\nNSURLSession\n',
        ),
      );
      final plainAts = IosPrivacyAudit.audit(
        infoPlist: _plist(infoPlist: atsOnlyPlist),
        executableBytes: const Utf8Encoder().convert('unrelated\n'),
      );
      // 隐私清单要单独一轮：`PrivacyInfo.xcprivacy` 不在 Info.plist 里。
      final privacy = IosPrivacyAudit.audit(
        infoPlist: _plist(
          infoPlist: emptyPlist,
          xcprivacy: '<?xml version="1.0" encoding="UTF-8"?>'
              '<plist version="1.0"><dict>'
              '<key>NSPrivacyTracking</key><false/>'
              '</dict></plist>',
        ),
        executableBytes: const Utf8Encoder().convert('unrelated\n'),
      );

      SecurityFinding? find(String rule) =>
          _byId(scheme, rule) ??
          _byId(photoOnly, rule) ??
          _byId(exfil, rule) ??
          _byId(background, rule) ??
          _byId(plainAts, rule) ??
          _byId(privacy, rule);

      limitationCodes.forEach((rule, code) {
        final f = find(rule);
        expect(f, isNotNull, reason: '测试输入没有触发 $rule');
        expect(f!.limitationCode, code, reason: rule);
        expect(
          RegExp(cjk).hasMatch(f.limitation!),
          isFalse,
          reason: '$rule 的局限英文回退里还有中文：${f.limitation}',
        );
      });

      relationshipCodes.forEach((rule, code) {
        final f = find(rule);
        expect(f, isNotNull, reason: '测试输入没有触发 $rule');
        expect(f!.relationshipCode, code, reason: rule);
        expect(
          RegExp(cjk).hasMatch(f.relationship!),
          isFalse,
          reason: '$rule 的关联说明英文回退里还有中文：${f.relationship}',
        );
      });
    });

    test('四个维护中的语言包都能取到，且中文变体确实是中文', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      SecurityFinding build({String? rel, String? lim}) => SecurityFinding(
            ruleId: 'X',
            platform: SecurityPlatform.ios,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.unknown,
            finding: 'fallback finding',
            evidence: const [],
            relationship: 'fallback relationship',
            limitation: 'fallback limitation',
            recommendation: 'fallback recommendation',
            relationshipCode: rel,
            limitationCode: lim,
          );

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await LocaleSettings.setLocaleRaw(locale);
        for (final code in limitationCodes.values) {
          final text = AnalysisReport.limitationText(build(lim: code), t);
          expect(text, isNot('fallback limitation'),
              reason: '$locale 下 $code 没取到本地化文案');
          expect(text, isNot(contains('{')));
          if (locale != 'en') {
            expect(RegExp(cjk).hasMatch(text!), isTrue,
                reason: '$locale 下 $code 不是中文：$text');
          }
        }
        for (final code in relationshipCodes.values) {
          final text = AnalysisReport.relationshipText(build(rel: code), t);
          expect(text, isNot('fallback relationship'),
              reason: '$locale 下 $code 没取到本地化文案');
          expect(text, isNot(contains('{')));
          if (locale != 'en') {
            expect(RegExp(cjk).hasMatch(text!), isTrue,
                reason: '$locale 下 $code 不是中文：$text');
          }
        }
      }
    });

    test('没填 code 的关联 / 局限仍按原文返回（迁移是增量的）', () {
      const f = SecurityFinding(
        ruleId: 'X',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.unknown,
        finding: '未迁移',
        evidence: [],
        relationship: '尚未迁移的关联',
        limitation: '尚未迁移的局限',
        recommendation: '尚未迁移的建议',
      );
      expect(AnalysisReport.relationshipText(f, t), '尚未迁移的关联');
      expect(AnalysisReport.limitationText(f, t), '尚未迁移的局限');
    });
  });
}
