// 侧边栏：宽度、导航文案、以及「不再重复应用名与版本号」。
//
// V2.4.6 的三项调整都在这里钉住：
// 1. 展开宽度 240 → 200（导航项只有四个、标签最长两个字，240px 里近一半是
//    空白，而右侧内容区为此少 40px）；
// 2. 导航项「版本对比」→「对比」（窄栏里四字标题会把图标挤到贴边）；
// 3. **侧边栏不再显示应用名与版本号** —— 应用名在窗口标题栏上已经有了，
//    版本号在设置页有一份。同一件事说三次，还占掉窄栏里最值钱的纵向空间。
//
// 第 3 条是「不显示」，而「不显示」没有天然的可断言物 —— 因此这里同时断言
// 正向的（导航项都在）与反向的（应用名、版本号不在），免得日后有人把标题
// 加回来而测试还是绿的。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ui/shell/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpSidebar(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              AppSidebar(selectedId: 'overview', onItemSelected: (_) {}),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

String _text(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(w.data ?? '');
  }
  return buffer.toString();
}

void main() {
  group('侧边栏', () {
    testWidgets('展开宽度是 200（不是 240）', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));

      final sidebar = tester.getSize(find.byType(AppSidebar));
      expect(sidebar.width, kSidebarWidth);
      expect(sidebar.width, 200);
    });

    testWidgets('窄窗口退化成 64px 紧凑模式', (tester) async {
      await _pumpSidebar(tester, const Size(700, 800));

      expect(tester.getSize(find.byType(AppSidebar)).width, 64);
    });

    testWidgets('导航项都在，且「版本对比」已简化成「对比」', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));
      final text = _text(tester);

      expect(text, contains(t.nav.overview));
      expect(text, contains(t.nav.analysis));
      expect(text, contains(t.nav.diff));
      expect(text, contains(t.nav.settings));

      // 窄栏放不下四字标题：中文下应当是「对比」而不是「版本对比」。
      // （英文本来就是 Compare，这条断言在 en 下等价于「不是 Version …」。）
      expect(t.nav.diff, isNot(contains('版本')));
      expect(t.nav.diff, isNot(contains('Version')));
    });

    testWidgets('不再显示应用名与副标题', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));
      final text = _text(tester);

      expect(text, isNot(contains(t.title)), reason: '应用名已经在窗口标题栏上，侧边栏不该再说一遍');
      expect(text, isNot(contains(t.base.app_subtitle)),
          reason: '副标题是纯噪音，还占掉窄栏的纵向空间');
    });

    testWidgets('不再显示版本号', (tester) async {
      await _pumpSidebar(tester, const Size(1280, 800));

      // 版本号在设置页有一份；侧边栏底部此前还有一份（紧凑模式下甚至是竖排的）。
      // 这里断言没有任何 `v<数字>` 形态的文本。
      final versionLike = RegExp(r'^v\d+\.\d+');
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        expect(
          versionLike.hasMatch(w.data ?? ''),
          isFalse,
          reason: '侧边栏不该出现版本号：${w.data}',
        );
      }
    });
  });
}
