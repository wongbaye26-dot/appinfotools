import 'package:flutter/foundation.dart';

/// 一次 Tab 切换请求。
///
/// [seq] 递增：同一个 Tab 连续点两次也要算两次请求，否则点击第二个入口时
/// 监听方会认为「值没变」而不动作。
class DetailTabRequest {
  final String tab;
  final int seq;

  const DetailTabRequest({required this.tab, required this.seq});
}

/// 跨组件请求详情页切换 Tab。
///
/// 为什么不用 provider：`DetailTabView` 是纯 `StatefulWidget`，大量既有测试
/// 直接 pump 它、不带 `ProviderScope`；为了一个跳转把整棵树改成 Consumer 会
/// 让那些测试全部失效。这里用一个进程内的 [ValueNotifier] 传递事件，
/// 监听方仍在 `dispose` 里解绑，语义与 provider 等价但侵入更小。
class DetailTabBus {
  DetailTabBus._();

  static final ValueNotifier<DetailTabRequest?> requests = ValueNotifier(null);

  static int _seq = 0;

  /// 请求切到 [tab]（取值同 `DetailTab.name`）。
  static void request(String tab) {
    requests.value = DetailTabRequest(tab: tab, seq: ++_seq);
  }

  @visibleForTesting
  static void reset() {
    requests.value = null;
    _seq = 0;
  }
}
