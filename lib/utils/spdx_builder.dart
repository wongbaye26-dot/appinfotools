// SPDX 2.3（JSON）导出（V3 F03 3.5）。
//
// 与 CycloneDX 共用同一份 Component 列表：两个格式只是外壳不同，组件身份
// （id / purl）必须一致，否则同一个包导出两份互相矛盾的清单。
//
// 刻意留空的地方：
// - `licenseConcluded` / `licenseDeclared` = NOASSERTION（没有许可证数据源）；
// - `downloadLocation` = NOASSERTION（不知道从哪下载）；
// - `filesAnalyzed: false`（没做逐文件校验和）。

import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:crypto/crypto.dart';

class SpdxBuilder {
  static const String spdxVersion = 'SPDX-2.3';

  static Map<String, dynamic> build({
    required String appName,
    required List<Component> components,
    String? appVersion,
    String? packageName,
    String? packageSha256,
    String? toolVersion,
    DateTime? timestamp,
    String? documentNamespace,
  }) {
    final at = (timestamp ?? DateTime.now()).toUtc();
    final appSpdxId = 'SPDXRef-Application';
    final namespace = documentNamespace ??
        'https://appinfotool.local/spdx/${_digest([
          appName,
          appVersion ?? '',
          packageName ?? '',
          packageSha256 ?? ''
        ].join('|'))}';

    final packages = <Map<String, dynamic>>[
      {
        'SPDXID': appSpdxId,
        'name': appName,
        if (appVersion != null) 'versionInfo': appVersion,
        'downloadLocation': 'NOASSERTION',
        'filesAnalyzed': false,
        'licenseConcluded': 'NOASSERTION',
        'licenseDeclared': 'NOASSERTION',
        if (packageName != null)
          'externalRefs': [
            {
              'referenceCategory': 'PACKAGE-MANAGER',
              'referenceType': 'purl',
              'referenceLocator':
                  'pkg:generic/${_encode(packageName)}@${_encode(appVersion ?? 'unknown')}',
            },
          ],
        if (packageSha256 != null)
          'checksums': [
            {'algorithm': 'SHA256', 'checksumValue': packageSha256},
          ],
      },
      for (final component in components)
        {
          'SPDXID': _spdxId(component),
          'name': component.name,
          if (component.version != null) 'versionInfo': component.version,
          'downloadLocation': 'NOASSERTION',
          'filesAnalyzed': false,
          'licenseConcluded': 'NOASSERTION',
          'licenseDeclared': 'NOASSERTION',
          if (component.supplier != null)
            'supplier': 'Organization: ${component.supplier}',
          if (component.purl != null)
            'externalRefs': [
              {
                'referenceCategory': 'PACKAGE-MANAGER',
                'referenceType': 'purl',
                'referenceLocator': component.purl,
              },
            ],
        },
    ];

    return {
      'spdxVersion': spdxVersion,
      'dataLicense': 'CC0-1.0',
      'SPDXID': 'SPDXRef-DOCUMENT',
      'name': '$appName SBOM',
      'documentNamespace': namespace,
      'creationInfo': {
        'created': at.toIso8601String(),
        'creators': [
          if (toolVersion != null)
            'Tool: AppInfoTool-$toolVersion'
          else
            'Tool: AppInfoTool',
        ],
        'comment':
            'Generated locally by AppInfoTool. Licenses and download locations '
                'are NOASSERTION: this tool has no external data source.',
      },
      'packages': packages,
      'relationships': [
        {
          'spdxElementId': 'SPDXRef-DOCUMENT',
          'relationshipType': 'DESCRIBES',
          'relatedSpdxElement': appSpdxId,
        },
        for (final component in components)
          {
            'spdxElementId': appSpdxId,
            'relationshipType': 'CONTAINS',
            'relatedSpdxElement': _spdxId(component),
          },
      ],
    };
  }

  static String toJsonString(Map<String, dynamic> document) =>
      const JsonEncoder.withIndent('  ').convert(document);

  /// SPDXID 只允许字母、数字、`.` 与 `-`；用组件 id 派生保证稳定且唯一。
  static String _spdxId(Component component) =>
      'SPDXRef-${component.id.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '-')}';

  static String _digest(String seed) =>
      sha256.convert(utf8.encode(seed)).toString().substring(0, 32);

  static String _encode(String value) {
    const unreserved =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final char = String.fromCharCode(byte);
      buffer.write(unreserved.contains(char)
          ? char
          : '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
    return buffer.toString();
  }
}
