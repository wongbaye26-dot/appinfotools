import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
import 'package:apk_info_tool/widgets/title_value_layout.dart';
import 'package:flutter/material.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show IosIconCandidate, IosIconResolution;

/// iOS 详情页的标识色。
///
/// 用**固定**的 iOS 系统蓝，而不是主题色：主题色可以被用户改成任意取值，
/// 一旦改成和 Android 侧相同的颜色，两页就又分不开了。这里的职责是「一眼
/// 看出这是 iOS 包」，因此需要一个不随主题漂移的锚点。
///
/// 但颜色**不是**唯一的区分手段 —— 分组标题、Hero 卡片、等宽标识符这些
/// 结构上的差异才是主力，颜色只是强化。这样即使主题色恰好也是蓝色，或者
/// 用户有色觉障碍，两页依然分得开。
const Color iosAccent = Color(0xFF007AFF);

/// 等宽字体族。
///
/// 不写 `fontFamily: 'monospace'`：它在 macOS / Windows 上解析不到，会静默
/// 退回默认比例字体 —— 看起来「没生效」但不报错，很难发现。按平台点名系统
/// 自带的等宽字体，桌面三端都有，不需要打包字体资源。
String get iosMonoFontFamily {
  if (Platform.isMacOS || Platform.isIOS) return 'Menlo';
  if (Platform.isWindows) return 'Consolas';
  return 'monospace';
}

/// 值文本的等宽样式。
///
/// 等宽在这里不是装饰：Bundle ID、可执行文件名、UUID、哈希都是要逐字比对的
/// 串，比例字体下 `l` / `1` / `I`、`0` / `O` 很难分辨。
TextStyle iosMonoStyle(BuildContext context) {
  final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
  return base.copyWith(fontFamily: iosMonoFontFamily, fontSize: 13);
}

/// iOS 详情页的分组标题。
///
/// Android 侧是一列平铺的卡片；iOS 侧按语义分组，这是两页最直观的差异 ——
/// 用户不必逐张读卡片标题才知道自己在看「签名」还是「容器」。
class IosSectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const IosSectionHeader({super.key, required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 15,
            decoration: BoxDecoration(
              color: iosAccent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 15, color: iosAccent),
          const SizedBox(width: 6),
          Text(
            title,
            // 字体**显式取自主题**，不靠环境 `DefaultTextStyle` 继承：
            // 这是本页唯一没有 `Material`/`Card` 祖先的组件，一旦页面不在
            // Scaffold 里（测试里就是这样），继承来的会是 `WidgetsApp` 的
            // 报错样式 —— monospace + 下划线 + w900，看起来就是一排色块。
            style: theme.textTheme.labelLarge?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: iosAccent,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Divider(
              height: 1,
              thickness: 1,
              color: iosAccent.withValues(alpha: 0.25),
            ),
          ),
        ],
      ),
    );
  }
}

/// iOS 详情页的键值卡片。
///
/// 与 Android 侧那张 [Card] 的差异是**刻意的**：卡片更圆、底色带一点淡蓝、
/// 有细边框、标题更小更淡。默认圆角与高度来自全局主题，两边用同一套默认值
/// 的话，页面看起来就还是同一个页面。
class IosInfoCard extends StatelessWidget {
  final String title;
  final String value;
  final Widget? end;

  /// 值最多显示多少行。`null` 表示不限制。
  ///
  /// 注意 `maxLines` 是**裁剪**而不是溢出滚动：超出的行根本不会被绘制。
  /// 因此只有「长度可预期的短值」才该设它，签名、容器清单、诊断这类
  /// 内容一旦截断就是在隐藏信息。
  final int? maxLines;

  /// 值是否用等宽字体渲染。
  final bool monospace;

