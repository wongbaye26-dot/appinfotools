// B-6：iOS「声明了用途说明、却没有对应 API 线索」——证据关联的**反方向**。
//
// ## 为什么这条要单独测
//
// iOS 侧原本只有「有实现、没声明」（`IOS-PHOTO-LIBRARY-NO-USAGE` /
// `IOS-CAMERA-NO-USAGE`）这一个方向 —— 那是会崩、会被拒的硬缺陷。
// 反方向（声明了、但扫描范围内找不到实现）一直没有判定，只留了一句
// 「请自行与 API 线索对照」。
//
// 这条反方向的价值在于抓**过度声明**：常见于从模板/示例复制过来的
// `NSPhotoLibraryUsageDescription`，应用其实从不读相册。过度声明本身是隐私
// 问题（用户会以为它在读相册），也会让 App Store 的隐私标签不准确。
//
// ## 措辞的边界（本文件守的就是这个）
//
// 「没有符号」**不能**推出「没有这个功能」：
// - 系统照片选择器（`PHPickerViewController`）是**跨进程**的，不需要相册权限；
// - SwiftUI 的 `PhotosPicker` 是封装，不一定留下可扫描符号；
// - 动态加载的代码同样不会出现在符号表里。
//
// 所以这条必须是 `info` + `unknown`，并且必须写清「结论未成立」。
// 另外：**没读到可执行文件时不判** —— 那是覆盖不足，不是矛盾。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

const _photoDeclared = '''
  <key>NSPhotoLibraryUsageDescription</key><string>用于上传头像</string>
''';
const _cameraDeclared = '''
  <key>NSCameraUsageDescription</key><string>用于拍照识别</string>
''';

SecurityAnalysisResult _audit(
  String usageKeysXml, {
  String macho = 'unrelated\n',
  bool withExecutable = true,
  Uint8List? rawBytes,
  List<IosNestedExecutableInput> nested = const [],
}) =>
    IosPrivacyAudit.audit(
      infoPlist: _plist(usageKeysXml),
      executableBytes: rawBytes ??
          (withExecutable ? const Utf8Encoder().convert(macho) : null),
      executablePath: '$_bundlePath/Example',
      nestedExecutables: nested,
    );

