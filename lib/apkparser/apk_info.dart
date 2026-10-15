import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/adaptive_icon_renderer.dart';
import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/cancellable_task.dart';
import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/vector_to_svg.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:apk_parser/apk_parser.dart' as apk_parser;
import 'package:apk_parser/apk_parser.dart'
    show
        ApkParseStage,
        HardeningObservation,
        ManifestParser,
        ReferenceCycleReport;
import 'package:path/path.dart' as path;
import 'aapt2_task.dart';
import 'parse_task.dart';
import 'xapk_info.dart';

enum IconCandidateType { bitmap, xmlVector }

class IconCandidate {
  final String path;
  final IconCandidateType type;
  final String? dpiLabel;
  final int? dpiValue;

  Image? renderedImage;
  Uint8List? rawBytes;

  IconCandidate({
    required this.path,
    required this.type,
    this.dpiLabel,
    this.dpiValue,
  });

  /// 从路径推断类型和 DPI，可选传入已知 DPI 值
  factory IconCandidate.fromPath(String entryPath, {int? knownDpi}) {
    final lower = entryPath.toLowerCase();
    final type = (lower.endsWith('.xml'))
        ? IconCandidateType.xmlVector
        : IconCandidateType.bitmap;

    String? dpiLabel;
    int? dpiValue;

    // 从路径目录名中提取 DPI（如 mipmap-xxxhdpi-v4/）
    final dpiMatch = RegExp(r'[/-](nodpi|anydpi(?:-v\d+)?|[a-z]*dpi)(?:[/-])')
        .firstMatch(lower);
    if (dpiMatch != null) {
      dpiLabel = dpiMatch.group(1);
      dpiValue = _dpiLabelToValue(dpiLabel);
    }

    // 如果路径中没找到 DPI，使用已知的 DPI 值
    if (dpiLabel == null && knownDpi != null) {
      dpiValue = knownDpi;
      dpiLabel = _dpiValueToLabel(knownDpi);
    }

    return IconCandidate(
      path: entryPath,
      type: type,
      dpiLabel: dpiLabel,
      dpiValue: dpiValue,
    );
  }

  /// 显示标签，包含文件名以便区分
  String get displayLabel {
    final fileName = path.split('/').last;
    final baseName = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    final dpiText = dpiLabel ?? '?';
    if (type == IconCandidateType.xmlVector) {
      return 'XML $baseName ($dpiText)';
    }
    final ext = fileName.contains('.')
        ? fileName.substring(fileName.lastIndexOf('.') + 1).toUpperCase()
        : '?';
    return '$ext $baseName ($dpiText)';
  }

  void dispose() {
    renderedImage?.dispose();
    renderedImage = null;
  }

  static int? _dpiLabelToValue(String? label) {
    if (label == null) return null;
    return switch (label) {
      'ldpi' => 120,
      'mdpi' => 160,
      'hdpi' => 240,
      'xhdpi' => 320,
      'xxhdpi' => 480,
      'xxxhdpi' => 640,
      'tvdpi' => 213,
      _ => null,
    };
  }

  static String? _dpiValueToLabel(int? value) {
    if (value == null) return null;
    return switch (value) {
      120 => 'ldpi',
      160 => 'mdpi',
      240 => 'hdpi',
      320 => 'xhdpi',
      480 => 'xxhdpi',
      640 => 'xxxhdpi',
      213 => 'tvdpi',
      _ => '${value}dpi',
    };
  }
}

bool _isArchiveApk(String apkPath) {
  final extension = path.extension(apkPath).toLowerCase();
  return extension == '.xapk' || extension == '.apkm' || extension == '.apks';
}

String _archiveTypeFromExtension(String extension) {
  if (extension == '.apkm') return 'APKM';
  if (extension == '.apks') return 'APKS';
  return 'XAPK';
}

enum _ZipContentType { renamedApk, containsApks, notApk }

Future<_ZipContentType> _detectZipContentType(String zipPath) async {
  final zip = ZipHelper();
  try {
    if (!(await zip.open(zipPath)).isOk) return _ZipContentType.notApk;
    final files = zip.listFiles();

    // 检查 ZIP 根目录是否有 AndroidManifest.xml → 说明这是重命名的 APK（优先级最高）
    final hasRootManifest =
        files.any((f) => f.toLowerCase() == 'androidmanifest.xml');

    // 检查是否包含 .apk 文件
    final hasApkFiles = files.any((f) => f.toLowerCase().endsWith('.apk'));

    if (hasRootManifest) return _ZipContentType.renamedApk;
    if (hasApkFiles) return _ZipContentType.containsApks;
    return _ZipContentType.notApk;
  } finally {
    zip.close();
  }
}

final _kSplitAbiTokens = <String>{
  'armeabi',
  'armeabi_v7a',
  'arm64_v8a',
  'x86',
  'x86_64',
  'mips',
  'mips64',
};

final _kSplitDensityTokens = <String>{
  'ldpi',
  'mdpi',
  'hdpi',
  'xhdpi',
  'xxhdpi',
  'xxxhdpi',
  'tvdpi',
};

bool _looksLikeSplitAbi(String value) {
  if (_kSplitAbiTokens.contains(value)) return true;
  return value.contains('v7a') ||
      value.contains('v8a') ||
      value.contains('x86');
}

bool _looksLikeSplitDensity(String value) {
  if (_kSplitDensityTokens.contains(value)) return true;
  return value.endsWith('dpi');
}

final _kSplitLanguagePattern = RegExp(r'^[a-z]{2,3}(-r[a-z]{2})?$');

bool _looksLikeSplitLanguage(String value) {
  return _kSplitLanguagePattern.hasMatch(value);
}

bool _hasOnlyPlaceholderLocales(List<String> locales) {
  if (locales.isEmpty) return false;
  final normalized = locales.map((e) => e.trim().toLowerCase()).toList();
  return normalized.every((e) => e == '--_--' || e == '--');
}

void _inferLocalesAndAbisFromSplits(
  ApkInfo apkInfo,
  List<String> splitApks,
) {
  final needLocales =
      apkInfo.locales.isEmpty || _hasOnlyPlaceholderLocales(apkInfo.locales);
  final needAbis = apkInfo.nativeCodes.isEmpty;
  if (!needLocales && !needAbis) return;

  final locales = <String>[];
  final localesSeen = <String>{};
  final abis = <String>[];
  final abisSeen = <String>{};

  for (final entry in splitApks) {
    final baseName = path.basenameWithoutExtension(entry).toLowerCase();
    String? suffix;
    if (baseName.startsWith('split_config.')) {
      suffix = baseName.substring('split_config.'.length);
    } else if (baseName.startsWith('config.')) {
      suffix = baseName.substring('config.'.length);
    } else {
      continue;
    }

    if (suffix.isEmpty) continue;
    if (needAbis && _looksLikeSplitAbi(suffix)) {
      if (abisSeen.add(suffix)) abis.add(suffix);
      continue;
    }
    if (_looksLikeSplitDensity(suffix)) continue;
    if (needLocales && _looksLikeSplitLanguage(suffix)) {
      if (localesSeen.add(suffix)) locales.add(suffix);
    }
  }

  if (needLocales && locales.isNotEmpty) {
    apkInfo.locales = locales;
  }
  if (needAbis && abis.isNotEmpty) {
    apkInfo.nativeCodes = abis;
  }
}

String? _findBaseApkEntry(List<String> apkEntries) {
  if (apkEntries.isEmpty) return null;
  for (final entry in apkEntries) {
    final name = path.basename(entry).toLowerCase();
    if (name == 'base.apk' || name.endsWith('/base.apk')) {
      return entry;
    }
  }
  for (final entry in apkEntries) {
    final name = path.basename(entry).toLowerCase();
    if (!name.contains('config.')) {
      return entry;
    }
  }
  return apkEntries.first;
}

/// 归档容器层就打开失败，携带可供 UI 展示的具体原因。
///
/// 这里刻意抛异常而不是返回 `null`：`null` 会让「不是归档」「归档损坏」
/// 「命中解压预算」「IO 失败」四种情况全部退化成同一句「解析失败」，
/// 既掩盖真实原因，也让安全拒绝（解压预算）无法被单独呈现。
class ApkOpenException implements Exception {
  final apk_parser.ArchiveOpenResult result;
  final String filePath;

  ApkOpenException(this.result, this.filePath);

  @override
  String toString() => 'ApkOpenException($filePath): ${result.description}';
}

