// 重命名对话框的表单验证。
//
// 此前 `GlobalKey<FormFieldState>()`（缺泛型参数）导致 `currentState`
// 返回 null，因为 Dart 泛型默认不可变：`FormFieldState<String>` is-not
// `FormFieldState<dynamic>`。点击「确定」时 `validate()` 根本不走，
// 用户看到的是「点了没反应」。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Rename dialog — formKey 类型', () {
    testWidgets('GlobalKey<FormFieldState<String>> 能正确找到 TextFormField 的 state',
        (tester) async {
      final formKey = GlobalKey<FormFieldState<String>>();
      final controller = TextEditingController(text: 'test.apk');

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: TextFormField(
                key: formKey,
                controller: controller,
                validator: (value) {
                  if (value == null || value.isEmpty) return 'empty';
                  if (!value.endsWith('.apk')) return 'bad suffix';
                  return null;
                },
              ),
            ),
          ),
        ),
      );

      // key 必须能拿到 state，否则就是泛型不匹配的老问题。
      expect(formKey.currentState, isNotNull,
          reason:
              'GlobalKey<FormFieldState<String>> 必须能找到 TextFormField 的 state');

      // 有效值 → validate 返回 true
      expect(formKey.currentState!.validate(), isTrue);

      // 无效值 → validate 返回 false
      controller.text = 'bad';
      await tester.pump();
      expect(formKey.currentState!.validate(), isFalse);
    });
  });
}
