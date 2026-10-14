import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'shell_navigation.g.dart';

/// AppShell 的导航目标。
///
/// 各页面可通过写入此 provider 请求切换到指定导航项，
/// 无需持有 BuildContext 或回调函数。
@riverpod
class ShellNavigation extends _$ShellNavigation {
  @override
  String build() => 'analysis';

  void navigate(String targetId) {
    state = targetId;
  }
}
