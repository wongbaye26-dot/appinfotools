import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';
import 'package:test/test.dart';

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.add(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('ArchiveTreeBuilder', () {
    test('按目录分层，目录排在文件前，条目数正确', () {
      final archive = ZipDecoder().decodeBytes(_zip({
        'AndroidManifest.xml': '<manifest/>',
        'lib/arm64-v8a/libfoo.so': 'elf',
        'lib/x86/libfoo.so': 'elf',
        'res/drawable/icon.png': 'png',
      }));

      final tree = ArchiveTreeBuilder.build(archive);
      expect(tree.entryCount, 4);
      expect(tree.truncated, isFalse);

      final lib = tree.root.child('lib')!;
      expect(lib.isDirectory, isTrue);
      expect(lib.children.map((e) => e.name), ['arm64-v8a', 'x86']);
      expect(lib.child('arm64-v8a')!.child('libfoo.so')!.size, 3);

      final rootNames = tree.root.children.map((e) => e.name).toList();
      expect(rootNames.first, 'lib'); // 目录优先
      expect(rootNames, containsAll(['AndroidManifest.xml', 'lib', 'res']));
    });

    test('嵌套 zip 被展开，内部路径用 ! 分隔', () {
      final inner = _zip({'payload.dex': 'dexdata'});
      final archive = Archive();
      archive.add(ArchiveFile('assets/payload.zip', inner.length, inner));
      archive.add(ArchiveFile('classes.dex', 3, utf8.encode('dex')));

      final tree = ArchiveTreeBuilder.build(
        archive,
        readForNesting: (file) =>
            file.name == 'assets/payload.zip' ? inner : null,
      );
      final payload = tree.root.child('assets')!.child('payload.zip')!;
      expect(payload.isNestedArchive, isTrue);
      final innerDex = payload.child('payload.dex')!;
      expect(innerDex.path, 'assets/payload.zip!payload.dex');
      expect(innerDex.size, 7);
      expect(tree.entryCount, 3);
    });

    test('魔数不是 PK\\x03\\x04 的候选不展开，记 nestedUndecodable', () {
      final archive = Archive();
      archive.add(ArchiveFile('assets/fake.zip', 4, utf8.encode('nope')));
      final tree = ArchiveTreeBuilder.build(
        archive,
        readForNesting: (_) => Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(tree.root.child('assets')!.child('fake.zip')!.children, isEmpty);
      expect(tree.skippedCodes, contains('tree.nestedUndecodable'));
    });

    test('超出条目上限时截断并记录 tree.entryLimit', () {
      final archive = ZipDecoder().decodeBytes(_zip({
        'a.txt': 'a',
        'b.txt': 'b',
        'c.txt': 'c',
      }));
      final tree = ArchiveTreeBuilder.build(
        archive,
        limits: const ArchiveTreeLimits(maxEntries: 2),
      );
      expect(tree.truncated, isTrue);
      expect(tree.skippedCodes, contains('tree.entryLimit'));
      expect(tree.entryCount, lessThanOrEqualTo(2));
    });

    test('maxNestedDepth = 0 时不展开，记 tree.depthLimit', () {
      final level1 = _zip({'l1.txt': 'x'});
      final archive = Archive();
      archive.add(ArchiveFile('outer.zip', 4, utf8.encode('zip')));
      final tree = ArchiveTreeBuilder.build(
        archive,
        limits: const ArchiveTreeLimits(maxNestedDepth: 0),
        readForNesting: (_) => level1,
      );
      expect(tree.root.child('outer.zip')!.children, isEmpty);
      expect(tree.skippedCodes, contains('tree.depthLimit'));
    });

    test('嵌套归档里的归档本次不展开，记 nestedNotExpanded（按需加载留给 UI）', () {
      final level1 = _zip({'inner.zip': 'pk'});
      final archive = Archive();
      archive.add(ArchiveFile('outer.zip', 4, utf8.encode('zip')));
      final tree = ArchiveTreeBuilder.build(
        archive,
        readForNesting: (_) => level1,
      );
      expect(tree.root.child('outer.zip')!.child('inner.zip'), isNotNull);
      expect(tree.skippedCodes, contains('tree.nestedNotExpanded'));
    });
  });
}
