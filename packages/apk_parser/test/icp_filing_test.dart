// ICP 备案号的识别。
//
// 背景：工信部 2023 年起要求应用在界面展示备案号，但 `AndroidManifest.xml`
// 里**没有**标准字段放它 —— 各家写在各处（关于页文案、应用名后缀、自定义
// meta-data）。唯一不依赖各家实现的位置是 `resources.arsc` 的字符串池。
//
// 因此这里的正则是「从一堆字符串里挑出备案号」，而它的**误报**代价很高：
// 挑错一个数字串展示成「备案号」，用户会以为这个包有备案。所以正例反例都钉。
//
// 真实样本（2026-10-17 实测，样本不入库）：
// - `抖音-v40.7.0.apk` 的字符串池里有一条独立的 `京ICP备16016397号-49A`；
// - `飞牛-v1.37.1.apk` 一条都没有 —— 所以界面必须「取不到就不显示」。

import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

List<String> scan(List<String> values) => IcpFilingScanner.scanValues(values);

void main() {
  group('ICP 备案号：正例', () {
    test('标准形态：省份 + ICP备 + 8 位 + 号 + 序号字母', () {
      expect(scan(['京ICP备16016397号-49A']), ['京ICP备16016397号-49A']);
    });

    test('不带序号', () {
      expect(scan(['沪ICP备12345678号']), ['沪ICP备12345678号']);
    });

    test('不带省份简称也合法', () {
      expect(scan(['ICP备2021000000号-1']), ['ICP备2021000000号-1']);
    });

    test('「证」是经营性许可，格式相同', () {
      expect(scan(['粤ICP证030173号']), ['粤ICP证030173号']);
    });

    test('繁体「證」也认', () {
      expect(scan(['粵ICP證030173號']), ['粵ICP證030173號']);
    });

    test('夹在一段文案里也能取出来', () {
      expect(
        scan(['备案号：京ICP备16016397号-49A 版权所有']),
        ['京ICP备16016397号-49A'],
      );
    });

    test('数字与号之间、ICP 与备之间有空格（半角与全角）', () {
      expect(scan(['京 ICP 备 16016397 号 - 49A']), ['京 ICP 备 16016397 号 - 49A']);
      expect(scan(['京ICP备 16016397 号']), ['京ICP备 16016397 号']);
    });

    test('去掉省份前缀的歧义：前一个汉字不是简称时不吃进来', () {
      // `[\u4e00-\u9fa5]{0,1}` 的写法会把「案」一起吃进来。
      expect(scan(['备案ICP备2021000000号']), ['ICP备2021000000号']);
    });

    test('多条按出现顺序返回，并去重', () {
      expect(
        scan(['京ICP备16016397号-49A', '粤ICP证030173号', '京ICP备16016397号-49A']),
        ['京ICP备16016397号-49A', '粤ICP证030173号'],
      );
    });

    test('全部省级简称（含繁体写法）都能识别', () {
      for (final code in IcpFilingScanner.provinceCodes.split('')) {
        expect(
          scan(['${code}ICP备12345678号']),
          ['${code}ICP备12345678号'],
          reason: '$code 是省级简称，应当被识别',
        );
      }
    });
  });

  group('ICP 备案号：反例（宁可漏报，不要误报）', () {
    test('只有 ICP 三个字母', () {
      expect(scan(['ICP']), isEmpty);
    });

    test('ICP 后面没有「备 / 证」——例如类名 PlayletSeriesICPModule', () {
      expect(scan(['com.ss.android.ugc.aweme.playlet.PlayletSeriesICPModule']),
          isEmpty);
      expect(scan(['ICPModule']), isEmpty);
      expect(scan(['icp备案']), isEmpty, reason: '小写 icp 不是备案号的写法');
    });

    test('备案字样但没有足够的数字', () {
      expect(scan(['ICP备']), isEmpty);
      expect(scan(['ICP备123']), isEmpty, reason: '主体编号至少 5 位');
      expect(scan(['ICP备ABCDEF']), isEmpty);
    });

    test('没有「ICP」三个字母', () {
      expect(scan(['京备16016397号-49A']), isEmpty);
      expect(scan(['']), isEmpty);
      expect(scan(['普通的中文字符串']), isEmpty);
    });

    test('空输入与全是无关字符串', () {
      expect(scan(const []), isEmpty);
      expect(scan(['a', 'b', 'ICP', 'not a filing']), isEmpty);
    });
  });
}
