// 安装页需要的 IPA 元数据：应用名、Bundle ID、版本、Build。
//
// 只读 `Payload/*.app/Info.plist` 一个条目 —— 不解 Mach-O、不碰 `Assets.car`。
// 安装页不是分析页：这里只需要在文件条上写清「这是哪个应用」，把整个 IPA
// 解析流水线搬过来会让选包多等几秒，也会把分析失败原因混进安装流程。
//
// 解析失败一律返回空值（各字段为 null），由界面退回文件名 —— 不编造名字。

import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:ipa_parser/ipa_parser.dart';

/// IPA 文件条上可展示的元数据。
class IpaInstallMetadata {
  /// `CFBundleDisplayName`，缺失时退回 `CFBundleName`。
  final String? displayName;

  /// `CFBundleIdentifier`。
  final String? bundleIdentifier;

  /// `CFBundleShortVersionString`（用户看到的版本号）。
  final String? version;

  /// `CFBundleVersion`（构建号）。
  final String? buildNumber;

  const IpaInstallMetadata({
    this.displayName,
    this.bundleIdentifier,
    this.version,
    this.buildNumber,
  });

  bool get hasAny =>
      (displayName?.isNotEmpty ?? false) ||
      (bundleIdentifier?.isNotEmpty ?? false) ||
      (version?.isNotEmpty ?? false) ||
      (buildNumber?.isNotEmpty ?? false);

  /// 读取 [path] 的元数据。任何失败都降级为空值，不抛。
  static Future<IpaInstallMetadata> read(String path) async {
    final zip = ZipHelper();
    try {
      final opened = await zip.open(path);
      final archive = zip.archive;
      if (!opened.isOk || archive == null) {
        log.warning(
            'IpaInstallMetadata: cannot open $path: ${opened.description}');
        return const IpaInstallMetadata();
      }
      final app = IpaContainerReader.read(archive).mainApp;
      if (app == null) {
        log.warning('IpaInstallMetadata: no Payload/*.app in $path');
        return const IpaInstallMetadata();
      }
      final info = IpaInfoPlistReader.read(archive, app);
      return IpaInstallMetadata(
        displayName: info.displayName.value ?? info.bundleName.value,
        bundleIdentifier: info.bundleIdentifier.value,
        version: info.shortVersionString.value,
        buildNumber: info.bundleVersion.value,
      );
    } catch (e) {
      log.warning('IpaInstallMetadata: failed to read $path: $e');
      return const IpaInstallMetadata();
    } finally {
      zip.close();
    }
  }
}
