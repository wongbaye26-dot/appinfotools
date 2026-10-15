// archive_safety 的包级测试。
//
// 与根目录 `test/archive_safety_boundary_test.dart` 的关系：那个文件从**应用**
// 的角度覆盖边界（阈值、误报防护、解包路径逃逸）；这里从**包自身**的角度确认
// 它作为独立库可用 —— 公开 API 齐全、不依赖应用层、单独 `dart test` 就能跑。
//
// 两边都保留：包级测试保证「这个包能独立成立」，根测试保证「应用真的用对了它」。
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';
import 'package:test/test.dart';

/// 造一个解压后为 [size] 字节的全零条目（压缩比极高，是 ZIP 炸弹的形态）。
Archive bomb(int size, {String name = 'bomb.bin'}) {
  final data = Uint8List(size);
  return Archive()..addFile(ArchiveFile(name, data.length, data));
}

/// 造一个含 [count] 个普通条目的归档。
Archive withEntries(int count) {
  final archive = Archive();
  for (var i = 0; i < count; i++) {
    archive
        .addFile(ArchiveFile('f$i.txt', 4, Uint8List.fromList([1, 2, 3, 4])));
  }
  return archive;
}

/// 把归档编码成 ZIP 字节。
Uint8List encode(Archive archive) =>
    Uint8List.fromList(ZipEncoder().encode(archive));

