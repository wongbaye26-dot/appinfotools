// 隐私清单（V3 F02）：把「权限风险 + SDK + iOS 用途声明」聚合成一份可解释的视图。
//
// 这里**不新增扫描**：Android 权限来自已解析的 manifest，iOS 用途声明来自
// 已解析的 Info.plist，SDK 来自库识别结果。F02 的价值是把三处事实放到同一
// 个视角下，而不是再造一套判定。

import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:ipa_parser/ipa_parser.dart' show IpaInfoPlist;

/// 一条与隐私相关的权限事实。
class PrivacyPermission {
  final String name;
  final String shortName;
  final String? label;
  final String? description;
  final AndroidPermissionRisk risk;

  const PrivacyPermission({
    required this.name,
    required this.shortName,
    required this.risk,
    this.label,
    this.description,
  });
}

/// 一个与隐私相关的 SDK（来自库识别的分组）。
class PrivacySdk {
  final String label;
  final String kind;
  final int hitCount;

  const PrivacySdk({
    required this.label,
    required this.kind,
    required this.hitCount,
  });
}

class PrivacyInventory {
  /// 是否读到了权限列表；false 时所有计数都不可信。
  final bool permissionsRead;

  final int totalPermissions;
  final Map<AndroidPermissionRisk, int> riskCounts;

  /// 高敏 + 敏感权限（已按风险排序），供界面直接展示。
  final List<PrivacyPermission> notable;

  /// 库识别命中的 SDK；空列表表示「没识别到」或「没加载库识别」。
  final List<PrivacySdk> sdks;
  final bool librariesRead;

  /// iOS：Info.plist 里声明的用途说明键。
  final List<String> iosUsageKeys;

  const PrivacyInventory({
    required this.permissionsRead,
    required this.totalPermissions,
    required this.riskCounts,
    required this.notable,
    required this.sdks,
    required this.librariesRead,
    required this.iosUsageKeys,
  });

  int countOf(AndroidPermissionRisk risk) => riskCounts[risk] ?? 0;

  bool get isEmpty =>
      totalPermissions == 0 && sdks.isEmpty && iosUsageKeys.isEmpty;

  static PrivacyInventory collect({
    required PackageAnalysisResult result,
    IpaInfoPlist? infoPlist,
    LibraryReport? libraries,
  }) {
    final metadata = AndroidMetadata.instance;
    final permissions = result.android?.permissions;
    final read = permissions != null && permissions.hasValue;

    final riskCounts = <AndroidPermissionRisk, int>{};
    final notable = <PrivacyPermission>[];
    var total = 0;
    if (read) {
      for (final name in permissions.value!) {
        total++;
        final risk = metadata.riskOf(name);
        riskCounts.update(risk, (value) => value + 1, ifAbsent: () => 1);
        if (risk == AndroidPermissionRisk.high ||
            risk == AndroidPermissionRisk.sensitive) {
          final short = name.startsWith('android.permission.')
              ? name.substring('android.permission.'.length)
              : name;
          notable.add(
            PrivacyPermission(
              name: name,
              shortName: short,
              label: metadata.permissionLabel(name),
              description: metadata.permissionDescription(name),
              risk: risk,
            ),
          );
        }
      }
      notable.sort((a, b) {
        final byRisk = a.risk.index.compareTo(b.risk.index);
        if (byRisk != 0) return byRisk;
        return a.shortName.compareTo(b.shortName);
      });
    }

    final sdks = <PrivacySdk>[];
    if (libraries != null) {
      void add(LibraryGroup group, String kind) {
        sdks.add(
          PrivacySdk(label: group.label, kind: kind, hitCount: group.count),
        );
      }

      for (final group in libraries.nativeGroups) {
        add(group, 'nativeLibrary');
      }
      for (final group in libraries.componentGroups) {
        add(group, 'component');
      }
      for (final group in libraries.dexGroups) {
        add(group, 'dexPackage');
      }
      sdks.sort((a, b) => b.hitCount.compareTo(a.hitCount));
    }

    final usage = infoPlist?.privacyUsageDescriptions;
    final usageKeys = usage != null && usage.hasValue
        ? (usage.value!.keys.toList()..sort())
        : const <String>[];

    return PrivacyInventory(
      permissionsRead: read,
      totalPermissions: total,
      riskCounts: riskCounts,
      notable: notable,
      sdks: sdks,
      librariesRead: libraries != null,
      iosUsageKeys: usageKeys,
    );
  }
}
