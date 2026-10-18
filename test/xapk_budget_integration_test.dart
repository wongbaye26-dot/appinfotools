// A1：XAPK 解包链路的预算集成测试。
//
// 走的是**真实调用链**：`XapkInstaller.install` → `ZipHelper.extractFile`
// → `ZipBudget.readEntry` → 逐块有界解压。
//
// 为什么需要这一组：阶段 A 的单元测试只证明「`readEntry` 有界」，
// 没有证明「XAPK 解包这条链真的把预算传下去了」。而这条链一旦漏了预算，
// 用户装一个恶意 XAPK 就能把内存/磁盘打满。
//
// 样本全部用 `ZipEncoder` 现造（不提交真实 XAPK，也不手拼字节）；
// 预算全部用**小值**（KB 级），不产生大内存分配。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/xapk_installer.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

/// 全零内容 —— 压缩比最高，能用极小样本逼出「解压后远超声明值」的场景。
Uint8List _zeros(int n) => Uint8List(n);

/// 把 ZIP 中央目录里某个条目的 `uncompressedSize` 改掉（偏移 +24）。
Uint8List _patchDeclaredSize(Uint8List zip, String name, int fakeSize) {
  final out = Uint8List.fromList(zip);
  for (var i = 0; i + 46 < out.length; i++) {
    if (out[i] != 0x50 ||
        out[i + 1] != 0x4b ||
        out[i + 2] != 0x01 ||
        out[i + 3] != 0x02) {
      continue;
    }
    final nameLen = out[i + 28] | (out[i + 29] << 8);
    final start = i + 46;
    if (start + nameLen > out.length) continue;
    if (String.fromCharCodes(out.sublist(start, start + nameLen)) != name) {
      continue;
    }
    final at = i + 24;
    out[at] = fakeSize & 0xff;
    out[at + 1] = (fakeSize >> 8) & 0xff;
    out[at + 2] = (fakeSize >> 16) & 0xff;
    out[at + 3] = (fakeSize >> 24) & 0xff;
    return out;
  }
  throw StateError('中央目录里没找到 $name');
}

