import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/providers/home_page_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// 分析页外壳。
///
/// 只做两件事：给 [APKInfoPage] 一个 Scaffold，以及把该页注册的动作
/// （打开、重命名、导出…）放到顶栏右侧。
///
/// 早先这里还兼着 1.0 的「页面切换」：标题栏里两个按钮在「信息」与
/// 「安装」之间切 IndexedStack，标题又重复了一遍应用名。侧边栏接管导航
/// 后那套就成了重复入口，而「安装」页本身只是个「开发中」占位 ——
/// 因此一并去掉，标题改为当前页面名。
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
    final actions = ref.watch(pageActionsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        // 与侧边栏同一套表面色，去掉 Material 默认的着色，
        // 让顶栏和左侧栏看起来是同一块界面的一部分。
        backgroundColor: theme.colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          t.nav.analysis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: actions,
      ),
      body: const APKInfoPage(),
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
