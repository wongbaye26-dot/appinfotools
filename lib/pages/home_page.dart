import 'package:apk_info_tool/pages/info_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// 分析页外壳。
///
/// 现在**只剩两件事**：给 [APKInfoPage] 一个 Scaffold，以及当窗口监听器
/// （页面用 `WindowListener` 让自己的 rebuild 跟随窗口尺寸变化）。
///
/// 早先这里还兼着三件事：标题栏里两个按钮在「信息」与「安装」之间切
/// IndexedStack；标题重复一遍应用名；把该页注册的动作放到顶栏右侧。
/// 侧边栏接管导航后前两件成了重复入口（「安装」页本身也只是个「开发中」
/// 占位），最后一件在 V2.4.1 并进了页面内的 `PageHeader` ——
/// 于是这一层退化成一个壳。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WindowListener, TickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 标题与操作**不再放在 AppBar 里**，而是并进页面内容的
    // `PageHeader`（`APKInfoPage` 负责渲染）—— 与 概览 / 版本对比 /
    // 设置 三个页面同一个做法。
    //
    // 为什么安全：窗口拖动靠的是**系统标题栏**（交通灯那块区域，见截图
    // 左上角），Flutter 的 AppBar 并不提供 macOS 的拖动区；概览与版本对比
    // 两页本来就没有 AppBar，拖动一直正常。
    return const Scaffold(
      body: APKInfoPage(),
    );
  }

  @override
  void onWindowMaximize() => setState(() {});
  @override
  void onWindowUnmaximize() => setState(() {});
  @override
  void onWindowMinimize() => setState(() {});
  @override
  void onWindowRestore() => setState(() {});
  @override
  void onWindowResize() => setState(() {});
  @override
  void onWindowFocus() => setState(() {});
}