/// 解析被用户取消。
///
/// 单独成类型是为了让 UI 能区分「用户主动取消」与「解析失败」——
/// 前者不该弹错误提示。
class ApkParseCancelledException implements Exception {
  const ApkParseCancelledException();

  @override
  String toString() => 'ApkParseCancelledException';
}

Future<ApkInfo?> getApkInfo(
  String apk, {
  void Function(ApkParseStage stage)? onStage,
  void Function(CancellableParseTask task)? onTaskStarted,
}) async {
  log.info("getApkInfo: apk=[$apk] start");
  final apkInfo = ApkInfo();
  apkInfo.apkPath = apk;
  apkInfo.apkSize = File(apk).lengthSync();

  // ZIP 文件智能检测：区分重命名的 APK 和包含多个 APK 的压缩包
  final extension = path.extension(apk).toLowerCase();
  bool zipAsArchive = false;

  if (extension == '.zip') {
    final zipType = await _detectZipContentType(apk);
    log.fine("getApkInfo: ZIP content type=$zipType");
    if (zipType == _ZipContentType.containsApks) {
      zipAsArchive = true;
    } else if (zipType == _ZipContentType.notApk) {
      log.warning("getApkInfo: ZIP file contains no APK content");
      return null;
    }
    // renamedApk: fall through to aapt2 direct parsing
  }

  // 检查是否为XAPK/APKM/APKS格式，或 ZIP 内含多个 APK
  if (_isArchiveApk(apk) || zipAsArchive) {
    log.fine("getApkInfo: parsing archive file (zipAsArchive=$zipAsArchive)");
    apkInfo.isXapk = true;
    apkInfo.archiveType =
        zipAsArchive ? 'ZIP' : _archiveTypeFromExtension(extension);

    final totalSw = Stopwatch()..start();
    var zipOpenMs = 0;
    var manifestMs = 0;
    var extractMs = 0;
    var aapt2Ms = 0;
    var parseMs = 0;
    var iconMs = 0;

    // XAPK/APKM/APKS 路径仍走 aapt2 子进程，阶段粒度只能到「打开容器 / 完成」。
    // 不为此编造中间阶段 —— 进度必须反映真实发生的事情。
    onStage?.call(ApkParseStage.openContainer);

    // 共享同一个 ZipHelper 实例，避免重复打开同一个大文件
    final zip = ZipHelper();
    Directory? tempDir;
    String? baseApkPath;
    XapkManifest? manifest;
    try {
      final zipOpenSw = Stopwatch()..start();
      final openResult = await zip.open(apk);
      if (!openResult.isOk) {
        log.warning(
            "getApkInfo: failed to open XAPK file: ${openResult.description}");
        throw ApkOpenException(openResult, apk);
      }
      zipOpenMs = zipOpenSw.elapsedMilliseconds;

      // 使用共享的 zip 实例解析清单（不再重新打开文件）
      final manifestSw = Stopwatch()..start();
      manifest = await parseXapkManifest(apk, sharedZip: zip);
      manifestMs = manifestSw.elapsedMilliseconds;

      apkInfo.archiveApks = zip.listFiles(extension: '.apk');
      apkInfo.obbFiles = zip.listFiles(extension: '.obb');

      // 优先加载打包文件自带的图标（xapk/apkm 自身携带的 icon）
      final iconSw = Stopwatch()..start();
      final xapkIcon =
          await loadXapkIcon(apk, iconPath: manifest?.icon, sharedZip: zip);
      if (xapkIcon != null) {
        apkInfo.mainIconImage = xapkIcon;
      }
      iconMs = iconSw.elapsedMilliseconds;

      final baseEntry = _findBaseApkEntry(apkInfo.archiveApks);
      if (baseEntry != null) {
        tempDir = await Directory.systemTemp.createTemp('apk_info_base');
        baseApkPath = path.join(tempDir.path, path.basename(baseEntry));
        final extractSw = Stopwatch()..start();
        final extracted = await zip.extractFile(baseEntry, baseApkPath);
        extractMs = extractSw.elapsedMilliseconds;
        if (extracted) {
          // 安全审计：分包安装包此前**完全没有审计** ——
          // `AndroidSecurityAudit` 的唯一生产调用点在只被内置引擎使用的
          // worker 里，而这条路径走 aapt2，其输出喂不了审计（审计要的是
          // `ApkMeta` + DEX 字节）。这里对刚提取出的 base APK 单独跑一次
          // 内置解析器把审计补上。
          //
          // **放在 aapt2 之前**：审计用内置解析器，不依赖 aapt2；放在后面
          // 会让「没装 aapt2」连带把审计也吞掉 —— 那正是本次要修的缺口。
          apkInfo.securityResult = await _auditExtractedBaseApk(baseApkPath);
          try {
            final aaptPath = CommandTools.findAapt2Path();
            if (aaptPath == null || aaptPath.isEmpty) {
              throw Exception(t.parse.please_set_path(name: 'aapt2'));
            }
            final aapt2Sw = Stopwatch()..start();
            final result = await Aapt2Task.run(
              aaptPath,
              ['dump', 'badging', baseApkPath],
              onStarted: onTaskStarted,
            );
            aapt2Ms = aapt2Sw.elapsedMilliseconds;
            // 取消：不是失败，也不该继续走后面的图标加载。
            if (result.cancelled) {
              throw const ApkParseCancelledException();
            }
            if (result.isSuccess) {
              final originalPath = apkInfo.apkPath;
              apkInfo.apkPath = baseApkPath;
              final parseSw = Stopwatch()..start();
              parseApkInfoFromOutput(result.stdout.toString(), apkInfo);
              parseMs = parseSw.elapsedMilliseconds;
              // 仅在打包文件不包含图标时，才从 base APK 加载图标
              if (apkInfo.mainIconImage == null) {
                iconSw
                  ..reset()
                  ..start();
                final iconImage = await apkInfo.loadIcon();
                if (iconImage != null) {
                  apkInfo.mainIconImage = iconImage;
                }
                iconMs += iconSw.elapsedMilliseconds;
              }
              apkInfo.apkPath = originalPath;
            }
          } on ApkParseCancelledException {
            // 用户取消不是「base APK 解析失败」—— 必须往上抛，否则会被记成
            // 一条无关的警告，然后继续走后面的图标加载，白等一场。
            rethrow;
          } catch (e) {
            log.warning("getApkInfo: base APK parse failed: $e");
          }
        }
      }

      if (manifest != null) {
        if (manifest.packageName?.isNotEmpty == true) {
          apkInfo.packageName = manifest.packageName;
        }
        if (manifest.versionCode != null && manifest.versionCode! > 0) {
          apkInfo.versionCode = manifest.versionCode;
        }
        if (manifest.versionName?.isNotEmpty == true) {
          apkInfo.versionName = manifest.versionName;
        }
        if (manifest.minSdkVersion != null && manifest.minSdkVersion! > 0) {
          apkInfo.sdkVersion = manifest.minSdkVersion;
        }
        if (manifest.targetSdkVersion != null &&
            manifest.targetSdkVersion! > 0) {
          apkInfo.targetSdkVersion = manifest.targetSdkVersion;
        }
        if (manifest.name?.isNotEmpty == true) {
          apkInfo.label = manifest.name;
          apkInfo.xapkName = manifest.name;
        }
        if (apkInfo.usesPermissions.isEmpty &&
            manifest.permissions.isNotEmpty) {
          apkInfo.usesPermissions = manifest.permissions;
        }
        if (manifest.splitConfigs.isNotEmpty) {
          apkInfo.splitConfigs = manifest.splitConfigs;
        }
        if (manifest.splitApks.isNotEmpty) {
          apkInfo.splitApks = manifest.splitApks.map((e) => e.file).toList();
        }
        if (manifest.totalSize != null && manifest.totalSize! > 0) {
          apkInfo.totalSize = manifest.totalSize;
        }
      }

      // 分包一致性校验：抽检若干分包，比对包名与 versionCode。
      //
      // 放在 manifest 补全**之后**：那时 apkInfo 的包名与版本已经取到最可靠
      // 的值（base APK 解析优先，XAPK manifest 兜底）。
      // 必须在 finally 之前 —— 分包要解压到 tempDir，而它随后就被删了。
      final temp = tempDir;
      final base = baseEntry;
      if (temp != null && base != null && apkInfo.archiveApks.length > 1) {
        apkInfo.splitConsistency = await _checkSplitConsistency(
          zip: zip,
          tempDirPath: temp.path,
          splitEntries: apkInfo.archiveApks.where((e) => e != base).toList(),
          basePackageName: apkInfo.packageName,
          baseVersionCode: apkInfo.versionCode,
        );
      }
    } finally {
      zip.close();
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }

    if (apkInfo.splitApks.isEmpty) {
      apkInfo.splitApks = apkInfo.archiveApks;
    }
    _inferLocalesAndAbisFromSplits(apkInfo, apkInfo.splitApks);
    apkInfo.totalSize ??= apkInfo.apkSize;

    if (apkInfo.packageName == null &&
        apkInfo.versionName == null &&
        apkInfo.label == null &&
        apkInfo.archiveApks.isEmpty &&
        manifest == null) {
      log.warning("getApkInfo: failed to parse XAPK/APKM/APKS");
      return null;
    }

    totalSw.stop();
    onStage?.call(ApkParseStage.done);
    log.info(
        "[PERF] getApkInfo(archive): total=${totalSw.elapsedMilliseconds}ms"
        " | zip_open=${zipOpenMs}ms"
        " | xapk_manifest=${manifestMs}ms"
        " | zip_extract=${extractMs}ms"
        " | aapt2_badging=${aapt2Ms}ms"
        " | output_parse=${parseMs}ms"
        " | icon=${iconMs}ms");

    return apkInfo;
  }

  // 根据配置选择解析引擎
  if (Config.parserEngine.value == Config.kParserBuiltin) {
    return await _getApkInfoBuiltin(
      apk,
      apkInfo,
      onStage: onStage,
      onTaskStarted: onTaskStarted,
    );
  }

  // 原有的APK解析逻辑（aapt2）
  final aaptPath = CommandTools.findAapt2Path();
  if (aaptPath == null || aaptPath.isEmpty) {
    throw Exception(t.parse.please_set_path(name: 'aapt2'));
  }
  final totalSw = Stopwatch()..start();
  var aapt2BadgingMs = 0;
  var outputParseMs = 0;
  var iconMs = 0;

  try {
    final aapt2Sw = Stopwatch()..start();
    final result = await Aapt2Task.run(
      aaptPath,
      ['dump', 'badging', apk],
      onStarted: onTaskStarted,
    );
    aapt2BadgingMs = aapt2Sw.elapsedMilliseconds;

    if (result.cancelled) {
      throw const ApkParseCancelledException();
    }

    final exitCode = result.exitCode;
    log.fine("getApkInfo: aapt2 exitCode=$exitCode");

    if (result.isSuccess) {
      final parseSw = Stopwatch()..start();
      parseApkInfoFromOutput(result.stdout, apkInfo);
      outputParseMs = parseSw.elapsedMilliseconds;

      final iconSw = Stopwatch()..start();
      final iconImage = await apkInfo.loadIcon();
      if (iconImage != null) {
        apkInfo.mainIconImage ??= iconImage;
      }
      iconMs = iconSw.elapsedMilliseconds;

      totalSw.stop();
      log.info("[PERF] getApkInfo: total=${totalSw.elapsedMilliseconds}ms"
          " | aapt2_badging=${aapt2BadgingMs}ms"
          " | output_parse=${outputParseMs}ms"
          " | icon=${iconMs}ms");

      return apkInfo;
    }
  } on ApkParseCancelledException {
    // 用户主动取消 —— 往上抛，让调用方与「解析失败」区分开。
    rethrow;
  } catch (e) {
    log.warning("getApkInfo: error=$e");
  }

  return null;
}

