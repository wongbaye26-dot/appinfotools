// iOS 隐私审计测试（V1.1 规格 4.1–4.4 与第五章规则）。
//
// 重点同样是措辞与状态区分：
// - PHPicker（用户主动选择）与 PhotoKit（完整库）必须分开判定；
// - 隐私清单是声明性材料，报告不得说成「已证实收集」；
// - 有 API 没用途说明才升级；只有用途说明不判「已访问」。

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
      expect(picker.finding, contains('不需要'));
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
        expect(f.finding, contains('不证明运行时'));
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
      expect(ruleC.relationship, contains('未被证实'));
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
      expect(ocr.finding, contains('不判定恶意'));
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
      expect(ruleF!.finding, contains('未发现'));
      expect(ruleF.finding, contains('这不表示'));
      expect(ruleF.finding, isNot(contains('确认安全')));
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
      expect(info!.finding, contains('声明性材料'));
      expect(info.finding, contains('不等于'));
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
        result.limitations.any((l) => l.contains('未能读取主 Mach-O')),
        isTrue,
      );
      expect(
          _byId(result, 'IOS-RULE-F')!.confidence, SecurityConfidence.unknown);
    });
  });
}
