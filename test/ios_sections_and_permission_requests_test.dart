// Mach-O 节表解析 + 「主动请求权限」发现项。
//
// ## 为什么要节
//
// 段级解析只能告诉你「`__TEXT` 有 34 MB」，而 `__TEXT` 里混着代码、C 字符串、
// ObjC 选择子表、Swift 反射元数据。**选择子表**（`__objc_methname`）是这个
// 二进制真正引用过的方法名 —— 在那里出现 `requestTrackingAuthorization...`，
// 说明代码里有 `objc_msgSend` 拿它去调用。
//
// 这把 iOS 的证据从「整文件里搜到这个词」推到「代码里引用了这个方法」，
// 是 Android 侧「字符串 → method_ids → 调用点」那套分级在 iOS 上的对应物。
//
// ## 两条测试
//
// 1. 节表本身：用 `test/fixtures/macho/` 的真实编译器产物，不手拼字节。
// 2. 权限请求：需要带 ObjC 选择子的真实 IPA。仓库里没有（40 MB，不入库），
//    缺失时跳过并写明原因 —— 与 `app_icon_extractor` 的做法一致。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/macho/$name').readAsBytesSync();

void main() {
  group('Mach-O 节表', () {
    test('真实 dylib 的节被解析出来，且落在文件范围内', () {
      final bytes = _fixture('libnative-fixture-arm64.dylib');
      final macho = MachOParser.parse(bytes);
      expect(macho.images, isNotEmpty);

      final image = macho.images.first;
      final text = image.segments.firstWhere((s) => s.name == '__TEXT');
      expect(text.sections, isNotEmpty, reason: '__TEXT 一定有节');
      expect(text.sections.map((s) => s.name), contains('__text'));
      expect(text.sections.length, lessThanOrEqualTo(text.sectionCount));

      for (final segment in image.segments) {
        for (final section in segment.sections) {
          expect(section.segment, segment.name);
          expect(section.fileOffset + section.fileSize,
              lessThanOrEqualTo(image.size),
              reason: '${section.qualifiedName} 越出切片');
        }
      }
    });

    test('按「段,节」取字节；没有的节返回 null 而不是空表', () {
      final bytes = _fixture('libnative-fixture-arm64.dylib');
      final macho = MachOParser.parse(bytes);

      final cstring =
          macho.sectionBytes(bytes, segment: '__TEXT', section: '__cstring');
      expect(cstring, isNotNull);
      expect(cstring, isNotEmpty);

      expect(
        macho.sectionBytes(bytes, segment: '__TEXT', section: '__nope'),
        isNull,
      );
      // 段名不对也不能命中。
      expect(
        macho.sectionBytes(bytes, segment: '__DATA', section: '__cstring'),
        isNull,
      );
    });

    test('畸形输入不抛异常', () {
      expect(() => MachOParser.parse(Uint8List(4)), returnsNormally);
      expect(() => MachOParser.parse(Uint8List(4096)), returnsNormally);
    });
  });

  group('主动请求权限（选择子表）', () {
    test('真实 IPA 上识别出主动请求的权限', () async {
      if (!File('sun_signed.ipa').existsSync()) {
        markTestSkipped('sun_signed.ipa 不在仓库里（需人工提供）');
        return;
      }
      final helper = ZipHelper();
      await helper.open('sun_signed.ipa');
      final parsed = IpaAnalysisReader.analyze(helper.archive!);
      final security = IosPrivacyAudit.audit(
        infoPlist: parsed.infoPlist!,
        executableBytes: parsed.executableBytes,
        executablePath: parsed.executablePath,
        provisioningProfilePresent: false,
        nestedBundleTotal: parsed.nestedBundleTotal,
        nestedExecutables: [
          for (final n in parsed.nestedBinaries)
            IosNestedExecutableInput(
              path: n.path,
              bundlePath: n.bundlePath,
              kind: n.kind,
              bytes: n.bytes,
              failure: n.failure ?? n.bytesFailure,
              usageDescriptions: n.usageDescriptions,
            ),
        ],
      );

      final finding = security.findings
          .where((f) => f.ruleId == 'IOS-PERMISSION-REQUEST')
          .toList();
      expect(finding, hasLength(1), reason: '选择子表里确实有请求权限的方法');

      final apis = (finding.single.messageArgs['apis'] as List).cast<String>();
      // 实测这三个选择子都在 `__TEXT,__objc_methname` 里。
      expect(apis, contains('PHPhotoLibrary'));
      expect(apis, contains('ATTrackingManager'));
      expect(apis, contains('AVCaptureDevice'));

      // 证据必须指到节，而不是「Mach-O executable strings」这种笼统位置。
      expect(
        finding.single.evidence.every(
          (e) => e.location == '__TEXT,__objc_methname',
        ),
        isTrue,
      );
      // 选择子带冒号，证明取的是原始选择子而不是猜的名字。
      expect(
        finding.single.evidence.any((e) => e.detail.contains(':')),
        isTrue,
      );
    });
  });
}