/// 用内置解析引擎解析。
///
/// 容器解析与资源表解析跑在**独立 isolate** 中（[ApkParseTask]）：
/// 这些是同步 CPU 密集计算，跑在主 isolate 上会让大 APK 冻住界面，而且
/// 无法取消。图标渲染必须留在主 isolate —— `ApkInfo` 持有 `dart:ui` 的
/// `Image`，不能跨 isolate 传递。
/// 对已提取到磁盘的 base APK 单独跑一次安全审计。
///
/// 分包安装包（XAPK / APKM / APKS）此前**完全不跑安全审计**：审计的唯一
/// 生产调用点在只被内置引擎使用的 worker 里，而这条路径走 aapt2，其输出
/// 喂不了审计（审计要 `ApkMeta` + DEX 字节）。
///
/// 覆盖范围**仅限 base APK** —— 各分包自己的 DEX 与资源不参与分析。
/// 这一点会作为 limitation 写进结果，避免把部分覆盖说成完整结论。
///
/// 失败时返回 `null` 而非抛异常：审计拿不到结果不该让整个解析失败，
/// 上层会把 `null` 呈现为「未执行」。
Future<SecurityAnalysisResult?> _auditExtractedBaseApk(
  String baseApkPath,
) async {
  final reader = apk_parser.ApkReader();
  try {
    final openResult = await reader.open(baseApkPath);
    if (!openResult.isOk) {
      log.warning(
          '_auditExtractedBaseApk: 打不开 base APK：${openResult.description}');
      return null;
    }
    final meta = await reader.parse();
    if (meta == null) {
      log.warning('_auditExtractedBaseApk: base APK 的 Manifest 未能解析');
      return null;
    }
    final dexEntries = <apk_parser.DexBytes>[
      for (final name in reader.listFiles(extension: '.dex'))
        if (reader.readFile(name) case final bytes?)
          apk_parser.DexBytes(name, bytes),
    ];
    // 原生库与 DEX 一样**先挑再读**（同一个库只取一个 ABI、超限不读）。
    final nativeSelection = apk_parser.NativeSymbolScanner.selectLibraries(
      reader.listFilesWithSize(extension: '.so'),
    );
    final nativeEntries = <apk_parser.NativeLibraryBytes>[
      for (final name in nativeSelection.selected)
        if (reader.readFile(name) case final bytes?)
          apk_parser.NativeLibraryBytes(name, bytes),
    ];
    final result = apk_parser.AndroidSecurityAudit.audit(
      meta: meta,
      dexEntries: dexEntries,
      nativeEntries: nativeEntries,
      containerAnomalies: [
        for (final obs in reader.scanHardeningSignals()) obs.evidence,
      ],
    );
    return result.withLimitation(const AnalysisNote(
      'android.split_apk.base_only',
      'This is a split package: the security audit **only covers the base '
          'APK**; the DEX and resources carried by the split APKs (language '
          '/ density / ABI) were not analysed, so this result does not '
          'represent the whole installation set. Native libraries '
          'especially — the ABI split usually holds the copy that is '
          'actually loaded.',
    ));
  } catch (e) {
    log.warning('_auditExtractedBaseApk failed: $e');
    return null;
  } finally {
    reader.close();
  }
}

/// 分包一致性校验的结果。
///
/// **「发现的不一致」与「这次查了多少」必须分开**：前者是结论，后者是覆盖
/// 范围。混在一个字符串列表里，下游只能靠猜来区分 —— 截断说明会被当成一条
/// 异常报给用户，而真正的不一致也可能被当成说明忽略掉。
class SplitConsistencyReport {
  /// 实际发现的问题：包名 / versionCode 与 base 不符，或分包读不出来。
  final List<String> issues;

  /// 本次实际尝试比对的分包数（不含 base）。
  final int checkedCount;

  /// 分包总数（不含 base）。
  final int totalCount;

  const SplitConsistencyReport({
    this.issues = const [],
    this.checkedCount = 0,
    this.totalCount = 0,
  });

  /// 是否因为抽检上限而没查完。
  bool get isTruncated => checkedCount < totalCount;
}

