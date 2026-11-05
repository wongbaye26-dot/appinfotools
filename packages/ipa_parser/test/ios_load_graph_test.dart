// iOS 加载链（`IosLoadGraphScanner`）。
//
// ## 真实夹具 + 合成命令
//
// Mach-O 解析用仓库根目录 `test/fixtures/macho/` 的真实 dylib（clang 编译，
// 期望值可用 `otool -L` 独立核对）；`@rpath` / `@executable_path` 这些
// **本机夹具里没有的 load command** 用 `MachOImage` 合成 —— 手工拼字节比
// 直接构造模型更容易把「解析器读到了什么」和「对账逻辑怎么判」混在一起。
//
// ## 钉住的口径
//
// * 系统库（`/usr/lib`、`/System/Library`）不建包内边、不建节点；
// * 越狱/注入位置（MobileSubstrate / frida / `/var/jb`）→ missing + dangling；
// * `@rpath` 命中时把「依据」（哪条 LC_RPATH）写进边的 location；
// * 重复边去重；边超限/解析失败/清单截断 → complete=false。
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

const String _fixtures = '../../test/fixtures/macho';

MachOFile _parse(String name) =>
    MachOParser.parse(File('$_fixtures/$name').readAsBytesSync());

MachOImage _image({
  int cpuType = 0x0100000C,
  List<String> libs = const [],
  List<String> rpaths = const [],
}) =>
    MachOImage(
      offset: 0,
      size: 4096,
      byteOrder: MachOByteOrder.little,
      is64Bit: true,
      cpuType: cpuType,
      cpuSubtype: 0,
      fileType: MachOFileType.execute,
      linkedLibraries: libs,
      rpaths: rpaths,
    );

IosMachOInput _input(
  String path, {
  List<String> libs = const [],
  List<String> rpaths = const [],
}) =>
    IosMachOInput(
      path: path,
      macho: MachOFile(images: [_image(libs: libs, rpaths: rpaths)]),
    );

IosMachOInput _fatInput(String path, {required List<String> libs}) =>
    IosMachOInput(
      path: path,
      macho: MachOFile(images: [
        _image(cpuType: 0x0100000C, libs: libs),
        _image(cpuType: 0x01000007, libs: libs),
      ]),
    );

ArtifactInventory _inventory(
  List<ArtifactEntry> entries, {
  bool complete = true,
}) =>
    ArtifactInventory(
      entries: entries,
      totalEntries: entries.length,
      inventoriedEntries: entries.length,
      entriesComplete: complete,
      skippedCodes: complete
          ? const []
          : const [IosArtifactInventoryScanner.truncatedCode],
    );

ArtifactEntry _macho(String path) =>
    ArtifactEntry(path: path, kind: ArtifactKind.machO, sizeBytes: 4096);

ArtifactEntry _dylib(String path,
        {ArtifactOrigin origin = ArtifactOrigin.frameworks}) =>
    ArtifactEntry(
      path: path,
      kind: ArtifactKind.dylib,
      origin: origin,
      sizeBytes: 4096,
    );

ArtifactEntry _framework(String path) => ArtifactEntry(
      path: path,
      kind: ArtifactKind.framework,
      origin: ArtifactOrigin.frameworks,
      sizeBytes: 4096,
    );