void main() {
  group('looksLikeZip — 只看魔数', () {
    test('三种合法的 ZIP 起始签名都被接受', () {
      // 本地文件头、空归档（EOCD）、跨卷续段。
      for (final sig in [
        [0x50, 0x4b, 0x03, 0x04],
        [0x50, 0x4b, 0x05, 0x06],
        [0x50, 0x4b, 0x07, 0x08],
      ]) {
        expect(looksLikeZip(sig), isTrue, reason: '$sig 应当被认成 ZIP');
      }
    });

    test('太短、非 ZIP、以及 PK 但第三字节不对的都不接受', () {
      expect(looksLikeZip(const []), isFalse);
      expect(looksLikeZip(const [0x50, 0x4b, 0x03]), isFalse);
      expect(looksLikeZip(const [0x89, 0x50, 0x4e, 0x47]), isFalse,
          reason: 'PNG');
      expect(looksLikeZip(const [0x50, 0x4b, 0x00, 0x00]), isFalse);
    });
  });

  group('ZipStructure.declaredEntryCount — EOCD 自洽校验', () {
    test('真实归档读出正确的条目数', () {
      final bytes = encode(withEntries(7));
      expect(ZipStructure.declaredEntryCount(bytes), 7);
    });

    test('字节太少时返回 null，而不是抛异常', () {
      expect(ZipStructure.declaredEntryCount(Uint8List(4)), isNull);
    });

    test('EOCD 后带合法注释仍能定位', () {
      final base = encode(withEntries(3));
      // 手工补一段注释并把 EOCD 的注释长度字段改对。
      final comment = Uint8List.fromList(List.filled(16, 0x41));
      final out = Uint8List(base.length + comment.length)
        ..setAll(0, base)
        ..setAll(base.length, comment);
      final eocd = base.length - ZipStructure.eocdLength;
      out[eocd + 20] = comment.length & 0xff;
      out[eocd + 21] = (comment.length >> 8) & 0xff;

      expect(ZipStructure.declaredEntryCount(out), 3);
    });

    test('注释长度不自洽时不认这个 EOCD', () {
      final base = encode(withEntries(3));
      final out = Uint8List.fromList(base);
      final eocd = base.length - ZipStructure.eocdLength;
      out[eocd + 20] = 0xff; // 声称有 255 字节注释，但后面什么都没有
      out[eocd + 21] = 0x00;

      expect(ZipStructure.declaredEntryCount(out), isNull,
          reason: '长度对不上就不是 EOCD，宁可返回 null 也不能读出错值');
    });

    test('随机字节永远不抛异常，只返回 null 或一个数', () {
      final random = Random(20261015);
      for (var i = 0; i < 200; i++) {
        final bytes = Uint8List.fromList(
          List.generate(64 + random.nextInt(256), (_) => random.nextInt(256)),
        );
        expect(() => ZipStructure.declaredEntryCount(bytes), returnsNormally);
      }
    });
  });

  group('ZipStructure.checkEntryCount — 声明与实际比对', () {
    test('一致时返回 null', () {
      final bytes = encode(withEntries(5));
      expect(ZipStructure.checkEntryCount(bytes, 5), isNull);
    });

    test('不一致时给出说明，并带上两个数', () {
      final bytes = encode(withEntries(5));
      final message = ZipStructure.checkEntryCount(bytes, 9);
      expect(message, isNotNull);
      expect(message, contains('5'));
      expect(message, contains('9'));
    });

    test('读不到 EOCD 时不算异常（非标准 ZIP 很常见）', () {
      expect(ZipStructure.checkEntryCount(Uint8List(8), 3), isNull);
    });
  });

  group('ZipBudget — 单条目与总量上限', () {
    test('正常归档不超限', () {
      expect(ZipBudget.isExceeded(withEntries(10)), isFalse);
    });

    test('单条目超过单文件上限即超限', () {
      expect(
          ZipBudget.isExceeded(bomb(ZipBudget.maxSingleEntryUncompressed + 1)),
          isTrue);
    });

    test('恰好等于上限不算超限（边界必须成对）', () {
      expect(ZipBudget.isExceeded(bomb(ZipBudget.maxSingleEntryUncompressed)),
          isFalse);
    });

    test('条目数超过上限即超限', () {
      final archive = Archive();
      for (var i = 0; i <= ZipBudget.maxEntryCount; i++) {
        archive.addFile(ArchiveFile('f$i', 0, Uint8List(0)));
      }
      expect(ZipBudget.isExceeded(archive), isTrue);
    });

    test('声明尺寸为负视为超限（不信任归档头）', () {
      final archive = Archive()..addFile(ArchiveFile('bad', -1, Uint8List(0)));
      expect(ZipBudget.isExceeded(archive), isTrue);
    });

    test('ensureWithin 抛 ZipBombException 并带上来源', () {
      expect(
        () => ZipBudget.ensureWithin(
          bomb(ZipBudget.maxSingleEntryUncompressed + 1),
          source: 'unit-test',
        ),
        throwsA(isA<ZipBombException>()
            .having((e) => e.toString(), 'message', contains('unit-test'))),
      );
    });

    test('ensureWithin 对合规归档不抛', () {
      expect(() => ZipBudget.ensureWithin(withEntries(3)), returnsNormally);
    });
  });

  group('ZipBudgetTracker — 跨层累计', () {
    test('单层不超限时正常累计', () {
      final tracker = ZipBudgetTracker()..add(withEntries(4), label: 'layer-1');
      expect(tracker.entryCount, 4);
      expect(tracker.layers, ['layer-1']);
    });

    test('多层累计超总量时抛出，并指出是哪一层顶爆的', () {
      const chunk = 64 * 1024 * 1024;
      // 每层都在单条目上限之内，但加起来超过总量上限。
      Archive layer() {
        final archive = Archive();
        var remaining = ZipBudget.maxTotalUncompressed ~/ 2 + chunk;
        var i = 0;
        while (remaining > 0) {
          final size = remaining > chunk ? chunk : remaining;
          archive.addFile(ArchiveFile('c${i++}.bin', size, Uint8List(0)));
          remaining -= size;
        }
        return archive;
      }

      final tracker = ZipBudgetTracker()..add(layer(), label: 'outer');
      expect(
        () => tracker.add(layer(), label: 'inner'),
        throwsA(isA<ZipBombException>()
            .having((e) => e.toString(), 'message', contains('inner'))),
      );
    });

    test('layers 只读且保持加入顺序', () {
      final tracker = ZipBudgetTracker()
        ..add(withEntries(1), label: 'a')
        ..add(withEntries(1), label: 'b');
      expect(tracker.layers, ['a', 'b']);
      expect(() => tracker.layers.add('c'), throwsUnsupportedError);
    });
  });

  group('looksStructurallyBroken — 空归档兜底', () {
    test('非空归档不算坏', () {
      expect(looksStructurallyBroken(withEntries(2), 1024), isFalse);
    });

    test('解析出空但输入不小，说明结构坏了', () {
      expect(looksStructurallyBroken(Archive(), 4096), isTrue);
    });

    test('输入本身就极小时不武断判定为坏', () {
      expect(looksStructurallyBroken(Archive(), 4), isFalse);
    });
  });

  group('ArchiveOpenResult', () {
    test('只有 ok 报 isOk', () {
      for (final result in ArchiveOpenResult.values) {
        expect(result.isOk, result == ArchiveOpenResult.ok);
      }
    });

    test('五种结局互不相同（分类不能合并）', () {
      expect(ArchiveOpenResult.values.toSet(), hasLength(5));
    });
  });
}
