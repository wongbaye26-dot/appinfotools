import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('ArtifactIdentity', () {
    test('同一路径稳定，路径大小写/前导斜杠不影响', () {
      expect(ArtifactIdentity.of('lib/arm64-v8a/libfoo.so'),
          ArtifactIdentity.of('/LIB/ARM64-V8A/libfoo.so'));
      expect(ArtifactIdentity.of('classes.dex'), startsWith('art_'));
      expect(ArtifactIdentity.of('classes.dex'), hasLength(20));
    });

    test('不同路径得到不同身份（嵌套归档用 ! 区分）', () {
      final outer = ArtifactIdentity.of('assets/payload.zip');
      final inner = ArtifactIdentity.of('assets/payload.zip!payload.dex');
      expect(outer, isNot(inner));
    });

    test('describe：普通条目取父目录，根条目为 null', () {
      expect(ArtifactIdentity.describe('lib/x86/libfoo.so'), ('lib/x86', null));
      expect(ArtifactIdentity.describe('classes.dex'), (null, null));
    });

    test('describe：嵌套归档条目的父容器是归档路径', () {
      expect(
        ArtifactIdentity.describe('assets/payload.zip!payload.dex'),
        ('assets/payload.zip', 'payload.dex'),
      );
      expect(
        ArtifactIdentity.describe('a.zip!b.zip!c.dex'),
        ('a.zip!b.zip', 'c.dex'),
      );
    });

    test('ArtifactEntry.stableId 优先用显式 id', () {
      const entry = ArtifactEntry(
        path: 'classes.dex',
        kind: ArtifactKind.dex,
        artifactId: 'art_explicit',
      );
      expect(entry.stableId, 'art_explicit');
      const derived =
          ArtifactEntry(path: 'classes.dex', kind: ArtifactKind.dex);
      expect(derived.stableId, ArtifactIdentity.of('classes.dex'));
    });
  });
}
