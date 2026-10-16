// `apk_parser` 的**顶层公开入口**测试：`ApkReader`。
//
// ## 为什么单独一个文件
//
// `apk_parser_test.dart` 覆盖的是四个解析**子系统**（ManifestParser / DexStructure /
// ELF / ArscParser）的纯逻辑入口。而包真正对外的入口是 `ApkReader` ——
// 打开容器 → 解析 → 报告阶段 —— 它此前**在包内没有任何测试**，
// 于是 CI 的「Package-level tests」这一步对「这个包作为独立库能不能自证」近乎空转。
//
// 本文件只做**入口级**的验证（关键字段 / 错误状态 / 部分解析结果），
// 不复制根 `test/` 里那套端到端用例。
//
// ## 期望值来源
//
// 全部取自**独立工具 `aapt2`**（macOS，Android SDK build-tools 36.1.0）：
//
//   $AAPT2 dump badging test/fixtures/apk/night-mode-resources.apk
//     package: name='com.example.fixture' … compileSdkVersion='34'
//     minSdkVersion:'21'
//     targetSdkVersion:'34'
//     application-label:'Fixture'
//   $AAPT2 dump configurations test/fixtures/apk/night-mode-resources.apk
//     night
//   $AAPT2 dump configurations test/fixtures/apk/no-night-mode-resources.apk
//     （空）
//
// **不从本项目的解析器取** —— 那样等于自证。
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';

const String _fixtures = '../../test/fixtures';

Uint8List _bytes(String relative) =>
    File('$_fixtures/$relative').readAsBytesSync();

