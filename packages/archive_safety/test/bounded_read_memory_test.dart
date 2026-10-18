import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';
import 'package:test/test.dart';

/// **峰值内存**必须随「上限」走，而不是随「条目大小」走。
///
/// ## 为什么这条测试非有不可
///
/// V2.4.12 的第一版把 `ZipFile.decompress()` 的输出接到一个带上限的
/// `OutputStream` 上，看起来「逐块中止」。收尾时一量才发现：
///
/// | 条目 | 上限 | 走 `decompress()` | 现在 |
/// |---|---|---|---|
/// | 64 MiB | 1 MiB | ΔRSS 24 MiB / 9 ms | ΔRSS 1.2 MiB / 0 ms |
/// | 256 MiB | 1 MiB | ΔRSS 72 MiB / 29 ms | ΔRSS 16 KiB / 0 ms |
///
/// 原因是 `archive` 的 `ZLibDecoder.decodeStream` 用
/// `ChunkedConversionSink.withCallback`：它把解压结果**先全部攒起来**，
/// 到 `close()` 才交给回调 —— 上限只挡住了「我们保留多少」，没挡住
/// 「解压器分配多少」。
///
/// 换成自己喂输入 + 自定义 `Sink` 之后，内存才真的随上限走。
///
/// ## 为什么阈值给得松
///
/// `ProcessInfo.currentRss` 是**进程级**的，且受 GC 时机影响。这里要抓的是
/// 「内存随条目大小线性涨」这个量级差异（24 MiB vs 1.2 MiB），所以阈值取
/// 16 MiB —— 对现在的实现有 10 倍余量，对旧实现则会稳定失败。
void main() {
  /// 造一个「声明值撒谎」的样本：真实 [entryMb] MiB 全零，中央目录谎报 1024。
  ArchiveFile lyingEntry(int entryMb) {
    final archive = Archive();
    archive.add(ArchiveFile(
      'zeros.bin',
      entryMb * 1024 * 1024,
      Uint8List(entryMb * 1024 * 1024),
    ));
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));

    // 中央目录文件头：`0 签名(4) | 20 compressedSize(4) | 24 uncompressedSize(4)`。
    // 只改 uncompressedSize，deflate 流一个字不动 —— 解压仍会产出全量。
    var patched = false;
    for (var i = 0; i + 46 < zip.length; i++) {
      if (zip[i] == 0x50 &&
          zip[i + 1] == 0x4b &&
          zip[i + 2] == 0x01 &&
          zip[i + 3] == 0x02) {
        zip[i + 24] = 1024 & 0xff;
        zip[i + 25] = (1024 >> 8) & 0xff;
        zip[i + 26] = 0;
        zip[i + 27] = 0;
        patched = true;
        break;
      }
    }
    expect(patched, isTrue, reason: '没找到中央目录，样本构造失败');
    return ZipDecoder().decodeBytes(zip).files.first;
  }

  test('64 MiB 条目 / 1 MiB 上限：ΔRSS 不随条目大小涨', () {
    final entry = lyingEntry(64);
    expect(entry.size, 1024, reason: '声明值必须是谎报的 1024');

    // 预热：把一次性分配（样本本身的 64 MiB 源数据、解码器初始化）排除掉。
    readEntryBounded(
      entry,
      maxEntryBytes: 2 * 1024 * 1024,
      ledger: BoundedReadLedger.session(),
    );

    final before = ProcessInfo.currentRss;
    final read = readEntryBounded(
      entry,
      maxEntryBytes: 1024 * 1024,
      ledger: BoundedReadLedger.session(),
    );
    final delta = ProcessInfo.currentRss - before;

    expect(read.isOk, isFalse, reason: '真实产出 64 MiB，必须被拒');
    expect(read.failure!.stage, BoundedReadStage.inflate);
    expect(read.bytes, isNull);

    // 旧实现这里是 24 MiB（随条目大小涨）；现在是 1.2 MiB（随上限涨）。
    expect(
      delta,
      lessThan(16 * 1024 * 1024),
      reason: 'ΔRSS ${delta ~/ 1024} KiB —— 峰值内存随条目大小涨，说明上限没有'
          '真正生效（解压器把整条条目物化了）',
    );
  });

  test('同一条目、上限放大 8 倍：ΔRSS 随上限涨而不是随条目涨', () {
    final entry = lyingEntry(64);
    readEntryBounded(
      entry,
      maxEntryBytes: 2 * 1024 * 1024,
      ledger: BoundedReadLedger.session(),
    );

    final before = ProcessInfo.currentRss;
    final read = readEntryBounded(
      entry,
      maxEntryBytes: 8 * 1024 * 1024,
      ledger: BoundedReadLedger.session(),
    );
    final delta = ProcessInfo.currentRss - before;

    expect(read.isOk, isFalse);
    // 8 MiB 上限实测 ΔRSS ≈ 4.9 MiB。仍然远小于条目本身（64 MiB）。
    expect(
      delta,
      lessThan(24 * 1024 * 1024),
      reason: 'ΔRSS ${delta ~/ 1024} KiB —— 上限放大后内存仍应远小于条目大小',
    );
  });
}
