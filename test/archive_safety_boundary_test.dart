// 归档安全边界（阶段 2）。
//
// 覆盖三项此前缺失的防护：
// 1. 单个条目的解压上限 —— 总量上限拦不住「一个 900 MiB 的条目」；
// 2. 跨多层归档的**累计**预算 —— 每层各自不超限，加起来失控；
// 3. EOCD 声明的条目数与实际条目数一致性 —— 发现被裁剪/拼接的归档。
//
// 这些样本都是**手工构造**的：没有工具能生成「声明尺寸与实际不符」的归档，
// 而这正是要防的形态。

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个解压后为 [size] 字节的全零条目。
///
/// 全零数据压缩比极高，因此压缩包本身很小 —— 这正是 ZIP 炸弹的形态。
Archive bomb(int size, {String name = 'bomb.bin'}) {
  final data = Uint8List(size);
  return Archive()..addFile(ArchiveFile(name, data.length, data));
}

/// 造一个总解压量为 [totalBytes] 的层，**用多个条目拼出来**。
///
/// 单条目会被单文件上限拦下，所以「多层累计超限」这个场景必须由多个
/// 合规条目组成 —— 否则测的就不是累计逻辑了。
Archive layerOf(int totalBytes) {
  const chunk = 64 * 1024 * 1024;
  final archive = Archive();
  var remaining = totalBytes;
  var i = 0;
  while (remaining > 0) {
    final size = remaining > chunk ? chunk : remaining;
    archive.addFile(ArchiveFile('c${i++}.bin', size, Uint8List(0)));
    remaining -= size;
  }
  return archive;
}