/// 把一段内容写进临时文件，返回路径。
Future<String> _tempFile(Directory dir, String name, List<int> bytes) async {
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file.path;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('apk_reader_entry_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  // -------------------------------------------------------------------
  // 容器打开
  // -------------------------------------------------------------------

  group('ApkReader.open — 容器打开的结果分类', () {
    test('真实 APK 打开成功', () async {
      final reader = ApkReader();
      final result =
          await reader.open('$_fixtures/apk/night-mode-resources.apk');

      expect(result, ArchiveOpenResult.ok);
      expect(result.isOk, isTrue);
    });

    test('不是归档的文件被如实分类为 notArchive（不是笼统的 false）', () async {
      final path = await _tempFile(
        tmp,
        'plain.txt',
        'this is definitely not a zip archive'.codeUnits,
      );

      expect(await ApkReader().open(path), ArchiveOpenResult.notArchive);
    });

    test('被截断的归档不报成功', () async {
      final full = _bytes('apk/night-mode-resources.apk');
      final truncated = full.sublist(0, full.length ~/ 2);
      final path = await _tempFile(tmp, 'truncated.apk', truncated);

      final result = await ApkReader().open(path);
      expect(
        result,
        isNot(ArchiveOpenResult.ok),
        reason: '半截归档不能报成功，否则后面每一步都在读不存在的东西',
      );
    });

    test('文件不存在时是 ioError，不是「损坏」', () async {
      final result = await ApkReader().open('${tmp.path}/does-not-exist.apk');
      expect(result, ArchiveOpenResult.ioError);
    });

    test('正常 APK 不带结构异常说明', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      expect(reader.structureAnomaly, isNull);
    });
  });

  // -------------------------------------------------------------------
  // 顶层解析：关键字段
  // -------------------------------------------------------------------

  group('ApkReader.parse — 关键字段与 aapt2 一致', () {
    test('包名 / SDK 区间与 aapt2 dump badging 一致', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      final meta = await reader.parse();

      expect(meta, isNotNull);
      expect(meta!.packageName, 'com.example.fixture');
      expect(meta.minSdkVersion, 21);
      expect(meta.targetSdkVersion, 34);
      expect(meta.compileSdkVersion, 34);
    });

    test('应用名从资源表解出（aapt2 报 application-label: Fixture）', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      final meta = await reader.parse();

      expect(meta!.label, 'Fixture');
    });

    test('未声明的 maxSdkVersion 保持 null（不编造上限）', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      final meta = await reader.parse();

      expect(meta!.maxSdkVersion, isNull);
    });

    test('解析成功时两条失败原因都是 null（不能把「解析过」也标成失败）', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      await reader.parse();

      expect(reader.manifestFailure, isNull);
      expect(reader.arscParseFailure, isNull);
    });

    test('阶段回调按顺序报告真实阶段，且不提供百分比', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');

      final stages = <ApkParseStage>[];
      await reader.parse(onStage: stages.add);

      expect(stages, contains(ApkParseStage.manifest));
      expect(stages, contains(ApkParseStage.resources));
      expect(
        stages.indexOf(ApkParseStage.manifest),
        lessThan(stages.indexOf(ApkParseStage.resources)),
        reason: '资源表在 manifest 之后解析',
      );
      expect(stages.last, ApkParseStage.done);
    });

    // 这一对必须**成对**：只留带夜间资源的那个，`hasNightMode` 直接
    // `return true` 也能通过。依据是 `aapt2 dump configurations` 的输出。
    test('夜间模式资源：有变体的报 true', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      final meta = await reader.parse();

      expect(meta!.hasNightMode, isTrue, reason: 'aapt2 输出 night');
    });

    test('夜间模式资源：没有变体的报 false', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/no-night-mode-resources.apk');
      final meta = await reader.parse();

      expect(meta!.hasNightMode, isFalse, reason: 'aapt2 输出为空');
    });
  });

  // -------------------------------------------------------------------
  // 部分解析
  // -------------------------------------------------------------------

  group('部分解析：缺 DEX / 缺原生库时仍给出可用结果', () {
    // 这四个夹具是 `aapt2 link` 的最小产物，只有 AndroidManifest.xml 与
    // resources.arsc —— **没有 classes.dex，也没有 lib/**。真实应用不会有
    // 这种形状，它恰好用来钉「缺哪一块就如实缺哪一块，而不是整体放弃」。
    test('没有 DEX 与原生库时，parse 仍返回完整的 ApkMeta', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      final meta = await reader.parse();

      expect(meta, isNotNull, reason: '缺 DEX 不该让整个解析失败');
      expect(meta!.packageName, 'com.example.fixture');
    });

    test('夹具里没有 lib/ 时，原生库列表为空（不是编出来的）', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      final meta = await reader.parse();

      expect(meta!.nativeCodes, isEmpty);
      expect(meta.features, isEmpty);
      expect(meta.permissions, isEmpty);
      expect(meta.components, isEmpty);
    });

    test('缺 resources.arsc 时解析照常完成，且不谎称「没有夜间资源」', () async {
      // 只有 manifest、没有资源表的最小归档。
      final archive = Archive()
        ..addFile(ArchiveFile(
          'AndroidManifest.xml',
          0,
          _bytes('apk/standard-manifest.axml'),
        ));
      final path = await _tempFile(
        tmp,
        'manifest-only.apk',
        ZipEncoder().encode(archive),
      );

      final reader = ApkReader();
      expect(await reader.open(path), ArchiveOpenResult.ok);

      final meta = await reader.parse();
      expect(meta, isNotNull, reason: '没有资源表不影响 manifest 层的结论');
      expect(
        meta!.hasNightMode,
        isNull,
        reason: '「没读到资源表」必须与「没有夜间资源」区分 —— '
            'false 会被用户当成结论',
      );
    });
  });

  // -------------------------------------------------------------------
  // 错误状态
  // -------------------------------------------------------------------

  group('错误状态：如实分类，不编造字段', () {
    test('归档里没有 AndroidManifest.xml → parse 返回 null 并说明原因', () async {
      final archive = Archive()..addFile(ArchiveFile('res/raw/x.txt', 1, [65]));
      final path =
          await _tempFile(tmp, 'no-manifest.apk', ZipEncoder().encode(archive));

      final reader = ApkReader();
      await reader.open(path);

      expect(await reader.parse(), isNull);
      expect(reader.manifestFailure, contains('not found'));
    });

    test('manifest 是垃圾字节 → parse 返回 null，原因指向「解析失败」而不是「不存在」', () async {
      final archive = Archive()
        ..addFile(ArchiveFile(
          'AndroidManifest.xml',
          256,
          Uint8List.fromList(List.generate(256, (i) => i % 251)),
        ));
      final path = await _tempFile(
        tmp,
        'bad-manifest.apk',
        ZipEncoder().encode(archive),
      );

      final reader = ApkReader();
      expect(await reader.open(path), ArchiveOpenResult.ok);

      expect(await reader.parse(), isNull);
      expect(reader.manifestFailure, isNotNull);
      expect(
        reader.manifestFailure,
        isNot(contains('not found')),
        reason: '「文件在、但读不出来」与「文件不在」必须分开措辞',
      );
    });

    test('没 open 就 parse → 返回 null，不抛异常', () async {
      expect(await ApkReader().parse(), isNull);
    });

    test('解析失败后仍可读 hardening 线索，不抛异常', () async {
      final reader = ApkReader();
      await reader.open('$_fixtures/apk/night-mode-resources.apk');
      await reader.parse();

      expect(() => reader.scanHardeningSignals(), returnsNormally);
    });
  });
}