void main() {
  group('真实夹具：系统库不产生包内边', () {
    test('thin dylib 只链接 libSystem → 零边，节点只有自己', () {
      final macho = _parse('thin-arm64.dylib');
      expect(macho.isMachO, isTrue);
      // LC_ID_DYLIB 是「我叫什么」，不是加载边（installName 不参与对账）。
      expect(macho.primary!.installName, 'libthin.dylib');
      expect(macho.primary!.linkedLibraries, ['/usr/lib/libSystem.B.dylib']);

      const path = 'Payload/Demo.app/Frameworks/libthin.dylib';
      final graph = IosLoadGraphScanner.scan(
        binaries: [IosMachOInput(path: path, macho: macho)],
        inventory: _inventory([_dylib(path)]),
      );

      expect(graph.edges, isEmpty);
      expect(graph.danglingEdgeIds, isEmpty);
      expect(graph.complete, isTrue);
      expect(graph.nodes.length, 1);
      expect(graph.node('artifact:$path')!.kind, LoadNodeKind.dylib);
    });

    test('fat 里两个切片链接同一个系统库 → 仍然零边', () {
      final macho = _parse('fat-x86_64-arm64.dylib');
      expect(macho.images.length, 2);
      expect(macho.allLinkedLibraries, ['/usr/lib/libSystem.B.dylib']);

      const path = 'Payload/Demo.app/Frameworks/libfat.dylib';
      final graph = IosLoadGraphScanner.scan(
        binaries: [IosMachOInput(path: path, macho: macho)],
        inventory: _inventory([_dylib(path)]),
      );
      expect(graph.edges, isEmpty);
      expect(graph.complete, isTrue);
    });

    test('libnative-fixture-fat 同样只有系统库', () {
      final macho = _parse('libnative-fixture-fat.dylib');
      const path = 'Payload/Demo.app/Frameworks/libnative.dylib';
      final graph = IosLoadGraphScanner.scan(
        binaries: [IosMachOInput(path: path, macho: macho)],
        inventory: _inventory([_dylib(path)]),
      );
      expect(graph.edges, isEmpty);
      expect(graph.complete, isTrue);
    });
  });

  group('@rpath', () {
    const mainPath = 'Payload/Demo.app/Demo';
    const fooPath = 'Payload/Demo.app/Frameworks/Foo.framework/Foo';
    final inventory = _inventory([_macho(mainPath), _framework(fooPath)]);

    test('按 LC_RPATH 展开命中，并把依据写进 location', () {
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(
            mainPath,
            libs: ['@rpath/Foo.framework/Foo', '/usr/lib/libSystem.B.dylib'],
            rpaths: ['@executable_path/Frameworks'],
          ),
        ],
        inventory: inventory,
      );

      expect(graph.edges.length, 1);
      final edge = graph.edges.single;
      expect(edge.kind, LoadEdgeKind.machoLinkedLibrary);
      expect(edge.fromId, 'artifact:$mainPath');
      expect(edge.toId, 'artifact:$fooPath');
      expect(edge.location, contains('rpath @executable_path/Frameworks'));
      expect(edge.source, SecurityEvidenceSource.loadGraph);
      expect(graph.danglingEdgeIds, isEmpty);
      expect(graph.complete, isTrue);
      expect(graph.node('artifact:$fooPath')!.kind, LoadNodeKind.framework);
      // 系统库既不建边也不建节点。
      expect(graph.nodes.any((n) => n.id.contains('libSystem')), isFalse);
    });

    test('没有 LC_RPATH 时退化为后缀匹配，并在 location 里注明', () {
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(mainPath, libs: ['@rpath/Foo.framework/Foo']),
        ],
        inventory: inventory,
      );
      expect(graph.edges.single.toId, 'artifact:$fooPath');
      expect(graph.edges.single.location, contains('suffix match'));
    });

    test('候选重名时优先 Frameworks/ 下的那个', () {
      const rootCopy = 'Payload/Demo.app/Foo.framework/Foo';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(mainPath, libs: ['@rpath/Foo.framework/Foo']),
        ],
        inventory: _inventory([
          _macho(mainPath),
          _framework(rootCopy),
          _framework(fooPath),
        ]),
      );
      expect(graph.edges.single.toId, 'artifact:$fooPath');
    });

    test('rpath 命中优先于同名的另一个 Frameworks/ 副本', () {
      const appexCopy =
          'Payload/Demo.app/PlugIns/W.appex/Frameworks/Foo.framework/Foo';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(
            mainPath,
            libs: ['@rpath/Foo.framework/Foo'],
            rpaths: ['@executable_path/Frameworks'],
          ),
        ],
        inventory: _inventory([
          _macho(mainPath),
          _framework(fooPath),
          _framework(appexCopy),
        ]),
      );
      expect(graph.edges.single.toId, 'artifact:$fooPath');
      expect(
          graph.edges.single.location, contains('@executable_path/Frameworks'));
    });

    test('包内没有对应条目 → missing 节点 + dangling', () {
      const library = '@rpath/Nope.framework/Nope';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(mainPath, libs: [library])
        ],
        inventory: inventory,
      );
      expect(graph.node('missing:$library')!.kind, LoadNodeKind.missing);
      expect(graph.node('missing:$library')!.presentInPackage, isFalse);
      expect(
        graph.danglingEdgeIds,
        ['artifact:$mainPath->missing:$library'],
      );
      // 悬空是**发现**，不是遍历不完整。
      expect(graph.complete, isTrue);
    });
  });

  group('@executable_path / @loader_path', () {
    const mainPath = 'Payload/Demo.app/Demo';

    test('@executable_path 相对主 bundle 解析命中', () {
      const dylibPath = 'Payload/Demo.app/Frameworks/libx.dylib';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(
            mainPath,
            libs: ['@executable_path/Frameworks/libx.dylib'],
          ),
        ],
        inventory: _inventory([_macho(mainPath), _dylib(dylibPath)]),
      );
      expect(graph.edges.single.toId, 'artifact:$dylibPath');
      expect(graph.danglingEdgeIds, isEmpty);
    });

    test('@executable_path 解析到包内不存在的路径 → dangling + 说明', () {
      const library = '@executable_path/Frameworks/nope.dylib';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(mainPath, libs: [library])
        ],
        inventory: _inventory([_macho(mainPath)]),
      );
      expect(
        graph.danglingEdgeIds,
        ['artifact:$mainPath->missing:$library'],
      );
      expect(graph.edges.single.location, contains('not in inventory'));
      expect(graph.complete, isTrue);
    });

    test('显式 mainBundlePath 覆盖推断值', () {
      const dylibPath = 'Payload/Demo.app/Frameworks/libx.dylib';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(
            'Payload/Other.app/Other',
            libs: ['@executable_path/Frameworks/libx.dylib'],
          ),
        ],
        inventory: _inventory([_dylib(dylibPath)]),
        mainBundlePath: 'Payload/Demo.app',
      );
      expect(graph.edges.single.toId, 'artifact:$dylibPath');
    });

    test('主 bundle 未知时不能假装「包里没有」：missing + complete=false', () {
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input('libfoo.dylib', libs: ['@executable_path/x.dylib']),
        ],
        inventory: _inventory(const []),
      );
      expect(graph.danglingEdgeIds, hasLength(1));
      expect(graph.complete, isFalse);
      expect(graph.edges.single.location, contains('no main bundle'));
    });

    test('@loader_path 相对当前二进制所在目录（含 .. 归一化）', () {
      const binary = 'Payload/Demo.app/Frameworks/A.framework/A';
      const target = 'Payload/Demo.app/Frameworks/B.framework/B';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(binary, libs: ['@loader_path/../B.framework/B']),
        ],
        inventory: _inventory([_framework(binary), _framework(target)]),
      );
      expect(graph.edges.single.toId, 'artifact:$target');
      expect(graph.danglingEdgeIds, isEmpty);
    });
  });

  group('越狱位置、系统库与其它绝对路径', () {
    const mainPath = 'Payload/Demo.app/Demo';
    final graph = IosLoadGraphScanner.scan(
      binaries: [
        _input(
          mainPath,
          libs: [
            '/Library/MobileSubstrate/MobileSubstrate.dylib',
            '/usr/lib/frida/frida-agent.dylib',
            '/usr/lib/libSystem.B.dylib',
            '/System/Library/Frameworks/UIKit.framework/UIKit',
            '/opt/evil/libx.dylib',
            'librelative.dylib',
          ],
        ),
      ],
      inventory: _inventory([_macho(mainPath)]),
    );

    test('MobileSubstrate / frida 记 dangling（即使前缀像 /usr/lib）', () {
      expect(
        graph.node('missing:/Library/MobileSubstrate/MobileSubstrate.dylib'),
        isNotNull,
      );
      expect(
        graph.node('missing:/usr/lib/frida/frida-agent.dylib')!.kind,
        LoadNodeKind.missing,
      );
      expect(graph.danglingEdgeIds, hasLength(4));
      expect(graph.complete, isTrue);
    });

    test('系统库不建边也不建节点，因此不算 dangling', () {
      expect(graph.nodes.any((n) => n.id.contains('libSystem')), isFalse);
      expect(graph.nodes.any((n) => n.id.contains('UIKit')), isFalse);
      expect(
        graph.edges.any((e) => e.toId.contains('libSystem')),
        isFalse,
      );
    });

    test('其它绝对路径与相对安装名 → missing', () {
      expect(graph.node('missing:/opt/evil/libx.dylib'), isNotNull);
      expect(graph.node('missing:librelative.dylib'), isNotNull);
    });

    test('包外绝对 LC_RPATH 也记 dangling（搜索路径在包内不存在）', () {
      final rpathGraph = IosLoadGraphScanner.scan(
        binaries: [
          _input(
            mainPath,
            rpaths: [
              '/Library/MobileSubstrate/DynamicLibraries',
              '@executable_path/Frameworks',
            ],
          ),
        ],
        inventory: _inventory([_macho(mainPath)]),
      );
      expect(rpathGraph.edges, hasLength(1));
      expect(rpathGraph.edges.single.kind, LoadEdgeKind.machoRPath);
      expect(
        rpathGraph.node('rpath:/Library/MobileSubstrate/DynamicLibraries'),
        isNotNull,
      );
      expect(
        rpathGraph.danglingEdgeIds,
        ['artifact:$mainPath->rpath:/Library/MobileSubstrate/DynamicLibraries'],
      );
    });
  });

  group('去重', () {
    test('同一镜像重复声明同一个库 → 一条边', () {
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input('Payload/Demo.app/Demo',
              libs: ['/opt/x.dylib', '/opt/x.dylib']),
        ],
        inventory: _inventory([_macho('Payload/Demo.app/Demo')]),
      );
      expect(graph.edges, hasLength(1));
    });

    test('fat 的两个切片声明同一个库 → 一条边', () {
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _fatInput('Payload/Demo.app/Demo', libs: ['/opt/x.dylib']),
        ],
        inventory: _inventory([_macho('Payload/Demo.app/Demo')]),
      );
      expect(graph.edges, hasLength(1));
    });

    test('同一个二进制传两次 → 边与节点都去重', () {
      final binary = _input(
        'Payload/Demo.app/Demo',
        libs: ['/opt/x.dylib'],
      );
      final graph = IosLoadGraphScanner.scan(
        binaries: [binary, binary],
        inventory: _inventory([_macho('Payload/Demo.app/Demo')]),
      );
      expect(graph.edges, hasLength(1));
      expect(graph.nodes, hasLength(2)); // 自己 + missing
    });
  });

  group('完整性', () {
    test('空输入 → 空图且 complete=true', () {
      final graph = IosLoadGraphScanner.scan(
        binaries: const [],
        inventory: _inventory(const []),
      );
      expect(graph.isEmpty, isTrue);
      expect(graph.complete, isTrue);
    });

    test('Mach-O 解析失败（没有镜像）→ complete=false', () {
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          const IosMachOInput(
            path: 'Payload/Demo.app/Broken',
            macho: MachOFile(),
          ),
        ],
        inventory: _inventory([_macho('Payload/Demo.app/Broken')]),
      );
      expect(graph.node('artifact:Payload/Demo.app/Broken'), isNotNull);
      expect(graph.complete, isFalse);
    });

    test('边数达到 maxEdges → 截断且 complete=false', () {
      const demo = 'Payload/Demo.app/Demo';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(
            demo,
            libs: ['@executable_path/A.dylib', '@executable_path/B.dylib'],
          ),
        ],
        inventory: _inventory([
          _macho(demo),
          _dylib('Payload/Demo.app/A.dylib'),
          _dylib('Payload/Demo.app/B.dylib'),
        ]),
        maxEdges: 1,
      );
      expect(graph.edges, hasLength(1));
      expect(graph.complete, isFalse);
    });

    test('maxEdges=0 → 一条边都不建', () {
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input('Payload/Demo.app/Demo', libs: ['/opt/x.dylib'])
        ],
        inventory: _inventory([_macho('Payload/Demo.app/Demo')]),
        maxEdges: 0,
      );
      expect(graph.edges, isEmpty);
      expect(graph.complete, isFalse);
    });

    test('清单被截断 → complete=false（找不到可能只是没列进清单）', () {
      const demo = 'Payload/Demo.app/Demo';
      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(demo, libs: ['@executable_path/A.dylib'])
        ],
        inventory: _inventory([
          _macho(demo),
          _dylib('Payload/Demo.app/A.dylib'),
        ], complete: false),
      );
      expect(graph.edges, hasLength(1));
      expect(graph.danglingEdgeIds, isEmpty);
      // 边都对上了，但清单本身不完整 → 覆盖不完整，不能声称「全查过」。
      expect(graph.complete, isFalse);
    });
  });

  group('端到端：清单 × 加载链', () {
    test('清单分类出的 framework / dylib 被 @rpath 正确对账', () {
      const demo = 'Payload/Demo.app/Demo';
      const foo = 'Payload/Demo.app/Frameworks/Foo.framework/Foo';
      const bar = 'Payload/Demo.app/Frameworks/libbar.dylib';
      final realInventory = IosArtifactInventoryScanner.scan(const [
        ContainerEntryFact(
          path: 'Payload/Demo.app/_CodeSignature/CodeResources',
          sizeBytes: 10,
        ),
        ContainerEntryFact(path: 'Payload/Demo.app/Demo', sizeBytes: 10),
        ContainerEntryFact(
          path: 'Payload/Demo.app/Frameworks/Foo.framework/Foo',
          sizeBytes: 10,
        ),
        ContainerEntryFact(
          path: 'Payload/Demo.app/Frameworks/libbar.dylib',
          sizeBytes: 10,
        ),
      ]);
      expect(realInventory.entriesComplete, isTrue);

      final graph = IosLoadGraphScanner.scan(
        binaries: [
          _input(demo,
              libs: ['@rpath/Foo.framework/Foo', '@rpath/libbar.dylib']),
        ],
        inventory: realInventory,
      );

      expect(graph.edges, hasLength(2));
      expect(graph.danglingEdgeIds, isEmpty);
      expect(graph.complete, isTrue);
      expect(graph.node('artifact:$foo')!.kind, LoadNodeKind.framework);
      expect(graph.node('artifact:$bar')!.kind, LoadNodeKind.dylib);
      expect(graph.node('artifact:$demo')!.kind, LoadNodeKind.machO);
    });
  });
}
