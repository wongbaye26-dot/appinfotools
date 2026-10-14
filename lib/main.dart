import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/theme/theme_manager.dart';
import 'package:apk_info_tool/ui/shell/app_shell.dart';
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

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();

  await ToolPaths.init();
  await Config.init();
  await Config.loadConfig();

  packageInfo = await PackageInfo.fromPlatform();

  await LoggerInit.instance.init();

  log.info("main: arguments=$arguments");
  if (arguments.isNotEmpty) {
    apkByArgs = arguments.first;
  }

  if (isDesktop) {
    await windowManager.ensureInitialized();
    windowManager.waitUntilReadyToShow().then((_) async {
      // 侧边栏在 >= 800px 时展开为 240px。最小宽度取 900：再窄下去
      // 内容区只剩不到 660px，卡片会被压成一列短横线。
      const minSize = Size(900, 600);
      await windowManager.setMinimumSize(minSize);
      await windowManager.setSize(await _initialWindowSize(minSize));
      await windowManager.setTitle('${t.title} v${packageInfo.version}');
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
