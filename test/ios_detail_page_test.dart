// IPA 详情页的版式测试。
//
// 用**合成**的 iOS 解析结果，因此不依赖真实样本、在任何机器上都会跑 ——
// `real_samples_ui_test.dart` 覆盖的是「真实样本能不能渲染出来」，这里覆盖的
// 是「渲染出来的版式是否符合设计」，两者不重叠。
//
// 钉住三件事：
// 1. IPA 页面按语义分组（Android 侧是一列平铺的卡片）；
// 2. Hero 卡片一次给出平台、应用名、Bundle ID 与版本；
// 3. **Android 的字段不出现在 IPA 页面上** —— 那些字段读的是 `apkInfo?.x`，
//    在 iOS 上会渲染成一排空值，看起来像「这个包什么都没有」。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/pages/info_page.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/widgets/ios_detail_widgets.dart';
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

const _bundlePath = 'Payload/Example.app';

const _bundle = IosBundle(
  kind: IosBundleKind.mainApp,
  path: _bundlePath,
  name: 'Example.app',
  infoPlistPath: '$_bundlePath/Info.plist',
  fileCount: 42,
  uncompressedBytes: 1024 * 1024,
  hasCodeSignatureDirectory: true,
);

const _framework = IosBundle(
  kind: IosBundleKind.framework,
  path: '$_bundlePath/Frameworks/libExample.dylib.framework',
  name: 'libExample.dylib.framework',
  fileCount: 3,
);

/// 一份合成的主应用 `Info.plist`。
///
/// 每个字段都走 `FieldValue.extracted`，与真实解析出来的形状一致 ——
/// 用 `absent` 会走到「为什么没有值」的分支，那是另一组断言的事。
final _infoPlist = IpaInfoPlist(
  bundle: _bundle,
  bundleIdentifier: const FieldValue.extracted(
    'com.example.demo',
    source: FieldSource.infoPlist,
  ),
  displayName: const FieldValue.extracted(
    '示例应用',
    source: FieldSource.infoPlist,
  ),
  shortVersionString: const FieldValue.extracted(
    '1.2.3',
    source: FieldSource.infoPlist,
  ),
  bundleVersion: const FieldValue.extracted(
    '42',
    source: FieldSource.infoPlist,
  ),
  executable: const FieldValue.extracted(
    'Example',
    source: FieldSource.infoPlist,
  ),
  minimumOSVersion: const FieldValue.extracted(
    '14.0',
    source: FieldSource.infoPlist,
  ),
  deviceFamily:
      const FieldValue.extracted([1, 2], source: FieldSource.infoPlist),
);

/// 一份合成的解析结果：图标只在 `Assets.car` 里，另有一条诊断。
IpaAnalysis _analysis() => IpaAnalysis(
      container: const IpaContainer(
        bundles: [_bundle, _framework],
        payloadApps: [_bundle],
        hasPayloadDirectory: true,
        fileEntryCount: 45,
        totalUncompressedBytes: 1024 * 1024,
      ),
      mainApp: _bundle,
      infoPlist: _infoPlist,
      executablePath: '$_bundlePath/Example',
      icon: const IosIconResolution(
        unresolved: [
          IosUnresolvedIcon(
            source: IosIconSource.assetCatalogName,
            declared: 'AppIcon',
            reason: 'the icon lives in Assets.car and cannot be previewed',
          ),
        ],
      ),
      diagnostics: [
        const AnalysisDiagnostic.info(
          'ios.demo.synthetic',
          'synthetic diagnostic for the layout test',
          source: FieldSource.zipDirectory,
        ),
      ],
    );

FileState _state({IpaAnalysis? analysis}) => FileState(
      filePath: '/tmp/Example.ipa',
      fileSize: 2048,
      ipaAnalysis: analysis,
      md5Hash: 'd41d8cd98f00b204e9800998ecf8427e',
      sha1Hash: 'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      sha256Hash:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );

Future<void> _pumpPage(WidgetTester tester, FileState state) async {
  // 详情页是一个 ListView：默认 800×600 的视口只会构建可见的那几张卡，
  // 断言后面的分组就等于断言一个从没被构建过的东西。
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentFileStateProvider.notifier).update(state);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: const MaterialApp(home: APKInfoPage()),
      ),
    ),
  );
  await tester.pump();
}

/// 界面上所有可见文本。`TitleValueLayout` 用 `Text` 渲染标题、用
/// `SelectableText` 渲染值；Hero 卡片两处都用 `SelectableText`。
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

List<IosInfoCard> _cards(WidgetTester tester) =>
    tester.widgetList<IosInfoCard>(find.byType(IosInfoCard)).toList();

IosInfoCard? _cardWithTitle(WidgetTester tester, String title) {
  for (final card in _cards(tester)) {
    if (card.title == title) return card;
  }
  return null;
}

