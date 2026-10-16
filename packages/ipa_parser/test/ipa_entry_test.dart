// `ipa_parser` 的**顶层公开入口**测试：`IpaContainerReader` 与 `IpaInfoPlistReader`。
//
// ## 为什么单独一个文件
//
// `ipa_parser_test.dart` 覆盖的是四个纯逻辑子系统（plist / Mach-O / CgBI / CMS）。
// 而包真正对外的入口是「读容器结构 → 读 Info.plist 字段」这条链 ——
// 它此前**在包内没有任何测试**，于是 CI 的「Package-level tests」这一步对
// 「这个包作为独立库能不能自证」近乎空转。
//
// 本文件只做**入口级**验证（关键字段 / 错误状态 / 部分解析结果），
// 不复制根 `test/` 里那套端到端用例。
//
// ## 输入是受控构造的，不是手拼字节
//
// 归档用 `archive` 包现造（`Archive()` + `ArchiveFile`），`Info.plist` 是
// 测试里写死的 XML —— **期望值就是这段 XML 里写的值**，因此不存在
// 「与解析器共享错误假设」的问题。
//
// ## 与「签名」的边界
//
// 本包**不做签名验证**（规范 5.5）。这里断言的是「签名材料在不在」，
// 不是「签名有没有效」。
import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

/// 一份受控的 `Info.plist`，键值与下面的断言一一对应。
const String _infoPlistXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>          <string>com.example.entry</string>
  <key>CFBundleName</key>                <string>EntryFixture</string>
  <key>CFBundleDisplayName</key>         <string>Entry Fixture</string>
  <key>CFBundleShortVersionString</key>  <string>3.2.1</string>
  <key>CFBundleVersion</key>             <string>321</string>
  <key>CFBundleExecutable</key>          <string>EntryFixture</string>
  <key>MinimumOSVersion</key>            <string>15.0</string>
  <key>UIDeviceFamily</key>              <array><integer>1</integer><integer>2</integer></array>
  <key>LSApplicationQueriesSchemes</key> <array><string>https</string><string>myapp</string></array>
  <key>UIBackgroundModes</key>           <array><string>fetch</string></array>
  <key>NSPhotoLibraryUsageDescription</key><string>Pick a photo</string>
