import '../models.dart';

/// 资源引用图里的一个环。
///
/// [ids] 按遍历顺序列出环上的资源 ID，**首尾不重复** —— 环的信息在
/// `description` 里用箭头补回起点，因为「A → B → A」比「[A, B]」更像一个环。
class ReferenceCycle {
  final List<int> ids;

  const ReferenceCycle(this.ids);

  /// 可读的环描述，例如 `0x7f010001 → 0x7f010002 → 0x7f010001`。
  String get description {
    if (ids.isEmpty) return '';
    final parts = ids.map(_hex).join(' → ');
    return '$parts → ${_hex(ids.first)}';
  }

  static String _hex(int id) => '0x${id.toRadixString(16).padLeft(8, '0')}';

  @override
  String toString() => 'ReferenceCycle($description)';
}

/// 资源引用环的检测结果。
///
/// **「发现了几个环」与「这次查了多少」必须分开**：环的数量被上限截断时，
/// [truncated] 为 `true`。否则读者会把「找到 5 个」当成「一共就 5 个」。
class ReferenceCycleReport {
  /// 找到的环（可能被 [ResourceReferenceGraph.maxCycles] 截断）。
  final List<ReferenceCycle> cycles;

  /// 是否因为上限而没找完。
  final bool truncated;

  /// 实际检查过的条目数（有出边的节点数）。
  final int examinedNodeCount;

  const ReferenceCycleReport({
    this.cycles = const [],
    this.truncated = false,
    this.examinedNodeCount = 0,
  });

  bool get isEmpty => cycles.isEmpty;

  @override
  String toString() =>
      'ReferenceCycleReport(${cycles.length} cycles, truncated: $truncated)';
}

/// 在资源引用图里查找环。
///
/// **环意味着什么**：环上那几个资源互相定义、谁也没有真正的值，因此涉及它们的
/// 取值在运行时会失败（Android 框架自己解析引用时也有深度上限）。这是一条
/// 实打实的**缺陷**信号。
///
/// **但环不等于篡改** —— 这一点是实测出来的，不是推断：`aapt2 link` 会**接受**
/// 环状的颜色别名并原样写进资源表。夹具 `cyclic-color-alias.apk` 就是 `aapt2`
/// 产出的，`aapt2 dump resources` 对它输出 `color/a → @color/b`、
/// `color/b → @color/a`。所以发现环时只能说「这些资源解析不了」，**不能说**
/// 「这个包被人动过手脚」。
///
/// 这与图标渲染器的深度上限（`_kMaxDepth`）是两件事：那个上限只是防无限递归，
/// 对所有深度超限一视同仁、也**不留说明**；这里把环本身找出来并描述清楚，
/// 让「图标为什么画不出来」有据可查。
///
/// 算法是显式栈的深度优先遍历（白/灰/黑三色标记）。**不用递归**：资源表可以
/// 有几十万个条目，递归会爆栈；而爆栈是崩溃，不是「拒绝解析」。
///
/// **覆盖局限**：输入是 `ArscParser.getAllResources()` 的结果，而它只收集
/// **普通值**里的引用（`Res_value.TYPE_REFERENCE`），**不收集 style / array
/// 这类「袋」（`ResourceEntry.mapValues`）内部的引用**。因此经由 style 间接
/// 形成的环查不到。补上它需要改 `getAllResources` 的输出，而那会同时改变
/// 图标渲染器的取数，属于另一件事。
class ResourceReferenceGraph {
  ResourceReferenceGraph._();

  /// 最多报告几个环。
  ///
  /// 取 5 是因为它只用于诊断说明 —— 用户需要知道「有问题」以及一两个可核对的
  /// 例子，不需要一份完整的环清单。超过上限时 [ReferenceCycleReport.truncated]
  /// 会置位。
  static const int maxCycles = 5;

  static const int _white = 0;
  static const int _gray = 1;
  static const int _black = 2;

  /// 找出 [resources] 里的引用环。
  ///
  /// 只沿着**表内存在**的引用走：指向框架资源（`android:color/white` 之类）
  /// 的 ID 在本表里没有节点，是叶子，不可能构成环。
  static ReferenceCycleReport findCycles(
    Map<int, ResourceInfo> resources, {
    int maxCycles = maxCycles,
  }) {
    // 邻接表。自引用（A → A）本身就是长度 1 的环，因此不排除自己。
    final edges = <int, List<int>>{};
    for (final entry in resources.entries) {
      final targets = <int>[
        for (final ref in entry.value.references)
          if (ref != 0 && resources.containsKey(ref)) ref,
      ];
      if (targets.isNotEmpty) edges[entry.key] = targets;
    }
    if (edges.isEmpty) {
      return const ReferenceCycleReport();
    }

    final color = <int, int>{};
    final path = <int>[];
    final cycles = <ReferenceCycle>[];

    for (final root in edges.keys) {
      if ((color[root] ?? _white) != _white) continue;

      color[root] = _gray;
      path.add(root);
      // 显式栈：每个元素是「节点」+「下一个待访问的邻居下标」。
      final work = <(int, int)>[(root, 0)];

      while (work.isNotEmpty) {
        final (node, index) = work.removeLast();
        final children = edges[node] ?? const <int>[];

        if (index < children.length) {
          // 先把自己放回去，下标 +1，等这个孩子处理完再继续。
          work.add((node, index + 1));
          final child = children[index];
          final childColor = color[child] ?? _white;

          if (childColor == _gray) {
            // 孩子还在当前路径上 → 从孩子在 path 里的位置到末尾就是一个环。
            final start = path.indexOf(child);
            if (start >= 0) {
              cycles.add(ReferenceCycle(path.sublist(start)));
              if (cycles.length >= maxCycles) {
                return ReferenceCycleReport(
                  cycles: cycles,
                  truncated: true,
                  examinedNodeCount: edges.length,
                );
              }
            }
          } else if (childColor == _white) {
            color[child] = _gray;
            path.add(child);
            work.add((child, 0));
          }
          // _black：这个节点已经走完，它的子树里没有能回到当前路径的边。
        } else {
          // 邻居走完了：出栈并标记为黑。
          color[node] = _black;
          path.removeLast();
        }
      }
    }

    return ReferenceCycleReport(
      cycles: cycles,
      examinedNodeCount: edges.length,
    );
  }
}