List<SecurityFinding> _usageWithoutApi(SecurityAnalysisResult r) =>
    r.findings.where((f) => f.ruleId == 'IOS-USAGE-WITHOUT-API').toList();

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('声明了、但没有对应线索', () {
    test('声明相册 + 无 PhotoKit 符号 → 一条 info，confidence=unknown', () {
      final findings = _usageWithoutApi(_audit(_photoDeclared));

      expect(findings, hasLength(1));
      final f = findings.single;
      expect(f.severity, SecuritySeverity.info, reason: '这是「值得看一眼」，不是「有问题」');
      expect(
        f.confidence,
        SecurityConfidence.unknown,
        reason: '「没有符号」不能推出「没有这个功能」',
      );
      expect(f.messageArgs['key'], 'NSPhotoLibraryUsageDescription');
      // 扫描范围要写出来，否则读者不知道「没找到」是在多大范围里得出的。
      expect(f.messageArgs['scope'], contains('main executable'));
    });

    test('声明相机 + 无 AVCapture 符号 → 同样一条', () {
      final findings = _usageWithoutApi(_audit(_cameraDeclared));
      expect(findings, hasLength(1));
      expect(findings.single.messageArgs['key'], 'NSCameraUsageDescription');
    });

    test('两条声明都没有实现线索 → 两条独立发现项', () {
      final findings =
          _usageWithoutApi(_audit('$_photoDeclared$_cameraDeclared'));
      expect(findings, hasLength(2));
      expect(
        findings.map((f) => f.messageArgs['key']).toSet(),
        {
          'NSPhotoLibraryUsageDescription',
          'NSCameraUsageDescription',
        },
      );
    });
  });

  group('有实现时不误报', () {
    test('声明相册 + 有 PHPhotoLibrary 符号 → 不报', () {
      final findings =
          _usageWithoutApi(_audit(_photoDeclared, macho: 'PHPhotoLibrary\n'));
      expect(findings, isEmpty);
    });

    test('声明相册 + 只有 PHPickerViewController（系统选择器）→ 不报', () {
      // 系统选择器不需要相册权限，但**确实**是相册输入路径 —— 有符号就不该
      // 说「声明是假的」。
      final findings = _usageWithoutApi(
        _audit(_photoDeclared, macho: 'PHPickerViewController\n'),
      );
      expect(findings, isEmpty);
    });

    test('声明相机 + 有 AVCapture 符号 → 不报', () {
      final findings =
          _usageWithoutApi(_audit(_cameraDeclared, macho: 'AVCaptureDevice\n'));
      expect(findings, isEmpty);
    });

    test('符号只出现在嵌套可执行文件里也算有实现', () {
      final findings = _usageWithoutApi(_audit(
        _photoDeclared,
        nested: [
          IosNestedExecutableInput(
            path: '$_bundlePath/PlugIns/Share.appex/Share',
            bundlePath: '$_bundlePath/PlugIns/Share.appex',
            kind: IosBundleKind.appExtension,
            bytes: const Utf8Encoder().convert('PHAsset\n'),
          ),
        ],
      ));
      expect(findings, isEmpty);
    });
  });

  group('不该判的情况', () {
    test('完全没有用途说明 → 不报（没有声明就没有矛盾）', () {
      final findings = _usageWithoutApi(_audit(''));
      expect(findings, isEmpty);
    });

    test('没读到可执行文件 → 不报（覆盖不足不是矛盾）', () {
      // 这条最关键：读不到二进制时「没有符号」只说明我们没看到。
      final findings = _usageWithoutApi(
        _audit(_photoDeclared, withExecutable: false),
      );
      expect(findings, isEmpty, reason: '读不到二进制时把「没看到」写成「没实现」就是编造');
    });

    test('扫描被预算截断 → 不判（线索可能在截断之后）', () {
      // 真实反例：`sun_signed.ipa` 主可执行文件 45 MB，只扫前 16 MB，
      // 而 `AVCapture` 出现在 16 MB 之后 —— 不排除截断就会误报
      // 「声明了相机但没有实现」。
      final bytes = Uint8List(16 * 1024 * 1024 + 64)
        ..fillRange(0, 16 * 1024 * 1024 + 64, 0x41);
      const marker = 'AVCapture';
      for (var i = 0; i < marker.length; i++) {
        bytes[bytes.length - marker.length + i] = marker.codeUnitAt(i);
      }
      final findings = _usageWithoutApi(
        _audit(_cameraDeclared, withExecutable: false, rawBytes: bytes),
      );
      expect(findings, isEmpty, reason: '超出扫描预算的部分没看到，不等于没有');
    });

    test('嵌套条目都在、但一个字节都没拿到 → 不判（仍然属于覆盖不足）', () {
      // 生产路径会把**读失败**的嵌套条目也传进来（`bytes == null`），
      // 用来算覆盖率。把它们算成「扫过」，这条规则就会在什么都没读到的
      // 情况下宣布「没有实现」。
      final findings = _usageWithoutApi(_audit(
        _photoDeclared,
        withExecutable: false,
        nested: [
          IosNestedExecutableInput(
            path: '$_bundlePath/PlugIns/Share.appex/Share',
            bundlePath: '$_bundlePath/PlugIns/Share.appex',
            kind: IosBundleKind.appExtension,
            failure: 'too large to read',
          ),
        ],
      ));
      expect(findings, isEmpty);
    });

    test('只读到嵌套可执行文件、主可执行文件缺失 → 仍然判（范围里有东西）', () {
      final findings = _usageWithoutApi(_audit(
        _photoDeclared,
        withExecutable: false,
        nested: [
          IosNestedExecutableInput(
            path: '$_bundlePath/PlugIns/Share.appex/Share',
            bundlePath: '$_bundlePath/PlugIns/Share.appex',
            kind: IosBundleKind.appExtension,
            bytes: const Utf8Encoder().convert('unrelated\n'),
          ),
        ],
      ));
      expect(findings, hasLength(1));
      expect(findings.single.messageArgs['scope'], contains('nested'));
    });
  });

  group('措辞边界', () {
    test('正文说清「声明与没有符号都是事实」，不宣称权限未被使用', () {
      final f = _usageWithoutApi(_audit(_photoDeclared)).single;
      final text = AnalysisReport.findingText(f, t);

      expect(text, contains('NSPhotoLibraryUsageDescription'));
      // 中文界面下必须是中文（走 i18n，不是英文回退）。
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue,
          reason: '中文界面下不能显示英文回退：$text');
      // 关系说明必须写明「结论未成立」。
      final relationship = AnalysisReport.relationshipText(f, t);
      expect(relationship, isNotNull);
      expect(relationship, anyOf(contains('並未成立'), contains('并未成立')));
    });

    test('局限里点名三种「不会留下符号」的实现方式', () {
      final f = _usageWithoutApi(_audit(_photoDeclared)).single;
      final limitation = AnalysisReport.limitationText(f, t);
      expect(limitation, isNotNull);
      expect(limitation, contains('PHPickerViewController'));
      expect(limitation, contains('PhotosPicker'));
      expect(limitation, anyOf(contains('動態載入'), contains('动态加载')));
    });

    test('建议是「删掉不用的声明」，不是「有风险」', () {
      final f = _usageWithoutApi(_audit(_photoDeclared)).single;
      final recommendation = AnalysisReport.recommendationText(f, t);
      expect(recommendation, anyOf(contains('刪掉'), contains('删掉')));
    });
  });

  group('i18n 守卫：新规则用到的每个 code 在四个语言包里都有键', () {
    // 「加了规则、忘了文案键」的后果是**静默回退英文** —— 编译不报错、
    // 中文界面照常显示英文句子。本文件前面那条 CJK 断言只覆盖 zh-CN 的正文，
    // 这里直接把 4 个语言包的 JSON 读出来逐个 key 核对（不靠 grep）。
    const locales = ['en', 'zh-CN', 'zh-HK', 'zh-TW'];
    final texts = {
      for (final loc in locales)
        loc: (jsonDecode(File('assets/i18n/$loc.json').readAsStringSync())
                as Map<String, dynamic>)['security']['finding_texts']
            as Map<String, dynamic>,
    };

    String keyOf(String code) => code.replaceAll('.', '_');

    test(
        '审计产出的 message / recommendation / relationship / limitation '
        'code 都有对应键', () {
      final result = _audit(
        '$_photoDeclared$_cameraDeclared',
        macho: 'PHPhotoLibrary\nVNRecognizeText\nNSURLSession\n',
      );

      final codes = <String>{
        for (final f in result.findings) ...[
          if (f.messageCode != null) f.messageCode!,
          if (f.recommendationCode != null) f.recommendationCode!,
          if (f.relationshipCode != null) f.relationshipCode!,
          if (f.limitationCode != null) f.limitationCode!,
        ],
      };
      // 至少要把本轮新增的那四个覆盖到，否则这条守卫等于没测。
      expect(codes, contains('ios.usage_without_api'));
      expect(codes, contains('ios.usage_without_api.review'));

      for (final loc in locales) {
        final missing =
            codes.where((c) => !texts[loc]!.containsKey(keyOf(c))).toList();
        expect(missing, isEmpty, reason: '$loc 缺少文案键：$missing');
      }
    });

    test('新键在四个语言包里都不带 Markdown 星号（界面是纯 Text）', () {
      for (final loc in locales) {
        for (final key in const [
          'ios_usage_without_api',
          'ios_usage_without_api_relationship',
          'ios_usage_without_api_limitation',
          'ios_usage_without_api_review',
        ]) {
          final value = texts[loc]![key] as String;
          expect(value, isNot(contains('**')), reason: '$loc / $key');
          expect(value.trim(), isNotEmpty, reason: '$loc / $key');
        }
      }
    });
  });

  group('与「实现但未声明」不混淆', () {
    test('只有符号、没有声明 → 走 IOS-PHOTO-LIBRARY-NO-USAGE，不是本条', () {
      final result = _audit('', macho: 'PHPhotoLibrary\n');
      expect(_usageWithoutApi(result), isEmpty);
      expect(
        result.findings.any((f) => f.ruleId == 'IOS-PHOTO-LIBRARY-NO-USAGE'),
        isTrue,
      );
    });
  });
}
