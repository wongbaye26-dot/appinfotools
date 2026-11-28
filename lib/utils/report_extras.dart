import 'package:analysis_model/analysis_model.dart' show SecretMatch;
import 'package:apk_parser/apk_parser.dart';
import 'package:ipa_parser/ipa_parser.dart' show X509CertificateInfo;
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/utils/libchecker_data.dart';
import 'package:apk_info_tool/utils/secret_scan_service.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// 报告里「界面能看到、JSON 里没有」的那部分事实。
///
/// 权限说明与库识别都需要异步准备（读资产、扫 DEX），而
/// `AnalysisReport.render*` 是纯函数。所以由调用方先算好，再作为可选入参传进去：
/// 不给就退回旧行为，给了就多出对应的段落/键。
class ReportExtras {
  /// 敏感信息命中（只有脱敏值与指纹，草稿里不出现明文）。
  final List<SecretMatch>? secrets;

  const ReportExtras({
    this.secrets,
    this.permissions,
    this.libraries,
    this.certificates,
  });

  /// 逐权限的风险与保护级别。`null` 表示没准备（不是「没有权限」）。
  final List<PermissionFact>? permissions;

  /// 库识别结果。`null` 表示没准备（不是「没识别到 SDK」）。
  final LibraryReport? libraries;

  /// 从包内证书里读到的事实（Android 本地读取 + iOS 证书链）。
  ///
  /// `null` 表示没采集（XAPK 这类容器读不到 base APK 的签名、或解析失败），
  /// 空数组表示**读了、一个证书都没有** —— 这两种情况在报告里必须分开。
  final List<CertificateFact>? certificates;

  bool get isEmpty =>
      permissions == null && libraries == null && certificates == null;

  /// 采集报告需要的异步数据。
  ///
  /// 任何一步失败都只让对应部分变成 `null`，并记一条日志 —— 导出报告不能
  /// 因为「顺带补充」的数据读不到而整体失败。
  static Future<ReportExtras> collect({
    required PackageAnalysisResult result,
    String? archivePath,
    bool includePermissions = true,
    bool includeLibraries = true,
    bool includeSecrets = true,
  }) async {
    final android = result.android;

    List<PermissionFact>? permissions;
    // iOS 没有 Android 权限表，但仍然有证书链要导出 —— 不能因为
    // `android == null` 就整体提前返回（v10 的写法会丢 iOS 证书）。
    if (includePermissions && android != null) {
      try {
        await AndroidMetadata.instance.ensureLoaded();
        final names = android.permissions.value ?? const <String>[];
        const prefix = 'android.permission.';
        final meta = AndroidMetadata.instance;
        permissions = [
          for (final name in names)
            PermissionFact(
              name: name,
              shortName: name.startsWith(prefix)
                  ? name.substring(prefix.length)
                  : null,
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

    List<SecretMatch>? secrets;
    if (includeSecrets && archivePath != null) {
      try {
        final report = await SecretScanService.scan(archivePath);
        secrets = report?.matches;
      } catch (error, stack) {
        log.warning('ReportExtras: 敏感信息扫描失败: \$error', error, stack);
      }
    }

    LibraryReport? libraries;
    if (includeLibraries && archivePath != null && android != null) {
      try {
        libraries = await _librariesOf(result, android, archivePath);
      } catch (error, stack) {
        log.warning('ReportExtras: 库识别失败: $error', error, stack);
      }
    }

    return ReportExtras(
      permissions: permissions,
      libraries: libraries,
      certificates: _certificatesOf(result),
      secrets: secrets,
    );
  }

  /// 证书事实：Android 从包内 PKCS#7 / Signing Block 读，iOS 从描述文件
  /// 的 CMS 证书链读。两边的证书结构相同（都是 X.509），因此合并成一个
  /// 平台无关的列表，只多一个 `platform` 字段。
  static List<CertificateFact>? _certificatesOf(
    PackageAnalysisResult result,
  ) {
    final facts = <CertificateFact>[];
    var collected = false;

    final android = result.android;
    if (android != null) {
      // `signature` 为 null 表示没做签名分析（XAPK 等），不是「没有证书」；
      // 只有非 null 才算采集过。
      if (android.signature != null) {
        collected = true;
        for (final certificate in android.signature!.localCertificates) {
          facts.add(CertificateFact(
            platform: 'android',
            scheme: certificate.scheme,
            signerIndex: certificate.signerIndex,
            details: certificate.details,
          ));
        }
      }
    }

    final ios = result.ios;
    if (ios != null) {
      final chain = ios.signatureMaterials?.certificateChain;
      if (chain != null) {
        collected = true;
        for (final certificate in chain.certificates) {
          facts.add(CertificateFact(
            platform: 'ios',
            details: certificate,
          ));
        }
      }
    }

    return collected ? facts : null;
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

/// 一张证书在报告里的投影。
///
/// 字段与界面上「签名」面板一致：主体、签发者、序列号、有效期、算法、
/// 密钥长度与三种指纹。指纹用 `X509Parser.formatFingerprint` 的冒号大写形式，
/// 与 apksigner / keytool 的输出一致，方便和外部结果对照。
class CertificateFact {
  const CertificateFact({
    required this.platform,
    required this.details,
    this.scheme,
    this.signerIndex,
  });

  /// `android` / `ios`。
  final String platform;

  /// Android 的签名方案（v1/v2/v3/v3.1）；iOS 没有这个概念，为 null。
  final String? scheme;

  final int? signerIndex;
  final X509CertificateInfo details;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'scheme': scheme,
        'signerIndex': signerIndex,
        'subject': details.subject,
        'issuer': details.issuer,
        'serialNumber': details.serialNumberHex,
        'notBefore': details.notBefore?.toUtc().toIso8601String(),
        'notAfter': details.notAfter?.toUtc().toIso8601String(),
        'signatureAlgorithm': details.signatureAlgorithm,
        'keyAlgorithm': details.publicKeyAlgorithm,
        'keySizeBits': details.publicKeyBits,
        'publicKeyCurve': details.publicKeyCurve,
        'sha256': details.sha256Fingerprint,
        'sha1': details.sha1Fingerprint,
        'md5': details.md5Fingerprint,
      };
}
