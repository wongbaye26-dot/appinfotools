import 'package:apk_parser/apk_parser.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一个声明尺寸为 [size] 的条目。
///
/// 实际只放几个字节 —— 统计只看**声明尺寸**，没必要真的分配那么多内存。
ArchiveFile _file(String name, int size) =>
    ArchiveFile(name, size, List.filled(size.clamp(0, 8), 0));

/// 目录条目（`isFile = false`）。
ArchiveFile _dir(String name) => ArchiveFile(name, 0, [])..isFile = false;

void main() {
  group('ContainerStructureCollector', () {
    test('统计文件条目数，排除目录条目', () {
      final archive = Archive()
        ..addFile(_dir('res/'))
        ..addFile(_file('AndroidManifest.xml', 100))
        ..addFile(_file('res/a.png', 200));

      final s = ContainerStructureCollector.collect(archive);

      expect(s.fileEntryCount, 2);
      expect(s.totalUncompressedBytes, 300);
    });

    test('DEX 条目按名字排序', () {
      final archive = Archive()
        ..addFile(_file('classes10.dex', 10))
        ..addFile(_file('classes2.dex', 20))
        ..addFile(_file('classes.dex', 30));

      final s = ContainerStructureCollector.collect(archive);

      expect(s.dexFileCount, 3);
      // 字典序：classes.dex < classes10.dex < classes2.dex
      expect(s.dexFiles.map((d) => d.name).toList(),
          ['classes.dex', 'classes10.dex', 'classes2.dex']);
    });

    test('只认根目录下的 classes*.dex', () {
      final archive = Archive()
        ..addFile(_file('classes.dex', 1))
        ..addFile(_file('assets/classes.dex', 1))
        ..addFile(_file('classesX.dex', 1));

      final s = ContainerStructureCollector.collect(archive);

      expect(s.dexFileCount, 1);
      expect(s.dexFiles.single.name, 'classes.dex');
    });

    test('原生库按 ABI 归类，ABI 去重且排序', () {
      final archive = Archive()
        ..addFile(_file('lib/arm64-v8a/liba.so', 10))
        ..addFile(_file('lib/arm64-v8a/libb.so', 20))
        ..addFile(_file('lib/armeabi-v7a/liba.so', 30))
        ..addFile(_file('lib/x86_64/odd', 5));

      final s = ContainerStructureCollector.collect(archive);

      expect(s.abis, ['arm64-v8a', 'armeabi-v7a', 'x86_64']);
      expect(s.nativeLibraryCount, 4);

      final first = s.nativeLibraries.first;
      expect(first.path, 'lib/arm64-v8a/liba.so');
      expect(first.abi, 'arm64-v8a');
      expect(first.name, 'liba.so');
      expect(first.size, 10);
    });

    test('lib/ 之外的目录不会被当成原生库', () {
      final archive = Archive()
        ..addFile(_file('assets/lib/arm64-v8a/x.so', 1))
        ..addFile(_file('lib/arm64-v8a/nested/deep.so', 1));

      final s = ContainerStructureCollector.collect(archive);

      expect(s.nativeLibraries, isEmpty);
      expect(s.abis, isEmpty);
    });

    test('顶层目录统计文件数与解压字节', () {
      final archive = Archive()
        ..addFile(_file('res/a.png', 100))
        ..addFile(_file('res/b.png', 200))
        ..addFile(_file('assets/c.dat', 50));

      final s = ContainerStructureCollector.collect(archive);

      expect(s.topLevelDirectories['res']!.fileCount, 2);
      expect(s.topLevelDirectories['res']!.uncompressedBytes, 300);
      expect(s.topLevelDirectories['assets']!.fileCount, 1);
    });

    test('根目录下的条目归到 (root)', () {
      final archive = Archive()..addFile(_file('AndroidManifest.xml', 10));

      final s = ContainerStructureCollector.collect(archive);

      expect(s.topLevelDirectories.keys, contains('(root)'));
      expect(s.topLevelDirectories['(root)']!.fileCount, 1);
      expect(s.topLevelDirectories['(root)']!.uncompressedBytes, 10);
    });

    test('空归档返回全零结构，不抛异常', () {
      final s = ContainerStructureCollector.collect(Archive());

      expect(s.fileEntryCount, 0);
      expect(s.dexFileCount, 0);
      expect(s.nativeLibraries, isEmpty);
      expect(s.abis, isEmpty);
      expect(s.topLevelDirectories, isEmpty);
      expect(s.totalUncompressedBytes, 0);
      expect(s.topDirectoriesBySize(), isEmpty);
    });

    test('topDirectoriesBySize 按体积降序并受 limit 限制', () {
      final archive = Archive();
      for (var i = 0; i < 10; i++) {
        archive.addFile(_file('d$i/f', (i + 1) * 100));
      }

      final s = ContainerStructureCollector.collect(archive);
      final top = s.topDirectoriesBySize(limit: 3);

      expect(top, hasLength(3));
      expect(top.map((e) => e.key).toList(), ['d9', 'd8', 'd7']);
    });
  });
}
