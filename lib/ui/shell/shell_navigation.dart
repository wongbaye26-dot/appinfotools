import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'shell_navigation.g.dart';

/// 一次导航请求。
@immutable
class ShellNavigationRequest {
  final String target;

  /// 请求序号，每次 [ShellNavigation.navigate] 递增。
  ///
  /// **必须靠它判断「是不是一次新请求」，不能只比 [target]。**
  /// 早先这里只存目标页，于是出现一个很难查的现象：「从概览点『前往分析』
  /// 没反应」。原因是 provider 的初始值恰好就是 `analysis`，而 AppShell
  /// 默认显示 `overview` —— 赋值后值没变化，`ref.listen` 认为无事发生。
  /// 改成事件式（序号递增）后，每次点击都是一次新请求。
  final int seq;

  const ShellNavigationRequest({required this.target, required this.seq});

  @override
  bool operator ==(Object other) =>
      other is ShellNavigationRequest &&
      other.target == target &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(target, seq);
}

/// AppShell 的导航请求通道。
///
/// 各页面通过写入此 provider 请求切换导航项，无需持有 BuildContext。
@riverpod
class ShellNavigation extends _$ShellNavigation {
  @override
  ShellNavigationRequest build() =>
      const ShellNavigationRequest(target: 'overview', seq: 0);

  void navigate(String target) {
    state = ShellNavigationRequest(target: target, seq: state.seq + 1);
  }
}
