/// iOS 侧的应用图标提取（纯 Dart）。
///
/// 与 APK 侧不同，这里的**大部分能力可以直接复用** `ipa_parser`：
/// `IpaIconResolver` 已经是纯 Dart 的（PNG 走 IHDR 读尺寸，`Assets.car`
/// 走 LZFSE 解码 + PNG 编码），不碰 `dart:ui`。
///
/// 本文件只负责三件事：
/// 1. **安全地打开归档**（与 `ApkReader.open` 同一套判据）；
/// 2. 把解析结果映射成 [AppIconResult] 的五态；
/// 3. 施加与 APK 侧**完全相同**的体积 / 像素预算。
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive_safety/archive_safety.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:path/path.dart' as path;

import 'app_icon_result.dart';
import 'limits.dart';
import 'image_probe.dart';

/// 从 IPA 提取图标。
Future<AppIconResult> extractIpaIcon(
  String filePath, {
  IconLimits limits = const IconLimits(),
}) async {
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

  // ---- 打开归档 ----
  //
  // IPA 侧没有 `ApkReader` 那样的现成入口，这里用**同一组原语**拼：
  // 魔数 → 流式解码 → 结构完整性 → 解压预算。判据与
  // `ApkReader.open`（`packages/apk_parser/lib/src/apk_reader.dart:91`）一致；
  // 改那边时这里要同步。
  InputFileStream? inputStream;
  try {
    if (!looksLikeZip(await readArchiveHeader(filePath))) {
      return const AppIconResult.failure(
        AppIconStatus.invalidInput,
        'archive.not_zip',
        detail: 'the file does not start with a ZIP signature',
      );
    }
    inputStream = InputFileStream(filePath);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(inputStream);
    } catch (e) {
      return AppIconResult.failure(
        AppIconStatus.invalidInput,
        'archive.corrupt',
        detail: '$e',
      );
    }
    if (looksStructurallyBroken(archive, fileLength)) {
      return const AppIconResult.failure(
        AppIconStatus.invalidInput,
        'archive.corrupt',
        detail: 'the archive structure is broken',
      );
    }
    final violation = ZipBudget.check(archive);
    if (violation != null) {
      return AppIconResult.failure(
        AppIconStatus.resourceLimit,
        'archive.budget_exceeded',
        detail: violation.describe(),
      );
    }
    if (archive.files.length > limits.maxArchiveEntries) {
      return AppIconResult.failure(
        AppIconStatus.resourceLimit,
        'archive.too_many_entries',
        detail: '${archive.files.length} entries exceeds '
            '${limits.maxArchiveEntries}',
      );
    }

    // ---- 定位主应用与图标 ----
    final container = IpaContainerReader.read(archive);
    final mainApp = container.mainApp;
    if (mainApp == null) {
      return const AppIconResult.failure(
        AppIconStatus.invalidInput,
        'ios.no_main_app',
        detail: 'no Payload/*.app bundle was found',
      );
    }

    // 一次解析一个账本：图标解析可能要读若干条目，共用一个产出预算。
    final ledger = BoundedReadLedger(
      maxTotalBytes: ZipBudgetLimits.maxSessionOutputBytes,
    );
    final info = IpaInfoPlistReader.read(archive, mainApp, ledger: ledger);
    final resolution = IpaIconResolver.resolve(archive, info, ledger: ledger);

    final best = resolution.best;
    if (best == null) {
      final declared = resolution.unresolved.isNotEmpty;
      return AppIconResult.failure(
        AppIconStatus.unsupported,
        declared ? 'ios.icon_unresolved' : 'ios.no_icon_declared',
        detail: declared
            ? '${resolution.unresolved.length} declared icon resource(s) could '
                'not be read'
            : 'Info.plist declares no icon and no Assets.car entry was found',
      );
    }

    final bytes = best.bytes;
    if (bytes == null) {
      // 字节没保留下来（超出解析器自己的保留上限）—— 这是预算问题，
      // 不是「图标不存在」。
      return const AppIconResult.failure(
        AppIconStatus.resourceLimit,
        'ios.icon_bytes_dropped',
        detail: 'the icon was located but its bytes were not retained',
      );
    }
    if (bytes.length > limits.maxIconBytes) {
      return AppIconResult.failure(
        AppIconStatus.resourceLimit,
        'ios.icon_too_large',
        detail: '${bytes.length} bytes exceeds ${limits.maxIconBytes}',
      );
    }
    final size = imagePixelSize(bytes);
    if (size != null &&
        (size.$1 > limits.maxIconPixels || size.$2 > limits.maxIconPixels)) {
      return AppIconResult.failure(
        AppIconStatus.resourceLimit,
        'ios.icon_too_large',
        detail: '${size.$1}x${size.$2} exceeds ${limits.maxIconPixels}px',
      );
    }

    // 与 Android 侧同一口径：不在这里转码，把**原始字节 + 格式**交给调用方。
    // `Assets.car` 路线出来的是解析器自己编码的 PNG；Info.plist 路线可能是
    // PNG，也可能（历史上）是别的格式。
    final format = detectFormat(bytes);
    if (format == AppIconFormat.unknown) {
      return const AppIconResult.failure(
        AppIconStatus.unsupported,
        'ios.icon_format_unsupported',
        detail: 'the extracted icon is not in a known image format',
      );
    }

    return AppIconResult.success(
      bytes: bytes,
      format: format,
      source: best.source == IosIconSource.assetCatalogName
          ? AppIconSource.iosAssetCatalog
          : AppIconSource.iosBundlePng,
      pixelWidth: size?.$1 ?? best.pixelWidth,
      pixelHeight: size?.$2 ?? best.pixelHeight,
    );
  } on FileSystemException catch (e) {
    return AppIconResult.failure(
      AppIconStatus.invalidInput,
      'archive.io_error',
      detail: e.message,
    );
  } catch (e) {
    // 解析器的契约是尽量不抛（畸形处停下记诊断），但归档层仍可能抛。
    // 这里兜住，保证原生扩展永远拿到一个结果而不是异常。
    return AppIconResult.failure(
      AppIconStatus.invalidInput,
      'ios.parse_failed',
      detail: '$e',
    );
  } finally {
    inputStream?.closeSync();
  }
}
