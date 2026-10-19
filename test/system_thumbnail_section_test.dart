// 「系统文件图标」区块的状态机与渲染。
//
// 这一组测的不是「有没有渲染出某个按钮」，而是**状态与文案的映射是否诚实**：
//
// - DLL 缺失时不能显示「未启用」—— 那会把用户引向「点启用」，而那一步注定失败；
// - 路径不一致要单独报出来（安装目录被移动过是最容易误判成「功能坏了」的状态）；
// - 点启用后如果 `usable` 仍是 false，提示语不能写「已启用」。
//
// 直接渲染 [SystemIconSection]（而不是整个 `SettingPage`）：后者被
// `Platform.isWindows` 门控，在 macOS / Linux 上整块不出现，测试只能跳过 ——
// 「全跳过」等于没验证。区块自己接受注入的状态，因此在任何平台都能真跑。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/system_thumbnail.dart';
import 'package:apk_info_tool/widgets/system_icon_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SystemThumbnailStatus _status({
  bool dllPresent = true,
  bool helperPresent = true,
  bool registered = false,
  String dllPath = r'C:\App\appinfotool_thumbnail.dll',
  String registeredPath = '',
  List<ThumbnailExtensionStatus> extensions = const [
    ThumbnailExtensionStatus(extension: '.apk', registered: false),
    ThumbnailExtensionStatus(extension: '.ipa', registered: false),
  ],
}) =>
    SystemThumbnailStatus(
      dllPresent: dllPresent,
      helperPresent: helperPresent,
      registered: registered,
      usable: dllPresent && helperPresent && registered,
      dllPath: dllPath,
      registeredPath: registeredPath,
      extensions: extensions,
    );

