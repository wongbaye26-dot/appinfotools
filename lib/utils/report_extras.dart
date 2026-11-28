import 'package:apk_parser/apk_parser.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/utils/libchecker_data.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// 报告里「界面能看到、JSON 里没有」的那部分事实。
///
/// 权限说明与库识别都需要异步准备（读资产、扫 DEX），而
/// `AnalysisReport.render*` 是纯函数。所以由调用方先算好，再作为可选入参传进去：
/// 不给就退回旧行为，给了就多出对应的段落/键。
class ReportExtras {
  const ReportExtras({this.permissions, this.libraries});

  /// 逐权限的风险与保护级别。`null` 表示没准备（不是「没有权限」）。
  final List<PermissionFact>? permissions;

  /// 库识别结果。`null` 表示没准备（不是「没识别到 SDK」）。
  final LibraryReport? libraries;

  bool get isEmpty => permissions == null && libraries == null;

  /// 采集报告需要的异步数据。
  ///
  /// 任何一步失败都只让对应部分变成 `null`，并记一条日志 —— 导出报告不能
  /// 因为「顺带补充」的数据读不到而整体失败。
  static Future<ReportExtras> collect({
    required PackageAnalysisResult result,
    String? archivePath,
    bool includePermissions = true,
    bool includeLibraries = true,
  }) async {
    final android = result.android;
    if (android == null) return const ReportExtras();

    List<PermissionFact>? permissions;
    if (includePermissions) {
      try {
        await AndroidMetadata.instance.ensureLoaded();
        final names = android.permissions.value ?? const <String>[];
        const prefix = 'android.permission.';
        final meta = AndroidMetadata.instance;
        permissions = [
          for (final name in names)
            PermissionFact(
              name: name,
              shortName:
                  name.startsWith(prefix) ? name.substring(prefix.length) : null,
              label: meta.permissionLabel(name),
              description: meta.permissionDescription(name),
              risk: meta.riskOf(name),
              base: meta.protectionOf(name)?.base,
              raw: meta.protectionOf(name)?.raw,
              flags: meta.protectionOf(name)?.flags ?? const [],
            ),
        ];
      } catch (error, stack) {
        log.warning('ReportExtras: 权限说明读取失败: $error', error, stack);
      }
    }

    LibraryReport? libraries;
    if (includeLibraries && archivePath != null) {
      try {
        libraries = await _librariesOf(result, android, archivePath);
      } catch (error, stack) {
        log.warning('ReportExtras: 库识别失败: $error', error, stack);
      }
    }

    return ReportExtras(permissions: permissions, libraries: libraries);
  }

  /// 与「库识别」页同一套输入：容器里的 `.so`、组件、DEX 类名前缀。
  static Future<LibraryReport> _librariesOf(
    PackageAnalysisResult result,
    AndroidPackageInfo android,
    String archivePath,
  ) async {
    final rules = await LibCheckerData.ensureLoaded();
    final reader = ApkReader();
    final open = await reader.open(archivePath);
    if (!open.isOk) {
      reader.close();
      throw StateError('无法打开安装包: ${open.description}');
    }

    var dex = DexLibrarySignals.empty;
    var scannedBytes = 0;
    try {
      final names = reader.listFiles();
      for (final name in names) {
        if (!RegExp(r'^classes\d*\.dex$').hasMatch(name)) continue;
        final bytes = reader.readFile(name);
        if (bytes == null) continue;
        if (scannedBytes + bytes.length > 96 * 1024 * 1024) {
          dex = dex.merge(DexLibrarySignals.truncatedMarker);
          break;
        }
        scannedBytes += bytes.length;
        dex = dex.merge(DexLibraryScanner.scan(bytes));
      }

      return LibraryDetector.detect(
        rules: rules,
        packageName: result.packageId.value ?? '',
        nativeLibraries: android.structure?.nativeLibraries ?? const [],
        components: android.components.value ?? const [],
        dex: dex,
        archiveEntries: names.toSet(),
      );
    } finally {
      reader.close();
    }
  }
}

/// 一条权限在报告里的投影：机器可读的分级 + 人可读的官方文案。
class PermissionFact {
  const PermissionFact({
    required this.name,
    required this.risk,
    this.base,
    this.raw,
    required this.flags,
    this.shortName,
    this.label,
    this.description,
  });

  /// 完整权限名（`android.permission.CAMERA`）。
  final String name;

  /// `AndroidMetadata` 的短名（`CAMERA`）；非框架权限为 `null`。
  final String? shortName;

  /// 官方标题/说明；当前界面语言下没有文案时是 `null`。
  final String? label;
  final String? description;

  final AndroidPermissionRisk risk;

  /// 平台保护级别；不在 1102 条表里时为 `null`（不猜成 normal）。
  final AndroidProtectionBase? base;

  /// `protectionLevel` 原始位掩码；不在 1102 条表里时为 `null`。
  final int? raw;
  final List<String> flags;
}
