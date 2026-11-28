import 'dart:io';

import 'package:apk_info_tool/utils/recent_icon_cache.dart';
import 'package:flutter/material.dart';

/// 最近文件条目里的应用图标。
///
/// 图标由 [RecentIconCache] 在解析完成时写入缓存目录；这里只在缓存命中时
/// 读文件，未命中（首次打开、缓存被清理、图标提取失败）就退回平台图标。
/// 异步读取期间先画占位底色，避免列表在滚动时跳动。
class RecentAppIcon extends StatefulWidget {
  /// 缓存文件名（不是绝对路径），见 [RecentFileEntry.iconFile]。
  final String? iconFile;

  /// 缓存缺失时的兜底图标（Android / iOS / 未知）。
  final IconData fallback;

  final Color fallbackColor;

  /// 外框边长。
  final double size;

  /// 圆角；默认取 [size] 的 22%。
  final double? radius;

  const RecentAppIcon({
    super.key,
    required this.iconFile,
    required this.fallback,
    required this.fallbackColor,
    this.size = 32,
    this.radius,
  });

  @override
  State<RecentAppIcon> createState() => _RecentAppIconState();
}

class _RecentAppIconState extends State<RecentAppIcon> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant RecentAppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.iconFile != widget.iconFile) _resolve();
  }

  Future<void> _resolve() async {
    final file = await RecentIconCache.fileFor(widget.iconFile);
    if (!mounted) return;
    if (file?.path == _file?.path) return;
    setState(() => _file = file);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = _file;
    final radius = widget.radius ?? widget.size * 0.22;

    Widget fallback() => Center(
          child: Icon(
            widget.fallback,
            size: widget.size * 0.5,
            color: widget.fallbackColor,
          ),
        );

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: file == null
          ? fallback()
          : Image.file(
              file,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback(),
            ),
    );
  }
}