/// 抽检分包的包名与 versionCode 是否与 base 一致。
///
/// **只比对这两项**：不一致意味着安装集合是拼凑的，是最值得报的异常。
/// `minSdk` / `targetSdk` 允许分包间有差异（工具链会为不同 ABI 生成不同的
/// 值），报出来只会是噪声。
///
/// 签名身份**不做**逐分包比对 —— 那要对每个分包跑一次 `apksigner`，开销远超
/// 收益，而 base 的签名结论已经给出。
///
/// 抽检有上限：大 XAPK 可能有几十个分包，逐个解压太慢。截断时如实报告查了
/// 多少、共多少，不假装查完了。
Future<SplitConsistencyReport> _checkSplitConsistency({
  required ZipHelper zip,
  required String tempDirPath,
  required List<String> splitEntries,
  required String? basePackageName,
  required int? baseVersionCode,
}) async {
  const maxSplitsToCheck = 8;
  final issues = <String>[];
  final attempted = splitEntries.take(maxSplitsToCheck).toList();

  for (final entry in attempted) {
    final name = path.basename(entry);
    final splitPath = path.join(tempDirPath, name);
    try {
      // 解压失败也必须留下记录：静默 `continue` 等于告诉用户「这个分包比对
      // 过了」，而实际根本没读到它。
      if (!await zip.extractFile(entry, splitPath)) {
        issues.add('分包 $name 解压失败，未能比对。');
        continue;
      }

      final splitZip = ZipHelper();
      try {
        final openResult = await splitZip.open(splitPath);
        if (!openResult.isOk) {
          issues.add('分包 $name 打不开（${openResult.description}）。');
          continue;
        }
        final manifestBytes =
            await splitZip.readFileContent('AndroidManifest.xml');
        if (manifestBytes == null) {
          issues.add('分包 $name 里没有 AndroidManifest.xml。');
          continue;
        }

        final splitMeta = ManifestParser.parse(manifestBytes);
        if (basePackageName != null &&
            splitMeta.packageName != null &&
            splitMeta.packageName != basePackageName) {
          issues.add(
            '分包 $name 的包名是 ${splitMeta.packageName}，'
            '与 base 的 $basePackageName 不一致。',
          );
        }
        if (baseVersionCode != null &&
            splitMeta.versionCode != null &&
            splitMeta.versionCode != baseVersionCode) {
          issues.add(
            '分包 $name 的 versionCode 是 ${splitMeta.versionCode}，'
            '与 base 的 $baseVersionCode 不一致。',
          );
        }
      } finally {
        splitZip.close();
      }
    } catch (e) {
      log.warning('_checkSplitConsistency: $entry failed: $e');
      issues.add('分包 $name 解析失败（$e）。');
    }
  }

  return SplitConsistencyReport(
    issues: issues,
    checkedCount: attempted.length,
    totalCount: splitEntries.length,
  );
}

Future<ApkInfo?> _getApkInfoBuiltin(
  String apk,
  ApkInfo apkInfo, {
  void Function(ApkParseStage stage)? onStage,
  void Function(ApkParseTask task)? onTaskStarted,
}) async {
  final totalSw = Stopwatch()..start();

  final task = await ApkParseTask.start(apk);
  onTaskStarted?.call(task);

  ParsedApkData? parsed;
  var cancelled = false;
  // Manifest 读不出来时，worker 仍会回传一个只含局限说明的审计结果。
  // 这两个变量负责把它接住 —— 早先这里直接 `return null`，于是「审计跑了
  // 但什么都查不到」这件事在界面上完全不可见。
  String? parseFailureReason;
  SecurityAnalysisResult? failedSecurity;

  await for (final event in task.events) {
    switch (event) {
      case ParseStageReached(:final stage):
        onStage?.call(stage);
      case ParseOpenFailed(:final result):
        log.warning(
            "_getApkInfoBuiltin: failed to open APK: ${result.description}");
        throw ApkOpenException(result, apk);
      case ParseFailed(:final reason, :final security):
        log.warning("_getApkInfoBuiltin: parse failed: $reason");
        parseFailureReason = reason;
        failedSecurity = security;
      case ParseSucceeded(:final data):
        parsed = data;
      case ParseCancelled():
        cancelled = true;
    }
  }

  if (cancelled) {
    log.info("_getApkInfoBuiltin: cancelled by user");
    throw ApkParseCancelledException();
  }

  final data = parsed;
  if (data == null) {
    if (parseFailureReason != null) {
      // Manifest 没读出来。**不返回 null** —— 那样调用方连「审计没跑成」
      // 都看不到，界面上安全 Tab 会是空白。改为把局限说明挂上后返回，
      // 由上层检查 `parseFailureReason` 决定呈现方式（仍显示解析失败）。
      apkInfo.parseFailureReason = parseFailureReason;
      apkInfo.securityResult = failedSecurity;
      return apkInfo;
    }
    log.warning("_getApkInfoBuiltin: worker produced no result");
    return null;
  }

  _applyMetaToApkInfo(data.meta, apkInfo);
  apkInfo.manifestSource = FieldSource.builtinParser;
  apkInfo.hardeningObservations = data.hardeningObservations;
  apkInfo.structure = data.structure;
  apkInfo.resourceReferenceCycles = data.referenceCycles;
  apkInfo.originalText = _generateTextInfo(data.meta);
  apkInfo.securityResult = data.security;

  // 导出 arsc 资源表数据供图标渲染器使用（替代 aapt2 dump resources）。
  // 渲染完成后立即释放 —— 资源表在大 APK 上可能占用可观内存。
  if (data.arscResources.isNotEmpty) {
    apkInfo.arscResources = data.arscResources;
  }
  final iconSw = Stopwatch()..start();
  final iconImage = await apkInfo.loadIcon();
  if (iconImage != null) {
    apkInfo.mainIconImage ??= iconImage;
  }
  apkInfo.arscResources = null;
  final iconMs = iconSw.elapsedMilliseconds;

  totalSw.stop();
  log.info("[PERF] getApkInfo(builtin): total=${totalSw.elapsedMilliseconds}ms"
      " | icon=${iconMs}ms (parsing ran in a worker isolate)");

  return apkInfo;
}

void _applyMetaToApkInfo(apk_parser.ApkMeta meta, ApkInfo apkInfo) {
  apkInfo.packageName = meta.packageName;
  apkInfo.versionCode = meta.versionCode;
  apkInfo.versionName = meta.versionName;
  apkInfo.sdkVersion = meta.minSdkVersion;
  apkInfo.targetSdkVersion = meta.targetSdkVersion;
  apkInfo.maxSdkVersion = meta.maxSdkVersion;
  apkInfo.applicationDebuggable = meta.applicationDebuggable;
  apkInfo.components = List.of(meta.components);
  apkInfo.compileSdkVersion = meta.compileSdkVersion;
  apkInfo.compileSdkVersionCodename = meta.compileSdkVersionCodename;
  apkInfo.platformBuildVersionName = meta.platformBuildVersionName;
  apkInfo.platformBuildVersionCode = meta.platformBuildVersionCode;
  apkInfo.label = meta.label;
  apkInfo.labels = meta.labels;
  apkInfo.usesPermissions = meta.permissions;
  apkInfo.userFeatures = meta.features;
  apkInfo.userFeaturesNotRequired = meta.featuresNotRequired;
  apkInfo.supportsScreens = meta.screenSizes;
  apkInfo.nativeCodes = meta.nativeCodes;
  apkInfo.locales = meta.locales;
  apkInfo.densities = meta.densities.map((d) => d.toString()).toList();
  apkInfo.hasNightMode = meta.hasNightMode;
  apkInfo.uiModeTypes = meta.uiModeTypes;

  // 从 arsc 解析的图标路径填充 icons map
  meta.iconPaths.forEach((dpi, iconPath) {
    apkInfo.icons[dpi.toString()] = iconPath;
  });

  if (meta.applicationIcon != null) {
    if (meta.applicationIcon!.startsWith('@res/0x') &&
        meta.iconPaths.isNotEmpty) {
      // 使用已解析的图标路径替代资源引用，避免重复候选
      final sorted = meta.iconPaths.entries.toList()
        ..sort((a, b) => b.key.compareTo(a.key));
      apkInfo.mainIconPath = sorted.first.value;
    } else {
      apkInfo.mainIconPath = meta.applicationIcon;
    }
  }

  if (meta.launchableActivities.isNotEmpty) {
    apkInfo.launchableActivity = meta.launchableActivities
        .map((a) => Component(name: a.name, label: a.label, icon: a.icon))
        .toList();
  }
  if (meta.applicationName != null) {
    apkInfo.application.name = meta.applicationName;
    apkInfo.application.label = meta.label;
    apkInfo.application.icon = meta.applicationIcon;
  }
}

