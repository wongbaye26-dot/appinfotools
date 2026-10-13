import 'dart:ui' as ui;

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/ios_icon_decoder.dart';
import 'package:flutter/material.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show IosIconCandidate, IosIconResolution;

/// iOS 图标预览。
///
/// 与 Android 侧的图标区不同，这里**不做候选切换**：iOS 的图标配置通常只
/// 点名一个文件名（`Icon`），`@2x` / `@3x` 是同一张图的不同分辨率，
/// 切换它们对用户没有意义。因此只显示分辨率最高的那一张。
///
/// 三件事必须如实呈现，而不是藏起来：
/// - 声明了但取不到的条目（典型是 `CFBundleIconName` 指向 `Assets.car`）；
/// - 字节没被携带（超过大小上限）；
/// - 解码失败或超出解码预算。
///
/// 规范 5.3 禁止把启动画面、截图或随便一张图当成应用图标 —— 因此这里
/// **只渲染解析器按 `Info.plist` 点名的文件找到的候选**，找不到就说明原因。
///
/// 本文件只负责**画图**：候选清单、来源、「为什么取不到」这些文字由
/// `DetailRenderer.iosIcon` 渲染成普通卡片 —— 与 Android 侧的字段走同一套
/// 版式，两侧才对得齐。
class IosIconThumbnail extends StatelessWidget {
  final IosIconResolution? resolution;
  final double size;

  const IosIconThumbnail({
    super.key,
    required this.resolution,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final candidates = resolution?.candidates ?? const <IosIconCandidate>[];

    if (candidates.isEmpty) {
      // 没有图时**说明原因**，而不是留一个空白框 ——
      // 空白框会被读成「这个包没有图标」。
      return Center(
        child: Text(
          t.ios_info.icon_unavailable,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: IosIconImage(candidate: candidates.first, size: size),
    );
  }
}

/// 单独一个组件承载解码状态。
///
/// 做成 [StatefulWidget] 而不是在父组件里用 `FutureBuilder`：`build` 会被
/// 频繁调用（主题、宽度配置、解析状态变化），每次重建都重新解码同一张图是
/// 纯浪费，而且会反复分配位图。
class IosIconImage extends StatefulWidget {
  final IosIconCandidate candidate;
  final double size;

  const IosIconImage({
    super.key,
    required this.candidate,
    this.size = 96,
  });

  @override
  State<IosIconImage> createState() => _IosIconImageState();
}

class _IosIconImageState extends State<IosIconImage> {
  Future<IosIconDecodeResult>? _decoding;

  @override
  void initState() {
    super.initState();
    _decoding = IosIconDecoder.decode(widget.candidate);
  }

  @override
  void didUpdateWidget(IosIconImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了候选才重新解码 —— 按**归档路径**比较，因为同一张图在不同候选里
    // 可能是同一个路径（解析器已按路径去重）。
    if (oldWidget.candidate.archivePath != widget.candidate.archivePath) {
      _decoding = IosIconDecoder.decode(widget.candidate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    return FutureBuilder<IosIconDecodeResult>(
      future: _decoding,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final result = snapshot.data;
        if (result == null || !result.hasImage) {
          // 没有图时**说明原因**，而不是留一个空白框 ——
          // 空白框会被读成「这个包没有图标」。
          return _placeholder(
            context,
            '${t.ios_info.icon_decode_failed}\n'
            '${result?.failure ?? 'unknown'}',
          );
        }

        return RawImage(
          image: result.image,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.contain,
          filterQuality: ui.FilterQuality.medium,
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, String message) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SingleChildScrollView(
            child: Text(
              message,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
      );
}
