/// 只读「应用名 + 版本」的轻量读取器 —— 专为**批量重命名**服务。
///
/// 与 `getApkInfo` 的区别是**只做这一件事**：`getApkInfo` 会跑完整解析
/// （资源表、DEX 方法扫描、原生库符号、载荷探测、图标渲染、安全审计）。
/// 批量重命名只需要一个名字和一个版本号，却要为每个文件付整条流水线的
/// 代价 —— 选 20 个包就要等几分钟，而且那几分钟里没有任何进度。
///
/// 这里做的事：
/// - `.ipa`：读 `Payload/*.app/Info.plist`（几十 KB），不碰 Mach-O；
/// - `.xapk` / `.apkm` / `.apks`：读容器里的 `manifest.json`；
/// - 其余（`.apk` / `.apk.1` / 改名的 zip）：只解析 `AndroidManifest.xml`
///   与 `resources.arsc`（`android:label` 常常是 `@string/app_name`，
///   必须靠资源表才能解出真正的名字）。
///
/// 三条路径都**不渲染图标、不跑安全审计**。
library;

import 'dart:isolate';

import 'package:apk_info_tool/apkparser/xapk_info.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:path/path.dart' as p;

/// 身份信息来自哪个平台。
///
/// 只影响界面上的图标与文案，不参与重命名决策 —— 重命名只认扩展名。
enum PackageIdentityPlatform { android, ios, unknown }

/// 一个包的「叫什么 / 什么版本」。
class PackageIdentity {
  /// 应用显示名。取不到时为空字符串（调用方退回文件名）。
  final String appName;

  /// 版本名（Android `versionName` / iOS `CFBundleShortVersionString`）。
  final String version;

  final PackageIdentityPlatform platform;

  /// 取不到时的**具体原因**（英文，面向诊断）。
  ///
  /// 不用它拼界面文案：界面上只需要知道「这个文件读不出名字，将按文件名
  /// 重命名」，具体原因进日志。留字段是为了排查「为什么 20 个文件里
  /// 有 3 个用的是文件名」时不必再复现一遍。
  final String? failure;

  const PackageIdentity({
    required this.appName,
    required this.version,
    required this.platform,
    this.failure,
  });

  /// 是否取到了可用的应用名。
  bool get hasAppName => appName.trim().isNotEmpty;

  /// 是否取到了可用的版本号。
  bool get hasVersion => version.trim().isNotEmpty;

  @override
  String toString() => 'PackageIdentity($platform, name: $appName, '
      'version: $version, failure: $failure)';
}

/// 读取一个包的应用名与版本。
///
/// 在**独立 isolate** 里跑：`ApkReader.open` / `parse` 是同步 CPU 计算，
/// 直接在主 isolate 上连读 20 个包会把界面冻住（这正是「批量重命名像卡死」
/// 的一半原因）。
///
/// 任何异常都被兜成「取不到名字」而不是抛出 —— 批量重命名不应该因为
/// 一个坏文件整体失败。
Future<PackageIdentity> readPackageIdentity(String path) async {
  try {
    return await Isolate.run(() => readPackageIdentityInIsolate(path));
  } catch (e) {
    log.warning('readPackageIdentity: $path failed: $e');
    return PackageIdentity(
      appName: '',
      version: '',
      platform: PackageIdentityPlatform.unknown,
      failure: '$e',
    );
  }
}

/// 同 [readPackageIdentity]，但在**当前** isolate 里执行。
///
/// 测试与「已经在 worker 里」的调用方用它；生产路径走 [readPackageIdentity]。
Future<PackageIdentity> readPackageIdentityInIsolate(String path) async {
  final extension = p.extension(path).toLowerCase();
  if (extension == '.ipa') return _readIpa(path);
  if (_archiveExtensions.contains(extension)) {
    final archiveIdentity = await _readArchiveManifest(path);
    if (archiveIdentity != null) return archiveIdentity;
    // 没有 `manifest.json`：可能是一个改名为 .xapk 的普通 APK，继续按
    // APK 读，而不是直接放弃。
  }
  return _readApk(path);
}

/// 带 `manifest.json` 的容器格式。
const Set<String> _archiveExtensions = {'.xapk', '.apkm', '.apks'};

/// 读容器自带的 `manifest.json`；没有就返回 `null`（交给 APK 路径兜底）。
Future<PackageIdentity?> _readArchiveManifest(String path) async {
  try {
    final manifest = await parseXapkManifest(path);
    if (manifest == null) return null;
    return PackageIdentity(
      appName: manifest.name?.trim() ?? '',
      version: manifest.versionName?.trim() ?? '',
      platform: PackageIdentityPlatform.android,
    );
  } catch (e) {
    log.warning('_readArchiveManifest: $path failed: $e');
    return null;
  }
}

Future<PackageIdentity> _readApk(String path) async {
  final reader = ApkReader();
  try {
    final open = await reader.open(path);
    if (!open.isOk) {
      return PackageIdentity(
        appName: '',
        version: '',
        platform: PackageIdentityPlatform.unknown,
        failure: 'open failed: ${open.description}',
      );
    }
    final meta = await reader.parse();
    if (meta == null) {
      return PackageIdentity(
        appName: '',
        version: '',
        platform: PackageIdentityPlatform.android,
        failure: reader.manifestFailure ?? 'AndroidManifest.xml unreadable',
      );
    }
    return PackageIdentity(
      appName: meta.label?.trim() ?? '',
      version: meta.versionName?.trim() ?? '',
      platform: PackageIdentityPlatform.android,
      failure: meta.manifestUnparsed ? meta.manifestParseFailure : null,
    );
  } catch (e) {
    return PackageIdentity(
      appName: '',
      version: '',
      platform: PackageIdentityPlatform.unknown,
      failure: '$e',
    );
  } finally {
    reader.close();
  }
}

Future<PackageIdentity> _readIpa(String path) async {
  final zip = ZipHelper();
  try {
    final open = await zip.open(path);
    if (!open.isOk) {
      return PackageIdentity(
        appName: '',
        version: '',
        platform: PackageIdentityPlatform.ios,
        failure: 'open failed: ${open.description}',
      );
    }
    final archive = zip.archive;
    if (archive == null) {
      return const PackageIdentity(
        appName: '',
        version: '',
        platform: PackageIdentityPlatform.ios,
        failure: 'the archive could not be opened',
      );
    }
    final container = IpaContainerReader.read(archive);
    final app = container.mainApp;
    if (app == null) {
      return const PackageIdentity(
        appName: '',
        version: '',
        platform: PackageIdentityPlatform.ios,
        failure: 'no Payload/*.app bundle was found',
      );
    }
    // 只读这一个 plist；不解析 Mach-O、不读图标。
    final info = IpaInfoPlistReader.read(archive, app);
    final name = info.displayName.value ?? info.bundleName.value ?? '';
    final version =
        info.shortVersionString.value ?? info.bundleVersion.value ?? '';
    return PackageIdentity(
      appName: name.trim(),
      version: version.trim(),
      platform: PackageIdentityPlatform.ios,
      failure:
          name.trim().isEmpty ? 'Info.plist has no bundle display name' : null,
    );
  } catch (e) {
    return PackageIdentity(
      appName: '',
      version: '',
      platform: PackageIdentityPlatform.ios,
      failure: '$e',
    );
  } finally {
    zip.close();
  }
}