void main() {
  group('IPA 详情页 — 分组结构', () {
    testWidgets('五个语义分组都渲染出来', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      expect(tester.takeException(), isNull);

      final titles = tester
          .widgetList<IosSectionHeader>(find.byType(IosSectionHeader))
          .map((h) => h.title)
          .toList();

      expect(
        titles,
        [
          t.ios_info.group_file,
          t.ios_info.group_app,
          t.ios_info.group_container,
          t.ios_info.group_signature,
          t.ios_info.group_integrity,
        ],
        reason: '顺序固定：先确认打开的是哪个文件，再逐层深入',
      );
    });

    testWidgets('分组标题只出现一次，不出现「解析诊断 解析诊断」这类叠字', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      final titles = tester
          .widgetList<IosSectionHeader>(find.byType(IosSectionHeader))
          .map((h) => h.title)
          .toList();
      expect(titles.toSet(), hasLength(titles.length));

      // 分组标题与卡片标题不得同名 —— 同名就是视觉上的重复。
      final cardTitles = _cards(tester).map((c) => c.title).toSet();
      for (final title in titles) {
        expect(cardTitles, isNot(contains(title)),
            reason: '「$title」既是分组标题又是卡片标题');
      }
    });

    testWidgets('签名与 codesign 是两张卡片，而不是一块拼接的长文本', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      final signature = _cardWithTitle(tester, t.ios_info.signature_verdict);
      final codeSign = _cardWithTitle(tester, t.ios_info.codesign_section);

      expect(signature, isNotNull);
      expect(codeSign, isNotNull);

      // codesign 的表头已经在卡片标题里，正文再来一遍就成了叠字。
      expect(codeSign!.value, isNot(contains(t.ios_info.codesign_section)));
      expect(signature!.value, isNot(contains(t.ios_info.codesign_section)));
    });
  });

  group('IPA 详情页 — Hero 卡片', () {
    testWidgets('平台徽标、应用名、Bundle ID、版本一次给全', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      expect(find.byType(IosHeroCard), findsOneWidget);

      final hero = tester.widget<IosHeroCard>(find.byType(IosHeroCard));
      expect(hero.badge, t.ios_info.platform_badge);
      expect(hero.name, '示例应用');
      expect(hero.bundleId, 'com.example.demo');
      expect(hero.version, '1.2.3 (42)');

      final text = _visibleText(tester);
      expect(text, contains(t.ios_info.platform_badge));
      expect(text, contains('com.example.demo'));
      expect(text, contains('1.2.3 (42)'));
    });

    testWidgets('Bundle ID 的复制入口留在它旁边', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      final hero = tester.widget<IosHeroCard>(find.byType(IosHeroCard));
      expect(hero.bundleIdEnd, isNotNull,
          reason: 'Bundle ID 是要复制去别处用的值，不能把复制按钮弄丢');
    });

    testWidgets('图标的未解析原因挂在 Hero 卡片底部，而不是被裁掉', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      final text = _visibleText(tester);
      expect(text, contains(t.ios_info.icon_declared_unresolved));
      expect(text, contains('Assets.car'));
    });

    testWidgets('容器里没有主应用时说明原因，而不是留一页短横线', (tester) async {
      // 没有 `Payload/*.app` 时 Hero 卡片与后面每一组都会是一排「-」，
      // 而「-」的含义是「文件里没有这一项」—— 与「我们没找到应用」是两件事。
      await _pumpPage(
        tester,
        _state(analysis: IpaAnalysis(container: const IpaContainer())),
      );

      final text = _visibleText(tester);
      expect(text, contains(t.ios_info.unavailable));
      expect(text, contains(t.ios_info.no_main_app));
      expect(text, contains(t.ios_info.platform_badge),
          reason: '即便读不出应用信息，也要能确认这是个 iOS 包');
    });
  });

  group('IPA 详情页 — 与 Android 的差异', () {
    testWidgets('标识符用等宽字体，不是比例字体', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      final bundleId = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .firstWhere((w) => w.data == 'com.example.demo');
      expect(bundleId.style?.fontFamily, iosMonoFontFamily);

      // 可执行文件名与哈希也走等宽 —— 它们同样要逐字比对。
      expect(_cardWithTitle(tester, t.ios_info.executable)?.monospace, isTrue);
      expect(_cardWithTitle(tester, t.file_info.sha256)?.monospace, isTrue);
      expect(_cardWithTitle(tester, t.ios_info.minimum_os)?.monospace, isFalse);
    });

    testWidgets('全部键值卡片都走 iOS 卡片样式，没有一张是裸 Card', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      // 页面上的每一张键值卡片都是 IosInfoCard；出现裸 Card + TitleValueLayout
      // 就说明某个分支漏掉了 iOS 样式。
      expect(_cards(tester), isNotEmpty);
      expect(
        find.byType(TitleValueLayout),
        findsNWidgets(_cards(tester).length),
      );
    });

    testWidgets('Android 专属字段不出现在 IPA 页面上', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      final text = _visibleText(tester);
      for (final androidOnly in [
        t.apk_info.package_name,
        t.apk_info.min_sdk,
        t.apk_info.target_sdk,
        t.apk_info.abi,
        t.apk_info.permissions,
        t.apk_info.components,
      ]) {
        expect(text, isNot(contains(androidOnly)),
            reason: '「$androidOnly」是 Android 字段，不该出现在 IPA 页面');
      }
    });

    testWidgets('长文本不设 maxLines，避免把签名与诊断裁掉', (tester) async {
      await _pumpPage(tester, _state(analysis: _analysis()));

      // maxLines 是裁剪而不是溢出滚动，设了就等于隐藏超出的行。
      for (final card in _cards(tester)) {
        expect(card.maxLines, isNull,
            reason: '「${card.title}」设了 maxLines，超出部分会被裁掉');
      }
    });
  });
}
