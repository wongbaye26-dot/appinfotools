import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'parsed_file_cache.g.dart';

/// 按路径缓存**已解析完成**的 [FileState]。
///
/// 差异页要同时拿到两份解析结果，而 `currentFileStateProvider` 只保留最近一次
/// 解析的那一份（这是产品选择，不是架构限制 —— 见
/// `docs/plans/V2.4.0_PROGRESS.md` §17.9）。解析流程本身（任务句柄、阶段回调、
/// 取消、代际计数）只存在于分析页，**不能为了差异页再复制一份**，因此这里
/// 不改解析流程，只旁听它的结果。
///
/// ## 为什么是「监听」而不是「让解析流程调用 put」
///
/// 分析页里更新 `currentFileStateProvider` 的地方有近二十处（哈希、签名、
/// Android 解析、iOS 解析、codesign 各写各的一项）。逐处插一句 `put(...)`
/// 迟早会漏 —— 而漏掉的那一处表现为「这个包在差异页里不见了」，没有任何报错。
/// 监听 provider 只有一处入口，且**新增写入点自动被覆盖**。
///
/// ## 只缓存「解析出结构」的状态
///
/// `analysis == null` 表示这个文件还没解析出可用结构（刚打开、或解析失败）。
/// 把它缓存下来会让差异页列出一个空壳，选进去得到一份全是「没读到」的差异 ——
/// 那比不列出它更糟。
///
/// ## 必须有人在启动时读一次
///
/// 本 provider 靠监听累积，而监听只在它**被创建之后**才生效。若直到用户进
/// 差异页才第一次读它，那么「解析 A → 解析 B → 进差异页」这条路径上缓存
/// 从没活过，两个包都会丢。`AppShell` 因此在 `initState` 里先读一次
/// （见 `lib/ui/shell/app_shell.dart`）。
@Riverpod(keepAlive: true)
class ParsedFileCache extends _$ParsedFileCache {
  @override
  Map<String, FileState> build() {
    ref.listen(currentFileStateProvider, (_, next) => _remember(next));
    return const {};
  }

  void _remember(FileState state) {
    final path = state.filePath;
    if (path == null) return;
    // 没解析出结构的不缓存（见类注释）。
    if (state.analysis == null) return;
    if (this.state[path] == state) return;
    // 重新赋值而不是就地改 Map：Riverpod 靠 `==` 判断是否通知，
    // 就地改会让 `previous == next` 成立，监听者收不到通知。
    this.state = {...this.state, path: state};
  }

  /// 清空缓存。仅供测试与「换一批包比较」使用。
  void clear() => state = const {};
}
