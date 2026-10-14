// IPA 详情页的版式测试。
//
// 用**合成**的 iOS 解析结果，因此不依赖真实样本、在任何机器上都会跑 ——
// `real_samples_ui_test.dart` 覆盖的是「真实样本能不能渲染出来」，这里覆盖的
// 是「渲染出来的版式是否符合设计」，两者不重叠。
//
// 钉住的核心是**两页对齐**：
// 1. 同样的 `Card` + `TitleValueLayout`，没有 iOS 专属的卡片壳；
// 2. 同样的卡片顺序（用相对次序断言，不写死完整列表）；
// 3. 同样的复制入口；
// 4. 区分靠最上面那一行**平台标识**，而不是把两页做成两种样子。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/widgets/copy_icon_button.dart';
import 'package:apk_info_tool/widgets/ios_detail_widgets.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:apk_info_tool/widgets/title_value_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show
        IosBundle,
        IosBundleKind,
        IosIconResolution,
        IosIconSource,
        IosUnresolvedIcon,
        IpaContainer,
        IpaInfoPlist;

const _appPath = 'Payload/Example.app';

const _mainApp = IosBundle(
  kind: IosBundleKind.mainApp,
  path: _appPath,
  name: 'Example.app',
  infoPlistPath: '$_appPath/Info.plist',
  fileCount: 640,
  uncompressedBytes: 88 * 1024 * 1024,
  hasCodeSignatureDirectory: true,
  hasEmbeddedProvision: true,
);

final _infoPlist = IpaInfoPlist(
  bundle: _mainApp,
  bundleIdentifier: const FieldValue.extracted(
    'com.example.demo',
    source: FieldSource.infoPlist,
  ),
  displayName: const FieldValue.extracted(
    '示例应用',
    source: FieldSource.infoPlist,
  ),
  shortVersionString: const FieldValue.extracted(
    '3.1.0',
    source: FieldSource.infoPlist,
  ),
  bundleVersion: const FieldValue.extracted(
    '310',
    source: FieldSource.infoPlist,
  ),
  executable: const FieldValue.extracted(
    'Example',
    source: FieldSource.infoPlist,
  ),
  minimumOSVersion: const FieldValue.extracted(
    '13.0',
    source: FieldSource.infoPlist,
  ),
  deviceFamily:
      const FieldValue.extracted([1, 2], source: FieldSource.infoPlist),
  queriesSchemes:
      const FieldValue.extracted(['demo'], source: FieldSource.infoPlist),
);

IpaAnalysis _ipa() => IpaAnalysis(
      container: const IpaContainer(
        bundles: [_mainApp],
        payloadApps: [_mainApp],
        hasPayloadDirectory: true,
        fileEntryCount: 641,
        totalUncompressedBytes: 88 * 1024 * 1024,
      ),
      mainApp: _mainApp,
      infoPlist: _infoPlist,
      executablePath: '$_appPath/Example',
      icon: const IosIconResolution(
        unresolved: [
          IosUnresolvedIcon(
            source: IosIconSource.assetCatalogName,
            declared: 'CFBundleIconName=AppIcon',
            reason: 'the icon lives in Assets.car and cannot be previewed',
          ),
        ],
      ),
      diagnostics: [
        const AnalysisDiagnostic.info(
          'ios.nested.truncated',
          'only the first 24 of 27 nested bundles were parsed',
          source: FieldSource.zipDirectory,
        ),
      ],
    );

FileState _ipaState({IpaAnalysis? analysis}) => FileState(
      filePath: '/tmp/Example.ipa',
      fileSize: 42465437,
      ipaAnalysis: analysis,
      md5Hash: 'd41d8cd98f00b204e9800998ecf8427e',
      sha1Hash: 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      sha256Hash:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );

FileState _apkState() => FileState(
      filePath: '/tmp/Example.apk',
      fileSize: 60608714,
      apkInfo: ApkInfo()
        ..packageName = 'com.example.demo'
        ..label = '示例应用'
        ..versionName = '3.1.0'
        ..versionCode = 310
        ..sdkVersion = 21
        ..targetSdkVersion = 34
        ..usesPermissions = ['android.permission.INTERNET'],
      md5Hash: 'd41d8cd98f00b204e9800998ecf8427e',
      sha1Hash: 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      sha256Hash:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );

