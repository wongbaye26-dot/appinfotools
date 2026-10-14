// `resources.arsc` 的资源引用环检测。
//
// 图结构类（无环 / 两节点环 / 自引用 / 菱形 / 超限 / 长链）用**手工构造**的
// 邻接表：要精确控制形态，真实产物做不到。
//
// 但**负例与端到端都用真实 aapt2 产物**：只有真实表才能证明检测器不会在正常
// 表上误报 —— 误报比漏报更糟，用户被误报几次就不再信任整个检测。
//
// 顺带纠正一个我原先写错的判断：我以为 `aapt2` 不会产出引用环，实测它会。
// 夹具 `cyclic-color-alias.apk` 就是 `aapt2 link` 的产物。

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// 造一个资源条目；[references] 是它指向的资源 ID。
ResourceInfo _res(int id, {List<int> references = const []}) => ResourceInfo(
      resourceId: id,
      typeName: 'color',
      keyName: 'c${id.toRadixString(16)}',
      references: references,
    );

/// 造一张资源表：`id -> 它引用的 id 列表`。
Map<int, ResourceInfo> _table(Map<int, List<int>> edges) => {
      for (final e in edges.entries) e.key: _res(e.key, references: e.value),
    };

void main() {
  group('资源引用环检测（纯函数）', () {
    test('无环时报告为空', () {
      // A → B → C，C 是叶子。
      final report = ResourceReferenceGraph.findCycles(_table({
        0x7f010001: [0x7f010002],
        0x7f010002: [0x7f010003],
        0x7f010003: [],
      }));

      expect(report.isEmpty, isTrue);
      expect(report.truncated, isFalse);
    });

    test('两节点环 A → B → A 被找出', () {
      final report = ResourceReferenceGraph.findCycles(_table({
        0x7f010001: [0x7f010002],
        0x7f010002: [0x7f010001],
      }));

      expect(report.cycles, hasLength(1));
      expect(
        report.cycles.single.description,
        '0x7f010001 → 0x7f010002 → 0x7f010001',
        reason: '描述要能看出「回到起点」，否则读者不知道它是个环',
      );
    });

    test('自引用 A → A 被找出', () {
      final report = ResourceReferenceGraph.findCycles(_table({
        0x7f010001: [0x7f010001],
      }));

      expect(report.cycles, hasLength(1));
      expect(report.cycles.single.description, '0x7f010001 → 0x7f010001');
    });

    test('三节点环被找出，且不重复报同一条', () {
      final report = ResourceReferenceGraph.findCycles(_table({
        0x7f010001: [0x7f010002],
        0x7f010002: [0x7f010003],
        0x7f010003: [0x7f010001],
      }));

      expect(report.cycles, hasLength(1));
      expect(report.cycles.single.ids, hasLength(3));
    });

    test('指向表外资源的引用是叶子，不算环', () {
      // 0x0106000c 是 android:color/black —— 本表里没有这个节点。
      final report = ResourceReferenceGraph.findCycles(_table({
        0x7f010001: [0x0106000c],
        0x7f010002: [0x0106000c, 0x7f010001],
      }));

      expect(
        report.isEmpty,
        isTrue,
        reason: '把框架引用当环会误报掉几乎所有真实应用',
      );
    });

    test('菱形（同一节点被两条路径指向）不是环', () {
      // A → B, A → C, B → D, C → D —— D 被两条路径指向，但图是无环的。
      final report = ResourceReferenceGraph.findCycles(_table({
        0x7f010001: [0x7f010002, 0x7f010003],
        0x7f010002: [0x7f010004],
        0x7f010003: [0x7f010004],
        0x7f010004: [],
      }));

      expect(report.isEmpty, isTrue, reason: '共享下游不是环');
    });

    test('超过上限时标记 truncated，不假装找完了', () {
      // 造 8 个互不相干的二元环，上限是 5。
      final edges = <int, List<int>>{};
      for (var i = 0; i < 8; i++) {
        final a = 0x7f010000 + i * 2;
        edges[a] = [a + 1];
        edges[a + 1] = [a];
      }

      final report = ResourceReferenceGraph.findCycles(_table(edges));

      expect(report.cycles, hasLength(ResourceReferenceGraph.maxCycles));
      expect(
        report.truncated,
        isTrue,
        reason: '「找到 5 个」不能被当成「一共就 5 个」',
      );
    });

    test('长链不爆栈（用显式栈而不是递归）', () {
      // 一条 5 万节点的链。递归实现在这个规模上会栈溢出 —— 那是崩溃，
      // 不是「拒绝解析」。
      const n = 50000;
      final edges = <int, List<int>>{};
      for (var i = 0; i < n; i++) {
        edges[0x10000000 + i] = i == n - 1 ? [] : [0x10000000 + i + 1];
      }

      final report = ResourceReferenceGraph.findCycles(_table(edges));

      expect(report.isEmpty, isTrue);
      expect(report.examinedNodeCount, n - 1, reason: '最后一个节点没有出边');
    });

    test('环在长链的末端也能找到', () {
      const n = 2000;
      final edges = <int, List<int>>{};
      for (var i = 0; i < n; i++) {
        edges[0x20000000 + i] = i == n - 1
            ? [0x20000000] // 回到链首
            : [0x20000000 + i + 1];
      }

      final report = ResourceReferenceGraph.findCycles(_table(edges));

      expect(report.cycles, hasLength(1));
      expect(report.cycles.single.ids, hasLength(n));
    });
  });

  group('真实 aapt2 产物上不误报', () {
    test('正常 APK 的资源表里没有环', () async {
      for (final name in const [
        'night-mode-resources.apk',
        'no-night-mode-resources.apk',
      ]) {
        final reader = ApkReader();
        try {
          final open = await reader.open(path.join('test/fixtures/apk', name));
          expect(open.isOk, isTrue, reason: name);
          expect(await reader.parse(), isNotNull, reason: name);

          final report = reader.arscParser!.findReferenceCycles();
          expect(
            report.isEmpty,
            isTrue,
            reason: '$name 是 aapt2 产出的正常表，报出环就是误报：'
                '${report.cycles.map((c) => c.description).join('; ')}',
          );
        } finally {
          reader.close();
        }
      }
    });

    test('从真实表里确实读到了引用边（否则上一条是空断言）', () async {
      final reader = ApkReader();
      try {
        final open = await reader
            .open(path.join('test/fixtures/apk', 'night-mode-resources.apk'));
        expect(open.isOk, isTrue);
        await reader.parse();

        final report = reader.arscParser!.findReferenceCycles();
        // 夹具里有 `color/bg_alias → @color/bg`（普通引用值）。这条断言是上一条
        // 负例的前提 —— `examinedNodeCount == 0` 时「没找到环」什么都证明不了。
        expect(
          report.examinedNodeCount,
          greaterThan(0),
          reason: '夹具资源表里应当有 bg_alias → bg 这条表内引用',
        );
      } finally {
        reader.close();
      }
    });
  });

  // 这一组用的也是**真实 aapt2 产物** —— 原先我以为 aapt2 不会产出引用环，
  // 实测发现它会：`aapt2 link` 对 `color/a → @color/b`、`color/b → @color/a`
  // 照单全收，并原样写进资源表。因此「有环」不能当作篡改的证据。
  group('真实 aapt2 产物里的环（端到端）', () {
    Future<ReferenceCycleReport> scan(String name) async {
      final reader = ApkReader();
      try {
        final open = await reader.open(path.join('test/fixtures/apk', name));
        expect(open.isOk, isTrue, reason: name);
        expect(await reader.parse(), isNotNull, reason: name);
        return reader.arscParser!.findReferenceCycles();
      } finally {
        reader.close();
      }
    }

    test('aapt2 产出的环状颜色别名被检出', () async {
      final report = await scan('cyclic-color-alias.apk');

      expect(
        report.cycles,
        hasLength(1),
        reason: 'aapt2 dump resources 对这个包输出 color/a → @color/b、'
            'color/b → @color/a',
      );
      final ids = report.cycles.single.ids.toSet();
      expect(ids, hasLength(2));
      // 环上应当是 color/a 与 color/b 这两个条目（0x7f010000 / 0x7f010001）。
      expect(ids, containsAll(<int>[0x7f010000, 0x7f010001]));
      expect(report.truncated, isFalse);
    });

    test('环外的引用（icon_fill → a）不算进环里', () async {
      final report = await scan('cyclic-color-icon.apk');

      expect(report.cycles, hasLength(1));
      // icon_fill 只是**指向**环，自己不在环上 —— 把它算进去会让描述多出一段
      // 误导性的箭头。
      expect(
        report.cycles.single.ids,
        isNot(contains(0x7f010002)),
        reason: 'color/icon_fill 指向环，但它不在环上',
      );
    });
  });

  // 这一组走完整的 `getApkInfo`：解析 → 收图标候选 → 渲染。
  //
  // 要钉住的是规范里那条「**禁止**遇到资源损坏时直接回退到一个无法解释的
  // 默认图标而不记录诊断」：图标画不出来可以接受，**画不出来还说不出原因**
  // 不可以。
  group('图标渲染遇到环时必须留下说明', () {
    test('引用成环时记下可解释的说明，而不是静默回退', () async {
      final info = await getApkInfo(
        path.join('test/fixtures/apk', 'cyclic-color-icon.apk'),
      );

      expect(info, isNotNull);
      expect(
        info!.iconResolutionNotes,
        isNotEmpty,
        reason: '夹具的图标填充色指向一个环；渲染失败必须留下原因，'
            '否则界面上只是一个空白，用户分不清「没有图标」与「没画出来」',
      );
      expect(
        info.iconResolutionNotes.any((n) => n.contains('cycle')),
        isTrue,
        reason: '说明里要指出是「成环」，而不只是「解析失败」：'
            '实际记下的是 ${info.iconResolutionNotes}',
      );
    });

    test('说明会进「解析诊断」，不只在日志里', () async {
      final info = await getApkInfo(
        path.join('test/fixtures/apk', 'cyclic-color-icon.apk'),
      );

      final codes = info!.diagnostics.map((d) => d.code).toList();
      expect(codes, contains('android.icon_resolution'));
      expect(
        codes,
        contains('android.resource_reference_cycle'),
        reason: '资源表层面的环检测结论也要能看到',
      );
    });
  });
}