/// 造一个 XAPK（`manifest.json` + 两个 APK 分包）并落盘。
Future<String> _writeXapk(
  Directory dir, {
  required int apkBytes,
  bool lieAboutSize = false,
}) async {
  final archive = Archive()
    ..addFile(ArchiveFile.string(
      'manifest.json',
      '{"package_name":"com.example.x","split_apks":'
          '["base.apk","config.arm64_v8a.apk"]}',
    ))
    ..addFile(ArchiveFile('base.apk', apkBytes, _zeros(apkBytes)))
    ..addFile(ArchiveFile('config.arm64_v8a.apk', apkBytes, _zeros(apkBytes)));

  var bytes = Uint8List.fromList(ZipEncoder().encode(archive));
  if (lieAboutSize) {
    // 声明 1 KiB，实际 apkBytes —— 中央目录撒谎。
    bytes = _patchDeclaredSize(bytes, 'base.apk', 1024);
  }
  final file = File(path.join(dir.path, 'sample.xapk'));
  await file.writeAsBytes(bytes);
  return file.path;
}

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('xapk_budget_test');
  });

  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  group('ZipHelper.extractFile —— xapk_installer 实际调用的那一层', () {
    test('预算内正常解出，字节完全一致', () async {
      final xapk = await _writeXapk(work, apkBytes: 8 * 1024);
      final out = path.join(work.path, 'out', 'base.apk');

      final zip = ZipHelper(maxSessionBytes: 1 << 20);
      expect((await zip.open(xapk)).isOk, isTrue);
      expect(await zip.extractFile('base.apk', out), isTrue);
      zip.close();

      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), 8 * 1024);
    });

    test('真实产出超限 -> 返回 false，且**不留下目标文件**', () async {
      final xapk = await _writeXapk(work, apkBytes: 64 * 1024);
      final out = path.join(work.path, 'out', 'base.apk');

      // 单次流程预算 8 KiB，条目 64 KiB。
      final zip = ZipHelper(maxSessionBytes: 8 * 1024);
      expect((await zip.open(xapk)).isOk, isTrue);
      expect(await zip.extractFile('base.apk', out), isFalse);
      zip.close();

      expect(File(out).existsSync(), isFalse,
          reason: '被拒绝时不得写出任何文件（否则用户会看到一个「解好了」的残片）');
    });

    test('中央目录撒谎（声明 1 KiB / 实际 64 KiB）同样被拦', () async {
      final xapk = await _writeXapk(
        work,
        apkBytes: 64 * 1024,
        lieAboutSize: true,
      );
      final out = path.join(work.path, 'out', 'base.apk');

      final zip = ZipHelper(maxSessionBytes: 8 * 1024);
      expect((await zip.open(xapk)).isOk, isTrue,
          reason: '声明值在预算内，所以 open 应当通过 —— 这正是漏洞的入口');
      expect(await zip.extractFile('base.apk', out), isFalse);
      zip.close();

      expect(File(out).existsSync(), isFalse);
    });

    test('累计超限：两个分包各 6 KiB，预算 8 KiB -> 第二个被拒', () async {
      final xapk = await _writeXapk(work, apkBytes: 6 * 1024);
      final outDir = path.join(work.path, 'out');

      final zip = ZipHelper(maxSessionBytes: 8 * 1024);
      expect((await zip.open(xapk)).isOk, isTrue);
      expect(await zip.extractFile('base.apk', path.join(outDir, 'base.apk')),
          isTrue);
      expect(
        await zip.extractFile(
            'config.arm64_v8a.apk', path.join(outDir, 'config.apk')),
        isFalse,
        reason: '共享 ledger：第一个用掉 6 KiB 后只剩 2 KiB',
      );
      zip.close();

      expect(File(path.join(outDir, 'base.apk')).existsSync(), isTrue);
      expect(File(path.join(outDir, 'config.apk')).existsSync(), isFalse);
    });

    test('解包只写在目标目录内（无越界写入）', () async {
      final xapk = await _writeXapk(work, apkBytes: 4 * 1024);
      final target = Directory(path.join(work.path, 'target'))..createSync();
      final out = path.join(target.path, 'base.apk');

      final zip = ZipHelper(maxSessionBytes: 1 << 20);
      await zip.open(xapk);
      expect(await zip.extractFile('base.apk', out), isTrue);
      zip.close();

      // 目标目录里只有它自己；work 根目录下没有多出文件。
      final inTarget = target
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => path.basename(f.path))
          .toList();
      expect(inTarget, ['base.apk']);
      final inWork = work
          .listSync()
          .whereType<File>()
          .map((f) => path.basename(f.path))
          .toList();
      expect(inWork, ['sample.xapk'], reason: '不得在目标目录之外写出任何东西');
    });
  });

  group('XapkInstaller.install —— 全链路', () {
    test('小预算时在解包阶段就失败，不会走到 adb，临时目录被清理', () async {
      final xapk = await _writeXapk(work, apkBytes: 64 * 1024);
      final tempDir = Directory(path.join(work.path, 'temp'))..createSync();

      final records = <String>[];
      final sub = Logger.root.onRecord.listen((r) => records.add(r.message));
      addTearDown(sub.cancel);

      final installer = XapkInstaller();
      final ok = await installer.install(
        xapk,
        'emulator-5554',
        const ['-r'],
        tempDirOverride: tempDir,
        maxSessionBytes: 8 * 1024,
      );

      expect(ok, isFalse);
      // 运行时证据：走的是**解包失败**这条分支。
      expect(
        records.any((m) => m.contains('Failed to extract APK')),
        isTrue,
        reason: '应当在解包阶段失败：$records',
      );
      // 没走到 adb —— 外层 catch 的措辞不会出现。
      expect(
        records.any((m) => m.contains('Failed to install XAPK')),
        isFalse,
        reason: '解包失败后不应继续执行安装命令：$records',
      );
      // finally 的清理生效。
      expect(tempDir.existsSync(), isFalse, reason: '临时目录必须被删除');
    });

    test('预算内：解包成功（随后因无 adb 失败），临时目录同样被清理', () async {
      final xapk = await _writeXapk(work, apkBytes: 4 * 1024);
      final tempDir = Directory(path.join(work.path, 'temp2'))..createSync();

      final records = <String>[];
      final sub = Logger.root.onRecord.listen((r) => records.add(r.message));
      addTearDown(sub.cancel);

      final installer = XapkInstaller();
      final ok = await installer.install(
        xapk,
        'emulator-5554',
        const ['-r'],
        tempDirOverride: tempDir,
        maxSessionBytes: 1 << 20,
      );

      // 没有真机 / 没有 adb，安装必然失败 —— 但**解包阶段不该报错**。
      expect(ok, isFalse);
      expect(
        records.any((m) => m.contains('Failed to extract APK')),
        isFalse,
        reason: '预算内不该在解包阶段失败：$records',
      );
      expect(tempDir.existsSync(), isFalse);
    });
  });
}
