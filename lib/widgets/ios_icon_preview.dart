import 'dart:ui' as ui;

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/ios_icon_decoder.dart';
import 'package:flutter/material.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show IosIconCandidate, IosIconResolution, IosIconSource;

/// iOS 图标预览。
///
/// 与 Android 侧的图标区不同，这里**不做候选切换**：iOS 的图标配置通常只
/// 点名一个文件名（`Icon`），`@2x` / `@3x` 是同一张图的不同分辨率，
/// 切换它们对用户没有意义。因此只显示分辨率最高的那一张，其余候选只列出
/// 文件名与尺寸。
///
/// 三件事必须如实呈现，而不是藏起来：
/// - 声明了但取不到的条目（典型是 `CFBundleIconName` 指向 `Assets.car`）；
/// - 字节没被携带（超过大小上限）；
/// - 解码失败或超出解码预算。
///
/// 规范 5.3 禁止把启动画面、截图或随便一张图当成应用图标 —— 因此这里
/// **只渲染解析器按 `Info.plist` 点名的文件找到的候选**，找不到就说明原因。
class IosIconPreview extends StatelessWidget {
  final IosIconResolution? resolution;

  /// 预览框的边长。
  final double size;

  const IosIconPreview({
    super.key,
    required this.resolution,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    final t = TranslationProvider.of(context).translations;
    final resolution = this.resolution;
    final candidates = resolution?.candidates ?? const <IosIconCandidate>[];
    final unresolved = resolution?.unresolved ?? const [];

    if (candidates.isEmpty && unresolved.isEmpty) {
      return _text(context, t.ios_info.icon_unavailable);
    }

    final primary = candidates.isEmpty ? null : candidates.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (primary == null)
          _text(context, t.ios_info.icon_unavailable)
        else
          _candidate(context, primary),
        if (unresolved.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final item in unresolved)
            _line(
              context,
              '${t.ios_info.icon_declared_unresolved}: ${item.declared}'
              '  [${_sourceLabel(item.source, t)}] — ${item.reason}',
            ),
        ],
        if (candidates.length > 1) ...[
          const SizedBox(height: 8),
          _line(context, '${t.ios_info.icon_more_candidates}:'),
          for (final candidate in candidates.skip(1))
            _line(
              context,
              '  ${candidate.relativePath}  ${_sizeLabel(candidate)}'
              '  [${_sourceLabel(candidate.source, t)}]',
            ),
        ],
      ],
    );
  }

  Widget _candidate(BuildContext context, IosIconCandidate candidate) {
    final t = TranslationProvider.of(context).translations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _image(context, candidate),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _line(context, candidate.relativePath),
                  _line(
                    context,
                    '${candidate.format.displayName}  ${_sizeLabel(candidate)}'
                    '  [${_sourceLabel(candidate.source, t)}]',
                  ),
                  _line(context, candidate.archivePath),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 渲染图片本身。
  ///
  /// 解码是异步的，因此用 `FutureBuilder`。**每次重建都会重新解码**这一点
  /// 由 `_decodeFuture` 的缓存规避 —— 这里没有状态，所以把 future 交给
  /// 上游缓存并不合适；改为在 [IosIconImage] 里缓存。
  Widget _image(BuildContext context, IosIconCandidate candidate) => SizedBox(
        width: size,
        height: size,
        child: IosIconImage(candidate: candidate, size: size),
      );

  String _sizeLabel(IosIconCandidate candidate) {
    final width = candidate.pixelWidth;
    final height = candidate.pixelHeight;
    if (width == null || height == null) {
      return '${candidate.size} B';
    }
    return '${width}x$height  ${candidate.size} B';
  }

  static String _sourceLabel(IosIconSource source, Translations t) =>
      switch (source) {
        IosIconSource.primaryIconFiles => t.ios_info.icon_source_primary,
        IosIconSource.alternateIconFiles => t.ios_info.icon_source_alternate,
        IosIconSource.primaryIconFilesIpad => t.ios_info.icon_source_ipad,
        IosIconSource.legacyIconFiles ||
        IosIconSource.legacyIconFile =>
          t.ios_info.icon_source_legacy,
        IosIconSource.assetCatalogName => t.ios_info.icon_source_asset_catalog,
      };

  Widget _text(BuildContext context, String value) => Text(
        value,
        style: Theme.of(context).textTheme.bodyMedium,
      );

  Widget _line(BuildContext context, String value) => SelectableText(
        value,
        style: Theme.of(context).textTheme.bodySmall,
      );
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
