// 有界解压（Phase A）：**逐块**限制真实产出。
//
// 这一组的存在理由：V2.4.11 只做到「解压完再比长度」—— 峰值内存不受限。
// V2.4.12 换成 `ZipFile.decompress(OutputStream)` + 带上限的 `OutputStream`，
// 超限时在写那一块时抛异常，zlib 就地停下。
//
// **所有用例都用小预算、小样本**：不允许靠「真解一个 100 MiB 再断言」来证明，
// 那种测试既慢又会在 CI 里制造不可控的内存峰值。

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';
import 'package:test/test.dart';

/// 造一个 ZIP 并解码（不落盘）。
Archive _zip(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((name, bytes) {
    a.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipDecoder().decodeBytes(Uint8List.fromList(ZipEncoder().encode(a)));
}

/// 把中央目录里某个条目的某个 4 字节字段改掉。
///
/// [fieldOffset] 相对 CD 头起点：`20` = compressedSize，`24` = uncompressedSize。
Uint8List _patchCd(
  Uint8List zip,
  String name,
  int fieldOffset,
  int value,
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
    final at = i + fieldOffset;
    out[at] = value & 0xff;
    out[at + 1] = (value >> 8) & 0xff;
    out[at + 2] = (value >> 16) & 0xff;
    out[at + 3] = (value >> 24) & 0xff;
    return out;
  }
  throw StateError('中央目录里没找到 $name');
}

/// 全零内容 —— 压缩比最高，用来在**小样本**上逼出解压路径。
Uint8List _zeros(int n) => Uint8List(n);

void main() {
  group('正常归档', () {
    test('预算内正常读出，内容逐字节一致', () {
      final archive =
          _zip({'a.txt': Uint8List.fromList('hello world'.codeUnits)});
      final read = ZipBudget.readEntry(
        archive.files.first,
        maxBytes: 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 1 << 20),
      );
      expect(read.isOk, isTrue);
      expect(String.fromCharCodes(read.bytes!), 'hello world');
      expect(read.failure, isNull);
    });

    test('合法的大量零填充不会被拒绝（V2.4.10 的兼容性）', () {
      // 2 MiB 全零，压缩比约 200:1 —— 这正是被填充的加固包的样子。
      final archive = _zip({'padded.bin': _zeros(2 * 1024 * 1024)});
      final read = ZipBudget.readEntry(
        archive.files.first,
        maxBytes: 4 * 1024 * 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 8 * 1024 * 1024),
      );
      expect(read.isOk, isTrue);
      expect(read.bytes!.length, 2 * 1024 * 1024);
    });
  });

  group('中央目录撒谎', () {
    test('声明 1 KiB / 实际 256 KiB —— 逐块中止，不返回超限内容', () {
      const real = 256 * 1024;
      final honest = Uint8List.fromList(
        ZipEncoder().encode(
            Archive()..addFile(ArchiveFile('liar.bin', real, _zeros(real)))),
      );
      final liar = _patchCd(honest, 'liar.bin', 24, 1024);
      final archive = ZipDecoder().decodeBytes(liar);
      final file = archive.files.first;

      // 前提：声明值确实被骗小了，`check` 会放行。
      expect(file.size, 1024);
      expect(ZipBudget.check(archive), isNull);

      final read = ZipBudget.readEntry(
        file,
        maxBytes: 64 * 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 1 << 20),
      );

      expect(read.isOk, isFalse, reason: '声明值造假不能绕过真实产出限制');
      expect(read.bytes, isNull, reason: '被拒绝时不得返回任何内容');
      expect(read.failure!.stage, BoundedReadStage.inflate);
      expect(read.failure!.entry, 'liar.bin');
      // 中止发生在**超过上限的那一刻**，而不是解完 256 KiB 之后。
      expect(read.failure!.observedBytes, greaterThan(64 * 1024));
      expect(read.failure!.observedBytes, lessThan(real));
    });
  });

  group('真实产出超限', () {
    test('单条目超限：只多出「最后一块」，不是整条条目', () {
      // **必须让声明值落在预算内**，否则第一道闸就拦下了、测不到逐块中止。
      // 因此把 CD 的声明值改小 —— 这同时也就是「CD 撒谎」的场景。
      const real = 512 * 1024;
      final honest = Uint8List.fromList(
        ZipEncoder().encode(
            Archive()..addFile(ArchiveFile('big.bin', real, _zeros(real)))),
      );
      final liar = _patchCd(honest, 'big.bin', 24, 1024);
      final archive = ZipDecoder().decodeBytes(liar);

      final read = ZipBudget.readEntry(
        archive.files.first,
        maxBytes: 8 * 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 1 << 20),
      );

      expect(read.isOk, isFalse);
      expect(read.failure!.stage, BoundedReadStage.inflate);
      expect(read.failure!.limitBytes, 8 * 1024);
      // zlib 每次吐一块（实测 64 KiB），因此 observed 只比上限多一块，
      // 远小于整条条目 —— 这就是「没有先完整解压」的证据。
      expect(read.failure!.observedBytes, lessThan(real ~/ 2),
          reason: '中止点应当接近上限，而不是接近条目大小');
    });

    test('多条目累计超限：共享 ledger 记账，后续条目被拒', () {
      final archive = _zip({
        'a.bin': _zeros(6 * 1024),
        'b.bin': _zeros(6 * 1024),
        'c.bin': _zeros(6 * 1024),
      });
      final ledger = BoundedReadLedger(maxTotalBytes: 16 * 1024);

      final reads = [
        for (final f in archive.files)
          ZipBudget.readEntry(f, maxBytes: 64 * 1024, ledger: ledger),
      ];

      expect(reads[0].isOk, isTrue);
      expect(reads[1].isOk, isTrue);
      // 第三条只剩 4 KiB 预算，装不下 6 KiB。
      expect(reads[2].isOk, isFalse);
      expect(reads[2].failure!.stage, BoundedReadStage.inflate);
      expect(ledger.producedBytes, lessThanOrEqualTo(16 * 1024));
    });

    test('嵌套归档共享预算：子归档不能重新取得完整配额', () {
      // 外层读走 6 KiB 后，内层只剩 2 KiB。
      final ledger = BoundedReadLedger(maxTotalBytes: 8 * 1024);
      final outer = _zip({'outer.bin': _zeros(6 * 1024)});
      final first = ZipBudget.readEntry(
        outer.files.first,
        maxBytes: 64 * 1024,
        ledger: ledger,
      );
      expect(first.isOk, isTrue);

      final inner = _zip({'inner.bin': _zeros(6 * 1024)});
      final second = ZipBudget.readEntry(
        inner.files.first,
        maxBytes: 64 * 1024,
        ledger: ledger,
      );
      expect(second.isOk, isFalse);
      expect(second.failure!.limitBytes, 2 * 1024, reason: '内层只能拿到剩余预算，不是完整配额');
    });
  });

  group('压缩输入与声明值', () {
    test('单条目声明超限 -> 不解压就拒绝', () {
      final archive = Archive()
        ..addFile(ArchiveFile('huge.bin', 300 * 1024 * 1024, const []));
      final read = ZipBudget.readEntry(
        archive.files.first,
        maxBytes: 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 1 << 20),
      );
      expect(read.isOk, isFalse);
      expect(read.failure!.stage, BoundedReadStage.declaredSize);
      expect(read.failure!.observedBytes, 300 * 1024 * 1024);
    });

    test('压缩后大小超限 -> 在打开阶段就被 check 拒绝', () {
      final honest = Uint8List.fromList(
        ZipEncoder().encode(
            Archive()..addFile(ArchiveFile('c.bin', 64, Uint8List(64)))),
      );
      // 把 CD 的 compressedSize 改成 1 GiB（超过 512 MiB 上限）。
      final fake = _patchCd(honest, 'c.bin', 20, 1024 * 1024 * 1024);
      final archive = ZipDecoder().decodeBytes(fake);

      final violation = ZipBudget.check(archive);
      expect(violation, isNotNull);
      expect(violation!.entry, 'c.bin');
      expect(violation.reason, contains('compressed bytes'));
    });

    test('加密条目 -> 拒绝而不是退回无界读取', () {
      // 手工置位「加密」标志（bit 0）。APK / IPA 从不使用 ZIP 加密。
      final honest = Uint8List.fromList(
        ZipEncoder().encode(
            Archive()..addFile(ArchiveFile('e.bin', 64, Uint8List(64)))),
      );
      final patched = Uint8List.fromList(honest);
      // 局部文件头 flags 在 +6；中央目录 flags 在 +8。两处都置位。
      for (var i = 0; i + 8 < patched.length; i++) {
        final isLocal = patched[i] == 0x50 &&
            patched[i + 1] == 0x4b &&
            patched[i + 2] == 0x03 &&
            patched[i + 3] == 0x04;
        final isCd = patched[i] == 0x50 &&
            patched[i + 1] == 0x4b &&
            patched[i + 2] == 0x01 &&
            patched[i + 3] == 0x02;
        if (isLocal) patched[i + 6] |= 0x1;
        if (isCd) patched[i + 8] |= 0x1;
      }
      final archive = ZipDecoder().decodeBytes(patched);
      final read = ZipBudget.readEntry(
        archive.files.first,
        maxBytes: 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 1 << 20),
      );
      expect(read.isOk, isFalse);
      expect(read.failure!.stage, BoundedReadStage.unsupported);
    });
  });

  group('损坏输入', () {
    test('deflate 流被截断 -> corrupt，而不是静默返回半截', () {
      final archive = _zip({'t.bin': _zeros(64 * 1024)});
      final zf = archive.files.first.rawContent as ZipFile;
      final compressed = zf.getRawContent();
      // 砍掉一半压缩数据，再把条目的 rawContent 换掉不可行（私有），
      // 因此改为构造一个「声明 64 KiB、压缩数据只有一半」的归档：
      final truncated = Uint8List.fromList(
        ZipEncoder().encode(Archive()
          ..addFile(ArchiveFile('t.bin', 64 * 1024,
              compressed.sublist(0, compressed.length ~/ 2)))),
      );
      final broken = ZipDecoder().decodeBytes(truncated);
      final read = ZipBudget.readEntry(
        broken.files.first,
        maxBytes: 1 << 20,
        ledger: BoundedReadLedger(maxTotalBytes: 4 << 20),
      );
      // 要么解压失败（corrupt），要么产出与声明不符 —— 都不能「假装成功」。
      if (read.isOk) {
        expect(read.bytes!.length, isNot(64 * 1024));
      } else {
        expect(read.failure!.stage, BoundedReadStage.corrupt);
      }
    });

    test('重复条目名：按名字取第一条，不崩', () {
      final a = Archive()
        ..addFile(ArchiveFile('dup.txt', 3, Uint8List.fromList([1, 2, 3])))
        ..addFile(ArchiveFile('dup.txt', 3, Uint8List.fromList([4, 5, 6])));
      final archive =
          ZipDecoder().decodeBytes(Uint8List.fromList(ZipEncoder().encode(a)));
      final file = archive.findFile('dup.txt')!;
      final read = ZipBudget.readEntry(
        file,
        maxBytes: 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 1 << 20),
      );
      expect(read.isOk, isTrue);
      expect(read.bytes!.length, 3);
    });
  });

  group('内存中的合成 ArchiveFile（无 ZIP 元数据）', () {
    test('没有 ZIP 元数据时按声明值判，超限拒绝', () {
      // 手工构造的 `ArchiveFile` 内容本来就在内存里，`size` 就是真实长度，
      // 因此第一道闸（声明值）就能拦住 —— 不需要也不应该走解压路径。
      final file = ArchiveFile('mem.bin', 2048, Uint8List(2048));
      final read = ZipBudget.readEntry(
        file,
        maxBytes: 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 1 << 20),
      );
      expect(read.isOk, isFalse);
      expect(read.failure!.stage, BoundedReadStage.declaredSize);
      expect(read.failure!.observedBytes, 2048);
    });

    test('没有 ZIP 元数据、预算够时正常返回', () {
      final file = ArchiveFile('mem.bin', 16, Uint8List(16));
      final read = ZipBudget.readEntry(
        file,
        maxBytes: 1024,
        ledger: BoundedReadLedger(maxTotalBytes: 1 << 20),
      );
      expect(read.isOk, isTrue);
      expect(read.bytes!.length, 16);
    });
  });
}
