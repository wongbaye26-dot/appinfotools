// iOS bundle 解包的安全测试（规范 5.1 / 5.5）。
//
// 这一层是**真的往磁盘上写文件**，因此测试的重点不是「正常路径能跑通」，
// 而是「不正常输入写不出东西」。每条拒绝路径都额外断言目标目录里没有多出
// 任何文件 —— 只断言返回值不足以说明磁盘是干净的。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/ipa_bundle_extractor.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

ArchiveFile _file(String name, List<int> content, {int? declaredSize}) =>
    ArchiveFile(
        name, declaredSize ?? content.length, Uint8List.fromList(content));

ArchiveFile _dir(String name) => ArchiveFile(name, 0, <int>[])..isFile = false;

/// 一个结构完整的主应用。
Archive _ipa() => Archive()
  ..addFile(_dir('Payload/'))
  ..addFile(_dir('Payload/MyApp.app/'))
  ..addFile(_file('Payload/MyApp.app/Info.plist', List.filled(32, 1)))
  ..addFile(_file('Payload/MyApp.app/MyApp', List.filled(64, 2)))
  ..addFile(_file(
      'Payload/MyApp.app/_CodeSignature/CodeResources', List.filled(16, 3)))
  ..addFile(_dir('Payload/MyApp.app/Frameworks/'))
  ..addFile(_file(
      'Payload/MyApp.app/Frameworks/Lib.framework/Lib', List.filled(24, 4)))
  // 另一个应用：不应被解包。
  ..addFile(_file('Payload/Other.app/Info.plist', List.filled(8, 9)));

IosBundle _mainApp(Archive archive) =>
    IpaContainerReader.read(archive).mainApp!;