/// 将 ApkMeta 格式化为 aapt2 dump badging 风格文本
String _generateTextInfo(apk_parser.ApkMeta meta) {
  final sb = StringBuffer();

  // package
  sb.writeln("package: name='${meta.packageName ?? ''}' "
      "versionCode='${meta.versionCode ?? ''}' "
      "versionName='${meta.versionName ?? ''}' "
      "compileSdkVersion='${meta.compileSdkVersion ?? ''}' "
      "compileSdkVersionCodename='${meta.compileSdkVersionCodename ?? ''}'");

  // SDK versions
  if (meta.minSdkVersion != null) {
    sb.writeln("sdkVersion:'${meta.minSdkVersion}'");
  }
  if (meta.targetSdkVersion != null) {
    sb.writeln("targetSdkVersion:'${meta.targetSdkVersion}'");
  }

  // application labels
  if (meta.label != null) {
    sb.writeln("application-label:'${meta.label}'");
  }
  for (final entry in meta.labels.entries) {
    sb.writeln("application-label-${entry.key}:'${entry.value}'");
  }

  // application icons
  for (final entry in meta.iconPaths.entries) {
    sb.writeln("application-icon-${entry.key}:'${entry.value}'");
  }

  // application
  sb.writeln("application: label='${meta.label ?? ''}' "
      "icon='${meta.applicationIcon ?? ''}'");

  // launchable activities
  for (final activity in meta.launchableActivities) {
    sb.writeln("launchable-activity: name='${activity.name ?? ''}' "
        "label='${activity.label ?? ''}' icon='${activity.icon ?? ''}'");
  }

  // permissions
  for (final perm in meta.permissions) {
    sb.writeln("uses-permission: name='$perm'");
  }

  // features
  for (final feature in meta.features) {
    sb.writeln("uses-feature: name='$feature'");
  }
  for (final feature in meta.featuresNotRequired) {
    sb.writeln("uses-feature-not-required: name='$feature'");
  }

  // supports-screens
  if (meta.screenSizes.isNotEmpty) {
    sb.writeln(
        "supports-screens: ${meta.screenSizes.map((s) => "'$s'").join(' ')}");
  }

  // locales
  final localeStrs = meta.locales.map((l) => "'$l'").join(' ');
  sb.writeln("locales: '--_--' $localeStrs");

  // densities
  if (meta.densities.isNotEmpty) {
    sb.writeln("densities: ${meta.densities.map((d) => "'$d'").join(' ')}");
  }

  // 夜间模式资源（aapt2 dump badging 不输出这一项，由内置解析器补上）
  if (meta.hasNightMode != null) {
    sb.writeln('night-mode-resources: ${meta.hasNightMode!}');
  }

  // uiMode 设备类型（3=车载 4=电视 6=手表）
  if (meta.uiModeTypes.isNotEmpty) {
    sb.writeln(
        "ui-mode-types: ${meta.uiModeTypes.map((t) => "'$t'").join(' ')}");
  }

  // native code
  if (meta.nativeCodes.isNotEmpty) {
    sb.writeln("native-code: ${meta.nativeCodes.map((n) => "'$n'").join(' ')}");
  }

  return sb.toString();
}

void parseApkInfoFromOutput(String output, ApkInfo apkInfo) {
  // 两条 aapt2 路径（XAPK 的 base APK、以及纯 aapt2 分支）都经过这里，
  // 因此来源标注放在这一处即可，且位置准确 —— 这里解析的正是 aapt2 的输出。
  apkInfo.manifestSource = FieldSource.aapt2;
  apkInfo.originalText = output;
  final lines = output.split("\n");
  for (final (index, item) in lines.indexed) {
    log.finer("parseApkInfoFromOutput: [$index] $item");
    apkInfo.parseLine(item);
  }
  log.fine("parseApkInfoFromOutput: apkInfo=$apkInfo");
}

final _kNoneSingleQuotePattern = RegExp(r"[^']");

extension StringExt on String {
  // 去除前后的单引号
  String trimSQ() {
    final start = indexOf(_kNoneSingleQuotePattern);
    if (start < 0) return '';
    final end = lastIndexOf(_kNoneSingleQuotePattern);
    if (end < start) return '';
    return substring(start, end + 1);
  }
}

class ApkInfo {
  String apkPath = "";
  int apkSize = 0;
  bool isXapk = false; // 是否为XAPK格式
  String? archiveType; // XAPK/APKM/APKS

  /// Builtin 解析器的资源表数据（临时字段，用于图标渲染，渲染后清除）
  Map<int, apk_parser.ResourceInfo>? arscResources;

  String? packageName;
  int? versionCode;
  String? versionName;
  String? platformBuildVersionName;
  int? platformBuildVersionCode;
  int? compileSdkVersion;
  String? compileSdkVersionCodename;
  int? sdkVersion;
  int? targetSdkVersion;

  /// `<uses-sdk android:maxSdkVersion>`。绝大多数应用不声明，此时为 `null`。
  int? maxSdkVersion;

  /// `<application android:debuggable>`。未声明时为 `null`（不等于 `false`）。
  bool? applicationDebuggable;

  /// manifest 中声明的全部组件（activity / service / receiver / provider
  /// 等），含 `exported` 与 `permission` 声明。
  List<apk_parser.AndroidComponent> components = [];

  /// manifest 字段的来源。
  ///
  /// 由各解析分支**如实填写**：内置引擎写 [FieldSource.builtinParser]，
  /// XAPK / aapt2 分支写 [FieldSource.aapt2]。猜错会让排查找错方向，
  /// 因此宁可留 [FieldSource.unknown] 也不臆测。
  FieldSource manifestSource = FieldSource.unknown;

  /// 容器结构上观察到的加固线索（只描述事实，不含厂商判定）。
  List<HardeningObservation> hardeningObservations = [];

  /// 容器结构概览（DEX 数量、原生库、ABI、顶层目录、解压后总字节数）。
  apk_parser.ContainerStructure structure =
      const apk_parser.ContainerStructure();
  String? label;
  String? mainIconPath; // 主图标路径
  Image? mainIconImage;
  List<IconCandidate> iconCandidates = [];
  Map<String, String> labels = {};
  List<String> usesPermissions = [];
  Map<String, String> icons = {};
  Component application = Component();
  List<Component> launchableActivity = [];
  List<String> userFeatures = [];
  List<String> userFeaturesNotRequired = [];
  List<String> userImpliedFeatures = [];
  List<String> supportsScreens = [];
  List<String> locales = [];
  List<String> densities = [];
  bool? supportsAnyDensity;
  List<String> nativeCodes = [];

  /// 资源表里是否有夜间模式变体；`null` 表示**没读到资源表**。
  ///
  /// 只有内置解析器会填这一项。aapt2 的 `dump badging` 输出里没有这个字段，
  /// 分包安装包（XAPK / APKM / APKS）走 aapt2 路径，因此保持 `null` ——
  /// 界面上必须与「没有夜间资源」区分开。
  bool? hasNightMode;

  /// 资源表里出现过的 `uiMode` 设备类型，已排序。
  ///
  /// 稳定标识符（`car` / `television` / `watch` …）。与 [hasNightMode] 一样
  /// 只有内置解析器会填。
  List<String> uiModeTypes = [];

  /// 资源引用图的环检测结果；`null` 表示**没查**（内置引擎之外没有资源表）。
  ///
  /// `null` 与「查了、没有环」必须分开：前者是我们没查，后者是查过没问题。
  ReferenceCycleReport? resourceReferenceCycles;

  /// 图标渲染过程中遇到的、需要向用户解释的问题（如资源引用成环）。
  ///
  /// 存在的理由：图标渲染失败时会回退到「没有图标」，而**回退必须能解释** ——
  /// 否则用户看到的是一个空白，分不清「这个包没有图标」与「我们没画出来」。
  List<String> iconResolutionNotes = [];

  List<String> others = [];

  // 文件哈希值
  String? md5Hash;
  String? sha1Hash;

  // XAPK 相关信息
  String? xapkName;
  List<String> splitConfigs = [];
  List<String> splitApks = [];
  List<String> archiveApks = [];
  List<String> obbFiles = [];
  int? totalSize;

  // 原始文本
  String originalText = "";

  /// 安全检测分析结果（V1.1）。
  ///
  /// `null` 表示未启用，或当前解析路径未产出安全分析
  ///（例如 aapt2 路径信息不完整）。
  SecurityAnalysisResult? securityResult;

  /// Manifest 解析失败的原因；成功时为 `null`。
  ///
  /// 与 `securityResult == null` 是**两件事**：
  /// - 本字段非 `null` → Manifest 没读出来，安全审计跑了但只能给局限说明；
  /// - `securityResult == null` → 审计压根没跑（未启用 / 该路径不产出）。
  ///
  /// 分开是因为界面上必须能区分「没查到」与「没查」。
  String? parseFailureReason;

  /// 分包（XAPK / APKM / APKS）一致性校验的结果。
  ///
  /// `null` 表示**没查**（单 APK，或没有可用的解包目录），与「查了、没发现
  /// 问题」（`issues` 为空）是两件必须分开的事。
  SplitConsistencyReport? splitConsistency;

