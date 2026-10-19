/// Android 侧的应用图标提取（纯 Dart，不依赖 Flutter 引擎）。
///
/// ## 与 `lib/apkparser/adaptive_icon_renderer.dart` 的关系
///
/// 那个渲染器能合成 `<adaptive-icon>`（前景 + 背景 + 遮罩），但它依赖
/// `dart:ui` 的 `Canvas` / `PictureRecorder` / `toImage` —— 这些由 **Flutter
/// 引擎**提供，`dart compile exe` 编不过（实测：`Method not found: 'Paint'`）。
///
/// 因此本文件**只走位图路线**：从 `resources.arsc` 找到图标资源条目，
/// 直接取那份 PNG。拿不到就明确报 `unsupported`，交给系统回退文件图标；
/// **绝不把一个矢量 XML 当成图片交出去**，也绝不猜测。
///
/// 自适应图标的纯 Dart 光栅化是后续独立工作项（见
/// `docs/plans/V2.5.0-system-icon-feasibility.md` §6.3）。
library;

import 'dart:io';

import 'package:apk_parser/apk_parser.dart';
import 'package:path/path.dart' as path;

import 'app_icon_result.dart';
import 'limits.dart';
import 'image_probe.dart';

/// 单个包最多尝试几个密度变体。
///
/// 真实 APK 通常提供 4–6 个 `mipmap-*dpi` 变体；超过这个数还在找，
/// 说明这份资源表要么被塞了垃圾，要么图标声明指向了一个异常条目。
/// 为缩略图请求遍历几百个条目是不可接受的（那是 Explorer 的同步路径）。
const int _kMaxDensityCandidates = 6;

/// 从 APK 提取图标。
///
/// 返回的 [AppIconResult] 永远不是 `null`：失败也用状态 + 稳定 code 表达，
/// 因为调用方（原生扩展）无法区分「没图标」与「抛异常了」时只能静默失败，
/// 而静默失败会让「我们没查」看起来像「这个包没有图标」。
Future<AppIconResult> extractApkIcon(
  String filePath, {
  IconLimits limits = const IconLimits(),
}) async {
  // ---- 1. 扩展名与体积：**在打开归档之前**判，避免为大文件分配任何内存 ----
  final ext = path.extension(filePath).toLowerCase();
  if (!limits.allowedExtensions.contains(ext)) {
    return AppIconResult.failure(
      AppIconStatus.unsupported,
      'input.unsupported_extension',
      detail: 'only ${limits.allowedExtensions.join(", ")} are supported',
    );
  }
  final File file = File(filePath);
  final int fileLength;
  try {
    if (!file.existsSync()) {
      return const AppIconResult.failure(
        AppIconStatus.invalidInput,
        'input.not_found',
        detail: 'the file does not exist',
      );
    }
    fileLength = file.lengthSync();
  } on FileSystemException catch (e) {
    return AppIconResult.failure(
      AppIconStatus.invalidInput,
      'input.unreadable',
      detail: e.message,
    );
  }
  if (fileLength > limits.maxFileBytes) {
    return AppIconResult.failure(
      AppIconStatus.resourceLimit,
      'input.file_too_large',
      detail: '$fileLength bytes exceeds ${limits.maxFileBytes}',
    );
  }
  if (fileLength == 0) {
    return const AppIconResult.failure(
      AppIconStatus.invalidInput,
      'input.empty',
      detail: 'the file is empty',
    );
  }

  // ---- 2. 打开归档（复用 APK 解析器的完整安全判定）----
  final reader = ApkReader();
  try {
    final openResult = await reader.open(filePath);
    if (!openResult.isOk) {
      return _mapOpenFailure(openResult, reader.budgetFailure);
    }

    final entryCount = reader.listFiles().length;
    if (entryCount > limits.maxArchiveEntries) {
      return AppIconResult.failure(
        AppIconStatus.resourceLimit,
        'archive.too_many_entries',
        detail: '$entryCount entries exceeds ${limits.maxArchiveEntries}',
      );
    }

    final meta = await reader.parse();
    if (meta == null) {
      return AppIconResult.failure(
        AppIconStatus.invalidInput,
        'android.manifest_unreadable',
        detail:
            reader.manifestFailure ?? 'AndroidManifest.xml could not be parsed',
      );
    }

    // ---- 3. 收集候选：density → 归档路径 ----
    final candidates = _iconCandidates(meta);
    if (candidates.isEmpty) {
      return const AppIconResult.failure(
        AppIconStatus.unsupported,
        'android.no_icon_declared',
        detail: 'AndroidManifest.xml declares no android:icon, or the '
            'resource could not be resolved through resources.arsc',
      );
    }

    // ---- 4. 按密度从高到低尝试，取第一份可识别的图片 ----
    //
    // 只试前 N 个：缩略图请求是 Explorer 的同步路径，遍历整张资源表
    // 会让「打开一个文件夹」变成一次磁盘风暴。
    //
    // **接受 PNG / WebP / JPEG / GIF**，不在这里转码。理由见
    // `AppIconFormat` 的注释：解码是调用方（Windows WIC）的事，
    // 本包只负责「从包里准确取出那一份字节」。
    var sawVector = false;
    var sawOversized = false;
    var sawUnknownFormat = false;
    for (final candidate in candidates.take(_kMaxDensityCandidates)) {
      final bytes = reader.readFile(candidate.path);
      if (bytes == null) continue;

      // 二进制 XML：自适应图标 / 矢量图。纯 Dart 侧还不能合成。
      if (isAndroidBinaryXml(bytes)) {
        sawVector = true;
        continue;
      }

      final format = detectFormat(bytes);
      if (format == AppIconFormat.unknown) {
        sawUnknownFormat = true;
        continue;
      }

      final size = imagePixelSize(bytes);
      if (size != null &&
          (size.$1 > limits.maxIconPixels || size.$2 > limits.maxIconPixels)) {
        sawOversized = true;
        continue;
      }
      if (bytes.length > limits.maxIconBytes) {
        sawOversized = true;
        continue;
      }
      return AppIconResult.success(
        bytes: bytes,
        format: format,
        source: candidate.source,
        pixelWidth: size?.$1,
        pixelHeight: size?.$2,
      );
    }

    if (sawOversized) {
      return AppIconResult.failure(
        AppIconStatus.resourceLimit,
        'android.icon_too_large',
        detail: 'every candidate exceeded ${limits.maxIconPixels}px or '
            '${limits.maxIconBytes} bytes',
      );
    }
    if (sawVector) {
      return const AppIconResult.failure(
        AppIconStatus.unsupported,
        'android.adaptive_icon_unsupported',
        detail: 'the icon is an <adaptive-icon> / <vector> XML: composing it '
            'requires rasterisation that is not available without the Flutter '
            'engine',
      );
    }
    if (sawUnknownFormat) {
      return const AppIconResult.failure(
        AppIconStatus.unsupported,
        'android.icon_format_unsupported',
        detail: 'the icon resource resolved to bytes that are not a known '
            'image format (PNG / WebP / JPEG / GIF)',
      );
    }
    // 所有候选都读不出来（`readFile` 返回 null）：预算拒绝或条目消失。
    return const AppIconResult.failure(
      AppIconStatus.invalidInput,
      'android.icon_entries_unreadable',
      detail: 'every candidate entry could not be read',
    );
  } finally {
    // worker 之外没有别的清理点：这里必须释放归档句柄，
    // 否则缩略图请求频繁时 Windows 会锁住文件。
    reader.close();
  }
}

