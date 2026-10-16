// XAPK 安装路径的 **Zip Slip** 回归测试。
//
// ## 背景
//
// 2026-10-13 的安全审计 T0-1：XAPK 的 manifest 没有可用分包列表时，代码回退到
// 枚举 ZIP 条目名并 `path.join(tempDir, apk)` 直接解包 —— `path.join` 只拼接、
// 不归一化，条目名 `Android/../../evil.apk` 会被 OS 解析到临时目录之外。
// 修复是把守卫收口到 `ZipGuard.safeJoin`，XAPK 解包统一走 `safeExtractJoin`。
//
// ## 本测试钉两件事
//
// 1. **行为**：`safeExtractJoin` 对越界条目抛异常、对正常条目放行（成对断言 ——
//    守卫不能把正常包也拦掉）。
// 2. **接线**：源码里**每一个** `zip.extractFile(...)` 之前都必须调过
//    `safeExtractJoin`。这一条比第 1 条更重要 —— 守卫本身有 `utils_test.dart`
//    的 9 个用例守着，但「新增一条解包路径却忘了过守卫」是**没有测试能发现**的
//    那类回归，所以这里直接读源码断言。
//
// 夹具在测试内用 `ZipEncoder` 现造（不提交真实 XAPK 样本，也不手拼字节）。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:apk_info_tool/utils/xapk_installer.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用 [ZipEncoder] 造一个 ZIP 并落盘，返回路径。
Future<String> _writeZip(Directory dir, String name, Archive archive) async {
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file.path;
}