  /// 由解析结果派生的诊断记录。
  ///
  /// 只放**解析层面**的事实（清单读不出来、分包不一致、抽检截断）。
  /// 安全发现不在这里 —— 它们有自己的模型与卡片，混进来会把「解析诊断」
  /// 变成第二个安全列表。
  ///
  /// 这个方法的存在是为了让 Android 侧也有诊断产出者：此前
  /// `AnalysisBuilder.buildAndroid` 从不接收 `diagnostics`，于是详情页的
  /// 「解析诊断」卡片与导出的报告里**永远是空的** —— 而「没读到」与
  /// 「没有可说的」必须分得开，那条链路断在这里就等于把前者说成了后者。
  List<AnalysisDiagnostic> get diagnostics {
    final out = <AnalysisDiagnostic>[];

    final failure = parseFailureReason;
    if (failure != null) {
      out.add(AnalysisDiagnostic.error(
        'android.manifest_unparsed',
        'AndroidManifest.xml 未能解析：$failure',
        source: manifestSource,
      ));
    }

    final split = splitConsistency;
    if (split != null) {
      for (final issue in split.issues) {
        out.add(AnalysisDiagnostic.warning(
          'android.split_inconsistent',
          issue,
          source: FieldSource.builtinParser,
        ));
      }
      if (split.isTruncated) {
        out.add(AnalysisDiagnostic.info(
          'android.split_sampling_truncated',
          '分包一致性只抽检了 ${split.checkedCount} 个分包'
              '（共 ${split.totalCount} 个），其余未比对。',
          source: FieldSource.builtinParser,
        ));
      }
    }

    // 资源引用环。`aapt2` 产出的表里不可能有环，因此「有环」是一条实打实的
    // 结构异常 —— 但那不等于「恶意」，措辞上只说事实与影响。
    final cycles = resourceReferenceCycles;
    if (cycles != null && cycles.cycles.isNotEmpty) {
      for (final cycle in cycles.cycles) {
        out.add(AnalysisDiagnostic.warning(
          'android.resource_reference_cycle',
          '资源引用成环：${cycle.description}。'
              '成环的资源互相定义、谁也没有真正的值，涉及它们的图标 / 颜色'
              '可能无法解析。',
          source: FieldSource.builtinParser,
        ));
      }
      if (cycles.truncated) {
        out.add(AnalysisDiagnostic.info(
          'android.resource_reference_cycle_truncated',
          '资源引用环只列出前 ${cycles.cycles.length} 个，'
              '表中可能还有更多。',
          source: FieldSource.builtinParser,
        ));
      }
    }

    // 图标渲染过程中的说明。放在诊断里而不是只写日志：渲染失败会回退到
    // 「没有图标」，而回退必须能解释。
    for (final note in iconResolutionNotes) {
      out.add(AnalysisDiagnostic.warning(
        'android.icon_resolution',
        note,
        source: FieldSource.builtinParser,
      ));
    }

    return out;
  }

  (String, String) parseToKeyValue(String line, String separator) {
    final pos = line.indexOf(separator);
    if (pos != -1) {
      final key = line.substring(0, pos).trim();
      final value = line.substring(pos + 1).trim();
      return (key, value);
    }
    return (line.trim(), "");
  }

  (String, String) parseLineToKeyValue(String line) {
    return parseToKeyValue(line, ":");
  }

  (String, String) parseValueToKeyValue(String line) {
    return parseToKeyValue(line, "=");
  }

  String? parseString(String line) {
    final items = line.split(":");
    if (items.length == 2) {
      return items[1].trim();
    } else {
      others.add(line);
    }
    return null;
  }

  int? parseInt(String value) {
    return int.tryParse(value.trimSQ());
  }

  String parseValueForName(String text) {
    final (_, value) = parseValueToKeyValue(text);
    return value.trimSQ();
  }

  void parseLine(String line) {
    final (key, value) = parseLineToKeyValue(line);
    switch (key) {
      case "package":
        parsePackage(value);
        break;
      case "sdkVersion":
      case "minSdkVersion":
        sdkVersion = parseInt(value);
        break;
      case "targetSdkVersion":
        targetSdkVersion = parseInt(value);
        break;
      case "application-label":
        label = value.trimSQ();
        break;
      case "uses-permission":
        usesPermissions.add(parseValueForName(value));
        break;
      case "application":
        parseComponent(value, application);
        // 从application中获取主图标
        if (mainIconPath == null && application.icon != null) {
          mainIconPath = application.icon;
        }
        break;
      case "launchable-activity":
        final component = Component();
        parseComponent(value, component);
        launchableActivity.add(component);
        // 如果没有主图标且launchable-activity有图标，则使用它
        if (mainIconPath == null && component.icon != null) {
          mainIconPath = component.icon;
        }
        break;
      case "supports-screens":
        parseStringList(value, supportsScreens);
        break;
      case "locales":
        parseStringList(value, locales);
        break;
      case "densities":
        parseStringList(value, densities);
        break;
      case "supports-any-density":
        supportsAnyDensity = value.trimSQ() == "true";
        break;
      case "native-code":
        parseStringList(value, nativeCodes);
        break;
      default:
        {
          if (key.startsWith("application-label-")) {
            labels[key.substring("application-label-".length)] = value.trimSQ();
          } else if (key.startsWith("application-icon-")) {
            icons[key.substring("application-icon-".length)] = value.trimSQ();
          } else {
            others.add(line);
          }
          break;
        }
    }
  }

  void parsePackage(String text) {
    final items = text.split(" ");
    for (final item in items) {
      final (key, value) = parseValueToKeyValue(item);
      switch (key) {
        case "name":
          packageName = value.trimSQ();
          break;
        case "versionCode":
          versionCode = parseInt(value);
          break;
        case "versionName":
          versionName = value.trimSQ();
          break;
        case "platformBuildVersionName":
          platformBuildVersionName = value.trimSQ();
          break;
        case "platformBuildVersionCode":
          platformBuildVersionCode = parseInt(value);
          break;
        case "compileSdkVersion":
          compileSdkVersion = parseInt(value);
          break;
        case "compileSdkVersionCodename":
          compileSdkVersionCodename = value.trimSQ();
          break;
      }
    }
  }

  void parseComponent(String value, Component component) {
    final items = value.split(" ");
    for (final item in items) {
      final (key, value) = parseValueToKeyValue(item);
      switch (key) {
        case "name":
          component.name = value.trimSQ();
          break;
        case "label":
          component.label = value.trimSQ();
          break;
        case "icon":
          component.icon = value.trimSQ();
          break;
      }
    }
  }

  void parseStringList(String value, List<String> out) {
    final items = value.split(" ");
    for (final item in items) {
      out.add(item.trimSQ());
    }
  }

  // 从 application-icon-* 中按密度从大到小排列，返回 (dpi, path) 对
  List<MapEntry<int, String>> _buildIconCandidatesWithDpi() {
    final entries = <MapEntry<int, String>>[];
    icons.forEach((key, value) {
      final tmp = int.tryParse(key);
      if (tmp != null) {
        entries.add(MapEntry(tmp, value));
      }
      log.finer("_buildIconCandidates: key=$key, value=$value");
    });

    entries.sort((a, b) => b.key.compareTo(a.key));
    return entries;
  }

  bool _isBitmapIcon(String path) {
    return path.endsWith('.webp') || path.endsWith('.png');
  }

