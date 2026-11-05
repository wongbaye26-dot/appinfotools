// IPA 条目 → 制品清单（`IosArtifactInventoryScanner`）。
//
// 断言的全部是**布局事实**：分类、来源（`.app` 根 / `Frameworks/` / 嵌套
// bundle / assets）、截断标记。不涉及内容（清单阶段不读字节），因此这里
// 不出现魔数，也就不可能把「文件里写了什么」当成判据。
import 'package:analysis_model/analysis_model.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

ContainerEntryFact _file(String path, {int size = 16}) => ContainerEntryFact(
      path: path,
      sizeBytes: size,
      compressedBytes: size,
      compressionMethod: 8,
    );

ContainerEntryFact _dir(String path) => ContainerEntryFact(
      path: path,
      sizeBytes: 0,
      isDirectory: true,
    );

void main() {
  group('主可执行文件：无扩展名 + _CodeSignature 同级', () {
    final entries = <ContainerEntryFact>[
      _dir('Payload/'),
      _dir('Payload/Demo.app/'),
      _dir('Payload/Demo.app/_CodeSignature/'),
      _file('Payload/Demo.app/_CodeSignature/CodeResources'),
      _file('Payload/Demo.app/Info.plist'),
      _file('Payload/Demo.app/Demo'),
      _file('Payload/Demo.app/PkgInfo'),
      _file('Payload/Demo.app/Frameworks/libswift_Concurrency.dylib'),
      _file('Payload/Demo.app/Frameworks/Foo.framework/Foo'),
      _file('Payload/Demo.app/Frameworks/Foo.framework/Info.plist'),
      _file('Payload/Demo.app/evil.dylib'),
      _file('Payload/Demo.app/PlugIns/Widget.appex/Widget'),
      _file('Payload/Demo.app/PlugIns/Widget.appex/Info.plist'),
      _file('Payload/Demo.app/assets/payload.dex'),
      _file('Payload/Demo.app/assets/run.js'),
      _file('Payload/Demo.app/assets/config.json'),
      _file('Payload/Demo.app/assets/images/bg.png'),
      _file('Payload/Demo.app/Assets.car'),
      _file('Payload/Demo.app/embedded.mobileprovision'),
    ];
    final inventory = IosArtifactInventoryScanner.scan(entries);

    test('主可执行文件 → machO / embedded', () {
      final entry = inventory.entryForPath('Payload/Demo.app/Demo');
      expect(entry, isNotNull);
      expect(entry!.kind, ArtifactKind.machO);
      expect(entry.origin, ArtifactOrigin.embedded);
      // 清单不读内容：架构/哈希恒为「没查」；skipCode 用 not.selected，
      // 不能留 null（null 在契约里表示「进入过内容级扫描」）。
      expect(entry.arch, isNull);
      expect(entry.sha256, isNull);
      expect(entry.contentScanned, isFalse);
      expect(entry.skipCode, IosArtifactInventoryScanner.notSelectedCode);
    });

    test('PkgInfo 不会被当成主可执行文件', () {
      expect(inventory.entryForPath('Payload/Demo.app/PkgInfo'), isNull);
    });

    test('根目录 dylib 与 Frameworks/ 的来源分开记', () {
      expect(
        inventory.entryForPath('Payload/Demo.app/evil.dylib')?.origin,
        ArtifactOrigin.bundleRoot,
      );
      expect(
        inventory.entryForPath('Payload/Demo.app/evil.dylib')?.kind,
        ArtifactKind.dylib,
      );
      final swift = inventory.entryForPath(
          'Payload/Demo.app/Frameworks/libswift_Concurrency.dylib');
      expect(swift!.kind, ArtifactKind.dylib);
      expect(swift.origin, ArtifactOrigin.frameworks);
    });

    test('framework 主二进制 → framework / frameworks', () {
      final foo = inventory
          .entryForPath('Payload/Demo.app/Frameworks/Foo.framework/Foo');
      expect(foo!.kind, ArtifactKind.framework);
      expect(foo.origin, ArtifactOrigin.frameworks);
      // framework 里的 Info.plist 是清单，不是代码。
      final plist = inventory
          .entryForPath('Payload/Demo.app/Frameworks/Foo.framework/Info.plist');
      expect(plist!.kind, ArtifactKind.manifest);
      expect(plist.origin, ArtifactOrigin.frameworks);
    });

    test('appex 里的可执行文件 → nestedCodeBundle / nestedBundle', () {
      final widget = inventory
          .entryForPath('Payload/Demo.app/PlugIns/Widget.appex/Widget');
      expect(widget!.kind, ArtifactKind.nestedCodeBundle);
      expect(widget.origin, ArtifactOrigin.nestedBundle);
      final plist = inventory
          .entryForPath('Payload/Demo.app/PlugIns/Widget.appex/Info.plist');
      expect(plist!.kind, ArtifactKind.manifest);
      expect(plist.origin, ArtifactOrigin.nestedBundle);
    });

    test('assets 载荷按扩展名分流，媒体资源不进清单', () {
      final dex = inventory.entryForPath('Payload/Demo.app/assets/payload.dex');
      expect(dex!.kind, ArtifactKind.dex);
      expect(dex.origin, ArtifactOrigin.assets);

      final script = inventory.entryForPath('Payload/Demo.app/assets/run.js');
      expect(script!.kind, ArtifactKind.script);
      expect(script.origin, ArtifactOrigin.assets);

      final json =
          inventory.entryForPath('Payload/Demo.app/assets/config.json');
      expect(json!.kind, ArtifactKind.assetText);
      expect(json.origin, ArtifactOrigin.assets);

      // 图片不是载荷候选：不占 2 000 条预算，也不能被读成「清单被截断」。
      expect(
        inventory.entryForPath('Payload/Demo.app/assets/images/bg.png'),
        isNull,
      );
    });

    test('Assets.car → assetArchive（编译后的资源归档，选 archive 不是 binary）', () {
      final car = inventory.entryForPath('Payload/Demo.app/Assets.car');
      expect(car!.kind, ArtifactKind.assetArchive);
      expect(car.origin, ArtifactOrigin.embedded);
    });

    test('签名材料 → signatureBlock', () {
      final resources = inventory.entryForPath(
        'Payload/Demo.app/_CodeSignature/CodeResources',
      );
      expect(resources!.kind, ArtifactKind.signatureBlock);
      final provision =
          inventory.entryForPath('Payload/Demo.app/embedded.mobileprovision');
      expect(provision!.kind, ArtifactKind.signatureBlock);
    });

    test('目录条目不计入清单，也不计入 totalEntries 分母', () {
      final fileCount = entries.where((e) => !e.isDirectory).length;
      expect(inventory.totalEntries, fileCount);
      expect(inventory.totalEntries, 16);
      // 16 个文件里：PkgInfo 与 bg.png 不是制品，剩下 14 条。
      expect(inventory.inventoriedEntries, 14);
      expect(inventory.entries.length, inventory.inventoriedEntries);
      expect(inventory.entriesComplete, isTrue);
      expect(inventory.skippedCodes, isEmpty);
    });

    test('清单按路径稳定排序', () {
      final paths = inventory.entries.map((e) => e.path).toList();
      final sorted = [...paths]..sort();
      expect(paths, sorted);
    });
  });

  group('无法确认主可执行文件时不瞎猜', () {
    final inventory = IosArtifactInventoryScanner.scan([
      _file('Payload/Demo.app/Info.plist'),
      _file('Payload/Demo.app/Demo'),
      _file('Payload/Demo.app/PkgInfo'),
    ]);

    test('缺 _CodeSignature/ → unknown/unknown，而不是硬判 machO', () {
      final entry = inventory.entryForPath('Payload/Demo.app/Demo');
      expect(entry!.kind, ArtifactKind.unknown);
      expect(entry.origin, ArtifactOrigin.unknown);
    });
  });

  group('嵌套 bundle 与静态库', () {
    final inventory = IosArtifactInventoryScanner.scan([
      _file('Payload/Demo.app/Demo'),
      _file('Payload/Demo.app/_CodeSignature/CodeResources'),
      _file('Payload/Demo.app/Watch/Demo Watch.app/Demo Watch'),
      _file('Payload/Demo.app/PlugIns/Widget.appex/libw.dylib'),
      _file(
          'Payload/Demo.app/PlugIns/Widget.appex/Frameworks/Bar.framework/Bar'),
      _file('Payload/Demo.app/Frameworks/libfoo.a'),
    ]);

    test('Watch 里的 .app 主可执行文件 → nestedCodeBundle', () {
      final watch = inventory
          .entryForPath('Payload/Demo.app/Watch/Demo Watch.app/Demo Watch');
      expect(watch!.kind, ArtifactKind.nestedCodeBundle);
      expect(watch.origin, ArtifactOrigin.nestedBundle);
    });

    test('appex 根目录的 dylib → nestedBundle（不是主包的 bundleRoot）', () {
      final dylib = inventory
          .entryForPath('Payload/Demo.app/PlugIns/Widget.appex/libw.dylib');
      expect(dylib!.kind, ArtifactKind.dylib);
      expect(dylib.origin, ArtifactOrigin.nestedBundle);
    });

    test('appex 里的 framework → framework / nestedBundle', () {
      final bar = inventory.entryForPath(
        'Payload/Demo.app/PlugIns/Widget.appex/Frameworks/Bar.framework/Bar',
      );
      expect(bar!.kind, ArtifactKind.framework);
      expect(bar.origin, ArtifactOrigin.nestedBundle);
    });

    test('Frameworks/ 下的 .a → staticLibrary / frameworks', () {
      final lib =
          inventory.entryForPath('Payload/Demo.app/Frameworks/libfoo.a');
      expect(lib!.kind, ArtifactKind.staticLibrary);
      expect(lib.origin, ArtifactOrigin.frameworks);
    });
  });

  group('assets 细分', () {
    final inventory = IosArtifactInventoryScanner.scan([
      _file('Payload/Demo.app/assets/bundle.zip'),
      _file('Payload/Demo.app/assets/blob'),
      _file('Payload/Demo.app/assets/sub/util.lua'),
      _file('Payload/Demo.app/assets/payload.so'),
      _file('Payload/Demo.app/assets/Asset.car'),
    ]);

    test('归档 / 无扩展名 / 脚本 / ELF', () {
      expect(
        inventory.entryForPath('Payload/Demo.app/assets/bundle.zip')?.kind,
        ArtifactKind.assetArchive,
      );
      expect(
        inventory.entryForPath('Payload/Demo.app/assets/blob')?.kind,
        ArtifactKind.assetBinary,
      );
      expect(
        inventory.entryForPath('Payload/Demo.app/assets/sub/util.lua')?.kind,
        ArtifactKind.script,
      );
      expect(
        inventory.entryForPath('Payload/Demo.app/assets/payload.so')?.kind,
        ArtifactKind.elf,
      );
      expect(
        inventory.entryForPath('Payload/Demo.app/assets/Asset.car')?.kind,
        ArtifactKind.assetArchive,
      );
    });
  });

  group('预算截断', () {
    List<ContainerEntryFact> dylibs(int count) => [
          for (var i = 0; i < count; i++)
            _file('Payload/Demo.app/Frameworks/lib$i.dylib'),
        ];

    test('超过 maxEntries → entriesComplete=false + inventory.entries_truncated',
        () {
      final inventory =
          IosArtifactInventoryScanner.scan(dylibs(5), maxEntries: 2);
      expect(inventory.entries.length, 2);
      expect(inventory.inventoriedEntries, 2);
      expect(inventory.entriesComplete, isFalse);
      expect(
        inventory.skippedCodes,
        contains(IosArtifactInventoryScanner.truncatedCode),
      );
      // 分母仍是**全部**文件条目：截断不能把分母也缩小。
      expect(inventory.totalEntries, 5);
    });

    test('正好等于上限不算截断', () {
      final inventory =
          IosArtifactInventoryScanner.scan(dylibs(2), maxEntries: 2);
      expect(inventory.entries.length, 2);
      expect(inventory.entriesComplete, isTrue);
      expect(inventory.skippedCodes, isEmpty);
    });

    test('maxEntries=0 → 空清单但保留分母与截断标记', () {
      final inventory =
          IosArtifactInventoryScanner.scan(dylibs(3), maxEntries: 0);
      expect(inventory.entries, isEmpty);
      expect(inventory.totalEntries, 3);
      expect(inventory.entriesComplete, isFalse);
    });

    test('空输入：complete=true（空是事实，不是截断）', () {
      final inventory = IosArtifactInventoryScanner.scan(const []);
      expect(inventory.isEmpty, isTrue);
      expect(inventory.totalEntries, 0);
      expect(inventory.entriesComplete, isTrue);
    });
  });

  group('空路径与普通资源', () {
    test('空路径条目既不进清单也不进分母（没有可比较的键）', () {
      final inventory = IosArtifactInventoryScanner.scan([
        _file(''),
        _file('Payload/Demo.app/LaunchScreen.storyboardc/Info.plist'),
        _file('Payload/Demo.app/en.lproj/Localizable.strings'),
      ]);
      expect(inventory.totalEntries, 2);
      // `Info.plist` 在任何位置都是清单；本地化 strings 不是制品。
      expect(
        inventory.entryForPath('Payload/Demo.app/en.lproj/Localizable.strings'),
        isNull,
      );
      expect(inventory.entries.length, 1);
      expect(inventory.entriesComplete, isTrue);
    });
  });
}
