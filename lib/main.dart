import 'dart:async';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/theme/theme_manager.dart';
import 'package:apk_info_tool/ui/shell/app_shell.dart';
import 'package:apk_info_tool/utils/file_association.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

late PackageInfo packageInfo;

String apkByArgs = "";

bool get isDesktop {
  if (kIsWeb) return false;
  return [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ].contains(defaultTargetPlatform);
}

/// 让框架层与异步未捕获的错误**留下痕迹**。
///
/// 不接管渲染（不动 `ErrorWidget.builder`），只加一层日志 —— 默认行为原样
/// 保留，因此不会改变用户看到的东西。
///
/// 为什么需要它：`unawaited(future)` 里抛出的异常会变成「未捕获的异步错误」，
/// 既不会让界面报错，也不会中断流程。最近文件那个 BUG 就是这么活了很久 ——
/// `RecentFilesManager.add` 抛 `UnsupportedError`，界面上表现为「统计永远是 0」，
/// 而日志里一行都没有，只能靠一行行读代码才找得到。
void _installErrorLogging() {
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    log.warning('FlutterError: ${details.exceptionAsString()}');
    previousFlutterError?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.warning('uncaught async error: $error');
    // 返回 false 表示「没处理」—— 交回默认处理，保持既有行为不变。
    return false;
  };
}

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();

  await ToolPaths.init();
  await Config.init();
  await Config.loadConfig();

  packageInfo = await PackageInfo.fromPlatform();

  await LoggerInit.instance.init();
  _installErrorLogging();

  log.info("main: arguments=$arguments");
  if (arguments.isNotEmpty) {
    apkByArgs = arguments.first;
  }

  // Windows：把本程序登记为 .apk / .ipa 等扩展名的候选打开方式。
  //
  // 为什么在**每次启动**都做，而不是只在安装时做一次：
  //
  // - 安装器（`inno_bundle`）生成的 Inno Setup 脚本**没有 `[Registry]` 段**，
  //   装完根本没有任何关联 —— 这是「Windows 下关联不了」的根因；
  // - ZIP 免安装版没有安装器，只能靠这一步；
  // - 用户升级 / 系统清理 / 另一个程序抢了关联之后，启动一次就自动恢复。
  //
  // 写入的是 `HKCU`，不需要管理员权限。**不阻塞启动**：注册表写入是
  // 微秒级，但没必要让它挡在首帧前面；失败也不弹窗（用户此刻要的是
  // 打开文件，不是看错误提示）。
  //
  // 注意它**不会**把本程序设成默认 —— Windows 10/11 的默认程序由带哈希
  // 校验的 `UserChoice` 决定，程序改不了。这里只保证「打开方式」列表里
  // 有我们，要不要设为默认由用户在系统里决定。
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    unawaited(
      FileAssociationManager.registerAssociations().then((registered) {
        log.info('main: registerAssociations -> $registered');
      }),
    );
  }

  if (isDesktop) {
    await windowManager.ensureInitialized();
    windowManager.waitUntilReadyToShow().then((_) async {
      // 侧边栏在 >= 800px 时展开为 `kSidebarWidth`（200px）。最小宽度取 900：
      // 再窄下去内容区只剩不到 660px，卡片会被压成一列短横线。
      const minSize = Size(900, 600);
      await windowManager.setMinimumSize(minSize);
      await windowManager.setSize(await _initialWindowSize(minSize));
      // 标题栏只写应用名，**不带版本号**。
      //
      // 「AppInfoTool v2.4.5」把两个信息挤在一处，而版本号在设置页有一份、
      // 侧边栏此前还各有一份。标题栏是最窄的地方，留给应用名本身。
      // 三平台走的是同一行代码（`window_manager`），因此 Windows 一并生效。
      await windowManager.setTitle(t.title);
      // 居中必须在 show 之前 —— show 之后再挪，用户会看到窗口跳一下。
      await windowManager.center();
      await windowManager.show();
      // await windowManager.setPreventClose(true);
    });
  }

  // 配置写入有 100ms 防抖，应用失焦/退出时若不主动 flush，
  // 最后一次修改会随进程一起丢失。
  //
  // `AppLifecycleListener` 的构造函数会把自己注册进 `WidgetsBinding`
  // （见 flutter/lib/src/widgets/app_lifecycle_listener.dart 的 addObserver），
  // 而 `WidgetsBinding.instance` 是进程级单例，绑定对象因此已被强引用持有，
  // 无需再用顶层变量防止被 GC 回收。
  AppLifecycleListener(
    onInactive: () => Config.flushAll(),
    onPause: () => Config.flushAll(),
    onHide: () => Config.flushAll(),
    onDetach: () => Config.flushAll(),
  );

  // 语言包是 **deferred（懒加载）** 的：`setLocaleRawSync` 会因为
  // 「Deferred library l_zh_CN was not loaded」直接抛异常。必须走异步版本
  // 并 **await** —— 不 await 的话 `runApp` 先跑，首帧用的是 base locale，
  // 等语言包加载完再切回来，表现为启动瞬间语言闪一下。
  final lang = Config.language.value;
  if (lang.isEmpty || lang == Config.kLanguageAuto) {
    await LocaleSettings.useDeviceLocale();
  } else {
    await LocaleSettings.setLocaleRaw(lang);
  }
  runApp(ProviderScope(child: TranslationProvider(child: const MyApp())));
}

