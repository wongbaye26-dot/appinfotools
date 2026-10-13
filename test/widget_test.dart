// 冒烟测试：确保应用能够构建出根 Widget。
//
// 历史上这里放的是 Flutter 模板自带的计数器测试，但本应用并没有计数器，
// 该测试既无法验证任何真实行为，又会成为 CI 的噪声。真正的回归测试位于
// test/utils_test.dart 与 test/split_type_test.dart。

import 'package:apk_info_tool/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app builds a root widget', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(tester.takeException(), isNull);
  });
}
