/// 平台中立的应用图标提取入口。
///
/// ## 谁在用
///
/// - **Windows 缩略图处理器**：COM DLL 起一个本包的 AOT 可执行文件，
///   传文件路径，拿 PNG 字节写回 `IStream`；
/// - **主应用**：设置页的「系统文件图标」诊断区，用来确认「同一个包，
///   扩展拿到的图标与界面显示的是不是同一张」。
///
/// ## 为什么单独成包
///
/// 现有能力分散在 `lib/`（Flutter 应用层）与四个解析包里。应用层的
/// `adaptive_icon_renderer.dart` 依赖 `dart:ui`，**无法 AOT**；
/// 而两平台的解析器是纯 Dart 的。把它们之间那条可复用的边界明确下来，
/// 才能让原生扩展和主应用**跑同一份代码**，而不是各写一份再对齐。
library;

import 'src/app_icon_result.dart';
import 'src/apk_icon.dart';
import 'src/ipa_icon.dart';
import 'src/limits.dart';

export 'src/app_icon_result.dart';
export 'src/limits.dart';
// 图片头解析整体导出：调用方（原生侧的自检、主应用的诊断区）需要
// 「这段字节是什么格式、多大」这两个结论，而不只是 PNG 那一支。
export 'src/image_probe.dart';

/// 按扩展名分发到对应平台的提取器。
///
/// 分发依据是**扩展名**而不是内容嗅探：文件管理器是按扩展名把请求交给
/// 我们的，扩展名与内容不一致本身就是异常输入，此时按扩展名走能给出
/// 更准确的诊断（「明明是 .ipa 却不像 IPA」比「不知道这是什么」有用）。
Future<AppIconResult> extractAppIcon(
  String filePath, {
  IconLimits limits = const IconLimits(),
}) {
  final lower = filePath.toLowerCase();
  if (lower.endsWith('.apk')) {
    return extractApkIcon(filePath, limits: limits);
  }
  if (lower.endsWith('.ipa')) {
    return extractIpaIcon(filePath, limits: limits);
  }
  return Future.value(AppIconResult.failure(
    AppIconStatus.unsupported,
    'input.unsupported_extension',
    detail: 'only ${limits.allowedExtensions.join(", ")} are supported',
  ));
}
