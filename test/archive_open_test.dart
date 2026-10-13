import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// 合法的空 ZIP 归档（22 字节 EOCD 记录）。
///
/// 用 [ZipEncoder] 生成而不是手写字节：手写时极易把 EOCD 长度写错，
/// 那样的样本测的是「损坏输入」而不是「合法空归档」。
final Uint8List _emptyZip = Uint8List.fromList(ZipEncoder().encode(Archive()));

/// 17 MiB，略高于 [ZipBudget.ratioCheckMinSize]，用于触发压缩比检查。
const int _ratioProbeBytes = 17 * 1024 * 1024;

void main() {
  group('looksLikeZip', () {
    test('accepts the three legal ZIP signatures', () {
      expect(looksLikeZip([0x50, 0x4B, 0x03, 0x04]), isTrue); // local header
      expect(looksLikeZip([0x50, 0x4B, 0x05, 0x06]), isTrue); // empty archive
      expect(looksLikeZip([0x50, 0x4B, 0x07, 0x08]), isTrue); // spanned
    });

    test('rejects non-ZIP input and truncated headers', () {
      expect(looksLikeZip('Hell'.codeUnits), isFalse);
      expect(looksLikeZip([0x50, 0x4B, 0x03, 0x05]), isFalse);
      expect(looksLikeZip([0x50, 0x4B, 0x03]), isFalse);
      expect(looksLikeZip(const []), isFalse);
    });
  });

  group('ArchiveOpenResult', () {
    test('only ok reports isOk, and every state has a description', () {
      expect(ArchiveOpenResult.ok.isOk, isTrue);
      for (final result in ArchiveOpenResult.values) {
        expect(result.description, isNotEmpty, reason: '$result');
        if (result == ArchiveOpenResult.ok) continue;
        expect(result.isOk, isFalse, reason: '$result');
      }
    });
  });

  group('ApkReader.open 的结果分类', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('apk_reader_open_test');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<String> write(String name, List<int> bytes) async {
      final file = File('${tmp.path}/$name');
      await file.writeAsBytes(bytes);
      return file.path;
    }

    test('合法的空 ZIP -> ok', () async {
      final path = await write('empty.zip', _emptyZip);
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(await reader.open(path), ArchiveOpenResult.ok);
    });

    test('非 ZIP 内容 -> notArchive', () async {
      final path =
          await write('plain.txt', 'this is not a zip archive'.codeUnits);
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(await reader.open(path), ArchiveOpenResult.notArchive);
    });

    test('魔数像 ZIP 但结构损坏 -> corrupt', () async {
      final path = await write('broken.zip', [
        0x50, 0x4B, 0x03, 0x04, //
        ...List.filled(64, 0xAB),
      ]);
      final reader = ApkReader();
      addTearDown(reader.close);
      final result = await reader.open(path);
      expect(result.isOk, isFalse, reason: '伪造的头部不得被判为 ok');
      expect(result, ArchiveOpenResult.corrupt);
    });

    test('文件不存在 -> ioError（而不是 corrupt）', () async {
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(
        await reader.open('${tmp.path}/does-not-exist.apk'),
        ArchiveOpenResult.ioError,
      );
    });

    test('真实高压缩比归档 -> resourceBudgetExceeded', () async {
      // 17 MiB 全零内容，deflate 后只剩十几 KB：这正是 ZIP 炸弹的特征。
      final bomb = Archive()
        ..addFile(ArchiveFile.string('zeros.bin', '\u0000' * _ratioProbeBytes));
      final bytes = ZipEncoder().encode(bomb);

      // 先确认样本本身确实满足「高压缩比」前提，否则测试是空的。
      final decoded = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
      expect(ZipBudget.isExceeded(decoded), isTrue,
          reason: '样本未触发压缩比预算，测试前提不成立');

      final path = await write('bomb.zip', bytes);
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(await reader.open(path), ArchiveOpenResult.resourceBudgetExceeded);
      // 被拒绝后不得留下可用的归档句柄。
      expect(reader.readFile('zeros.bin'), isNull);
    });

    test('随机输入永不抛异常，且结果始终是合法枚举值', () async {
      final random = Random(20261013);
      final reader = ApkReader();
      addTearDown(reader.close);
      for (var i = 0; i < 40; i++) {
        final bytes =
            List<int>.generate(random.nextInt(512), (_) => random.nextInt(256));
        final path = await write('rnd_$i.bin', bytes);
        final result = await reader.open(path);
        expect(ArchiveOpenResult.values, contains(result));
      }
    });
  });

  group('ApkReader.openBytes 的结果分类', () {
    test('空 ZIP 字节 -> ok', () {
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(reader.openBytes(_emptyZip), ArchiveOpenResult.ok);
    });

    test('非 ZIP 字节 -> notArchive', () {
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(
        reader.openBytes(Uint8List.fromList('nope'.codeUnits)),
        ArchiveOpenResult.notArchive,
      );
    });
  });

  group('ZipBudget', () {
    test('空归档与普通小归档都通过', () {
      expect(ZipBudget.isExceeded(Archive()), isFalse);

      final small = Archive()
        ..addFile(ArchiveFile.string('a.txt', 'hello'))
        ..addFile(ArchiveFile.string('res/drawable/b.png', 'world'));
      expect(ZipBudget.isExceeded(small), isFalse);
      expect(() => ZipBudget.ensureWithin(small), returnsNormally);
    });

    test('条目数超限时拒绝', () {
      final many = Archive();
      for (var i = 0; i <= ZipBudget.maxEntryCount; i++) {
        many.addFile(ArchiveFile.string('f$i', ''));
      }
      expect(ZipBudget.isExceeded(many), isTrue);
      expect(
        () => ZipBudget.ensureWithin(many, source: 'unit-test'),
        throwsA(isA<ZipBombException>()),
      );
    });
  });
}
