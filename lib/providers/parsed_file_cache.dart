import 'dart:ui' as ui;

import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/utils/logger.dart';
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

/// 已解析包的**图标副本**，按路径索引。
///
/// ## 为什么必须有这一份
///
/// `CurrentApkInfo.update/reset` 在换文件时会 `dispose()` 上一个 `ApkInfo`，
/// 而 `ApkInfo.dispose()` 会把图标候选的 `ui.Image` 一起释放、并把
/// `mainIconImage` 置空。`parsedFileCacheProvider` 里存的正是**同一个**
/// `ApkInfo` 实例 —— 于是**先解析的那个包**在差异页里图标消失，只有当前那个
/// 还活着。
///
/// 实测（V2.4.8 用户报告）：版本对比左侧槽位显示平台通用图标、右侧显示真实
/// 图标。左侧是先解析的那个，已经被 dispose 过。
///
/// `ui.Image.clone()` 共享底层像素、各自计数，因此克隆体不受原对象 dispose
/// 影响。**iOS 侧不需要这一份** —— 它的图标是从 `IpaAnalysis` 里的字节现解
/// 的，那份数据不会被 dispose。
@Riverpod(keepAlive: true)
class ParsedFileIcons extends _$ParsedFileIcons {
  /// 副本的**权威来源**。
  ///
  /// 不直接在 `ref.onDispose` 里读 `state`：Riverpod 明确禁止在生命周期回调
  /// 里碰 `state`（实测报 `Cannot use Ref or modify other providers inside
  /// life-cycles`），而那恰恰是要释放资源的地方。因此另存一份，
  /// `state` 只是给监听者的投影。
  final Map<String, ui.Image> _icons = {};

  @override
  Map<String, ui.Image> build() {
    ref.listen(currentFileStateProvider, (_, next) => _remember(next));
    ref.onDispose(() {
      for (final image in _icons.values) {
        image.dispose();
      }
      _icons.clear();
    });
    return const {};
  }

  void _remember(FileState fileState) {
    final path = fileState.filePath;
    if (path == null) return;
    // 没解析出结构的不留（与 `ParsedFileCache` 同一条口径）。
    if (fileState.analysis == null) return;
    // 同一个路径只留第一份：图标解析出来之后就固定了，重复克隆只是白占内存。
    if (state.containsKey(path)) return;

    final icon = fileState.apkInfo?.mainIconImage;
    if (icon == null) return;

    try {
      final copy = icon.clone();
      _icons[path] = copy;
      // 重新赋值而不是就地改 Map —— 与 `ParsedFileCache` 同一个理由：
      // Riverpod 靠 `==` 判断是否通知，就地改收不到通知。
      state = Map.unmodifiable({...state, path: copy});
    } catch (e) {
      // 原图已经被释放（例如本 provider 比解析结果晚创建）—— 那就没有副本，
      // 差异页退回平台通用图标。**不是错误**，只是一次没赶上。
      log.fine('ParsedFileIcons: 无法克隆 $path 的图标: $e');
    }
  }

  /// 清空副本（换一批包比较 / 测试用）。
  void clear() {
    for (final image in _icons.values) {
      image.dispose();
    }
    _icons.clear();
    state = const {};
  }
}