List<({int density, String path, AppIconSource source})> _iconCandidates(
  ApkMeta meta,
) {
  final out = <({int density, String path, AppIconSource source})>[];
  for (final entry in meta.iconPaths.entries) {
    out.add((
      density: entry.key,
      path: entry.value,
      source: AppIconSource.androidResourcePng,
    ));
  }
  if (out.isEmpty) {
    final declared = meta.applicationIcon;
    // 只认归档内的相对路径：`@res/0x...` 没能解析成路径时不能瞎读。
    if (declared != null &&
        declared.isNotEmpty &&
        !declared.startsWith('@') &&
        !declared.startsWith('/')) {
      out.add((
        density: 0,
        path: declared,
        source: AppIconSource.androidManifestPath,
      ));
    }
  }
  // density 越大越清晰；`anydpi` 之类的特殊值排在其后由内容判定。
  out.sort((a, b) => b.density.compareTo(a.density));
  return out;
}

/// 归档打开失败 → 结果状态。
///
/// `resourceBudgetExceeded` 必须与「文件坏了」分开：前者是我们主动拒绝，
/// 后者是输入本身有问题。用户在文件管理器里看到的行为一样（回退文件图标），
/// 但诊断日志里的结论完全不同。
AppIconResult _mapOpenFailure(ArchiveOpenResult result, String? budgetFailure) {
  return switch (result) {
    ArchiveOpenResult.notArchive => const AppIconResult.failure(
        AppIconStatus.invalidInput,
        'archive.not_zip',
        detail: 'the file does not start with a ZIP signature',
      ),
    ArchiveOpenResult.corrupt => const AppIconResult.failure(
        AppIconStatus.invalidInput,
        'archive.corrupt',
        detail: 'the archive structure is broken',
      ),
    ArchiveOpenResult.resourceBudgetExceeded => AppIconResult.failure(
        AppIconStatus.resourceLimit,
        'archive.budget_exceeded',
        detail: budgetFailure,
      ),
    ArchiveOpenResult.ioError => const AppIconResult.failure(
        AppIconStatus.invalidInput,
        'archive.io_error',
        detail: 'the file could not be read',
      ),
    ArchiveOpenResult.ok => const AppIconResult.failure(
        AppIconStatus.invalidInput,
        'archive.unexpected_ok',
      ),
  };
}
