import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/system_thumbnail.dart';
import 'package:flutter/material.dart';

/// 「系统文件图标」的设置区块。
///
/// ## 为什么单独成 widget
///
/// 1. **可测**：状态与回调由外部注入，因此可以在 macOS / Linux 上真实渲染
///    并驱动（不需要伪造 `Platform.isWindows`）。留在 `setting_page.dart` 里
///    时，整块被平台判断门控，测试只能跳过 —— 那是「没验证」而不是「通过」。
/// 2. `setting_page.dart` 已经 1400+ 行，一块系统集成逻辑不该继续堆在里面。
///
/// ## 状态显示的三条规矩
///
/// 1. **不可用必须说清是哪一步不可用**：DLL 缺失、helper 缺失、注册指向旧路径，
///    三种情况的补救动作完全不同，压成一个「不可用」用户没有任何可执行的下一步；
/// 2. **不显示虚假成功**：只有 `status.usable` 为真才出现「已启用」；
/// 3. **先报最根本的缺失**：DLL 不在时「未注册」是必然结果，先说「未注册」
///    会把用户引向「点启用」—— 而那一步注定失败。
class SystemIconSection extends StatelessWidget {
  final SystemThumbnailStatus status;

  /// 正在执行注册 / 注销 / 刷新。为真时按钮换成进度指示并禁用。
  final bool busy;

  /// 点「启用 / 停用」。
  final VoidCallback onToggle;

  /// 点「刷新」（通知 Shell 重新读取关联）。
  final VoidCallback onRefresh;

  /// 是否展开「诊断信息」。
  final bool expandDiagnostics;

  const SystemIconSection({
    super.key,
    required this.status,
    required this.busy,
    required this.onToggle,
    required this.onRefresh,
    this.expandDiagnostics = false,
  });

  /// 当前状态的一句话描述。
  ///
  /// 顺序有意义 —— 见类注释第 3 条。抽成静态方法是为了让它能被单独断言：
  /// 这是本区块里唯一有分支逻辑的地方，最值得逐态覆盖。
  static String stateLabel(SystemThumbnailStatus status, Translations t) {
    if (!status.dllPresent) {
      return t.settings.system_icon.state_dll_missing;
    }
    if (!status.helperPresent) {
      return t.settings.system_icon.state_helper_missing;
    }
    if (status.registered) {
      return t.settings.system_icon.state_usable;
    }
    return t.settings.system_icon.state_not_registered;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = t.settings.system_icon;
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Theme(
        // 与设置页其它卡片同一套展开样式（`_buildSettingCard` 的写法）。
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(Icons.image_outlined,
              size: 18, color: theme.colorScheme.primary),
          title: Text(
            icon.title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          initiallyExpanded: expandDiagnostics,
          children: [
            ListTile(
              title: Text(
                status.usable ? icon.hint_on : icon.hint_off,
                style: theme.textTheme.bodyMedium,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  stateLabel(status, t),
                  style: theme.textTheme.bodySmall?.copyWith(
                    // 「已启用」用主色，其余一律 hintColor —— 不用绿色：
                    // 「不可用」不是错误，是「还没做」。
                    color: status.usable
                        ? theme.colorScheme.primary
                        : theme.hintColor,
                  ),
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          // 测试环境里动画会让 `pumpAndSettle` 永不收敛；
                          // 尊重系统的「减少动态效果」即可，测试自己会设。
                          value: reducedMotion ? 0.5 : null,
                        ),
                      ),
                    )
                  else ...[
                    TextButton(
                      onPressed: onToggle,
                      child: Text(status.usable ? icon.disable : icon.enable),
                    ),
                    if (status.usable)
                      TextButton(
                        onPressed: onRefresh,
                        child: Text(icon.refresh),
                      ),
                  ],
                ],
              ),
            ),

            // 路径不一致单独一行：这是最容易被当成「功能坏了」的状态，
            // 而它其实点一下就能修好。两个路径都要显示，否则用户不知道改成哪个。
            if (status.pathMismatch)
              ListTile(
                leading: Icon(Icons.warning_amber_outlined,
                    size: 18, color: theme.colorScheme.error),
                title: Text(
                  icon.state_path_mismatch,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
                subtitle: Text(
                  icon.state_path_mismatch_detail(
                    registered: status.registeredPath,
                    current: status.dllPath,
                  ),
                  style: theme.textTheme.bodySmall,
                ),
                dense: true,
              ),

            // 逐扩展名：`.apk` 挂上、`.ipa` 没挂上时，「已启用」会掩盖一半问题。
            if (status.extensions.isNotEmpty) ...[
              const Divider(height: 1),
              ListTile(
                title: Text(icon.extensions_title,
                    style: theme.textTheme.bodySmall),
                dense: true,
              ),
              for (final entry in status.extensions)
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 32, right: 16),
                  dense: true,
                  title:
                      Text(entry.extension, style: theme.textTheme.bodySmall),
                  trailing: Icon(
                    entry.registered ? Icons.check : Icons.remove,
                    size: 16,
                    color: entry.registered
                        ? theme.colorScheme.primary
                        : theme.hintColor,
                  ),
                  subtitle: Text(
                    entry.registered ? icon.ext_registered : icon.ext_missing,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                ),
            ],

            // 诊断信息：有用，但不该是这块的默认内容。
            if (status.dllPath.isNotEmpty)
              ExpansionTile(
                title: Text(icon.diagnostics, style: theme.textTheme.bodySmall),
                tilePadding: const EdgeInsets.only(left: 16, right: 16),
                childrenPadding:
                    const EdgeInsets.only(left: 32, right: 16, bottom: 8),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      '${icon.diag_dll(path: status.dllPath)}\n'
                      '${icon.diag_helper(
                        present:
                            status.helperPresent ? icon.diag_yes : icon.diag_no,
                      )}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),

            // 已知限制：这一版能做什么、不能做什么。
            // 规格 1.2 明确禁止「统一图标充当已完成」，所以边界必须写在界面上。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                '${icon.limitations}：${icon.limits}',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
