import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:apk_info_tool/utils/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 「最近文件」列表里那个小图标的磁盘缓存。
///
/// **为什么要落盘**：最近文件列表在概览页上常驻，而真实应用图标只能从安装包
/// 里解出来（要开归档、解 arsc / plist、渲染矢量图）。每次重建列表都去解一遍
/// 是不可接受的 —— 那是「打开一个包」的开销，不是「画一行」的开销。
/// 因此在**解析成功那一刻**（图标已经在手上、且已经渲染好了）顺手存一份缩略图。
///
/// **一切失败都是非致命的**：缓存只是让列表好看一点，取不到就退回平台通用
/// 图标。因此这里所有方法都自己兜住异常并返回 `null`/`false`，绝不向上抛 ——
/// 一个画不出来的小图标不该让「记录最近文件」这件事失败。
class RecentIconCache {
  RecentIconCache._();

  /// 缩略图最长边（px）。
  ///
  /// 列表里按 32px 显示，2x / 3x 屏幕下 96px 足够；再大只是白占内存 ——
  /// 列表一次可能画 10 行，512px 的原图解码就是 10 MB 级别的位图。
  static const int thumbnailSize = 96;

  static Directory? _cachedDir;

  /// 是否已经尝试过解析缓存目录。
  ///
  /// 失败也要记住：列表一次最多画 10 行，每行都会问一次缓存 —— 不记住的话
  /// 「平台不支持 path_provider」这条路上会连抛 10 次异常（虽然都被兜住了）。
  static bool _dirResolved = false;

  /// 缓存目录（`<应用支持目录>/recent_icons`），取不到时返回 `null`。
  static Future<Directory?> _directory() async {
    if (_dirResolved) return _cachedDir;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'recent_icons'));
      if (!await dir.exists()) await dir.create(recursive: true);
      _cachedDir = dir;
    } catch (e) {
      // 测试环境里 path_provider 没有平台实现；沙箱里也可能被拒。
      // 「没有缓存目录」是正常状态，不是错误。
      log.fine('RecentIconCache: 无法准备缓存目录: $e');
      _cachedDir = null;
    }
    _dirResolved = true;
    return _cachedDir;
  }

  /// 缓存文件名：由「源路径 + 体积」派生。
  ///
  /// 带上体积是为了让**被替换过的同名文件**拿到新图标 —— 只按路径做键的话，
  /// 用户重新下载了一个同名的包，列表里还是旧图标，而那是错的。
  static String fileNameFor(String sourcePath, int sourceSize) {
    final digest = sha1.convert(utf8.encode('$sourcePath|$sourceSize'));
    return '$digest.png';
  }

  /// 把已渲染的图标写成缩略图，返回缓存文件名；失败返回 `null`。
  ///
  /// [image] 是调用方**已经渲染好的**图标（Android 来自
  /// `AdaptiveIconRenderer`，iOS 来自 `IosIconDecoder`）—— 这里只做缩放与
  /// 编码，不再碰安装包。
  static Future<String?> storeFromImage(
    String sourcePath,
    int sourceSize,
    ui.Image image,
  ) async {
    try {
      final dir = await _directory();
      if (dir == null) return null;

      final name = fileNameFor(sourcePath, sourceSize);
      final target = File(p.join(dir.path, name));

      final bytes = await _encodeThumbnail(image);
      if (bytes == null) return null;

      await target.writeAsBytes(bytes, flush: false);
      return name;
    } catch (e) {
      log.fine('RecentIconCache: 写入缩略图失败: $e');
      return null;
    }
  }

  /// 取缓存文件；文件不存在或缓存目录不可用时返回 `null`。
  static Future<File?> fileFor(String? fileName) async {
    if (fileName == null || fileName.isEmpty) return null;
    // 防目录穿越：文件名只允许是纯文件名。
    if (fileName.contains('/') || fileName.contains('\\')) return null;
    try {
      final dir = await _directory();
      if (dir == null) return null;
      final file = File(p.join(dir.path, fileName));
      return await file.exists() ? file : null;
    } catch (e) {
      log.fine('RecentIconCache: 读取缩略图失败: $e');
      return null;
    }
  }

  /// 删掉不在 [keep] 里的缓存文件。
  ///
  /// 最近文件列表最多 10 条，被挤出去的记录对应的图标不该永远留在磁盘上。
  /// 失败只是漏清一次，不影响功能。
  static Future<void> prune(Set<String> keep) async {
    try {
      final dir = await _directory();
      if (dir == null) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (keep.contains(p.basename(entity.path))) continue;
        try {
          await entity.delete();
        } catch (_) {
          // 单个文件删不掉不影响其它文件。
        }
      }
    } catch (e) {
      log.fine('RecentIconCache: 清理缓存失败: $e');
    }
  }

  /// 把图标缩到 [thumbnailSize] 以内并编码为 PNG。
  ///
  /// 用 `PictureRecorder` + `Canvas`（与 `AdaptiveIconRenderer` 同一条路），
  /// **保持长宽比**：列表里用 `BoxFit.cover` 裁成方形，缩放阶段拉伸会把
  /// 非正方形图标压扁。
  static Future<Uint8List?> _encodeThumbnail(ui.Image image) async {
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) return null;

    final longest = width > height ? width : height;
    final scale = longest > thumbnailSize ? thumbnailSize / longest : 1.0;
    final targetWidth = (width * scale).round().clamp(1, thumbnailSize);
    final targetHeight = (height * scale).round().clamp(1, thumbnailSize);

    if (scale == 1.0) {
      // 已经够小，不必过一遍画布。
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      final scaled = await picture.toImage(targetWidth, targetHeight);
      try {
        final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        scaled.dispose();
      }
    } finally {
      picture.dispose();
    }
  }
}
