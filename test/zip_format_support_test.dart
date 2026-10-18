import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// ZIP **结构形态**与**有界解压**的交叉验证。
///
/// ## 为什么单开一个文件
///
/// `archive` 在本项目里是 git 依赖，它对 Zip64 与 data descriptor 的支持
/// 只能实测。更要紧的是：**解析器能读出来，不代表我们的有界读取也还有界**。
/// 这两个格式的差别恰好落在「尺寸从哪来」上 ——
///
/// - Zip64：真实的尺寸在 extra field 里，中央目录里是 0xFFFFFFFF 哨兵；
/// - data descriptor：本地头里的尺寸是 0，真实值在数据之后。
///
/// 有界读取的三道闸（声明值 / 压缩后大小 / 真实产出）全都读的是
/// `ArchiveFile.size` 与 `ZipFile.compressedSize`。如果这两个字段在某种
/// 形态下变成了 0 或哨兵，闸 1、闸 2 就会失效，只剩闸 3 兜底 —— 那就必须
/// 证明闸 3 真的兜住了。
///
/// 夹具由 `tool/make_zip_fixtures.py` 生成（Python `zipfile` 产物 +
/// 按规范改指定字段），并已用 `unzip -t` 与 Python `zipfile` 独立核对过。
/// **期望值不来自本项目的解析器。**
void main() {
  Uint8List fixture(String name) =>
      File('test/fixtures/zip/$name').readAsBytesSync();

  Archive open(String name) => ZipDecoder().decodeBytes(fixture(name));

  ArchiveFile single(String name) {
    final files = open(name).files;
    expect(files, hasLength(1), reason: '$name 应当只有一个条目');
    return files.first;
  }

  BoundedReadLedger ledger([int maxTotal = 64 * 1024 * 1024]) =>
      BoundedReadLedger(maxTotalBytes: maxTotal);

  /// 逐字节比较，避免 `expect(list, list)` 在超长列表上打印一大片。
  void expectBytes(Uint8List actual, List<int> expected, String what) {
    expect(actual.length, expected.length, reason: '$what 的长度');
    for (var i = 0; i < expected.length; i++) {
      if (actual[i] != expected[i]) {
        fail('$what 第 $i 字节是 ${actual[i]}，期望 ${expected[i]}');
      }
    }
  }

  group('Zip64', () {
    test('中央目录字段置哨兵、真实值在 extra(0x0001) —— 能正常读出', () {
      final file = single('zip64_cd.zip');
      expect(file.name, 'payload.bin');

      // 闸 1 读的是 `file.size`。Zip64 的意义就在于它**不是** 0xFFFFFFFF，
      // 而是从 extra field 解出来的真实值 —— 否则闸 1 直接失效。
      expect(file.size, 512, reason: 'Zip64 extra 里的真实原始大小');

      final read = readEntryBounded(
        file,
        maxEntryBytes: 1024,
        ledger: ledger(),
      );
      expect(read.isOk, isTrue, reason: '${read.failure}');
      expectBytes(
        read.bytes!,
        [for (var i = 0; i < 512; i++) i % 256],
        'Zip64 条目内容',
      );
    });

    test('Zip64 EOCD 记录 + 定位器 —— 中央目录仍被正确定位', () {
      final file = single('zip64_eocd.zip');
      expect(file.name, 'payload.bin');
      expect(file.size, 136);

      final read =
          readEntryBounded(file, maxEntryBytes: 4096, ledger: ledger());
      expect(read.isOk, isTrue, reason: '${read.failure}');
      expectBytes(
        read.bytes!,
        [for (var i = 0; i < 136; i++) 'zip64-eocd-sample'.codeUnitAt(i % 17)],
        'Zip64 EOCD 条目内容',
      );
    });

    test('Zip64 条目照样受真实产出上限约束（闸 3 不因格式特殊而旁路）', () {
      final file = single('zip64_cd.zip');
      final read = readEntryBounded(
        file,
        maxEntryBytes: 256, // 比 512 小
        ledger: ledger(),
      );
      // 声明值 512 > 256 → 闸 1 先拦下，压根不解压。
      expect(read.isOk, isFalse);
      expect(read.failure!.stage, BoundedReadStage.declaredSize);
      expect(read.failure!.observedBytes, 512);
      expect(read.failure!.limitBytes, 256);
    });
  });

  group('data descriptor', () {
    test('flag bit 3 的条目：尺寸以中央目录为准，能正常读出', () {
      final file = single('data_descriptor.zip');
      expect(file.name, 'streamed.bin');

      // 本地头里这三个字段是 0，权威值在中央目录。`archive` 用中央目录的
      // 值覆盖本地头 —— 这一条是闸 1 / 闸 2 在这个形态下仍然有效的前提。
      expect(file.size, 4096);

      final raw = file.rawContent as ZipFile;
      expect(raw.flags & 0x08, 0x08, reason: '夹具必须真的带 data descriptor');
      expect(raw.compressedSize, greaterThan(0), reason: '压缩后大小不能是 0');

      final read = readEntryBounded(
        file,
        maxEntryBytes: 8192,
        ledger: ledger(),
      );
      expect(read.isOk, isTrue, reason: '${read.failure}');
      expectBytes(
        read.bytes!,
        [for (var i = 0; i < 4096; i++) i % 256],
        'data descriptor 条目内容',
      );
    });

    test('data descriptor 条目超上限时同样被拦', () {
      final file = single('data_descriptor.zip');
      final read =
          readEntryBounded(file, maxEntryBytes: 1024, ledger: ledger());
      expect(read.isOk, isFalse);
      expect(read.failure!.stage, BoundedReadStage.declaredSize);
      expect(read.failure!.observedBytes, 4096);
    });
  });

  group('正常条目：上限确实是它拦下来的', () {
    test('1 MiB 全零、上限 64 KiB → 闸 1 在解压前就拦下（不浪费一次解压）', () {
      final file = single('zeros_1m.zip');
      expect(file.size, 1024 * 1024);

      final l = ledger();
      final read = readEntryBounded(
        file,
        maxEntryBytes: 64 * 1024,
        ledger: l,
      );

      expect(read.isOk, isFalse);
      expect(read.bytes, isNull, reason: '被拒绝时不得返回任何内容');
      // 声明值诚实的时候，闸 1 先命中 —— 比逐块中止更省。
      expect(read.failure!.stage, BoundedReadStage.declaredSize);
      expect(read.failure!.entry, 'zeros.bin');
      expect(read.failure!.observedBytes, 1024 * 1024);
      expect(read.failure!.limitBytes, 64 * 1024);
      expect(l.producedBytes, 0);
    });

    test('同一条目、上限 2 MiB → 完整读出，账本记到真实产出', () {
      final file = single('zeros_1m.zip');
      final l = ledger();
      final read = readEntryBounded(
        file,
        maxEntryBytes: 2 * 1024 * 1024,
        ledger: l,
      );
      expect(read.isOk, isTrue, reason: '${read.failure}');
      expect(read.bytes!.length, 1024 * 1024);
      expect(l.producedBytes, 1024 * 1024);
    });

    test('被拒绝之后再读同一条目仍能读全（流位置被还原）', () {
      // `ZipFile.decompress` 只在成功路径还原流位置，超限时是从 zlib 里抛
      // 出来的。不自己还原的话，第二次读会得到 0 字节 —— 这条守着那个坑。
      final file = single('zeros_1m.zip');
      final l = ledger();

      final refused = readEntryBounded(
        file,
        maxEntryBytes: 64 * 1024,
        ledger: l,
      );
      expect(refused.isOk, isFalse);

      final ok = readEntryBounded(
        file,
        maxEntryBytes: 2 * 1024 * 1024,
        ledger: l,
      );
      expect(ok.isOk, isTrue, reason: '${ok.failure}');
      expect(ok.bytes!.length, 1024 * 1024);
    });

    test('前缀读取：声明 1 MiB、只读 4 KiB，不因闸 1 被误拒且拿满 4 KiB', () {
      final file = single('zeros_1m.zip');
      final read = readEntryPrefix(file, maxBytes: 4096, ledger: ledger());
      expect(read.isOk, isTrue, reason: '${read.failure}');
      // zlib 会把 1 MiB 一次性交过来；整块丢弃就会得到 0 字节，
      // 调用方无法区分「被上限截断」和「条目本来是空的」。
      expect(read.bytes!.length, 4096);
    });
  });

  group('中心目录撒谎（审计 P1-1 的形态）', () {
    test('声明 1024、实际 1 MiB —— 闸 1 放行，闸 3 必须拦下', () {
      final file = single('cd_lie_uncompressed.zip');
      // 谎报的声明值就是这个样子：解析器眼里它只有 1 KiB。
      expect(file.size, 1024);

      final read = readEntryBounded(
        file,
        maxEntryBytes: 512 * 1024, // 远大于声明值，闸 1 必然放行
        ledger: ledger(),
      );

      expect(
        read.isOk,
        isFalse,
        reason: '声明值撒谎时唯一有效的是真实产出闸；返回内容就等于把谎报坐实',
      );
      expect(read.failure!.stage, BoundedReadStage.inflate);
      // 观察值来自真实产出，而不是那个 1024 —— 它必须越过 512 KiB 上限，
      // 又不可能超过条目真实的 1 MiB。
      expect(read.failure!.observedBytes, greaterThan(512 * 1024));
      expect(read.failure!.observedBytes, lessThanOrEqualTo(1024 * 1024));
    });

    test('上限足够大时能读出真实内容 —— 拦住它的是上限，不是解析失败', () {
      final file = single('cd_lie_uncompressed.zip');
      final read = readEntryBounded(
        file,
        maxEntryBytes: 2 * 1024 * 1024,
        ledger: ledger(),
      );
      // 与上一条合起来才说明问题：同一个样本，512 KiB 上限时被拒、
      // 2 MiB 上限时读出 1 MiB。声明值始终是 1024，完全不起作用。
      expect(read.isOk, isTrue, reason: '${read.failure}');
      expect(read.bytes!.length, 1024 * 1024);
    });
  });

  group('结构异常：解压失败要变成稳定诊断，不许抛、不许退回无界', () {
    test('压缩后大小被改小（deflate 流被截断）', () {
      final file = single('cd_lie_compressed.zip');
      final read = readEntryBounded(
        file,
        maxEntryBytes: 4 * 1024 * 1024,
        ledger: ledger(),
      );
      expect(read.isOk, isFalse, reason: '截断的流不许当正常内容返回');
      expect(read.bytes, isNull);
      expect(
        read.failure!.stage,
        anyOf(BoundedReadStage.corrupt, BoundedReadStage.inflate),
      );
      expect(read.failure!.entry, 'zeros.bin');
    });

    test('压缩数据被替换成垃圾字节', () {
      final file = single('garbage_deflate.zip');
      final read = readEntryBounded(
        file,
        maxEntryBytes: 4 * 1024 * 1024,
        ledger: ledger(),
      );
      expect(read.isOk, isFalse);
      expect(read.bytes, isNull);
      expect(
        read.failure!.stage,
        anyOf(BoundedReadStage.corrupt, BoundedReadStage.inflate),
      );
      expect(read.failure!.observedBytes, lessThan(4 * 1024 * 1024));
    });

    test('尾部被截断：走真实的打开入口，归类为「归档损坏」而不是抛出去', () {
      // `ZipDecoder.decodeBytes` 对这种输入会抛 `RangeError`（EOCD 还在、
      // 但读不到完整记录）。**这是库的行为，不是本工具的行为** —— 真正要
      // 守的是调用方看到什么。生产路径 `ApkReader.openBytes` 把它归类为
      // `corrupt`，绝不会让异常冒到界面层。
      final reader = ApkReader();
      final result = reader.openBytes(fixture('truncated_tail.zip'));
      expect(result, ArchiveOpenResult.corrupt);
      // 打不开 → 没有任何可读条目 → 不存在「退回无界解压」的机会。
      expect(reader.readFile('zeros.bin'), isNull);
    });
  });

  group('共享账本', () {
    test('两个条目共用预算：第二个被拦时上限报的是剩余量', () {
      final file = single('zeros_1m.zip');
      final l = BoundedReadLedger(maxTotalBytes: 1536 * 1024);

      final first = readEntryBounded(
        file,
        maxEntryBytes: 2 * 1024 * 1024,
        ledger: l,
      );
      expect(first.isOk, isTrue, reason: '${first.failure}');
      expect(l.producedBytes, 1024 * 1024);
      expect(l.remainingBytes, 512 * 1024);

      final second = readEntryBounded(
        file,
        maxEntryBytes: 2 * 1024 * 1024,
        ledger: l,
      );
      expect(second.isOk, isFalse);
      expect(second.failure!.stage, BoundedReadStage.inflate);
      // 生效上限是 min(单条目上限, 剩余预算) = 512 KiB。
      expect(second.failure!.limitBytes, 512 * 1024);
      expect(l.producedBytes, 1024 * 1024, reason: '被拒绝的读取不记账');
    });
  });

  group('诊断文本', () {
    test('describe() 三项齐全：哪个条目、停在哪一步、观察到多少', () {
      // 用「声明值撒谎」的样本：闸 1 放行，停在真实的 inflate 闸上。
      final file = single('cd_lie_uncompressed.zip');
      final read = readEntryBounded(
        file,
        maxEntryBytes: 512 * 1024,
        ledger: ledger(),
      );
      final text = read.failure!.describe();
      expect(text, contains('zeros.bin'));
      expect(text, contains('inflate'));
      expect(text, contains('limit ${512 * 1024}'));
      expect(
        RegExp(r'after \d+ bytes').hasMatch(text),
        isTrue,
        reason: '实际观察到的字节数必须出现在诊断里：$text',
      );
    });
  });
}