/// 首次打开时的窗口尺寸。
///
/// 理想值是 1280×800（16:10）：侧边栏展开 240px 后内容区仍有 1040px，
/// 概览页的三列统计卡片、详情页的卡片列表都能一屏铺开，不必横向滚动。
///
/// 但这个高度在 1366×768 这类小屏上会超出可用区域，窗口底部（侧边栏的
/// 版本号、列表的最后一张卡片）会落到屏幕外。因此以**屏幕可用区域**为
/// 上界夹紧；读不到屏幕信息时退回理想尺寸 —— 尺寸不理想只是难看，
/// 让应用起不来才是真问题。
Future<Size> _initialWindowSize(Size minimum) async {
  const preferred = Size(1280, 800);
  try {
    final display = await screenRetriever.getPrimaryDisplay();
    // `visibleSize` 排除了任务栏与 Dock，比 `size` 更接近「真正能用的区域」。
    final visible = display.visibleSize ?? display.size;
    // 屏幕比最小尺寸还小时，clamp 的上下界会颠倒并抛 ArgumentError，
    // 这里退回最小尺寸，让窗口管理器自己去裁。
    final maxWidth =
        visible.width > minimum.width ? visible.width : minimum.width;
    final maxHeight =
        visible.height > minimum.height ? visible.height : minimum.height;
    return Size(
      preferred.width.clamp(minimum.width, maxWidth).toDouble(),
      preferred.height.clamp(minimum.height, maxHeight).toDouble(),
    );
  } catch (e) {
    log.warning('读取屏幕尺寸失败，使用默认窗口尺寸：$e');
    return preferred;
  }
}

final _navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeManager = ref.watch(themeManagerProvider);
    return MaterialApp(
      navigatorKey: _navigatorKey,
      locale: TranslationProvider.of(context).flutterLocale,
      supportedLocales: AppLocaleUtils.supportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      title: t.title,
      initialRoute: "/",
      theme: themeManager.lightTheme,
      darkTheme: themeManager.darkTheme,
      themeMode: themeManager.mode,
      // 设置页由侧边栏承载，不再是一条独立路由 —— 早先分析页顶栏还有一个
      // 设置按钮 push 到这里，与侧边栏重复，已去掉。
      routes: {
        "/": (context) => const AppShell(),
      },
      builder: (context, child) {
        return _GlobalShortcuts(child: child!);
      },
    );
  }
}

class _GlobalShortcuts extends StatelessWidget {
  final Widget child;

  const _GlobalShortcuts({required this.child});

  Future<void> _handleBackOrClose() async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    final didPop = await navigator.maybePop();
    if (!didPop && isDesktop) {
      windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        final isCtrlW = HardwareKeyboard.instance.isControlPressed &&
            event.logicalKey == LogicalKeyboardKey.keyW;
        final isEsc = event.logicalKey == LogicalKeyboardKey.escape;

        if (isCtrlW || isEsc) {
          _handleBackOrClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
