import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeArchivePath', () {
    test('统一反斜杠、去掉前导 ./ 与结尾 /', () {
      expect(normalizeArchivePath(r'Payload\App.app\Info.plist'),
          'Payload/App.app/Info.plist');
      expect(normalizeArchivePath('./classes.dex'), 'classes.dex');
      expect(normalizeArchivePath('lib/arm64-v8a/'), 'lib/arm64-v8a');
      expect(normalizeArchivePath(''), '');
    });

    test('不折叠内部 ..（边界校验是 archive_safety 的职责）', () {
      expect(normalizeArchivePath('a/../b'), 'a/../b');
    });
  });

  group('ContainerEntryFact', () {
    test('isFile 与 isDirectory 互斥', () {
      const file = ContainerEntryFact(path: 'classes.dex', sizeBytes: 1);
      const dir = ContainerEntryFact(
        path: 'lib',
        sizeBytes: 0,
        isDirectory: true,
      );
      expect(file.isFile, isTrue);
      expect(file.isDirectory, isFalse);
      expect(dir.isFile, isFalse);
      expect(dir.isDirectory, isTrue);
    });

    test('compressed/method 不可得时保持 null，不填 0', () {
      const entry = ContainerEntryFact(path: 'a', sizeBytes: 10);
      expect(entry.compressedBytes, isNull);
      expect(entry.compressionMethod, isNull);
    });

    test('copyWith 只改传入字段', () {
      const entry = ContainerEntryFact(
        path: 'a',
        sizeBytes: 10,
        compressionMethod: 8,
      );
      final copy = entry.copyWith(path: 'b');
      expect(copy.path, 'b');
      expect(copy.sizeBytes, 10);
      expect(copy.compressionMethod, 8);
    });
  });
}