  bool _isBitmapPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.webp') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg');
  }

  bool _isXmlPath(String path) {
    return path.toLowerCase().endsWith('.xml');
  }

  Future<Image?> _decodeImageData(Uint8List data) async {
    try {
      final codec = await instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  int _unknownPathScore(String candidate) {
    final lower = candidate.toLowerCase();
    var score = 0;
    if (lower.contains('mipmap')) score += 300;
    if (lower.contains('drawable')) score += 220;
    if (lower.contains('launcher')) score += 180;
    if (_isBitmapPath(lower)) score += 200;
    if (_isXmlPath(lower)) score += 120;
    if (lower.contains('-xxxhdpi')) score += 90;
    if (lower.contains('-xxhdpi')) score += 80;
    if (lower.contains('-xhdpi')) score += 70;
    if (lower.contains('-hdpi')) score += 60;
    if (lower.contains('-mdpi')) score += 50;
    return score;
  }

  List<String> _findUnknownCandidatePaths(
      List<String> allFiles, String candidate) {
    final raw = candidate.trim();
    if (raw.isEmpty) return const [];
    final normalized = raw.replaceAll('\\', '/');
    final files = allFiles;
    final result = <String>{};
    if (files.contains(normalized)) {
      result.add(normalized);
    }
    if (normalized.startsWith('/')) {
      final tmp = normalized.substring(1);
      if (files.contains(tmp)) {
        result.add(tmp);
      }
    }
    final base = path.basename(normalized).toLowerCase();
    for (final file in files) {
      final fileLower = file.toLowerCase();
      final fileBase = path.basename(fileLower);
      if (fileBase == base || fileLower.endsWith('/$base')) {
        result.add(file);
      }
    }
    final sorted = result.toList();
    sorted.sort((a, b) => _unknownPathScore(b).compareTo(_unknownPathScore(a)));
    return sorted;
  }

  /// 收集所有图标候选路径，构建 iconCandidates 列表（不渲染）
  Future<void> collectIconCandidates({
    ZipHelper? sharedZip,
    AdaptiveIconRenderer? sharedRenderer,
  }) async {
    iconCandidates.clear();

    if (mainIconPath == null || mainIconPath!.isEmpty) {
      if (icons.isEmpty) return;
    }

    final zip = sharedZip ?? ZipHelper();
    AdaptiveIconRenderer? adaptiveIconRenderer = sharedRenderer;
    try {
      if (sharedZip == null) await zip.open(apkPath);
      final aaptPath = CommandTools.findAapt2Path();
      final allFiles = zip.listFiles();

      // 构建 path -> knownDpi 的映射
      final dpiMap = <String, int>{};
      final candidatesWithDpi = _buildIconCandidatesWithDpi();
      for (final entry in candidatesWithDpi) {
        dpiMap[entry.value] = entry.key;
      }

      final candidates = <String>[];
      if (mainIconPath != null && mainIconPath!.isNotEmpty) {
        candidates.add(mainIconPath!);
      }
      candidates.addAll(candidatesWithDpi.map((e) => e.value));
      final uniqueCandidates = <String>[];
      final seenCandidates = <String>{};
      for (final item in candidates) {
        if (seenCandidates.add(item)) {
          uniqueCandidates.add(item);
        }
      }

      final prioritizedPaths = <String>[];
      final prioritizedSeen = <String>{};
      for (final iconPath in uniqueCandidates) {
        var resourceLinkedBitmaps = <String>[];
        if (_isXmlPath(iconPath) && aaptPath != null && aaptPath.isNotEmpty) {
          adaptiveIconRenderer ??= AdaptiveIconRenderer(
            apkPath: apkPath,
            aaptPath: aaptPath,
            zip: zip,
          );
          resourceLinkedBitmaps = await adaptiveIconRenderer
              .findBitmapAlternativesForPath(iconPath);
        }
        if (prioritizedSeen.add(iconPath)) {
          prioritizedPaths.add(iconPath);
        }
        for (final bitmap in resourceLinkedBitmaps) {
          if (prioritizedSeen.add(bitmap)) {
            prioritizedPaths.add(bitmap);
          }
        }
      }

      // 收集有效候选
      final validPaths = <String>[];
      for (final iconPath in prioritizedPaths) {
        if (_isBitmapIcon(iconPath)) {
          if (allFiles.contains(iconPath)) {
            validPaths.add(iconPath);
          }
        } else if (_isXmlPath(iconPath)) {
          if (allFiles.contains(iconPath)) {
            validPaths.add(iconPath);
          }
        } else {
          // 资源引用或未知路径，尝试解析
          final resolvedPaths = _findUnknownCandidatePaths(allFiles, iconPath);
          if (resolvedPaths.isNotEmpty) {
            for (final resolved in resolvedPaths) {
              if (prioritizedSeen.add(resolved)) {
                validPaths.add(resolved);
              }
            }
          } else {
            // 保留原始路径（可能是资源引用，渲染时由 AdaptiveIconRenderer 处理）
            validPaths.add(iconPath);
          }
        }
      }

      // 兜底：启发式扫描
      if (validPaths.isEmpty) {
        final fallbackCandidates = allFiles
            .where((e) {
              final lower = e.toLowerCase();
              return lower.contains('mipmap') ||
                  (lower.contains('drawable') && lower.contains('launcher'));
            })
            .toSet()
            .toList()
          ..sort(
              (a, b) => _unknownPathScore(b).compareTo(_unknownPathScore(a)));
        for (final candidate in fallbackCandidates) {
          if (prioritizedSeen.add(candidate)) {
            validPaths.add(candidate);
          }
        }
      }

      // 去除 _round 后缀的变体
      final filtered = validPaths.where((p) {
        final lower = p.toLowerCase();
        return !lower.contains('_round.');
      }).toList();

      // 构建 IconCandidate 对象，传入已知 DPI
      final seen = <String>{};
      for (final p in filtered) {
        if (seen.add(p)) {
          iconCandidates.add(IconCandidate.fromPath(p, knownDpi: dpiMap[p]));
        }
      }

      log.fine(
          'collectIconCandidates: found ${iconCandidates.length} candidates: ${iconCandidates.map((c) => c.path).join(", ")}');
    } catch (e) {
      log.warning('collectIconCandidates: 收集图标候选失败: $e');
    } finally {
      // 只清理自己创建的资源，共享资源由调用者管理
      if (sharedRenderer == null) adaptiveIconRenderer?.dispose();
      if (sharedZip == null) zip.close();
    }
  }

  /// 渲染指定索引的候选图标，结果缓存到 IconCandidate.renderedImage
  Future<Image?> renderIcon(
    int index, {
    ZipHelper? sharedZip,
    AdaptiveIconRenderer? sharedRenderer,
  }) async {
    if (index < 0 || index >= iconCandidates.length) return null;
    final candidate = iconCandidates[index];

    // 已有缓存，直接返回
    if (candidate.renderedImage != null) return candidate.renderedImage;

    final zip = sharedZip ?? ZipHelper();
    AdaptiveIconRenderer? adaptiveIconRenderer = sharedRenderer;
    try {
      if (sharedZip == null) await zip.open(apkPath);
      final aaptPath = CommandTools.findAapt2Path();
      final iconPath = candidate.path;

      if (_isBitmapIcon(iconPath) || _isBitmapPath(iconPath)) {
        final data = await zip.readFileContent(iconPath);
        if (data != null) {
          final image = await _decodeImageData(data);
          if (image != null) {
            candidate.renderedImage = image;
            log.fine('renderIcon: 渲染位图图标: $iconPath');
            return image;
          }
        }
      }

      if (_isXmlPath(iconPath)) {
        // 渲染器**不依赖 aapt2**：`loadIcon` 已经把内置解析器的资源表给了
        // `sharedRenderer`（见那里的注释「当有 arsc 数据时，即使没有 aapt2
        // 也能创建渲染器」）。
        //
        // 这里原先只判断 `aaptPath` 非空，于是那条能力被这道门挡死了 ——
        // 没装 aapt2 的机器上 XML 图标一律画不出来，**而且不留任何说明**。
        // 现在只要调用方备好了资源表（`sharedRenderer != null`）就放行。
        final aaptAvailable = aaptPath != null && aaptPath.isNotEmpty;
        if (aaptAvailable || sharedRenderer != null) {
          adaptiveIconRenderer ??= AdaptiveIconRenderer(
            apkPath: apkPath,
            aaptPath: aaptPath ?? '',
            zip: zip,
          );
          final image = await adaptiveIconRenderer.render(iconPath);
          if (image != null) {
            candidate.renderedImage = image;
            log.fine('renderIcon: 渲染XML图标: $iconPath');
            return image;
          }
        }
      }

      // 尝试作为资源引用渲染
      if (aaptPath != null && aaptPath.isNotEmpty) {
        adaptiveIconRenderer ??= AdaptiveIconRenderer(
          apkPath: apkPath,
          aaptPath: aaptPath,
          zip: zip,
        );
        final rendered = await adaptiveIconRenderer.render(iconPath);
        if (rendered != null) {
          candidate.renderedImage = rendered;
          log.fine('renderIcon: 渲染资源引用图标: $iconPath');
          return rendered;
        }
      }

      log.fine('renderIcon: 无法渲染图标: $iconPath');
    } catch (e) {
      log.warning('renderIcon: 渲染图标失败: $e');
    } finally {
      if (sharedRenderer == null) adaptiveIconRenderer?.dispose();
      if (sharedZip == null) zip.close();
    }
    return null;
  }

  /// 加载APK图标（兼容接口）
  /// 先收集候选，再渲染第一个可用的
  /// 共享 ZipHelper 和 AdaptiveIconRenderer，避免资源表重复加载
  Future<Image?> loadIcon() async {
    final zip = ZipHelper();
    AdaptiveIconRenderer? sharedRenderer;
    try {
      await zip.open(apkPath);
      final aaptPath = CommandTools.findAapt2Path() ?? '';

      // 当有 arsc 数据时，即使没有 aapt2 也能创建渲染器（不需要 aapt2 dump resources）
      if (aaptPath.isNotEmpty || arscResources != null) {
        sharedRenderer = AdaptiveIconRenderer(
          apkPath: apkPath,
          aaptPath: aaptPath,
          zip: zip,
        );
        // 从 builtin 解析器的 arsc 数据预加载资源表，完全替代 aapt2
        if (arscResources != null) {
          sharedRenderer.preloadResourceTableFromArsc(arscResources!);
        }
      }

      await collectIconCandidates(
        sharedZip: zip,
        sharedRenderer: sharedRenderer,
      );
      if (iconCandidates.isEmpty) {
        log.fine('loadIcon: 未找到可用图标');
        return null;
      }

      // 按顺序尝试渲染，直到成功
      for (var i = 0; i < iconCandidates.length; i++) {
        final image = await renderIcon(
          i,
          sharedZip: zip,
          sharedRenderer: sharedRenderer,
        );
        if (image != null) {
          return image;
        }
      }

      log.fine('loadIcon: 所有候选图标渲染失败');
      return null;
    } finally {
      final renderer = sharedRenderer;
      if (renderer != null) {
        // 图标渲染失败会回退到「没有图标」，而**回退必须能解释** ——
        // 把渲染器记下的说明（引用成环、深度触顶）带到 ApkInfo 上，
        // 最终进「解析诊断」卡片。此前这些情况只写进日志，界面上是空白。
        iconResolutionNotes = List.of(renderer.resolutionNotes);
        renderer.dispose();
      }
      zip.close();
    }
  }

  /// 为导出渲染高清图标（XML 矢量图使用更大 canvas + 透明背景）
  /// 位图图标直接解码原始分辨率
  Future<Image?> renderIconForExport(int index, {int exportSize = 1024}) async {
    if (index < 0 || index >= iconCandidates.length) return null;
    final candidate = iconCandidates[index];
    final iconPath = candidate.path;

    final zip = ZipHelper();
    AdaptiveIconRenderer? adaptiveIconRenderer;
    try {
      await zip.open(apkPath);
      final aaptPath = CommandTools.findAapt2Path();

      // 位图：直接解码原始分辨率
      if (_isBitmapIcon(iconPath) || _isBitmapPath(iconPath)) {
        final data = await zip.readFileContent(iconPath);
        if (data != null) {
          return await _decodeImageData(data);
        }
      }

      // XML 矢量图：高分辨率 + 透明背景
      if (aaptPath != null && aaptPath.isNotEmpty) {
        adaptiveIconRenderer = AdaptiveIconRenderer(
          apkPath: apkPath,
          aaptPath: aaptPath,
          zip: zip,
        );
        return await adaptiveIconRenderer.render(
          iconPath,
          canvasSize: exportSize,
          transparentBackground: true,
        );
      }
    } catch (e) {
      log.warning('renderIconForExport: 导出渲染失败: $e');
    } finally {
      adaptiveIconRenderer?.dispose();
      zip.close();
    }
    return null;
  }

  /// 将指定索引的 XML 矢量图标候选导出为 SVG 字符串。
  /// 支持解析 adaptive-icon 中引用的 vector drawable。
  Future<String?> exportSvgString(int index) async {
    if (index < 0 || index >= iconCandidates.length) return null;
    final candidate = iconCandidates[index];
    if (candidate.type != IconCandidateType.xmlVector) return null;

    final zip = ZipHelper();
    AdaptiveIconRenderer? renderer;
    try {
      await zip.open(apkPath);
      final aaptPath = CommandTools.findAapt2Path();
      if (aaptPath == null || aaptPath.isEmpty) {
        // 无 aapt 时直接读取 XML 字节尝试转换
        final bytes = await zip.readFileContent(candidate.path);
        if (bytes != null) {
          return VectorToSvg.convert(bytes);
        }
        return null;
      }

      renderer = AdaptiveIconRenderer(
        apkPath: apkPath,
        aaptPath: aaptPath,
        zip: zip,
      );

      // 优先尝试 adaptive-icon 完整导出（包含 background + foreground）
      final adaptiveData =
          await renderer.resolveAdaptiveIconForSvg(candidate.path);
      if (adaptiveData != null) {
        if (adaptiveData.backgroundVector != null) {
          await renderer.resolveVectorColorRefs(adaptiveData.backgroundVector!);
          await renderer
              .resolveVectorGradientRefs(adaptiveData.backgroundVector!);
        }
        if (adaptiveData.foregroundVector != null) {
          await renderer.resolveVectorColorRefs(adaptiveData.foregroundVector!);
          await renderer
              .resolveVectorGradientRefs(adaptiveData.foregroundVector!);
        }
        return VectorToSvg.convertAdaptiveIconData(adaptiveData);
      }

      // 回退：单个 vector drawable 导出
      final vectorElement =
          await renderer.resolveToVectorElement(candidate.path);
      if (vectorElement != null) {
        await renderer.resolveVectorColorRefs(vectorElement);
        await renderer.resolveVectorGradientRefs(vectorElement);
        return VectorToSvg.convertElement(vectorElement);
      }
      return null;
    } catch (e) {
      log.warning('exportSvgString: SVG 导出失败: $e');
      return null;
    } finally {
      renderer?.dispose();
      zip.close();
    }
  }

  @override
  String toString() {
    return 'ApkInfo{apkPath: $apkPath, apkSize: $apkSize, isXapk: $isXapk, archiveType: $archiveType, packageName: $packageName, versionCode: $versionCode, versionName: $versionName, platformBuildVersionName: $platformBuildVersionName, platformBuildVersionCode: $platformBuildVersionCode, compileSdkVersion: $compileSdkVersion, compileSdkVersionCodename: $compileSdkVersionCodename, sdkVersion: $sdkVersion, targetSdkVersion: $targetSdkVersion, label: $label, mainIcon: $mainIconPath, labels: $labels, usesPermissions: $usesPermissions, icons: $icons, application: $application, launchableActivity: $launchableActivity, userFeatures: $userFeatures, userFeaturesNotRequired: $userFeaturesNotRequired, userImpliedFeatures: $userImpliedFeatures, supportsScreens: $supportsScreens, locales: $locales, densities: $densities, supportsAnyDensity: $supportsAnyDensity, nativeCodes: $nativeCodes, others: $others, xapkName: $xapkName, splitConfigs: $splitConfigs, splitApks: $splitApks, archiveApks: $archiveApks, obbFiles: $obbFiles, totalSize: $totalSize}';
  }

  /// 释放持有的 GPU 资源（dart:ui.Image）
  void dispose() {
    for (final candidate in iconCandidates) {
      candidate.dispose();
    }
    iconCandidates.clear();
    // mainIconImage 指向某个候选的 renderedImage，已在上面释放
    mainIconImage = null;
  }

  void reset() {
    apkPath = "";
    apkSize = 0;
    isXapk = false;
    archiveType = null;
    packageName = null;
    versionCode = null;
    versionName = null;
    platformBuildVersionName = null;
    platformBuildVersionCode = null;
    compileSdkVersion = null;
    compileSdkVersionCodename = null;
    sdkVersion = null;
    targetSdkVersion = null;
    maxSdkVersion = null;
    applicationDebuggable = null;
    components.clear();
    manifestSource = FieldSource.unknown;
    hardeningObservations = [];
    structure = const apk_parser.ContainerStructure();
    label = null;
    mainIconPath = null;
    for (final candidate in iconCandidates) {
      candidate.dispose();
    }
    iconCandidates.clear();
    mainIconImage = null;
    labels.clear();
    usesPermissions.clear();
    icons.clear();
    application = Component();
    launchableActivity.clear();
    userFeatures.clear();
    userFeaturesNotRequired.clear();
    userImpliedFeatures.clear();
    supportsScreens.clear();
    locales.clear();
    densities.clear();
    supportsAnyDensity = null;
    nativeCodes.clear();
    others.clear();
    md5Hash = null;
    sha1Hash = null;
    xapkName = null;
    splitConfigs.clear();
    splitApks.clear();
    archiveApks.clear();
    obbFiles.clear();
    totalSize = null;
    originalText = "";
    securityResult = null;
  }
}

class Component {
  String? name;
  String? label;
  String? icon;

  Component({this.name, this.label, this.icon});

  @override
  String toString() {
    return 'Component{name: $name, label: $label, icon: $icon}';
  }
}
