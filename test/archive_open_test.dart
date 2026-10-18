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

/// 17 MiB —— 与真实加固包零填充的量级相当（实测被填充的
/// `AndroidManifest.xml` 是 72.3 MiB）。
const int _paddedProbeBytes = 17 * 1024 * 1024;

/// 把 ZIP 中央目录里某个条目的「解压后大小」改小 —— 制造**声明值撒谎**的样本。
///
/// 中央目录文件头布局（偏移量相对头起点）：
/// `0 签名(4) | 20 compressedSize(4) | 24 uncompressedSize(4) | 28 文件名长度(2)`
/// 只改 `uncompressedSize`，deflate 流一个字不动 —— 解压出来仍是原始大小。
Uint8List _patchCdUncompressedSize(
  Uint8List zip,
  String name,
  int fakeSize,
) {
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
    out[i + 24] = fakeSize & 0xff;
    out[i + 25] = (fakeSize >> 8) & 0xff;
    out[i + 26] = (fakeSize >> 16) & 0xff;
    out[i + 27] = (fakeSize >> 24) & 0xff;
    return out;
  }
  throw StateError('中央目录里没找到 $name');
}

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

    test('被零填充的大条目**不再**被拒绝（加固包的常见做法）', () async {
      // V2.4.10 起不再按压缩比拒绝：实测 `49af6cnn-1018.apk`
      // （`澳門新葡京` 变种）把 `AndroidManifest.xml` 零填充到 72.3 MiB
      // （压缩比 205:1），而 `archive` 的 deflate 对 17 MiB 纯零也只给
      // **229:1** —— 压缩比区分不了「零填充的合法文件」与「零填充的炸弹」。
      //
      // 真正的判据是**解压后占多少内存**：17 MiB 读进来毫无压力。
      final padded = Archive()
        ..addFile(
            ArchiveFile.string('zeros.bin', '\u0000' * _paddedProbeBytes));
      final bytes = ZipEncoder().encode(padded);

      // 先确认样本确实「解压后远大于压缩后」，否则这条测试是空的。
      final decoded = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
      final entry = decoded.files.first;
      expect(entry.size, _paddedProbeBytes);
      expect(entry.size, greaterThan(bytes.length * 100),
          reason: '样本应当是「高度可压缩」的，否则测不到这条路径');

      final path = await write('padded.zip', bytes);
      final reader = ApkReader();
      addTearDown(reader.close);
      expect(await reader.open(path), ArchiveOpenResult.ok);
      // 真的能读出来，而不只是「没被拒绝」。
      expect(reader.readFile('zeros.bin')?.length, _paddedProbeBytes);
    });

    test('单条目超过 256 MiB -> 拒绝，且说明是哪一条', () {
      final archive = Archive()
        ..addFile(ArchiveFile('classes.dex', 300 * 1024 * 1024, const []));
      final violation = ZipBudget.check(archive);
      expect(violation, isNotNull);
      expect(violation!.entry, 'classes.dex');
      expect(violation.reason, contains('per-entry limit'));
      expect(violation.describe(), contains('classes.dex'));
    });

    test('解压后总量超过 1 GiB -> 拒绝', () {
      final archive = Archive();
      for (var i = 0; i < 5; i++) {
        archive
            .addFile(ArchiveFile('classes$i.dex', 250 * 1024 * 1024, const []));
      }
      final violation = ZipBudget.check(archive);
      expect(violation, isNotNull);
      expect(violation!.reason, contains('cumulative'));
    });

    test('条目数超过上限 -> 拒绝', () {
      final archive = Archive();
      for (var i = 0; i <= ZipBudget.maxEntryCount; i++) {
        archive.addFile(ArchiveFile('f$i', 1, const []));
      }
      expect(ZipBudget.check(archive)?.reason, contains('entry count'));
    });

    test('预算内的归档返回 null（不误报）', () {
      final archive = Archive()
        ..addFile(
            ArchiveFile('AndroidManifest.xml', 72 * 1024 * 1024, const []))
        ..addFile(ArchiveFile('resources.arsc', 20 * 1024 * 1024, const []));
      expect(ZipBudget.check(archive), isNull);
    });

    test('单条目声明超限 -> readEntry 直接拒绝，不做解压', () {
      // 第一道闸看 `file.size`（声明值）。注意：声明超限的归档在
      // `ApkReader.open` 那一步就会被 `ZipBudget.check` 拒掉，因此这里
      // 直接对 `readEntry` 断言 —— 它是**冗余的第二道防线**，防的是
      // 「先 open 成功、之后归档内容被替换」这类构造。
      final archive = Archive()
        ..addFile(ArchiveFile('big.bin', 300 * 1024 * 1024, const []));
      final read = ZipBudget.readEntry(archive.files.first);
      expect(read.isOk, isFalse);
      expect(read.violation, contains('declares 314572800 bytes'));
      expect(read.violation, contains('big.bin'));
    });

    test('中央目录撒谎的条目会被拒绝（第二道闸看真实产出）', () async {
      // 1 MiB 真实内容，但把 CD 的 uncompressedSize 改成 1024。
      const real = 1024 * 1024;
      final archive = Archive()
        ..addFile(ArchiveFile.string('liar.bin', '\u0000' * real));
      final honest = Uint8List.fromList(ZipEncoder().encode(archive));
      final liar = _patchCdUncompressedSize(honest, 'liar.bin', 1024);

      final decoded = ZipDecoder().decodeBytes(liar);
      final entry = decoded.files.first;
      // 前提：CD 确实撒谎了（声明 1 KiB），而 `ZipBudget.check` 会因此放行。
      expect(entry.size, 1024);
      expect(ZipBudget.check(decoded), isNull,
          reason: '第一道闸只看声明值，撒谎的条目能过 —— 这正是要补的洞');

      // 第二道闸：用一个小上限把「实际产出超限」这条路径逼出来。
      final read = ZipBudget.readEntry(entry, maxBytes: 64 * 1024);
      expect(read.isOk, isFalse);
      expect(read.violation, contains('declared 1024 bytes but produced'));
      expect(read.violation, contains('liar.bin'));
      expect(read.bytes, isNull);

      // 上限足够时不误伤：同样撒谎，但产出在预算内。
      final ok = ZipBudget.readEntry(entry, maxBytes: real + 1024);
      expect(ok.isOk, isTrue);
      expect(ok.bytes!.length, real);
    });

    test('正常条目读取不受影响', () async {
      final archive = Archive()
        ..addFile(ArchiveFile.string('ok.bin', 'hello world'));
      final path = await write('normal.zip', ZipEncoder().encode(archive));

      final reader = ApkReader();
      addTearDown(reader.close);
      expect(await reader.open(path), ArchiveOpenResult.ok);
      expect(reader.readFile('ok.bin'), isNotNull);
      expect(reader.readFile('ok.bin')!.length, 11);
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
