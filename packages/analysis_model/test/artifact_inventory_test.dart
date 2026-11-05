import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('ArtifactInventory', () {
    const dex = ArtifactEntry(
      path: 'classes.dex',
      kind: ArtifactKind.dex,
      sizeBytes: 100,
      contentScanned: true,
    );
    const so = ArtifactEntry(
      path: 'lib/arm64-v8a/libfoo.so',
      kind: ArtifactKind.elf,
      sizeBytes: 200,
      arch: 'arm64-v8a',
    );
    const dylib = ArtifactEntry(
      path: 'Payload/App.app/evil.dylib',
      kind: ArtifactKind.dylib,
      origin: ArtifactOrigin.bundleRoot,
      sizeBytes: 300,
    );

    test('countByKind 按类型计数', () {
      const inventory = ArtifactInventory(
        entries: [dex, so, dylib],
        totalEntries: 10,
        inventoriedEntries: 3,
      );
      expect(inventory.countByKind[ArtifactKind.dex], 1);
      expect(inventory.countByKind[ArtifactKind.elf], 1);
      expect(inventory.countByKind[ArtifactKind.dylib], 1);
      expect(inventory.countByKind[ArtifactKind.framework], isNull);
    });

    test('entryForPath 精确匹配，找不到返回 null', () {
      const inventory = ArtifactInventory(entries: [dex, so]);
      expect(inventory.entryForPath('classes.dex')?.kind, ArtifactKind.dex);
      expect(inventory.entryForPath('nope'), isNull);
    });

    test('entryForBasename 把 loadLibrary("libfoo.so") 解析到 ABI 路径', () {
      const inventory = ArtifactInventory(entries: [so]);
      expect(inventory.entryForBasename('libfoo.so')?.arch, 'arm64-v8a');
      expect(inventory.entryForBasename('libbar.so'), isNull);
    });

    test('空清单不编造 entriesComplete=false', () {
      const inventory = ArtifactInventory();
      expect(inventory.isEmpty, isTrue);
      expect(inventory.totalEntries, 0);
      expect(inventory.entriesComplete, isTrue);
    });

    test('isCode 只对代码类为 true', () {
      expect(dex.isCode, isTrue);
      expect(so.isCode, isTrue);
      expect(dylib.isCode, isTrue);
      const asset = ArtifactEntry(
        path: 'assets/a.json',
        kind: ArtifactKind.assetText,
      );
      expect(asset.isCode, isFalse);
    });
  });

  group('PayloadSignal', () {
    test('code/kind/entropy 保持原值', () {
      const signal = PayloadSignal(
        path: 'assets/payload.dex',
        kind: PayloadKind.dex,
        code: 'payload.magicMismatch',
        sizeBytes: 12,
        entropy: 7.5,
        args: {'extension': '.bin'},
      );
      expect(signal.kind, PayloadKind.dex);
      expect(signal.code, 'payload.magicMismatch');
      expect(signal.entropy, 7.5);
      expect(signal.args['extension'], '.bin');
    });

    test('entropy 不可得时为 null，不填 0', () {
      const signal = PayloadSignal(
        path: 'a',
        kind: PayloadKind.unknown,
        code: 'payload.unknown',
      );
      expect(signal.entropy, isNull);
    });
  });
}