void main() {
  group('单条目解压上限', () {
    test('超过单文件上限的条目被拒绝', () {
      // 只放一个条目，但它的声明尺寸超过单文件上限（256 MiB）。
      final archive = Archive()
        ..addFile(ArchiveFile(
          'huge.bin',
          ZipBudget.maxSingleEntryUncompressed + 1,
          Uint8List(0), // 内容无关紧要，判定只看声明尺寸
        ));

      expect(ZipBudget.isExceeded(archive), isTrue);
      expect(
        () => ZipBudget.ensureWithin(archive, source: 'test'),
        throwsA(isA<ZipBombException>()),
      );
    });

    test('刚好等于上限的条目放行', () {
      final archive = Archive()
        ..addFile(ArchiveFile(
          'ok.bin',
          ZipBudget.maxSingleEntryUncompressed,
          Uint8List(0),
        ));

      expect(ZipBudget.isExceeded(archive), isFalse);
    });
  });

  group('跨层累计预算', () {
    test('单层不超限时正常累计', () {
      final tracker = ZipBudgetTracker();

      tracker.add(bomb(1024), label: 'layer-1');
      tracker.add(bomb(2048), label: 'layer-2');

      expect(tracker.layers, ['layer-1', 'layer-2']);
      expect(tracker.totalUncompressed, 1024 + 2048);
    });

    test('多层累计超过总量时抛出，并指出是哪一层', () {
      final tracker = ZipBudgetTracker();
      // 每层都远低于单层上限，但加起来超过总量上限。
      const layerSize = ZipBudget.maxTotalUncompressed ~/ 3 + 1;

      tracker.add(layerOf(layerSize), label: 'layer-1');
      tracker.add(layerOf(layerSize), label: 'layer-2');

      expect(
        () => tracker.add(layerOf(layerSize), label: 'layer-3'),
        throwsA(
          isA<ZipBombException>().having(
            (e) => e.source,
            'source',
            'layer-3',
          ),
        ),
        reason: '异常必须指出是哪一层把总量顶爆的，否则无从排查',
      );
    });

    test('累计条目数超限时抛出', () {
      final tracker = ZipBudgetTracker();
      // 一层里放超过上限的条目数 —— 用空条目，避免真的分配内存。
      final many = Archive();
      for (var i = 0; i <= ZipBudget.maxEntryCount; i++) {
        many.addFile(ArchiveFile('f$i', 0, Uint8List(0)));
      }

      expect(
        () => tracker.add(many, label: 'many'),
        throwsA(isA<ZipBombException>()),
      );
    });

    test('负尺寸条目被拒绝', () {
      final tracker = ZipBudgetTracker();
      final archive = Archive()
        ..addFile(ArchiveFile('neg.bin', -1, Uint8List(0)));

      expect(
        () => tracker.add(archive, label: 'neg'),
        throwsA(isA<ZipBombException>()),
      );
    });
  });

  group('EOCD 条目数一致性', () {
    /// 造一个最小合法 ZIP，并把 EOCD 里的总条目数改成 [declaredOverride]。
    Uint8List zipWithDeclaredCount(int realCount, int declaredOverride) {
      final archive = Archive();
      for (var i = 0; i < realCount; i++) {
        final data = Uint8List.fromList([i]);
        archive.addFile(ArchiveFile('f$i.txt', data.length, data));
      }
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

      // EOCD 从尾部往前找（这里没有注释，就是最后 22 字节）。
      final eocd = bytes.length - ZipStructure.eocdLength;
      expect(bytes[eocd], 0x50, reason: '样本应当是合法 ZIP');
      // 偏移 8 是「本磁盘条目数」，**10 是「总条目数」**，12 起是中央目录
      // 大小（4 字节）。我们读的是偏移 10，因此只改这一处。
      bytes[eocd + 10] = declaredOverride & 0xff;
      bytes[eocd + 11] = (declaredOverride >> 8) & 0xff;
      return bytes;
    }

    test('一致时返回 null', () {
      final bytes = zipWithDeclaredCount(3, 3);
      expect(ZipStructure.declaredEntryCount(bytes), 3);
      expect(ZipStructure.checkEntryCount(bytes, 3), isNull);
    });

    test('不一致时给出说明', () {
      // 声明 99 条，实际只有 3 条 —— 典型的「归档被裁剪」。
      final bytes = zipWithDeclaredCount(3, 99);
      final problem = ZipStructure.checkEntryCount(bytes, 3);

      expect(problem, isNotNull);
      expect(problem, contains('99'));
      expect(problem, contains('3'));
    });

    test('读不到 EOCD 时不算异常（避免误报）', () {
      final notZip = Uint8List.fromList(List<int>.filled(100, 0x41));
      expect(ZipStructure.declaredEntryCount(notZip), isNull);
      expect(
        ZipStructure.checkEntryCount(notZip, 5),
        isNull,
        reason: '读不到 EOCD 不是「不一致」，把它当异常会产生误报',
      );
    });

    test('EOCD 后面带合法注释时仍能定位', () {
      final bytes = zipWithDeclaredCount(2, 2);
      // 追加注释，并**同步改 comment length 字段** —— 否则这不是一个合法
      // ZIP，测的就是另一回事了。
      const commentLength = 64;
      final eocd = bytes.length - ZipStructure.eocdLength;
      bytes[eocd + 20] = commentLength & 0xff;
      bytes[eocd + 21] = (commentLength >> 8) & 0xff;

      final withComment = Uint8List.fromList([
        ...bytes,
        ...List<int>.filled(commentLength, 0x2a),
      ]);
      expect(ZipStructure.declaredEntryCount(withComment), 2);
      expect(ZipStructure.checkEntryCount(withComment, 2), isNull);
    });

    test('尾部多出字节导致长度不自洽时，不认那个 EOCD（避免误报）', () {
      // 压缩数据里偶然出现 `PK\x05\x06` 是可能的。校验「注释长度恰好把
      // EOCD 顶到末尾」才能把它排除掉；不校验的话，这里会报出 0 条并据此
      // 判定「归档不一致」—— 一次彻底的误报。
      final bytes = zipWithDeclaredCount(2, 2);
      final padded = Uint8List.fromList([...bytes, 0x00, 0x00, 0x00, 0x00]);

      expect(
        ZipStructure.declaredEntryCount(padded),
        isNull,
        reason: '注释长度为 0 却还有 4 个尾随字节 → 这不是一个合法的 EOCD',
      );
      expect(ZipStructure.checkEntryCount(padded, 2), isNull);
    });
  });
}