</dict>
</plist>
''';

/// 一个条目名 + 内容的便捷构造。
ArchiveFile _file(String name, List<int> bytes) =>
    ArchiveFile(name, bytes.length, bytes);

/// 标准 IPA：`Payload/Example.app/` 下一个主应用。
Archive _standardIpa({List<int>? infoPlist}) => Archive()
  ..addFile(_file(
    'Payload/Example.app/Info.plist',
    infoPlist ?? utf8.encode(_infoPlistXml),
  ))
  ..addFile(_file('Payload/Example.app/Example', [0xCF, 0xFA, 0xED, 0xFE]));

IosBundle _mainApp(Archive archive) =>
    IpaContainerReader.read(archive).mainApp!;

void main() {
  // -------------------------------------------------------------------
  // 容器结构
  // -------------------------------------------------------------------

  group('IpaContainerReader — 容器结构', () {
    test('标准 IPA 定位到主应用，并认出 Payload 目录', () {
      final container = IpaContainerReader.read(_standardIpa());

      expect(container.hasPayloadDirectory, isTrue);
      expect(container.mainApp, isNotNull);
      expect(container.mainApp!.path, 'Payload/Example.app');
      expect(container.mainApp!.name, 'Example.app');
      expect(container.mainApp!.kind, IosBundleKind.mainApp);
    });

    test('文件条目数与声明尺寸被统计', () {
      final container = IpaContainerReader.read(_standardIpa());

      expect(container.fileEntryCount, 2);
      expect(container.totalUncompressedBytes, greaterThan(0));
    });

    test('Info.plist 的路径与声明尺寸都记在 bundle 上', () {
      final bundle = _mainApp(_standardIpa());

      expect(bundle.infoPlistPath, 'Payload/Example.app/Info.plist');
      expect(bundle.infoPlistSize, isNotNull);
    });

    test('没有 Payload/ 时如实记录，mainApp 为 null —— 不因此判定为恶意', () {
      final archive = Archive()
        ..addFile(_file('Example.app/Info.plist', utf8.encode(_infoPlistXml)));

      final container = IpaContainerReader.read(archive);

      expect(container.hasPayloadDirectory, isFalse);
      expect(
        container.mainApp,
        isNull,
        reason: '不在 Payload/ 下的 .app 不是主应用',
      );
    });

    test('多个 Payload/*.app 时如实报告，且主应用取路径排序第一个（不猜）', () {
      final archive = Archive()
        ..addFile(
            _file('Payload/Beta.app/Info.plist', utf8.encode(_infoPlistXml)))
        ..addFile(
            _file('Payload/Alpha.app/Info.plist', utf8.encode(_infoPlistXml)));

      final container = IpaContainerReader.read(archive);

      expect(container.hasMultipleMainApps, isTrue);
      expect(container.payloadApps, hasLength(2));
      expect(
        container.mainApp!.path,
        'Payload/Alpha.app',
        reason: '取排序后的第一个是**约定**，不是「推断哪个才是真的」',
      );
    });

    test('嵌套的 Framework 与 App Extension 被分别归类', () {
      final archive = _standardIpa()
        ..addFile(_file(
          'Payload/Example.app/Frameworks/Kit.framework/Kit',
          [1, 2, 3],
        ))
        ..addFile(_file(
          'Payload/Example.app/PlugIns/Share.appex/Share',
          [4, 5, 6],
        ));

      final container = IpaContainerReader.read(archive);

      expect(
          container.frameworks.map((b) => b.name), contains('Kit.framework'));
      expect(
          container.appExtensions.map((b) => b.name), contains('Share.appex'));
    });

    test('没有签名材料时 hasAnySignatureMaterials 为 false', () {
      final container = IpaContainerReader.read(_standardIpa());
      expect(container.hasAnySignatureMaterials, isFalse);
    });

    test('有 _CodeSignature 时被认出（只表示「在不在」）', () {
      final archive = _standardIpa()
        ..addFile(_file(
          'Payload/Example.app/_CodeSignature/CodeResources',
          utf8.encode('<plist><dict/></plist>'),
        ));

      final container = IpaContainerReader.read(archive);

      expect(container.hasAnySignatureMaterials, isTrue);
      expect(container.mainApp!.hasCodeSignatureDirectory, isTrue);
    });

    test('空归档不抛异常，给出空容器', () {
      late IpaContainer container;
      expect(() => container = IpaContainerReader.read(Archive()),
          returnsNormally);

      expect(container.bundles, isEmpty);
      expect(container.mainApp, isNull);
      expect(container.hasPayloadDirectory, isFalse);
    });
  });

  // -------------------------------------------------------------------
  // Info.plist 字段
  // -------------------------------------------------------------------

  group('IpaInfoPlistReader — 关键字段（期望值即测试里写的那份 plist）', () {
    test('身份字段全部取到，状态为 extracted', () {
      final plist =
          IpaInfoPlistReader.read(_standardIpa(), _mainApp(_standardIpa()));

      expect(plist.bundleIdentifier.value, 'com.example.entry');
      expect(plist.bundleIdentifier.status, FieldStatus.extracted);
      expect(plist.bundleName.value, 'EntryFixture');
      expect(plist.displayName.value, 'Entry Fixture');
      expect(plist.shortVersionString.value, '3.2.1');
      expect(plist.bundleVersion.value, '321');
      expect(plist.executable.value, 'EntryFixture');
      expect(plist.minimumOSVersion.value, '15.0');
    });

    test('数组类字段：设备族与 URL Scheme', () {
      final archive = _standardIpa();
      final plist = IpaInfoPlistReader.read(archive, _mainApp(archive));

      expect(plist.deviceFamily.value, [1, 2]);
      expect(plist.queriesSchemes.value, ['https', 'myapp']);
      expect(plist.backgroundModes.value, ['fetch']);
    });

    test('隐私用途说明被单独取出（不是混在原始 dict 里）', () {
      final archive = _standardIpa();
      final plist = IpaInfoPlistReader.read(archive, _mainApp(archive));

      expect(
        plist.privacyUsageDescriptions.value?['NSPhotoLibraryUsageDescription'],
        'Pick a photo',
      );
    });

    test('原始 dict 保留，键数与 plist 里写的一致', () {
      final archive = _standardIpa();
      final plist = IpaInfoPlistReader.read(archive, _mainApp(archive));

      // `raw` 是 PlistValue?（解析失败时为 null），成功时是字典。
      final raw = plist.raw;
      expect(raw, isA<PlistDict>());
      expect((raw! as PlistDict).value.keys, contains('CFBundleIdentifier'));
      expect((raw as PlistDict).value.length, 11);
    });

    test('成功解析会留下一条 info 诊断，并带 path 与键数参数', () {
      final archive = _standardIpa();
      final plist = IpaInfoPlistReader.read(archive, _mainApp(archive));

      final parsed = plist.diagnostics.where(
        (d) => d.code == 'ios.info_plist.parsed',
      );
      expect(parsed, hasLength(1));
      expect(
          parsed.single.messageArgs['path'], 'Payload/Example.app/Info.plist');
      expect(parsed.single.messageArgs['keys'], 11);
    });

    test('未声明的键是 absent，不是空串 —— 两者含义相反', () {
      // 这份 plist 没有 CFBundleDisplayName。
      const minimal = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.min</string>
</dict></plist>
''';
      final archive = _standardIpa(infoPlist: utf8.encode(minimal));
      final plist = IpaInfoPlistReader.read(archive, _mainApp(archive));

      expect(plist.bundleIdentifier.value, 'com.example.min');
      expect(plist.displayName.status, FieldStatus.absent);
      expect(plist.displayName.value, isNull);
      expect(plist.displayName.hasValue, isFalse);
    });
  });

  // -------------------------------------------------------------------
  // 错误状态
  // -------------------------------------------------------------------

  group('IpaInfoPlistReader — 错误状态', () {
    test('没有 Info.plist → 全部 absent，并留下 missing 诊断', () {
      final archive = Archive()
        ..addFile(_file('Payload/Example.app/Example', [1, 2, 3]));

      final container = IpaContainerReader.read(archive);
      final bundle = container.mainApp!;
      expect(bundle.infoPlistPath, isNull);

      final plist = IpaInfoPlistReader.read(archive, bundle);

      expect(plist.bundleIdentifier.status, FieldStatus.absent);
      expect(plist.bundleIdentifier.value, isNull);
      expect(
        plist.diagnostics.any((d) => d.code == 'ios.info_plist.missing'),
        isTrue,
      );
    });

    test('Info.plist 是垃圾字节 → 全部 failed，且不编造字段', () {
      final archive = _standardIpa(
        infoPlist: Uint8List.fromList(List.generate(256, (i) => i % 251)),
      );
      final plist = IpaInfoPlistReader.read(archive, _mainApp(archive));

      expect(plist.bundleIdentifier.status, FieldStatus.failed);
      expect(plist.bundleIdentifier.value, isNull);
      expect(plist.bundleIdentifier.diagnostic, isNotNull);
      expect(
        plist.diagnostics.any((d) => d.code == 'ios.info_plist.unparsable'),
        isTrue,
      );
    });

    test('Info.plist 根不是字典 → failed，并说明实际类型', () {
      // 根是字符串而不是 dict。
      const notADict = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><string>nope</string></plist>
''';
      final archive = _standardIpa(infoPlist: utf8.encode(notADict));
      final plist = IpaInfoPlistReader.read(archive, _mainApp(archive));

      expect(plist.bundleIdentifier.status, FieldStatus.failed);
      expect(plist.bundleIdentifier.value, isNull);

      final diagnostic = plist.diagnostics.firstWhere(
        (d) => d.code == 'ios.info_plist.not_a_dict',
      );
      expect(diagnostic.messageArgs['actual'], 'string');
    });

    test('容器层说有、归档里却没有 → vanished，而不是静默 absent', () {
      // 构造一个 bundle 指向归档里不存在的 Info.plist。
      const bundle = IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/Ghost.app',
        name: 'Ghost.app',
        infoPlistPath: 'Payload/Ghost.app/Info.plist',
      );

      final plist = IpaInfoPlistReader.read(Archive(), bundle);

      expect(
        plist.diagnostics.any((d) => d.code == 'ios.info_plist.vanished'),
        isTrue,
        reason: '「容器说在、实际读不到」是内部不一致，不能降级成「没有」',
      );
      expect(plist.bundleIdentifier.status, FieldStatus.absent);
    });

    test('超过大小上限的 Info.plist 被拒绝，不分配内存', () {
      final archive = _standardIpa(
        infoPlist: Uint8List(IpaInfoPlistReader.maxInfoPlistBytes + 1),
      );
      final plist = IpaInfoPlistReader.read(archive, _mainApp(archive));

      expect(plist.bundleIdentifier.status, FieldStatus.absent);
      expect(
        plist.diagnostics.any((d) => d.code == 'ios.info_plist.too_large'),
        isTrue,
      );
    });

    test('空归档 + 空 bundle 不抛异常', () {
      const bundle = IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/Nothing.app',
        name: 'Nothing.app',
      );

      expect(
        () => IpaInfoPlistReader.read(Archive(), bundle),
        returnsNormally,
      );
    });
  });
}
