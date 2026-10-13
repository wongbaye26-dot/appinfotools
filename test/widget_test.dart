// 冒烟测试：确保应用能够构建出根 Widget。
//
// 历史上这里放的是 Flutter 模板自带的计数器测试，但本应用并没有计数器，
// 该测试既无法验证任何真实行为，又会成为 CI 的噪声。真正的回归测试位于
// test/utils_test.dart 与 test/split_type_test.dart。
//
// 注意：`MyApp` 依赖两个祖先 Widget，缺一不可 ——
//   1. Riverpod 的 `ProviderScope`：`MyApp` 是 `ConsumerWidget`，
//      `build` 中会 `ref.watch(themeManagerProvider)`；
//   2. slang 的 `TranslationProvider`：`build` 中调用
//      `TranslationProvider.of(context).flutterLocale`。
// 生产入口 `main()` 同时提供了两者，此处必须保持一致，否则测试会以
// `Bad state: No ProviderScope found` 之类与产品逻辑无关的原因失败。
//
// 已验证：`ThemeManager.build()` 只读取 `Config.themeColor.value`（`ConfigItem`
// 自带默认值），不触碰 `Config.gPrefs`，因此无需初始化 SharedPreferences。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app builds a root widget', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(child: TranslationProvider(child: const MyApp())),
    );
    expect(tester.takeException(), isNull);
  });
}
