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
        // 措辞在阶段 5b 改成「任何」—— 扫描范围不再只有主应用。
        result.limitations.any((l) => l.contains('未能读取任何 Mach-O')),
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
      expect(finding.finding, contains('example'));
      expect(finding.finding, contains('外部可以唤起'));
      expect(finding.limitation, contains('未反汇编'));
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
      expect(ruleA.finding, contains('更克制'));
      expect(ruleA.relationship, contains('静态推断'));
      expect(ruleA.recommendation, contains('不是恶意判定'));
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
      expect(ruleB.relationship, contains('未被证实'));
      expect(ruleB.finding, contains('可能'));
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
      expect(ruleE.relationship, contains('没有任何一跳被证实'));
      expect(ruleE.limitation, contains('声明'));
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
      expect(coverage.finding, contains('1 个可执行文件中的 1 个'));
      expect(coverage.finding, contains('全部可执行文件都已覆盖'));
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
      expect(coverage.finding, contains('2 个可执行文件中的 2 个'));

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
      expect(coverage.finding, contains('2 个可执行文件中的 1 个'));
      expect(coverage.finding, contains('未覆盖 1 个'));
      expect(
        coverage.evidence.any((e) => e.detail == 'NOT scanned'),
        isTrue,
        reason: '未覆盖的要逐条列出，不能只报覆盖到的',
      );
      expect(
        result.limitations.any((l) => l.contains('未参与扫描')),
        isTrue,
      );
      expect(
        result.limitations.any((l) => l.contains('不是「没有」')),
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

      expect(result.limitations.any((l) => l.contains('没读到')), isTrue,
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
}
