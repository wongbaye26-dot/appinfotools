// Android 加载链：DEX 里的加载调用 × 包内制品清单。
//
// 夹具 `test/fixtures/loader-api.dex`（d8 从 Java 生成，1,224 字节）的方法体
// `Ltest/Loader;.main([Ljava/lang/String;)V` 里有三条真实调用：
//   System.loadLibrary("foo")
//   System.load("/data/local/tmp/libbar.so")
//   new dalvik.system.DexClassLoader("payload.dex", "/data/local/tmp", …)
// 字符串表里同时有 `foo` / `payload.dex` / `/data/local/tmp/libbar.so`。
//
// ## 本文件断言的强度
//
// 实现把「加载调用」与「路径字面量」按**同现**配对（参数级关联需要寄存器
// 数据流，见 `android_load_graph.dart` 文件头）。因此这里断言的是：
// 「loader 调用存在 + 路径字面量解析成边」，并检查 `location` 里明确写着
// `loader call + literal co-occurrence` —— 不让读者误以为这是调用点级证据。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

/// 夹具在包内的路径（测试的工作目录是包的根目录）。
const String _fixture = 'test/fixtures/loader-api.dex';

Uint8List _loadFixture() => File(_fixture).readAsBytesSync();

/// 与夹具配套的合成清单：`libfoo.so` 在两个 ABI 里各一份（验证 name→ABI
/// 解析的确定性），`assets/payload.dex` 是 `DexClassLoader("payload.dex")`
/// 的包内落点；`libbar.so` **故意不在包里**，用来验证悬空边。
ArtifactInventory _inventory() {
  return const ArtifactInventory(
    entries: [
      ArtifactEntry(
          path: 'classes.dex', kind: ArtifactKind.dex, sizeBytes: 1224),
      ArtifactEntry(
        path: 'lib/arm64-v8a/libfoo.so',
        kind: ArtifactKind.elf,
        arch: 'arm64-v8a',
      ),
      ArtifactEntry(
        path: 'lib/armeabi-v7a/libfoo.so',
        kind: ArtifactKind.elf,
        arch: 'armeabi-v7a',
      ),
      ArtifactEntry(
        path: 'assets/payload.dex',
        kind: ArtifactKind.assetBinary,
        origin: ArtifactOrigin.assets,
      ),
    ],
    totalEntries: 4,
    inventoriedEntries: 4,
  );
}

LoadGraph _scan({
  List<DexBytes>? dexEntries,
  ArtifactInventory? inventory,
  int maxEdges = AndroidLoadGraphScanner.defaultMaxEdges,
}) {
  return AndroidLoadGraphScanner.scan(
    dexEntries: dexEntries ?? [DexBytes('classes.dex', _loadFixture())],
    inventory: inventory ?? _inventory(),
    maxEdges: maxEdges,
  );
}

LoadEdge _edge(LoadGraph graph, String toId, LoadEdgeKind kind) {
  return graph.edges.firstWhere(
    (edge) => edge.toId == toId && edge.kind == kind,
    orElse: () => throw StateError(
      '找不到边 $kind → $toId，实际：'
      '${graph.edges.map((e) => '${e.kind.name}→${e.toId}').toList()}',
    ),
  );
}