/// 统计目录下的文件数与总字节数。
(int, int) _treeSize(Directory dir) {
  if (!dir.existsSync()) return (0, 0);
  var files = 0;
  var bytes = 0;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File) {
      files++;
      bytes += entity.lengthSync();
    }
  }
  return (files, bytes);
}

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('appinfo_extract_test_');
  });

  tearDown(() async {
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  /// 让解包落到沙箱里，便于断言磁盘状态。
  Future<IpaExtractionResult> extract(
    Archive archive, {
    bool Function()? isCancelled,
  }) =>
      IpaBundleExtractor.extract(
        archive,
        _mainApp(archive),
        isCancelled: isCancelled,
        destinationRoot: '${sandbox.path}/out',
      );

  group('IpaBundleExtractor — 正常路径', () {
    test('只解包目标 bundle 的内容', () async {
      final archive = _ipa();
      final result = await extract(archive);

      expect(result.ok, isTrue, reason: result.failure);
      expect(result.entryCount, 4);
      expect(result.symlinkCount, 0);
      expect(result.bundlePath, '${sandbox.path}/out/MyApp.app');

      expect(File('${result.bundlePath}/Info.plist').existsSync(), isTrue);
      expect(File('${result.bundlePath}/MyApp').existsSync(), isTrue);
      expect(
        File('${result.bundlePath}/_CodeSignature/CodeResources').existsSync(),
        isTrue,
      );
      expect(
        File('${result.bundlePath}/Frameworks/Lib.framework/Lib').existsSync(),
        isTrue,
      );
    });

    test('另一个应用的条目不会出现在磁盘上', () async {
      final result = await extract(_ipa());

      expect(result.ok, isTrue);
      final (files, _) = _treeSize(Directory('${sandbox.path}/out'));
      expect(files, 4);
      expect(
        Directory('${sandbox.path}/out/Other.app').existsSync(),
        isFalse,
      );
    });

    test('写出的字节数与源内容一致', () async {
      final result = await extract(_ipa());

      expect(result.ok, isTrue);
      // 32 + 64 + 16 + 24
      expect(result.totalBytes, 136);
      final (_, bytes) = _treeSize(Directory('${sandbox.path}/out'));
      expect(bytes, 136);

      final myApp = File('${result.bundlePath}/MyApp').readAsBytesSync();
      expect(myApp, List.filled(64, 2));
    });

    test('bundle 在归档里没有任何文件时明确失败，而不是返回空目录', () async {
      // 容器层不会为「零文件的 bundle」建条目（它按文件条目枚举），因此这条
      // 防御分支只能由直接构造的 IosBundle 触发 —— 正是「容器说有、归档里
      // 没有」这种内部不一致的场景。
      const bundle = IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/Missing.app',
        name: 'Missing.app',
      );

      final result = await IpaBundleExtractor.extract(
        _ipa(),
        bundle,
        destinationRoot: '${sandbox.path}/out2',
      );

      expect(result.ok, isFalse);
      expect(result.failureCode, 'empty_bundle');
      expect(Directory('${sandbox.path}/out2').existsSync(), isFalse);
    });
  });

  group('IpaBundleExtractor — 路径安全', () {
    test('条目名带 .. 时拒绝，且不在目标目录之外写出任何文件', () async {
      final archive = _ipa()
        ..addFile(
            _file('Payload/MyApp.app/../../escaped.txt', List.filled(4, 0xAA)));

      final result = await extract(archive);

      expect(result.ok, isFalse);
      expect(result.failureCode, 'unsafe_entry');
      expect(File('${sandbox.path}/escaped.txt').existsSync(), isFalse);
      expect(File('${sandbox.path}/out/escaped.txt').existsSync(), isFalse);
    });

    test('绝对路径条目不在 bundle 前缀内，因此不会被写出', () async {
      final archive = _ipa()
        ..addFile(_file('/Payload/MyApp.app/evil.txt', List.filled(4, 1)));

      // 绝对路径条目不满足 `Payload/MyApp.app/` 前缀，被前缀过滤掉，
      // 走不到 safeJoin。两条路都安全，这里断言的是「没有被写出」。
      final result = await extract(archive);

      expect(result.ok, isTrue);
      final (files, _) = _treeSize(Directory('${sandbox.path}/out'));
      expect(files, 4);
      expect(
          File('${sandbox.path}/out/MyApp.app/evil.txt').existsSync(), isFalse);
    });

    test('前缀之内但越出 bundle 目录的条目被拒绝', () async {
      // `Payload/MyApp.app/../MyApp.app/ok.txt` 归一化后仍在 bundle 内，
      // 但含 `..` 段 —— safeJoin 逐段拒绝，不做归一化后再放行。
      final archive = _ipa()
        ..addFile(_file(
            'Payload/MyApp.app/sub/../../MyApp.app/ok.txt', List.filled(4, 1)));

      final result = await extract(archive);

      expect(result.ok, isFalse);
      expect(result.failureCode, 'unsafe_entry');
      expect(Directory('${sandbox.path}/out').existsSync(), isFalse);
    });

    test('反斜杠分隔符被规范化后仍受校验', () async {
      final archive = _ipa()
        ..addFile(
            _file(r'Payload/MyApp.app\..\..\escaped.txt', List.filled(4, 1)));

      final result = await extract(archive);

      expect(result.ok, isFalse);
      expect(result.failureCode, 'unsafe_entry');
      expect(File('${sandbox.path}/escaped.txt').existsSync(), isFalse);
    });

    test('符号链接被当作普通文件写，不会在磁盘上建出链接', () async {
      final archive = _ipa();
      final link = ArchiveFile('Payload/MyApp.app/link', 16,
          Uint8List.fromList(List.filled(16, 0x2F)));
      link.symbolicLink = '../../../../etc/passwd';
      archive.addFile(link);

      final result = await extract(archive);

      expect(result.ok, isTrue, reason: result.failure);
      expect(result.symlinkCount, 1);

      final linkFile = File('${result.bundlePath}/link');
      expect(linkFile.existsSync(), isTrue);
      expect(Link(linkFile.path).existsSync(), isFalse, reason: '磁盘上不应存在符号链接');
    });
  });

  group('IpaBundleExtractor — 资源上限', () {
    test('条目数超限时在写盘之前就拒绝', () async {
      final archive = Archive()
        ..addFile(_dir('Payload/'))
        ..addFile(_dir('Payload/MyApp.app/'));
      for (var i = 0; i <= IpaBundleExtractor.maxEntryCount; i++) {
        archive.addFile(_file('Payload/MyApp.app/f$i', const [1]));
      }

      final result = await extract(archive);

      expect(result.ok, isFalse);
      expect(result.failureCode, 'too_many_entries');
      // 关键断言：一条都没写。
      expect(Directory('${sandbox.path}/out').existsSync(), isFalse);
    });

    test('声明解压总量超限时在写盘之前就拒绝', () async {
      final archive = _ipa();
      // 只声明尺寸、不给内容 —— 上限检查发生在读取内容之前。
      archive.addFile(ArchiveFile(
        'Payload/MyApp.app/huge.bin',
        IpaBundleExtractor.maxTotalBytes + 1,
        Uint8List.fromList(const [1]),
      ));

      final result = await extract(archive);

      expect(result.ok, isFalse);
      expect(result.failureCode, 'too_large');
      expect(Directory('${sandbox.path}/out').existsSync(), isFalse);
    });

    test('声明尺寸与实际不符时拒绝，并且不留下半成品', () async {
      final archive = _ipa()
        // 声称 4096 字节，实际只有 4 字节。
        ..addFile(_file('Payload/MyApp.app/liar.bin', List.filled(4, 1),
            declaredSize: 4096));

      final result = await extract(archive);

      expect(result.ok, isFalse);
      expect(result.failureCode, 'size_mismatch');
      expect(result.failure, contains('4096'));
      // 已经写出的文件也要清掉。
      final (files, _) = _treeSize(Directory('${sandbox.path}/out'));
      expect(files, 0);
    });
  });

  group('IpaBundleExtractor — 取消与清理', () {
    test('取消时不留下任何文件', () async {
      final archive = _ipa();
      final result = await extract(archive, isCancelled: () => true);

      expect(result.ok, isFalse);
      expect(result.cancelled, isTrue);
      expect(result.failureCode, 'cancelled');
      final (files, _) = _treeSize(Directory('${sandbox.path}/out'));
      expect(files, 0);
    });

    test('中途取消会清掉已经写出的部分', () async {
      final archive = _ipa();
      var calls = 0;
      final result = await extract(archive, isCancelled: () => calls++ >= 2);

      expect(result.cancelled, isTrue);
      final (files, _) = _treeSize(Directory('${sandbox.path}/out'));
      expect(files, 0, reason: '取消后不应留下半成品');
    });

    test('cleanUp 删除临时目录', () async {
      final result = await extract(_ipa());
      expect(result.ok, isTrue);

      final root = Directory(result.tempRoot!);
      expect(root.existsSync(), isTrue);

      await IpaBundleExtractor.cleanUp(result.tempRoot);
      expect(root.existsSync(), isFalse);
    });

    test('cleanUp 对 null 与不存在的目录都不报错', () async {
      await expectLater(IpaBundleExtractor.cleanUp(null), completes);
      await expectLater(
        IpaBundleExtractor.cleanUp('${sandbox.path}/never-existed'),
        completes,
      );
    });

    test('cleanUp 失败时不抛异常', () async {
      // 传一个不是目录的路径。
      final file = File('${sandbox.path}/a-file')..writeAsStringSync('x');
      await expectLater(
        IpaBundleExtractor.cleanUp(file.path),
        completes,
      );
    });
  });
}