Future<void> _pumpPage(WidgetTester tester, FileState state) async {
  // 详情页是一个 ListView：默认 800×600 的视口只会构建可见的那几张卡，
  // 断言后面的卡片就等于断言一个从没被构建过的东西。
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentFileStateProvider.notifier).update(state);
  // Android 卡片读的是 `currentApkInfoProvider`，测试必须照做。
  if (state.apkInfo != null) {
    container.read(currentApkInfoProvider.notifier).update(state.apkInfo);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        // 与真实树一致：`APKInfoPage` 在 `HomePage` 的 Scaffold 里。
        // 直接当 `home` 时环境字体是 WidgetsApp 的报错样式。
        child: const MaterialApp(home: Scaffold(body: APKInfoPage())),
      ),
    ),
  );
  await tester.pump();
}

/// 界面上所有可见文本。`TitleValueLayout` 用 `Text` 渲染标题、用
/// `SelectableText` 渲染值，两者都要收。
String _visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(widget.data ?? '');
  }
  for (final widget
      in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
    buffer.writeln(widget.data ?? '');
  }
  return buffer.toString();
}

List<TitleValueLayout> _layouts(WidgetTester tester) =>
    tester.widgetList<TitleValueLayout>(find.byType(TitleValueLayout)).toList();

/// 页面上所有卡片的标题，**按渲染顺序**。
List<String> _cardTitles(WidgetTester tester) =>
    _layouts(tester).map((layout) => layout.title).toList();

TitleValueLayout _layoutTitled(WidgetTester tester, String title) =>
    _layouts(tester).firstWhere((layout) => layout.title == title);

