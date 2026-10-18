// A2：工具下载解包链路的预算集成测试。
//
// 走的是真实方法：`ToolDownloader.extractPlatformTools` /
// `extractBuildTools` → `ZipBudget.ensureWithin`（声明级）→
// `ZipGuard.extractToDirectory`（**逐条目有界**）→ `ZipBudget.readEntry`。
//
// 为什么不测整条下载流程：那要先联网下载 platform-tools / build-tools，
// 而任务书明确要求「不要为了测试而自动下载或执行不可信工具」。
// 因此把「下载」与「解包」在测试里切开 —— 解包这一步是**同一个方法**，
// 不是复制品。
//
// 校验和那一侧已有 `tool_downloader_test.dart` 覆盖（一致 / 不匹配 /
// 未声明 / 两者可区分），本文件只补「解包」与「两种失败可区分」。

import 'dart:io';
import 'dart:typed_data';

import 'package:apk_info_tool/utils/tool_downloader.dart';
import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

Uint8List _zeros(int n) => Uint8List(n);

/// 造一个 platform-tools 风格的归档：条目都带 `platform-tools/` 前缀。
Future<File> _writePlatformTools(Directory dir, {required int adbBytes}) async {
  final archive = Archive()
    ..addFile(ArchiveFile('platform-tools/adb', adbBytes, _zeros(adbBytes)))
    ..addFile(ArchiveFile.string(
        'platform-tools/source.properties', 'Pkg.Revision=35.0.0\n'));
  final file = File(path.join(dir.path, 'platform-tools.zip'));
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

/// 把中央目录里某个条目的 `uncompressedSize` 改大 —— 制造「声明级超限」。
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

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('tool_unpack_budget_test');
  });

  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  group('extractPlatformTools —— 真实解包方法', () {
    test('正常归档：前缀被剥离，文件落到 platform-tools/ 下', () async {
      final zip = await _writePlatformTools(work, adbBytes: 8 * 1024);
      final installDir = path.join(work.path, 'install');

      await ToolDownloader.extractPlatformTools(zip, installDir);

      final adb = File(path.join(installDir, 'platform-tools', 'adb'));
      expect(adb.existsSync(), isTrue);
      expect(adb.lengthSync(), 8 * 1024);
      expect(
        File(path.join(installDir, 'platform-tools', 'source.properties'))
            .existsSync(),
        isTrue,
      );
    });

    test('真实产出超限：抛 ZipBombException，且**不留下**可当作成功的 adb', () async {
      final zip = await _writePlatformTools(work, adbBytes: 64 * 1024);
      final installDir = path.join(work.path, 'install');

      await expectLater(
        ToolDownloader.extractPlatformTools(
          zip,
          installDir,
          maxSessionBytes: 8 * 1024,
        ),
        throwsA(isA<ZipBombException>()),
      );

      // 「解到一半的 adb」最危险 —— 它会被上层当成可用工具。
      expect(
        File(path.join(installDir, 'platform-tools', 'adb')).existsSync(),
        isFalse,
        reason: '被拒绝的条目不得留下任何文件',
      );
    });

    test('声明级超限：在解包**之前**就被 ensureWithin 拒掉（目录里一个文件都没有）', () async {
      // 造一个声明 300 MiB 的条目 —— 超过单条目 256 MiB 上限。
      final honest = await _writePlatformTools(work, adbBytes: 64);
      final fake = _patchDeclaredSize(
        Uint8List.fromList(await honest.readAsBytes()),
        'platform-tools/adb',
        300 * 1024 * 1024,
      );
      final liar = File(path.join(work.path, 'liar.zip'));
      await liar.writeAsBytes(fake);
      final installDir = path.join(work.path, 'install2');

      await expectLater(
        ToolDownloader.extractPlatformTools(liar, installDir),
        throwsA(isA<ZipBombException>()),
      );

      final extracted = Directory(installDir).existsSync()
          ? Directory(installDir)
              .listSync(recursive: true)
              .whereType<File>()
              .length
          : 0;
      expect(extracted, 0, reason: '声明级拒绝发生在写盘之前');
    });

    test('解压失败与校验和不匹配是**不同的异常类型**（调用方能分别提示）', () async {
      final zip = await _writePlatformTools(work, adbBytes: 64 * 1024);
      final installDir = path.join(work.path, 'install3');

      // 解压侧：ZipBombException
      await expectLater(
        ToolDownloader.extractPlatformTools(
          zip,
          installDir,
          maxSessionBytes: 8 * 1024,
        ),
        throwsA(isA<ZipBombException>()),
      );

      // 校验和侧：ToolDownloadException(checksumMismatch)
      final info = ArchiveInfo(
        url: 'https://example.invalid/x.zip',
        checksums: {'sha256': 'deadbeef' * 8},
      );
      await expectLater(
        ToolDownloader.verifyArchiveChecksum(zip, info),
        throwsA(isA<ToolDownloadException>().having(
          (e) => e.code,
          'code',
          ToolDownloadError.checksumMismatch,
        )),
      );

      // 两者不是同一个类型 —— 界面不会把「超预算」说成「校验失败」。
      expect(
        isA<ZipBombException>().matches(
          ToolDownloadException(ToolDownloadError.checksumMismatch),
          {},
        ),
        isFalse,
      );
    });
  });

  group('extractBuildTools —— 前缀自动探测', () {
    test('正常归档：按 build-tools/<version>/ 剥离', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('build-tools/35.0.0/aapt2', 4096, _zeros(4096)))
        ..addFile(ArchiveFile.string('build-tools/35.0.0/package.xml', '<x/>'));
      final zip = File(path.join(work.path, 'build-tools.zip'));
      await zip.writeAsBytes(ZipEncoder().encode(archive));
      final installDir = path.join(work.path, 'bt');

      await ToolDownloader.extractBuildTools(zip, installDir, '35.0.0');

      expect(
        File(path.join(installDir, 'build-tools', '35.0.0', 'aapt2'))
            .existsSync(),
        isTrue,
      );
    });

    test('小预算：同样抛 ZipBombException，不留下 aapt2', () async {
      final archive = Archive()
        ..addFile(ArchiveFile(
            'build-tools/35.0.0/aapt2', 64 * 1024, _zeros(64 * 1024)));
      final zip = File(path.join(work.path, 'build-tools2.zip'));
      await zip.writeAsBytes(ZipEncoder().encode(archive));
      final installDir = path.join(work.path, 'bt2');

      await expectLater(
        ToolDownloader.extractBuildTools(
          zip,
          installDir,
          '35.0.0',
          maxSessionBytes: 8 * 1024,
        ),
        throwsA(isA<ZipBombException>()),
      );

      expect(
        File(path.join(installDir, 'build-tools', '35.0.0', 'aapt2'))
            .existsSync(),
        isFalse,
      );
    });
  });
}