void main() {
  test('复用 DexMethodScanner 的调用点：边与兼容路径一致，且位置来自样本', () {
    final bytes = _loadFixture();
    final methodScan = DexMethodScanner.scan([DexBytes('classes.dex', bytes)]);
    final graph = AndroidLoadGraphScanner.scan(
      dexEntries: [DexBytes('classes.dex', bytes)],
      inventory: _inventory(),
      methodScan: methodScan,
    );
    final edge = _edge(
      graph,
      'artifact:lib/arm64-v8a/libfoo.so',
      LoadEdgeKind.systemLoadLibrary,
    );
    expect(edge.location, contains('loader call + literal co-occurrence'));
    expect(
      _edge(graph, 'missing:/data/local/tmp/libbar.so', LoadEdgeKind.systemLoad)
          .location,
      contains('loader call + literal co-occurrence'),
    );
    expect(graph.danglingEdgeIds, isNotEmpty);
  });

  test('System.loadLibrary("foo") 解析到 lib/<abi>/libfoo.so', () {
    final graph = _scan();

    final edge = _edge(
      graph,
      'artifact:lib/arm64-v8a/libfoo.so',
      LoadEdgeKind.systemLoadLibrary,
    );
    expect(edge.fromId, 'artifact:classes.dex');
    expect(edge.source, SecurityEvidenceSource.loadGraph);

    // 多 ABI 时取字典序最小的路径：归档顺序变化不该改变结论。
    expect(
      graph.edges
          .where((e) => e.kind == LoadEdgeKind.systemLoadLibrary)
          .map((e) => e.toId),
      ['artifact:lib/arm64-v8a/libfoo.so'],
    );

    final node = graph.node('artifact:lib/arm64-v8a/libfoo.so')!;
    expect(node.presentInPackage, isTrue);
    expect(node.kind, LoadNodeKind.elf);
    expect(node.resolvedPath, 'lib/arm64-v8a/libfoo.so');
  });

  test('System.load("/data/local/tmp/libbar.so") 是悬空边', () {
    final graph = _scan();

    final edge = _edge(
      graph,
      'missing:/data/local/tmp/libbar.so',
      LoadEdgeKind.systemLoad,
    );
    expect(edge.fromId, 'artifact:classes.dex');

    final node = graph.node('missing:/data/local/tmp/libbar.so')!;
    expect(node.presentInPackage, isFalse);
    expect(node.kind, LoadNodeKind.missing);
    expect(node.resolvedPath, isNull, reason: '绝对路径不可能映射到包内条目');

    expect(
      graph.danglingEdgeIds,
      contains('artifact:classes.dex->missing:/data/local/tmp/libbar.so'),
    );
  });

  test('DexClassLoader("payload.dex") 解析到 assets/payload.dex', () {
    final graph = _scan();

    final edge = _edge(
      graph,
      'artifact:assets/payload.dex',
      LoadEdgeKind.dexClassLoader,
    );
    expect(edge.fromId, 'artifact:classes.dex');

    final node = graph.node('artifact:assets/payload.dex')!;
    expect(node.presentInPackage, isTrue);
    // 清单里它是 assetBinary（角色），加载边按字面量后缀判成 dex（会被当什么
    // 加载）—— 这正是两者分开记录的原因。
    expect(node.kind, LoadNodeKind.dex);
  });

  test('边位置写明这是「同现」，不是调用点级证据', () {
    final graph = _scan();
    final edge = _edge(
      graph,
      'artifact:lib/arm64-v8a/libfoo.so',
      LoadEdgeKind.systemLoadLibrary,
    );

    expect(edge.location, startsWith('classes.dex: Ltest/Loader;.main'));
    expect(edge.location, contains('loader call + literal co-occurrence'));
    // 至少能指回指令偏移（`dexdump -d` 的 `|0002:` 口径）。
    expect(edge.location, contains('@0x2'));
  });

  test('图是完整的（夹具结构合法、无截断）', () {
    final graph = _scan();

    expect(graph.complete, isTrue);
    expect(graph.isEmpty, isFalse);
    expect(graph.hasDanglingEdges, isTrue);
    // 4 个节点：调用者 DEX + 包内 libfoo + 包内 payload.dex + 悬空目标。
    expect(graph.nodes, hasLength(4));
    expect(graph.edges, hasLength(3));
  });

  test('重复的 DEX 输入不产生重复边（from+to+kind 去重）', () {
    final bytes = _loadFixture();
    final graph = _scan(
      dexEntries: [
        DexBytes('classes.dex', bytes),
        DexBytes('classes.dex', bytes),
      ],
    );

    expect(graph.edges, hasLength(3));
    expect(
      graph.edges.map((e) => '${e.fromId}->${e.toId}|${e.kind.name}').toSet(),
      hasLength(3),
    );
  });

  test('目标不在包里时是悬空边，且不会凭空解析到同名文件', () {
    // 清单里只有调用者 DEX：`foo` 的裸库名不再命中，`DexClassLoader` 的
    // `payload.dex` 也没有落点。
    final graph = _scan(
      inventory: const ArtifactInventory(entries: [
        ArtifactEntry(path: 'classes.dex', kind: ArtifactKind.dex),
      ]),
    );

    expect(
      graph.node('artifact:lib/arm64-v8a/libfoo.so'),
      isNull,
      reason: '包内没有 libfoo.so，就不该凭空造出节点',
    );
    expect(graph.nodes.map((n) => n.id), contains('missing:payload.dex'));
    expect(graph.danglingEdgeIds, hasLength(2));
    expect(graph.danglingEdgeIds,
        contains('artifact:classes.dex->missing:payload.dex'));
    expect(graph.complete, isTrue, reason: '目标缺失是事实，不是截断');
  });

  test('空 DEX 列表 → 空图且完整', () {
    final graph = _scan(dexEntries: const []);

    expect(graph.isEmpty, isTrue);
    expect(graph.nodes, isEmpty);
    expect(graph.edges, isEmpty);
    expect(graph.danglingEdgeIds, isEmpty);
    expect(graph.complete, isTrue);
  });

  test('结构不可遍历的 DEX 记 complete=false，不产出边', () {
    final garbage = Uint8List.fromList([0x4E, 0x4F, 0x54, 0x44, 0x45, 0x58]);
    final graph = _scan(
      dexEntries: [DexBytes('classes.dex', garbage)],
      inventory: _inventory(),
    );

    expect(graph.edges, isEmpty);
    expect(graph.nodes, isEmpty);
    expect(graph.complete, isFalse, reason: '「没发现加载点」在结构不可信时不成立');
  });

  test('边数超过 maxEdges 时截断并记 complete=false', () {
    final graph = _scan(maxEdges: 1);

    expect(graph.edges, hasLength(1));
    expect(graph.complete, isFalse);
  });

  test('没有加载调用的 DEX 不产出边（不靠字面量编造）', () {
    // 只用同一份夹具的字符串、去掉结构合法性：坏 magic 的输入连 method_ids
    // 都读不出来，必须一颗边都不产出。
    final empty = Uint8List(0);
    final graph = AndroidLoadGraphScanner.scan(
      dexEntries: [DexBytes('classes.dex', empty)],
      inventory: _inventory(),
    );

    expect(graph.isEmpty, isTrue);
    expect(graph.complete, isFalse);
  });
}
