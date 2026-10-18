// B-2：XapkInstaller 的**调用路径**安全测试。
//
// ## 与已有测试的分工
//
// `xapk_installer_test.dart` 覆盖的是「守卫本身」（`safeExtractJoin` 拒绝
// `..` / 绝对路径 / 盘符 / UNC / `~`）以及一条**源码级**断言：每个
// `zip.extractFile(...)` 之前都调过守卫。
//
// 源码级断言能挡住「新加的代码忘了过守卫」，但挡不住「守卫过了、后面的写入
// 仍然出问题」。本文件补的是**真的跑一遍 `install()`** 之后，磁盘上发生了什么：
//
// 1. manifest 里带 `../escaped.apk` → 安装失败，且**目标目录之外没有文件**；
// 2. 取消 → 失败，临时目录被删；
// 3. 两个条目名解析到**同一个路径**（`a/b.apk` 与 `a//b.apk`）→ 不产生两份；
// 4. 符号链接条目 → 写成普通文件，**不创建链接**；
// 5. manifest 里同一个分包列两次 → 只解一次、只传给 adb 一次；
// 6. base 的命名：XAPK 的 base 并不总是叫 `base.apk`（APKPure 用
//    `<包名>.apk`），所以「没有 base*」不能当成失败 —— 这条要钉住，
//    否则将来有人「顺手加个校验」就会误伤真实包。
//
// ## 边界
//
// `install()` 最后会调 `adb`。本文件的所有用例都在**调 adb 之前**就结束
// （越界 / 取消），或者只断言 adb 之前落盘的结果（碰撞 / 符号链接用
// `ZipHelper.extractFile` 这个**同一个**方法验证）。
// **不执行任何真实安装、不连设备。**

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/xapk_installer.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// 造一个 XAPK：`manifest.json` 里列出 [splitApks]，条目内容由 [entries] 给。
Future<File> _writeXapk(
  Directory dir, {
  required List<String> splitApks,
  Map<String, String>? entries,
}) async {
  final archive = Archive();
  archive.add(ArchiveFile.string(
    'manifest.json',
    jsonEncode({
      'package_name': 'com.example.demo',
      'split_apks': splitApks,
    }),
  ));
  for (final entry in (entries ?? const <String, String>{}).entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  final file = File(path.join(dir.path, 'sample.xapk'));
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void main() {
  late Directory work;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> logSub;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('xapk_path_safety');
    logs = [];
    logSub = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() async {
    await logSub.cancel();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  // -------------------------------------------------------------------
  // A. 越界条目：整条安装必须失败，且目标目录之外没有文件
  // -------------------------------------------------------------------

  group('A. manifest 里带越界条目', () {
    test('`../escaped.apk`：install 返回 false，目标目录之外没有文件', () async {
      final xapk = await _writeXapk(
        work,
        splitApks: ['../escaped.apk', 'base.apk'],
        entries: {'base.apk': 'base-bytes'},
      );
      // 临时目录放在 work 里面，这样「逃出去」会落在 work 里，可观测。
      final tempDir = Directory(path.join(work.path, 'tmp', 'install'));
      final installer = XapkInstaller();

      final ok = await installer.install(
        xapk.path,
        'device-not-used',
        const [],
        tempDirOverride: tempDir,
      );

      expect(ok, isFalse, reason: '越界条目必须让整条安装失败');
      expect(
        File(path.join(work.path, 'tmp', 'escaped.apk')).existsSync(),
        isFalse,
        reason: '条目名里的 `..` 不许真的把文件写到目标目录之外',
      );
      expect(
        File(path.join(work.path, 'escaped.apk')).existsSync(),
        isFalse,
        reason: '更上一层同样不许出现',
      );
      // 失败原因要能在日志里看到，而不是静默返回 false。
      expect(
        logs.any((r) => r.message.contains('escapes destination')),
        isTrue,
        reason: '日志里要说明是「越界」而不是笼统的失败：'
            '${logs.map((r) => r.message).join(' | ')}',
      );
    });

    test('绝对路径条目：同样被拒', () async {
      final xapk = await _writeXapk(
        work,
        splitApks: ['/tmp/absolute-escape.apk'],
      );
      final tempDir = Directory(path.join(work.path, 'tmp2', 'install'));
      final ok = await XapkInstaller().install(
        xapk.path,
        'device-not-used',
        const [],
        tempDirOverride: tempDir,
      );
      expect(ok, isFalse);
      expect(File('/tmp/absolute-escape.apk').existsSync(), isFalse);
    });
  });

  // -------------------------------------------------------------------
  // B. 取消：失败并且不留临时目录
  // -------------------------------------------------------------------

  group('B. 取消', () {
    test('一开始就取消：返回 false，临时目录被删掉', () async {
      final xapk = await _writeXapk(
        work,
        splitApks: ['base.apk'],
        entries: {'base.apk': 'base-bytes'},
      );
      final tempDir = Directory(path.join(work.path, 'tmp3', 'install'));
      await tempDir.create(recursive: true);

      final ok = await XapkInstaller().install(
        xapk.path,
        'device-not-used',
        const [],
        tempDirOverride: tempDir,
        isCancelled: () => true,
      );

      expect(ok, isFalse);
      expect(tempDir.existsSync(), isFalse, reason: '取消也要清临时目录');
    });
  });

  // -------------------------------------------------------------------
  // C. 两个条目名解析到同一路径
  // -------------------------------------------------------------------

  group('C. 同名条目碰撞', () {
    test('`a/b.apk` 与 `a//b.apk` 解析到同一个绝对路径', () {
      final installer = XapkInstaller();
      final root = path.join(work.path, 'root');
      final first = installer.safeExtractJoin(root, 'a/b.apk');
      final second = installer.safeExtractJoin(root, 'a//b.apk');
      expect(second, first, reason: '重复的分隔符不该产生第二个文件');
    });

    test('先后解出这两个条目：只有一份文件，内容是后写的那个', () async {
      // `install()` 用的就是 `ZipHelper.extractFile`，这里用同一个方法验证。
      final archive = Archive()
        ..addFile(ArchiveFile.string('a/b.apk', 'FIRST'))
        ..addFile(ArchiveFile.string('a//b.apk', 'SECOND'));
      final xapk = File(path.join(work.path, 'collide.xapk'));
      await xapk.writeAsBytes(ZipEncoder().encode(archive));

      final zip = ZipHelper();
      expect((await zip.open(xapk.path)).isOk, isTrue);
      final installer = XapkInstaller();
      final root = path.join(work.path, 'out');

      final firstTarget = installer.safeExtractJoin(root, 'a/b.apk');
      final secondTarget = installer.safeExtractJoin(root, 'a//b.apk');
      expect(await zip.extractFile('a/b.apk', firstTarget), isTrue);
      expect(await zip.extractFile('a//b.apk', secondTarget), isTrue);
      zip.close();

      // 只有一个文件（同名路径不会变成两份），且内容被后者覆盖。
      final files =
          Directory(root).listSync(recursive: true).whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.readAsStringSync(), 'SECOND');
    });
  });

  // -------------------------------------------------------------------
  // D. 符号链接条目
  // -------------------------------------------------------------------

  group('D. 符号链接条目', () {
    test('解包写成普通文件，不创建链接（内容就是链接目标字符串）', () async {
      // UNIX 的符号链接 = mode 0o120777，内容是目标路径。
      final target = '/etc/passwd';
      final archive = Archive()
        ..addFile(ArchiveFile('evil-link', target.length, _bytes(target))
          ..mode = 0x0000A1FF);
      final xapk = File(path.join(work.path, 'symlink.xapk'));
      await xapk.writeAsBytes(ZipEncoder().encode(archive));

      final zip = ZipHelper();
      expect((await zip.open(xapk.path)).isOk, isTrue);
      final root = path.join(work.path, 'sym-out');
      final dest = XapkInstaller().safeExtractJoin(root, 'evil-link');
      expect(await zip.extractFile('evil-link', dest), isTrue);
      zip.close();

      expect(File(dest).existsSync(), isTrue);
      expect(
        Link(dest).existsSync(),
        isFalse,
        reason: '符号链接条目绝不能被真的建成链接 —— 那等于把 /etc/passwd 交给后续写入',
      );
      expect(File(dest).readAsStringSync(), target, reason: '内容原样写成文件，不去跟随目标');
    });
  });

  // -------------------------------------------------------------------
  // E. manifest 里的重复条目
  // -------------------------------------------------------------------

  group('E. manifest 里同一个分包列两次', () {
    test('清单去重：同一个条目只出现一次（否则 adb 会收到重复路径）', () async {
      final xapk = await _writeXapk(
        work,
        splitApks: ['base.apk', 'base.apk', 'config.arm64.apk'],
        entries: {'base.apk': 'b', 'config.arm64.apk': 'c'},
      );
      final splits = await XapkInstaller().getSplitApks(xapk.path);
      expect(splits, isNotNull);
      expect(splits, hasLength(2), reason: '重复的 base.apk 必须只留一条');
      expect(splits!.where((s) => s == 'base.apk'), hasLength(1));
    });
  });

  // -------------------------------------------------------------------
  // F. base 的命名：不能把「没有 base*」当成失败
  // -------------------------------------------------------------------

  group('F. base 的命名约定', () {
    test('base 不叫 base.apk（APKPure 用 <包名>.apk）时照样列出全部', () async {
      final xapk = await _writeXapk(
        work,
        splitApks: ['com.example.demo.apk', 'config.arm64_v8a.apk'],
        entries: {
          'com.example.demo.apk': 'main',
          'config.arm64_v8a.apk': 'arm',
        },
      );
      final splits = await XapkInstaller().getSplitApks(xapk.path);
      expect(splits, isNotNull);
      expect(splits, hasLength(2), reason: '「没有 base* 就是坏包」会误伤真实的 APKPure 包');
    });

    test('多个 base* 时都排在非 base 之前（顺序稳定）', () async {
      final xapk = await _writeXapk(
        work,
        splitApks: ['config.zh.apk', 'base.apk', 'base-arm64.apk'],
        entries: {
          'config.zh.apk': 'zh',
          'base.apk': 'b',
          'base-arm64.apk': 'b64',
        },
      );
      final splits = await XapkInstaller().getSplitApks(xapk.path);
      expect(splits, isNotNull);
      expect(splits!.first.startsWith('base'), isTrue);
      expect(splits.last, 'config.zh.apk');
    });
  });
}
