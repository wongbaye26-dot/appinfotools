// Tab 跳转总线：轻量事件通道，只为让概览里的「查看证书详情」能切到签名 Tab。
//
// 真正的 TabBarView 在测试环境会被替换成连续列表（见 DetailTabView 的
// `_isTest`），所以这里只验证事件语义：seq 递增、重置清空。

import 'package:apk_info_tool/ui/detail_tab_bus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(DetailTabBus.reset);
  tearDown(DetailTabBus.reset);

  test('每次请求都递增 seq，连续请求同一 Tab 也算两次', () {
    expect(DetailTabBus.requests.value, isNull);

    DetailTabBus.request('signature');
    final first = DetailTabBus.requests.value!;
    expect(first.tab, 'signature');
    expect(first.seq, 1);

    DetailTabBus.request('signature');
    final second = DetailTabBus.requests.value!;
    expect(second.seq, 2);
  });

  test('reset 清空请求', () {
    DetailTabBus.request('permissions');
    DetailTabBus.reset();
    expect(DetailTabBus.requests.value, isNull);
  });
}