  const IosInfoCard({
    super.key,
    required this.title,
    required this.value,
    this.end,
    this.maxLines,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: iosAccent.withValues(alpha: 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: iosAccent.withValues(alpha: 0.20)),
      ),
      child: TitleValueLayout(
        title: title,
        value: value,
        end: end,
        minLines: 1,
        maxLines: maxLines,
        titleStyle: theme.textTheme.bodyMedium?.copyWith(
          fontSize: 13,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        valueStyle:
            monospace ? iosMonoStyle(context) : theme.textTheme.bodyMedium,
      ),
    );
  }
}

/// iOS 详情页顶部的身份卡片。
///
/// Android 侧的图标是右侧独立的一栏；iOS 侧把图标、平台徽标、应用名、
/// Bundle ID、版本收进同一张卡 —— 打开一个 IPA，用户最先要确认的就是
/// 「这是哪个应用、哪个版本」，这四项应该在第一屏一次看全。
///
/// 图标的诊断（候选清单、未解析原因）放在卡片底部的通栏里，而不是挤在
/// 图标右边的窄栏中：`Assets.car` 那种原因串很长，塞进窄栏会被压成竖排。
class IosHeroCard extends StatelessWidget {
  final IosIconResolution? icon;
  final String badge;
  final String name;
  final String bundleId;

  /// Bundle ID 那一行末尾的附加控件（详情页放复制按钮）。
  ///
  /// 放在这里而不是让调用方再单开一张「Bundle ID」卡片：Bundle ID 是要
  /// 复制去别处用的值，复制入口必须留在它旁边。
  final Widget? bundleIdEnd;

  final String version;

  const IosHeroCard({
    super.key,
    required this.icon,
    required this.badge,
    required this.name,
    required this.bundleId,
    this.bundleIdEnd,
    required this.version,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = TranslationProvider.of(context).translations;
    final candidates = icon?.candidates ?? const [];
    final unresolved = icon?.unresolved ?? const [];
    // 图标诊断的内容判据与 [IosIconDetails] 内部保持一致；不一致的话会出现
    // 「画了分隔线但下面什么都没有」的空档。
    final hasIconNotes = candidates.isNotEmpty || unresolved.isNotEmpty;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 2),
      color: iosAccent.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iosAccent.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 图标固定 72×72 的槽位：无论有没有图、图解码成功与否，
                // 右侧文字都不会跟着上下跳。
                SizedBox(
                  width: 72,
                  height: 72,
                  child: _thumbnail(context, candidates),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _badge(context, badge),
                      const SizedBox(height: 8),
                      SelectableText(
                        name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              bundleId,
                              style: iosMonoStyle(context).copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (bundleIdEnd != null) bundleIdEnd!,
                        ],
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        version,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // 有诊断内容时才画分隔线，避免空卡片底部多出一条横线。
            if (hasIconNotes) ...[
              const SizedBox(height: 12),
              _divider(),
              IosIconDetails(resolution: icon),
            ] else ...[
              // 连候选都没有时，`IosIconDetails` 是空的，但「为什么没有图」
              // 这件事仍要说清楚 —— 只留一个占位方块会被读成「这个包没图标」。
              const SizedBox(height: 12),
              _divider(),
              Text(
                t.ios_info.icon_unavailable,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 图标槽位。
  ///
  /// 没有候选时放一个占位方块，而不是把「未找到可直接预览的图标资源」那行字
  /// 塞进 72px 宽的窄栏 —— 那行字在那里会被裁成半行，看起来像渲染坏了。
  /// 原因本身由卡片底部的说明承担。
  Widget _thumbnail(BuildContext context, List<IosIconCandidate> candidates) {
    if (candidates.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: iosAccent.withValues(alpha: 0.30)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Center(
          child: Icon(Icons.apps_outlined, size: 28, color: iosAccent),
        ),
      );
    }
    return IosIconThumbnail(resolution: icon, size: 72);
  }

  Widget _divider() => Divider(
        height: 1,
        thickness: 1,
        color: iosAccent.withValues(alpha: 0.20),
      );

  Widget _badge(BuildContext context, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: iosAccent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          // 同 [IosSectionHeader]：字体取自主题而不是环境继承。
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: iosAccent,
                letterSpacing: 0.4,
              ),
        ),
      );
}
