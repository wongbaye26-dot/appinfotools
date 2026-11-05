// 制品清单分类：路径 → 类型/来源/ABI。
//
// 这一层只读**目录**，所以测试也只喂条目事实，不构造真实 APK：分类规则
// 是纯函数，用合成的条目表能覆盖到真实包里难得一见的分支（无扩展名的
// assets 载荷、`META-INF` 子目录里的假签名材料、超多条目触发截断）。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

/// 造一条文件条目。
ContainerEntryFact _file(String path, {int size = 16}) =>
    ContainerEntryFact(path: path, sizeBytes: size);

/// 造一条目录条目。
ContainerEntryFact _dir(String path) =>
    ContainerEntryFact(path: path, sizeBytes: 0, isDirectory: true);

ArtifactEntry _only(ArtifactInventory inventory, String path) {
  final entry = inventory.entryForPath(path);
  expect(entry, isNotNull,
      reason: '$path 应当进入清单，实际：'
          '${inventory.entries.map((e) => e.path).toList()}');
  return entry!;
}

void main() {
  group('分类', () {
    test('DEX 分片按 classes*.dex 收，且都在根目录', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _file('classes.dex'),
        _file('classes3.dex'),
        _file('classes10.dex'),
      ]);

      expect(
        inventory.entries.map((e) => e.kind).toSet(),
        {ArtifactKind.dex},
      );
      expect(inventory.entries, hasLength(3));
    });

    test('lib/<abi>/*.so 是 ELF，架构取自 ABI 目录', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _file('lib/arm64-v8a/libcrypto.so'),
        _file('lib/x86_64/libcrypto.so'),
      ]);

      final arm64 = _only(inventory, 'lib/arm64-v8a/libcrypto.so');
      expect(arm64.kind, ArtifactKind.elf);
      expect(arm64.arch, 'arm64-v8a');
      expect(arm64.origin, ArtifactOrigin.embedded);

      final x64 = _only(inventory, 'lib/x86_64/libcrypto.so');
      expect(x64.kind, ArtifactKind.elf);
      expect(x64.arch, 'x86_64');
    });

    test('assets 按扩展名分到 archive/binary/text/script', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _file('assets/payload.zip'),
        _file('assets/payload.dex'),
        _file('assets/config.json'),
        _file('assets/run.sh'),
      ]);

      expect(_only(inventory, 'assets/payload.zip').kind,
          ArtifactKind.assetArchive);
      expect(_only(inventory, 'assets/payload.dex').kind,
          ArtifactKind.assetBinary);
      expect(
          _only(inventory, 'assets/config.json').kind, ArtifactKind.assetText);
      expect(_only(inventory, 'assets/run.sh').kind, ArtifactKind.script);

      for (final entry in inventory.entries) {
        expect(entry.origin, ArtifactOrigin.assets,
            reason: '${entry.path} 的来源应当是 assets');
      }
    });

    test('assets 里认不出扩展名的条目保留为 unknown，而不是丢掉', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _file('assets/payload'),
      ]);

      final entry = _only(inventory, 'assets/payload');
      expect(entry.kind, ArtifactKind.unknown);
      // 认不出类型不等于「没有风险」：它仍在清单里，仍会被载荷探测看到。
      expect(entry.origin, ArtifactOrigin.assets);
    });

    test('资源表 / 清单 / v1 签名材料', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _file('resources.arsc'),
        _file('AndroidManifest.xml'),
        _file('META-INF/CERT.SF'),
        _file('META-INF/CERT.RSA'),
        _file('META-INF/CERT.EC'),
        _file('META-INF/MANIFEST.MF'),
      ]);

      expect(
          _only(inventory, 'resources.arsc').kind, ArtifactKind.resourceTable);
      expect(
          _only(inventory, 'AndroidManifest.xml').kind, ArtifactKind.manifest);
      expect(_only(inventory, 'META-INF/CERT.SF').kind,
          ArtifactKind.signatureBlock);
      expect(_only(inventory, 'META-INF/CERT.RSA').kind,
          ArtifactKind.signatureBlock);
      expect(_only(inventory, 'META-INF/CERT.EC').kind,
          ArtifactKind.signatureBlock);
      expect(
          _only(inventory, 'META-INF/MANIFEST.MF').kind, ArtifactKind.manifest);
    });

    test('META-INF 子目录里的同名文件不是签名材料（平台不认）', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _file('META-INF/sub/CERT.SF'),
        _file('META-INF/services/foo.Bar'),
      ]);

      // 平台只在 META-INF 顶层找 v1 材料；把子目录的算进来会给出不生效的结论。
      expect(inventory.entries, isEmpty);
      expect(inventory.entriesComplete, isTrue);
    });

    test('普通资源条目（图片/布局）不进清单', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _file('res/drawable/icon.png'),
        _file('res/layout/main.xml'),
        _file('kotlin/kotlin.kotlin_builtins'),
        _file('classes.dex'),
      ]);

      expect(inventory.entries, hasLength(1));
      expect(inventory.entries.single.path, 'classes.dex');
      // 分母仍然是全部**文件**条目：清单少不代表包小。
      expect(inventory.totalEntries, 4);
    });
  });

  group('不读内容', () {
    test('sha256 恒为 null、contentScanned 恒为 false、skipCode 说明未扫', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _file('classes.dex', size: 4096),
        _file('lib/arm64-v8a/libfoo.so', size: 8192),
      ]);

      for (final entry in inventory.entries) {
        expect(entry.sha256, isNull, reason: '本层不算哈希');
        expect(entry.contentScanned, isFalse);
        expect(entry.skipCode, AndroidArtifactInventoryScanner.notSelectedCode,
            reason: 'skipCode 为 null 会被下游读成「已扫过」');
        expect(entry.suspicionCodes, isEmpty);
        expect(entry.sizeBytes, greaterThan(0));
      }
    });
  });

  group('目录与截断', () {
    test('目录条目被过滤，也不进 totalEntries 分母', () {
      final inventory = AndroidArtifactInventoryScanner.scan([
        _dir('lib/'),
        _dir('lib/arm64-v8a/'),
        _file('lib/arm64-v8a/libfoo.so'),
        _dir('assets/'),
        _file('assets/x.dat'),
      ]);

      expect(inventory.entries, hasLength(2));
      expect(inventory.entries.any((e) => e.path.endsWith('/')), isFalse);
      // 2 个文件条目；两个目录不参与分母。
      expect(inventory.totalEntries, 2);
      expect(inventory.inventoriedEntries, 2);
    });

    test('超过 maxEntries 时截断并给出稳定 code', () {
      final inventory = AndroidArtifactInventoryScanner.scan(
        [
          _file('classes.dex'),
          _file('classes2.dex'),
          _file('classes3.dex'),
        ],
        maxEntries: 2,
      );

      expect(inventory.entries, hasLength(2));
      expect(inventory.inventoriedEntries, 2);
      expect(inventory.entriesComplete, isFalse);
      expect(inventory.skippedCodes,
          contains(AndroidArtifactInventoryScanner.truncatedCode));
    });

    test('截断只看「有哪些条目」，与输入顺序无关', () {
      final forward = AndroidArtifactInventoryScanner.scan(
        [
          _file('classes.dex'),
          _file('lib/arm64-v8a/liba.so'),
          _file('assets/z.bin'),
        ],
        maxEntries: 2,
      );
      final reversed = AndroidArtifactInventoryScanner.scan(
        [
          _file('assets/z.bin'),
          _file('lib/arm64-v8a/liba.so'),
          _file('classes.dex'),
        ],
        maxEntries: 2,
      );

      // 同一份内容重打包后中央目录顺序会变，留下的子集不该跟着变。
      expect(
        forward.entries.map((e) => e.path).toList(),
        reversed.entries.map((e) => e.path).toList(),
      );
    });

    test('maxEntries 为 0 时不收条目，但仍报告截断', () {
      final inventory = AndroidArtifactInventoryScanner.scan(
        [_file('classes.dex')],
        maxEntries: 0,
      );

      expect(inventory.entries, isEmpty);
      expect(inventory.entriesComplete, isFalse);
      expect(inventory.totalEntries, 1);
    });

    test('空输入是完整清单，不是截断', () {
      final inventory =
          AndroidArtifactInventoryScanner.scan(const <ContainerEntryFact>[]);

      expect(inventory.entries, isEmpty);
      expect(inventory.totalEntries, 0);
      expect(inventory.inventoriedEntries, 0);
      expect(inventory.entriesComplete, isTrue);
      expect(inventory.skippedCodes, isEmpty);
    });
  });

  test('清单条目按路径稳定排序，便于报告与断言', () {
    final inventory = AndroidArtifactInventoryScanner.scan([
      _file('resources.arsc'),
      _file('classes.dex'),
      _file('assets/a.bin'),
    ]);

    expect(
      inventory.entries.map((e) => e.path).toList(),
      ['assets/a.bin', 'classes.dex', 'resources.arsc'],
    );
  });
}