ArchiveFile _entry(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xapk_installer_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  // -------------------------------------------------------------------
  // 接线：每个解包点都必须过守卫
  // -------------------------------------------------------------------

  group('源码级守卫：解包点不得绕过 ZipGuard', () {
    // 与 `info_page.dart` 的 `?? ""` 断言同一套做法：约定写不进类型系统，
    // 就用源码断言把它钉住。
    const sourcePath = 'lib/utils/xapk_installer.dart';

    /// 剥掉**整行都是注释**的行再扫描。
    ///
    /// 第一版没有这一步，于是文档注释里那句「每个 `zip.extractFile(...)`
    /// 之前都调过它」被当成了一个调用点，测试直接假红。
    /// **这正是本项目栽过两次的那类错误**（`V2.4.0_PROGRESS.md` §16.6 / §18.3：
    /// 清点源码字面量时正则覆盖不全，数出来的数字是假的），所以显式处理。
    String codeOnly(String source) => source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    test('每一个 zip.extractFile(...) 之前都调过 safeExtractJoin', () {
      final source = codeOnly(File(sourcePath).readAsStringSync());

      final sites = RegExp(r'zip\.extractFile\(').allMatches(source).toList();
      expect(
        sites,
        isNotEmpty,
        reason: '一个解包点都没找到 —— 说明源码结构变了，'
            '这条守卫正在空转，必须同步更新它而不是让它静默通过',
      );

      for (final site in sites) {
        final line = source.substring(0, site.start).split('\n').length;
        final window = source.substring(max(0, site.start - 400), site.start);
        expect(
          window.contains('safeExtractJoin('),
          isTrue,
          reason: '$sourcePath 的某个 zip.extractFile 之前 400 字符内'
              '没有 safeExtractJoin —— 新增的解包路径绕过了 ZipGuard'
              '（扫描的是剥掉注释后的第 $line 行）',
        );
      }
    });

    test('守卫调用点的数量不少于解包点（不能只有一处过守卫）', () {
      final source = codeOnly(File(sourcePath).readAsStringSync());
      final guardCalls = RegExp(r'safeExtractJoin\(').allMatches(source).length;
      final extractCalls =
          RegExp(r'zip\.extractFile\(').allMatches(source).length;

      expect(extractCalls, greaterThanOrEqualTo(1));
      expect(
        guardCalls,
        greaterThanOrEqualTo(extractCalls),
        reason: '过守卫的次数（$guardCalls）少于解包次数（$extractCalls）',
      );
    });

    test('守卫本身仍然委托给 ZipGuard.safeJoin（没有被改成「自己拼」）', () {
      final source = codeOnly(File(sourcePath).readAsStringSync());
      expect(
        source.contains('ZipGuard.safeJoin'),
        isTrue,
        reason: 'safeExtractJoin 必须继续走 ZipGuard.safeJoin，'
            '否则前面那条「调过守卫」的断言就成了空话',
      );
    });
  });

  // -------------------------------------------------------------------
  // 行为：越界拒绝 / 正常放行
  // -------------------------------------------------------------------

  group('safeExtractJoin：越界条目抛异常', () {
    late XapkInstaller installer;
    late String root;

    setUp(() {
      installer = XapkInstaller();
      root = tmp.path;
    });

    test('父目录上跳被拒绝（T0-1 的原始攻击形态）', () {
      expect(
        () => installer.safeExtractJoin(root, 'Android/../../evil.apk'),
        throwsArgumentError,
      );
      expect(
        () => installer.safeExtractJoin(root, '../../.ssh/authorized_keys'),
        throwsArgumentError,
      );
    });

    test('绝对路径被拒绝', () {
      expect(
        () => installer.safeExtractJoin(root, '/etc/passwd'),
        throwsArgumentError,
      );
    });

    test('Windows 盘符被拒绝', () {
      expect(
        () => installer.safeExtractJoin(root, r'C:\Windows\System32\cmd.exe'),
        throwsArgumentError,
      );
    });

    test('UNC 路径被拒绝', () {
      expect(
        () => installer.safeExtractJoin(root, r'\\server\share\evil.exe'),
        throwsArgumentError,
      );
    });

    test('~ 前缀被拒绝', () {
      expect(
        () => installer.safeExtractJoin(root, '~/.zshrc'),
        throwsArgumentError,
      );
    });

    test('空条目名被拒绝', () {
      expect(
        () => installer.safeExtractJoin(root, ''),
        throwsArgumentError,
      );
    });

    test('正常的分包与 OBB 条目照常放行（守卫不能把正常包也拦掉）', () {
      for (final entry in [
        'base.apk',
        'split_config.arm64_v8a.apk',
        'Android/obb/com.example.app/main.1.com.example.app.obb',
        'res/drawable/a..b.png', // 看着像越界，其实没有上跳
      ]) {
        final resolved = installer.safeExtractJoin(root, entry);
        expect(
          resolved.startsWith(root),
          isTrue,
          reason: '$entry 应落在 $root 之内（实际 $resolved）',
        );
      }
    });

    test('越界条目不会在目标目录之外留下任何文件', () async {
      final outside = File('${tmp.parent.path}/xapk_escape_probe.apk');
      expect(outside.existsSync(), isFalse);

      expect(
        () => installer.safeExtractJoin(root, '../xapk_escape_probe.apk'),
        throwsArgumentError,
      );

      // 守卫只做路径判定、不落盘；这里确认「拒绝」没有副作用。
      expect(
        outside.existsSync(),
        isFalse,
        reason: '越界条目不得在目标目录之外产生文件',
      );
    });
  });

  // -------------------------------------------------------------------
  // getSplitApks：公开入口的行为回归
  // -------------------------------------------------------------------

  group('getSplitApks：分包清单的来源与排序', () {
    test('manifest.json 里有 split_apks 时用它，且 base 排在最前', () async {
      final archive = Archive()
        ..addFile(_entry(
          'manifest.json',
          jsonEncode({
            'package_name': 'com.example.app',
            // 故意把 base 放在后面 —— 排序必须是代码保证的，不是碰巧
            'split_apks': [
              'split_config.arm64_v8a.apk',
              'split_config.xxhdpi.apk',
              'base.apk',
            ],
          }),
        ))
        ..addFile(_entry('base.apk', 'stub'))
        ..addFile(_entry('split_config.arm64_v8a.apk', 'stub'))
        ..addFile(_entry('split_config.xxhdpi.apk', 'stub'));

      final path = await _writeZip(tmp, 'with-manifest.xapk', archive);
      final splits = await XapkInstaller().getSplitApks(path);

      expect(splits, isNotNull);
      expect(splits!.first, 'base.apk');
      expect(splits.length, 3);
    });

    test('没有 manifest 时回退到枚举 .apk 条目', () async {
      final archive = Archive()
        ..addFile(_entry('base.apk', 'stub'))
        ..addFile(_entry('split_config.armeabi_v7a.apk', 'stub'))
        ..addFile(_entry('icon.png', 'not-an-apk'));

      final path = await _writeZip(tmp, 'no-manifest.xapk', archive);
      final splits = await XapkInstaller().getSplitApks(path);

      expect(splits, isNotNull);
      expect(splits!.first, 'base.apk');
      expect(splits.length, 2, reason: '非 .apk 条目不应混进来');
      expect(splits.any((s) => s.endsWith('.png')), isFalse);
    });

    test('既没有 manifest 也没有 .apk 条目时返回 null', () async {
      final archive = Archive()..addFile(_entry('readme.txt', 'nothing here'));
      final path = await _writeZip(tmp, 'empty.xapk', archive);

      expect(await XapkInstaller().getSplitApks(path), isNull);
    });

    test('不是归档的文件返回 null（不抛异常）', () async {
      final bogus = File('${tmp.path}/not-a-zip.xapk');
      await bogus.writeAsString('this is definitely not a zip archive');

      expect(await XapkInstaller().getSplitApks(bogus.path), isNull);
    });

    test('manifest 里的条目名带越界片段时，清单照原样返回、由解包点拦下', () async {
      // 这里刻意**不在清单层过滤** —— 拦截点是 `safeExtractJoin`（解包前）。
      // 本用例钉住「两层职责分开」：清单只管列出，守卫只管拦截。
      final archive = Archive()
        ..addFile(_entry(
          'manifest.json',
          jsonEncode({
            'split_apks': ['base.apk', '../../evil.apk'],
          }),
        ))
        ..addFile(_entry('base.apk', 'stub'));

      final path = await _writeZip(tmp, 'malicious-manifest.xapk', archive);
      final splits = await XapkInstaller().getSplitApks(path);

      expect(splits, isNotNull);
      expect(splits, contains('../../evil.apk'));

      // 而解包点会把它拦下。
      expect(
        () => XapkInstaller().safeExtractJoin(tmp.path, '../../evil.apk'),
        throwsArgumentError,
      );
    });
  });
}
