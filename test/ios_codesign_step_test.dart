// 「解包 + codesign」这一步的测试。
//
// 重点全在**清理**与**结论语义**上：
// - 任何一条退出路径都不许留下临时目录；
// - 解包失败、工具缺失都必须归入「无法确认」，不能变成「签名无效」。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/ipaparser/ios_codesign_step.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

ArchiveFile _file(String name, List<int> content) =>
    ArchiveFile(name, content.length, Uint8List.fromList(content));

ArchiveFile _dir(String name) => ArchiveFile(name, 0, <int>[])..isFile = false;

Archive _ipa() => Archive()
  ..addFile(_dir('Payload/'))
  ..addFile(_dir('Payload/Example.app/'))
  ..addFile(_file('Payload/Example.app/Info.plist', List.filled(32, 1)))
  ..addFile(_file('Payload/Example.app/Example', List.filled(64, 2)));

/// 统计系统临时目录里由本工具创建的目录。
///
/// 用前缀过滤，避免把别的进程的临时目录算进来。
Set<String> _ourTempDirs() {
  final result = <String>{};
  for (final entity in Directory.systemTemp.listSync()) {
    final name = entity.path.split(Platform.pathSeparator).last;
    if (name.startsWith('appinfo_ipa_')) result.add(entity.path);
  }
  return result;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('appinfo_cs_step_test_');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<String> writeIpa([String name = 'app.ipa']) async {
    final path = '${temp.path}/$name';
    await File(path).writeAsBytes(ZipEncoder().encode(_ipa()), flush: true);
    return path;
  }

  IosBundle mainApp() => const IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/Example.app',
        name: 'Example.app',
      );

  group('IosCodeSignStep — 工具不可用时不解包', () {
    // `findCodesignPath` 只在非 macOS 上返回 null，因此这两条**只能在非 macOS
    // 上执行**。在 macOS 上用 skip 标记为「未执行」，而不是写一个提前 return
    // 让测试显示为通过 —— 那会把「没跑」伪装成「跑过了」。
    final notMac =
        Platform.isMacOS ? '该用例只在非 macOS 上执行（macOS 一定有 codesign）' : null;

    test('codesign 不可用时直接返回「工具不可用」，不创建临时目录', () async {
      final before = _ourTempDirs();
      final result = await IosCodeSignStep.run(await writeIpa(), mainApp());

      expect(result.status, SignatureStatus.toolUnavailable);
      expect(result.toolExecuted, isFalse);
      expect(result.error, contains('not available'));
      expect(_ourTempDirs(), before);
    }, skip: notMac);
  });

  group('IosCodeSignStep — 打开失败', () {
    test('IPA 不是 ZIP 时归入「工具不可用」，不留下临时目录', () async {
      final before = _ourTempDirs();
      final path = '${temp.path}/bad.ipa';
      await File(path).writeAsString('not a zip');

      final result = await IosCodeSignStep.run(
        path,
        mainApp(),
        codesignPath: '/usr/bin/true',
      );

      expect(result.status, SignatureStatus.toolUnavailable);
      expect(result.error, contains('reopened'));
      expect(_ourTempDirs(), before);
    });

    test('文件不存在时归入「工具不可用」', () async {
      final before = _ourTempDirs();
      final result = await IosCodeSignStep.run(
        '${temp.path}/missing.ipa',
        mainApp(),
        codesignPath: '/usr/bin/true',
      );

      expect(result.status, SignatureStatus.toolUnavailable);
      expect(_ourTempDirs(), before);
    });
  });

  group('IosCodeSignStep — 取消与清理', () {
    test('取消时返回「未知」并说明是取消，且不留临时目录', () async {
      final before = _ourTempDirs();
      final result = await IosCodeSignStep.run(
        await writeIpa(),
        mainApp(),
        codesignPath: '/usr/bin/true',
        isCancelled: () => true,
      );

      expect(result.status, SignatureStatus.unknown);
      expect(result.error, contains('cancelled'));
      expect(_ourTempDirs(), before);
    });

    test('bundle 在归档里不存在时归入「工具不可用」，不留临时目录', () async {
      final before = _ourTempDirs();
      final result = await IosCodeSignStep.run(
        await writeIpa(),
        const IosBundle(
          kind: IosBundleKind.mainApp,
          path: 'Payload/Missing.app',
          name: 'Missing.app',
        ),
        codesignPath: '/usr/bin/true',
      );

      expect(result.status, SignatureStatus.toolUnavailable);
      expect(result.error, contains('extracted'));
      expect(_ourTempDirs(), before);
    });
  });

  group('IosCodeSignStep — 端到端（仅在装有 codesign 的 macOS 上运行）', () {
    final codesign = _systemCodesignPath();
    final skipReason = codesign == null ? '本机没有 codesign' : null;

    test('解包后调用 codesign，并保证临时目录被删掉', () async {
      final before = _ourTempDirs();
      final path = await writeIpa();

      final result = await IosCodeSignStep.run(path, mainApp());

      // 归档里的「可执行文件」是 64 个 0x02 字节，不是 Mach-O，
      // 因此 codesign 不会说「验证通过」。这里断言的是**语义正确**：
      // 无论结论是什么，都不许是 verified。
      expect(result.status, isNot(SignatureStatus.verified));
      expect(result.toolExecuted, isTrue);
      expect(_ourTempDirs(), before, reason: '临时目录必须被清理');
    }, skip: skipReason);
  });
}

/// 系统 codesign 的存在性检查。
///
/// 单独写在这里是为了让本文件的 skip 判定**不依赖被测代码** —— 若被测代码的
/// 查找逻辑出错，测试应当因此失败，而不是被静默跳过。
String? _systemCodesignPath() {
  if (!Platform.isMacOS) return null;
  return File('/usr/bin/codesign').existsSync() ? '/usr/bin/codesign' : null;
}
