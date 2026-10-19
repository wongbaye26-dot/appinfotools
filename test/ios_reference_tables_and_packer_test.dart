// iOS 结构化引用表 + Android 加固壳识别。
//
// ## 这两个能力的共同点
//
// 都回答「这个二进制里**到底有什么**」，而不是「某个词出现过没有」：
//
// - iOS：`__objc_classrefs` / `__objc_selrefs` 的槽位是**指针**，解出来的是
//   代码真正引用的类与选择子。此前 iOS 侧只有裸字符串扫描 —— `PHPhotoLibrary`
//   出现在注释或资源名里也算命中。
// - Android：加固壳必须把解密器编译成 `.so`，库名是各家自己定的、极少改动。
//   认出来之后，「没扫到 DEX 内容」这件事才有解释。
//
// 两者都**不越界**：iOS 不解 ARM64E 的 PAC 指针（解错会产出看起来像真的垃圾），
// Android 不做脱壳（那需要动态分析）。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

Uint8List _elf(String name) =>
    File('test/fixtures/elf/$name').readAsBytesSync();

void main() {
  group('iOS 结构化引用表', () {
    test('真实 IPA：解出类引用与选择子引用，且能认出框架类', () async {
      if (!File('sun_signed.ipa').existsSync()) {
        markTestSkipped('sun_signed.ipa 不在仓库里（需人工提供）');
        return;
      }
      final helper = ZipHelper();
      await helper.open('sun_signed.ipa');
      final parsed = IpaAnalysisReader.analyze(helper.archive!);
      final bytes = parsed.executableBytes!;
      final macho = MachOParser.parse(bytes);

      final tables = IosReferenceTables.resolve(bytes, macho.images.first);
      expect(tables.failure, isNull);
      expect(tables.classes, isNotEmpty);
      expect(tables.selectors, isNotEmpty);
      expect(tables.decodedPointers, greaterThan(100));

      // 这三个是「字符串里也搜得到、但只有引用表能证明代码用了它」的例子。
      expect(tables.classes, contains('PHPhotoLibrary'));
      expect(tables.classes, contains('ATTrackingManager'));
      expect(tables.classes, contains('AVCaptureDevice'));

      // 选择子带冒号，证明取的是原始方法名。
      expect(
        tables.selectors.any((s) => s.contains(':')),
        isTrue,
      );
      // 解出来的名字必须是「像名字」的字符串，不能混进二进制垃圾。
      expect(
        tables.classes.every((c) => !c.contains(' ')),
        isTrue,
      );
    });
  });

  group('Android 加固壳识别', () {
    test('libjiagu.so → 360 加固，等级 info，并写明「不脱壳」', () {
      final result = AndroidSecurityAudit.audit(
        meta: ApkMeta()..targetSdkVersion = 34,
        dexEntries: const [],
        nativeEntries: [
          NativeLibraryBytes(
            'lib/arm64-v8a/libjiagu_a64.so',
            _elf('arm64-v8a-libnative.so'),
          ),
        ],
      );

      final finding =
          result.findings.where((f) => f.ruleId == 'ANDROID-PACKER').toList();
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.info);
      expect(finding.single.messageArgs['names'], ['360 Jiagu']);
      expect(
        finding.single.evidence.single.location,
        contains('libjiagu_a64.so'),
      );
      // 边界必须写在局限里：识别 ≠ 脱壳。
      expect(finding.single.limitation, contains('does not unpack'));
    });

    test('不认识的原生库不报（少一条信息，不能误报）', () {
      final result = AndroidSecurityAudit.audit(
        meta: ApkMeta()..targetSdkVersion = 34,
        dexEntries: const [],
        nativeEntries: [
          NativeLibraryBytes(
            'lib/arm64-v8a/libflutter.so',
            _elf('arm64-v8a-libnative.so'),
          ),
        ],
      );
      expect(
        result.findings.where((f) => f.ruleId == 'ANDROID-PACKER'),
        isEmpty,
      );
    });

    test('两家壳同时命中时都列出来', () {
      final result = AndroidSecurityAudit.audit(
        meta: ApkMeta()..targetSdkVersion = 34,
        dexEntries: const [],
        nativeEntries: [
          NativeLibraryBytes(
            'lib/arm64-v8a/libjiagu.so',
            _elf('arm64-v8a-libnative.so'),
          ),
          NativeLibraryBytes(
            'lib/arm64-v8a/libshella-2.10.so',
            _elf('hardening-execstack.so'),
          ),
        ],
      );
      final finding =
          result.findings.where((f) => f.ruleId == 'ANDROID-PACKER').single;
      expect(
        (finding.messageArgs['names']! as List).cast<String>(),
        containsAll(['360 Jiagu', 'Tencent Legu']),
      );
    });
  });
}
