// `ApkReader.entryFacts()`：一次遍历把归档条目变成平台无关事实表。
//
// 这是 Phase B 事实层的入口之一（清单/载荷探测都吃它），所以断言两类东西：
// 1. 真实包（`attr-fixture.apk`）上的路径归一化与压缩字段；
// 2. 目录条目 —— 仓库里的 APK 夹具都没有显式目录条目（打包器省略了），
//    因此用内存 ZIPC 现场合成一个，专门验证 `isDirectory` 与「目录不给
//    压缩字段」的口径。

import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:test/test.dart';

const String _fixture = '../../test/fixtures/apk/attr-fixture.apk';

/// 造一个带目录条目、怪路径的内存 ZIP。
Uint8List _syntheticZip() {
  final archive = Archive();
  archive.addFile(ArchiveFile.directory('lib/'));
  final payload = Uint8List.fromList(List<int>.filled(16, 0x7F));
  archive.addFile(
    ArchiveFile.noCompress('lib/arm64-v8a/libfoo.so', payload.length, payload),
  );
  // 归一化的两种输入：前导 `./` 与反斜杠分隔符。
  archive.addFile(
    ArchiveFile.noCompress('./weird\\path', 3, Uint8List.fromList([1, 2, 3])),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('真实 APK', () {
    late ApkReader reader;

    setUp(() async {
      reader = ApkReader();
      final result = await reader.open(_fixture);
      expect(result, ArchiveOpenResult.ok);
    });

    tearDown(() => reader.close());

    test('条目事实非空，包含 AndroidManifest.xml', () {
      final facts = reader.entryFacts();

      expect(facts, isNotEmpty);
      expect(
        facts.map((f) => f.path),
        contains('AndroidManifest.xml'),
      );
      // 清单里的每一条都必须是文件（这个夹具没有显式目录条目）。
      expect(facts.every((f) => f.isFile), isTrue);
    });

    test('路径已归一化：无前导 ./、无反斜杠、无结尾 /', () {
      final facts = reader.entryFacts();

      for (final fact in facts) {
        expect(fact.path, isNotEmpty);
        expect(fact.path, isNot(startsWith('./')));
        expect(fact.path, isNot(contains('\\')));
        expect(fact.path, isNot(endsWith('/')));
      }
    });

    test('压缩字段取自中央目录：stored 与 deflate 都如实反映', () {
      final facts = reader.entryFacts();
      final byPath = {for (final fact in facts) fact.path: fact};

      // 夹具里 resources.arsc 是 stored（method=0，压缩大小 = 原大小）。
      final arsc = byPath['resources.arsc']!;
      expect(arsc.compressionMethod, 0);
      expect(arsc.compressedBytes, arsc.sizeBytes);

      // AndroidManifest.xml 是 deflate（method=8，压缩后更小）。
      final manifest = byPath['AndroidManifest.xml']!;
      expect(manifest.compressionMethod, 8);
      expect(manifest.compressedBytes, isNotNull);
      expect(manifest.compressedBytes!, lessThan(manifest.sizeBytes));
      expect(manifest.sizeBytes, greaterThan(0));
    });
  });

  group('合成 ZIP', () {
    test('目录条目进事实表（isDirectory=true），压缩字段为 null', () async {
      final reader = ApkReader();
      expect(reader.openBytes(_syntheticZip()), ArchiveOpenResult.ok);
      addTearDown(() => reader.close());

      final facts = reader.entryFacts();
      final dir = facts.firstWhere((f) => f.isDirectory);

      // `normalizeArchivePath` 会去掉结尾 `/`；目录身份由 isDirectory 表达。
      expect(dir.path, 'lib');
      expect(dir.isFile, isFalse);
      expect(dir.compressedBytes, isNull, reason: '目录没有可压缩内容，不该给出 0');
      expect(dir.compressionMethod, isNull);
    });

    test('文件条目归一化：反斜杠与前导 ./ 都被处理', () async {
      final reader = ApkReader();
      expect(reader.openBytes(_syntheticZip()), ArchiveOpenResult.ok);
      addTearDown(() => reader.close());

      final paths = reader.entryFacts().map((f) => f.path).toList();
      expect(paths, contains('weird/path'));
      expect(paths, contains('lib/arm64-v8a/libfoo.so'));
      expect(paths, isNot(contains('./weird\\path')));
    });

    test('未打开时返回空列表（不是 null，也不抛异常）', () {
      final reader = ApkReader();
      expect(reader.entryFacts(), isEmpty);
    });
  });
}
