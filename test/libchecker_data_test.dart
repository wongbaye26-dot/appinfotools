// 打包进应用的 LibChecker 规则资产。
//
// 这一组断言的是「资产能读、读数符合预期」：规则文件是脚本生成的二进制
// JSON，一旦生成参数或数据版本变了，匹配层不会报错，只会静默少识别 ——
// 所以这里钉住版本、条数与几条已知规则。

import 'package:apk_info_tool/utils/libchecker_data.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(LibCheckerData.resetForTest);
  tearDown(LibCheckerData.resetForTest);

  group('LibCheckerData', () {
    test('资产可解析，版本与条数符合预期', () async {
      final rules = await LibCheckerData.ensureLoaded();
      expect(rules.dataVersion, 50);
      expect(rules.regexCompileFailures, isEmpty);
      // 3053 条里 14 条 static 不参与匹配。
      expect(rules.usableRuleCount, 3039);

      final counts = rules.countByType();
      expect(counts[LibCheckerRuleType.native], 1636);
      expect(counts[LibCheckerRuleType.dex], 82);
      expect(counts[LibCheckerRuleType.action], 107);
    });

    test('常见 SDK 规则能命中', () async {
      final rules = await LibCheckerData.ensureLoaded();
      final flutter = rules.find(LibCheckerRuleType.native, 'libflutter.so');
      expect(flutter?.label, 'Flutter');

      // DEX 规则名是包名前缀；OkHttp 的规则是 `okhttp3\.(.*)` 这种正则。
      expect(
        rules.find(LibCheckerRuleType.dex, 'okhttp3.internal'),
        isNotNull,
      );

      final activity = rules.find(
        LibCheckerRuleType.activity,
        'com.facebook.FacebookActivity',
      );
      expect(activity, isNotNull);
    });

    test('规则详情按语言取到开发者与说明', () async {
      final rules = await LibCheckerData.ensureLoaded();
      final flutter = rules.find(LibCheckerRuleType.native, 'libflutter.so')!;
      final detail = rules.detailFor(flutter, 'en');
      expect(detail, isNotNull);
      expect(detail!.description, isNotEmpty);
    });

    test('重复调用只解析一次', () async {
      final first = await LibCheckerData.ensureLoaded();
      final second = await LibCheckerData.ensureLoaded();
      expect(identical(first, second), isTrue);
      expect(LibCheckerData.loaded, same(first));
    });
  });
}