/// 渲染区块并展开（`ExpansionTile` 默认折叠）。
Future<void> _pumpSection(
  WidgetTester tester, {
  required SystemThumbnailStatus status,
  bool busy = false,
  VoidCallback? onToggle,
  VoidCallback? onRefresh,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  // 关掉动画：`CircularProgressIndicator` 的无限动画会让 `pumpAndSettle` 超时。
  tester.view.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(() {
    tester.view.reset();
    tester.view.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });

  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SystemIconSection(
              status: status,
              busy: busy,
              onToggle: onToggle ?? () {},
              onRefresh: onRefresh ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // 展开卡片。
  await tester.tap(find.text(t.settings.system_icon.title));
  await tester.pumpAndSettle();
}

void main() {
  group('状态 → 文案（唯一有分支的逻辑，逐态覆盖）', () {
    test('DLL 缺失优先于「未注册」', () {
      // 顺序很重要：DLL 不在时「未注册」是必然结果，先说「未注册」会
      // 把用户引向「点启用」，而那一步注定失败。
      final label = SystemIconSection.stateLabel(
        _status(dllPresent: false),
        t,
      );
      expect(label, t.settings.system_icon.state_dll_missing);
    });

    test('helper 缺失排在注册状态之前', () {
      final label = SystemIconSection.stateLabel(
        _status(helperPresent: false, registered: true),
        t,
      );
      expect(label, t.settings.system_icon.state_helper_missing);
    });

    test('三件事齐备才是「已启用」', () {
      expect(
        SystemIconSection.stateLabel(_status(registered: true), t),
        t.settings.system_icon.state_usable,
      );
    });

    test('文件都在但没注册 → 「尚未启用」', () {
      expect(
        SystemIconSection.stateLabel(_status(), t),
        t.settings.system_icon.state_not_registered,
      );
    });
  });

  group('路径不一致的判定', () {
    test('只有「注册路径非空且与当前不同」才算不一致', () {
      expect(
        _status(
          dllPath: r'C:\New\a.dll',
          registeredPath: r'C:\Old\a.dll',
        ).pathMismatch,
        isTrue,
      );
      // 空注册路径 = 从未注册过，不该报「路径不一致」。
      expect(_status(dllPath: r'C:\New\a.dll').pathMismatch, isFalse);
      // 相同路径 = 正常。
      expect(
        _status(
          dllPath: r'C:\Same\a.dll',
          registeredPath: r'C:\Same\a.dll',
        ).pathMismatch,
        isFalse,
      );
    });

    test('unknown 状态全部为 false —— 「没查」不能显示成「可用」', () {
      const unknown = SystemThumbnailStatus.unknown();
      expect(unknown.usable, isFalse);
      expect(unknown.registered, isFalse);
      expect(unknown.dllPresent, isFalse);
      expect(unknown.helperPresent, isFalse);
      expect(unknown.extensions, isEmpty);
      expect(unknown.pathMismatch, isFalse);
    });
  });

  group('渲染', () {
    testWidgets('未注册：显示「尚未启用」与「启用」按钮，不显示「刷新」', (tester) async {
      await _pumpSection(tester, status: _status());

      expect(
        find.text(t.settings.system_icon.state_not_registered),
        findsOneWidget,
      );
      expect(find.text(t.settings.system_icon.enable), findsOneWidget);
      expect(find.text(t.settings.system_icon.refresh), findsNothing);
    });

    testWidgets('已启用：显示「已启用」与「停用」「刷新」', (tester) async {
      await _pumpSection(
        tester,
        status: _status(
          registered: true,
          registeredPath: r'C:\App\appinfotool_thumbnail.dll',
          extensions: const [
            ThumbnailExtensionStatus(extension: '.apk', registered: true),
            ThumbnailExtensionStatus(extension: '.ipa', registered: true),
          ],
        ),
      );

      expect(find.text(t.settings.system_icon.state_usable), findsOneWidget);
      expect(find.text(t.settings.system_icon.disable), findsOneWidget);
      expect(find.text(t.settings.system_icon.refresh), findsOneWidget);
    });

    testWidgets('DLL 缺失：说清缺的是 DLL，不出现「尚未启用」', (tester) async {
      await _pumpSection(tester, status: _status(dllPresent: false));

      expect(
        find.text(t.settings.system_icon.state_dll_missing),
        findsOneWidget,
      );
      expect(
        find.text(t.settings.system_icon.state_not_registered),
        findsNothing,
      );
    });

    testWidgets('helper 缺失：同样说清是哪一件', (tester) async {
      await _pumpSection(tester, status: _status(helperPresent: false));

      expect(
        find.text(t.settings.system_icon.state_helper_missing),
        findsOneWidget,
      );
    });

    testWidgets('路径不一致：两个路径都显示出来（否则用户不知道改成哪个）', (tester) async {
      await _pumpSection(
        tester,
        status: _status(
          dllPath: r'C:\New\appinfotool_thumbnail.dll',
          registeredPath: r'C:\Old\appinfotool_thumbnail.dll',
        ),
      );

      expect(
        find.text(t.settings.system_icon.state_path_mismatch),
        findsOneWidget,
      );
      expect(
        find.textContaining(r'C:\Old\appinfotool_thumbnail.dll'),
        findsOneWidget,
      );
      expect(
        find.textContaining(r'C:\New\appinfotool_thumbnail.dll'),
        findsWidgets,
      );
    });

    testWidgets('逐扩展名分开显示（.apk 挂上、.ipa 没挂上时不能只报「已启用」）', (tester) async {
      await _pumpSection(
        tester,
        status: _status(
          registered: true,
          extensions: const [
            ThumbnailExtensionStatus(extension: '.apk', registered: true),
            ThumbnailExtensionStatus(extension: '.ipa', registered: false),
          ],
        ),
      );

      expect(find.text('.apk'), findsOneWidget);
      expect(find.text('.ipa'), findsOneWidget);
      expect(find.text(t.settings.system_icon.ext_registered), findsOneWidget);
      expect(find.text(t.settings.system_icon.ext_missing), findsOneWidget);
    });

    testWidgets('busy 时按钮换成进度指示（避免连点并发写注册表）', (tester) async {
      await _pumpSection(tester, status: _status(), busy: true);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(t.settings.system_icon.enable), findsNothing);
    });

    testWidgets('已知限制必须出现在区块里（不能把统一图标说成已完成）', (tester) async {
      await _pumpSection(tester, status: _status());

      expect(
        find.textContaining(t.settings.system_icon.limits),
        findsOneWidget,
      );
    });

    testWidgets('回调真的被调用', (tester) async {
      var toggled = 0;
      var refreshed = 0;
      await _pumpSection(
        tester,
        status: _status(registered: true),
        onToggle: () => toggled++,
        onRefresh: () => refreshed++,
      );

      await tester.tap(find.text(t.settings.system_icon.disable));
      await tester.pumpAndSettle();
      expect(toggled, 1);

      await tester.tap(find.text(t.settings.system_icon.refresh));
      await tester.pumpAndSettle();
      expect(refreshed, 1);
    });

    testWidgets('诊断信息默认折叠，路径不出现在首屏', (tester) async {
      await _pumpSection(tester, status: _status());

      // 折叠状态下 `ExpansionTile` 的 children 不在树里。
      expect(
        find.textContaining(t.settings.system_icon.diagnostics),
        findsOneWidget,
        reason: '诊断标题本身要可见（它是展开入口）',
      );
      expect(
        find.textContaining('appinfotool_thumbnail.dll'),
        findsNothing,
        reason: '折叠时不该把路径铺在界面上',
      );
    });
  });
}