void main() {
  group('IPA 详情页 — 与 APK 页同一套版式', () {
    testWidgets('核心卡片仍是 Card + TitleValueLayout，允许 iOS 专属视觉卡片', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));
      expect(tester.takeException(), isNull);

      final layouts = find.byType(TitleValueLayout);
      expect(layouts, findsWidgets);

      // 每个 TitleValueLayout 的直接祖先都必须是一张 Card。
      final wrapped = find.ancestor(of: layouts, matching: find.byType(Card));
      expect(
        tester.widgetList<Card>(wrapped).length,
        tester.widgetList<TitleValueLayout>(layouts).length,
      );

      // iOS 专属视觉组件存在
      expect(find.byType(IosHeroCard), findsOneWidget);
    });

    testWidgets('卡片顺序与 APK 页一致：文件 → 平台 → 版本 → 容器 …', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));
      final titles = _cardTitles(tester);

      void before(String a, String b) {
        final ia = titles.indexOf(a);
        final ib = titles.indexOf(b);
        expect(ia, isNonNegative, reason: '页面上没有「$a」');
        expect(ib, isNonNegative, reason: '页面上没有「$b」');
        expect(ia, lessThan(ib), reason: '「$a」应当排在「$b」前面');
      }

      // 平台标识刻意排在最前 —— 它是两页唯一的分辨依据，应该第一眼看到。
      before(t.file_info.platform, t.file_info.file);
      before(t.file_info.file, t.apk_info.version_name);
      before(t.apk_info.version_name, t.ios_info.minimum_os);
      before(t.ios_info.minimum_os, t.ios_info.container_section);
      before(t.ios_info.container_section, t.ios_info.signature_section);
      before(t.ios_info.signature_section, t.ios_info.codesign_section);
      before(t.ios_info.codesign_section, t.file_info.md5);
      before(t.file_info.md5, t.file_info.sha256);
      before(t.file_info.sha256, t.apk_info.diagnostics);
    });

    testWidgets('复制入口与 APK 页一样留在值旁边', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));

      // 三个哈希都要能一键复制。
      //
      // 复制按钮现在由 `TitleValueLayout` 统一提供（`copyable` 默认为 true），
      // 不再由各调用点用 `end:` 各挂一个 —— 那样同一张卡片上会出现两个
      // 一模一样的复制图标（这次改造前就是这样）。
      for (final title in [
        t.file_info.md5,
        t.file_info.sha1,
        t.file_info.sha256,
      ]) {
        final layout = _layoutTitled(tester, title);
        expect(layout.copyable, isTrue, reason: '「$title」缺少复制入口');
        expect(
          find.descendant(
            of: find.byWidget(layout),
            matching: find.byType(CopyIconButton),
          ),
          findsOneWidget,
          reason: '「$title」的复制按钮必须真的渲染出来，而不只是开关是开的',
        );
      }

      // Bundle ID 的复制在 Hero 卡片**内部**（`trailing`）—— 早先它被贴在
      // 卡片下方，界面上是一个孤零零的图标飘在空白里，看不出属于哪一项。
      final hero = tester.widget<IosHeroCard>(find.byType(IosHeroCard));
      expect(hero.trailing, isNotNull, reason: 'Hero 卡片应自带复制入口');
    });

    testWidgets('每张字段卡片只有一个复制入口', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));

      // 复制按钮统一由 `TitleValueLayout` 提供。如果某个调用点又用 `end:`
      // 挂一个，同一张卡片上就会出现两个一模一样的图标 —— 那正是这次改造
      // 之前的实际状态（哈希卡片、Platform、File 都是两个）。
      for (final layout in _layouts(tester)) {
        final copies = find
            .descendant(
              of: find.byWidget(layout),
              matching: find.byType(CopyIconButton),
            )
            .evaluate()
            .length;
        expect(
          copies,
          lessThanOrEqualTo(1),
          reason: '「${layout.title}」有 $copies 个复制按钮，只应有一个',
        );
      }
    });

    testWidgets('分组标题不与 Tab 名重复', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));

      // Tab 栏已经写着「应用」「权限」，内容里再来一行一模一样的字纯属噪音。
      // 测试视图会把 Tab 名渲染成一个小标题，因此每个名字只应出现一次。
      final lines = _visibleText(tester)
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      for (final label in [
        t.detail_tab.application,
        t.detail_tab.permissions,
        t.detail_tab.overview,
      ]) {
        expect(
          lines.where((line) => line == label).length,
          lessThanOrEqualTo(1),
          reason: '「$label」在页面上出现了多次（Tab 名与分组标题重复）',
        );
      }
    });

    testWidgets('Android 专属字段不出现在 IPA 页面上', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));

      final text = _visibleText(tester);
      // 注意：`t.apk_info.permissions` 不在此列 —— 两个平台的详情页现在
      // 都有「权限」Tab（Tab 统一规范），那是 Tab 名而非 Android 字段。
      for (final androidOnly in [
        t.apk_info.package_name,
        t.apk_info.min_sdk,
        t.apk_info.target_sdk,
        t.apk_info.max_sdk,
        t.apk_info.abi,
        t.apk_info.components,
      ]) {
        expect(text, isNot(contains(androidOnly)),
            reason: '「$androidOnly」是 Android 字段，不该出现在 IPA 页面');
      }
    });
  });

  group('平台标识 — 两页的分辨依据', () {
    testWidgets('IPA 页第一张卡片就是「平台 = iOS」', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));

      expect(_cardTitles(tester).first, t.file_info.platform);

      final platform = _layoutTitled(tester, t.file_info.platform);
      expect(platform.value, t.file_info.platform_ios);
      expect((platform.end! as Icon).icon, Icons.apple);
    });

    testWidgets('APK 页也有同一行，值不同', (tester) async {
      await _pumpPage(tester, _apkState());

      final platform = _layoutTitled(tester, t.file_info.platform);
      expect(platform.value, t.file_info.platform_android);
      expect((platform.end! as Icon).icon, Icons.android);
    });

    testWidgets('两页的卡片版式一致', (tester) async {
      // 同样的断言在 APK 页再跑一遍：两页都满足才算「对齐」。
      await _pumpPage(tester, _apkState());

      final layouts = find.byType(TitleValueLayout);
      final wrapped = find.ancestor(of: layouts, matching: find.byType(Card));
      expect(
        tester.widgetList<Card>(wrapped).length,
        tester.widgetList<TitleValueLayout>(layouts).length,
      );
    });
  });

  group('IPA 详情页 — 图标', () {
    testWidgets('图标只在 Hero 卡片里出现一次', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));

      // 图标**只出现一次**：Hero 卡片。早先版本栏右侧还挂着一张独立的
      // 图标卡，与 Hero 是同一个图标 —— 那是重复，已去掉。
      expect(find.byType(IosIconThumbnail), findsOneWidget);

      // 且那一个确实在 Hero 卡片里
      final hero = find.byType(IosHeroCard);
      expect(hero, findsOneWidget);
      expect(
        find.descendant(
            of: hero.first, matching: find.byType(IosIconThumbnail)),
        findsOneWidget,
      );
    });

    testWidgets('图标清单连同「为什么取不到」一起列出', (tester) async {
      await _pumpPage(tester, _ipaState(analysis: _ipa()));

      final icon = _layoutTitled(tester, t.ios_info.icon_section);
      expect(icon.value, contains(t.ios_info.icon_declared_unresolved));
      expect(icon.value, contains('Assets.car'));
    });

    testWidgets('容器里没有主应用时说明原因，而不是留一页短横线', (tester) async {
      await _pumpPage(
        tester,
        _ipaState(analysis: IpaAnalysis(container: const IpaContainer())),
      );

      final text = _visibleText(tester);
      expect(text, contains(t.ios_info.unavailable));
      expect(text, contains(t.ios_info.no_main_app));
      // 即便读不出应用信息，也要能确认这是个 iOS 包。
      expect(text, contains(t.file_info.platform_ios));
    });
  });
}
