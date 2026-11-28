// SBOM 导出（V3 F03）：把库识别结果转成 CycloneDX 1.5 JSON。
//
// 为什么只做「组件清单」：CycloneDX 的漏洞/依赖图需要外部数据源，本项目
// 离线运行、没有漏洞库（F08 才做）；硬塞空的 vulnerabilities 会让工具
// 显示「0 漏洞」，那比不写更误导。
//
// 组件身份：名称取 LibChecker 规则的 label（人可读），版本在规则里没有，
// 因此不编造 `version` 字段，而是在 properties 里写命中证据（规则 id、
// 命中数、命中类型），让读者能回到「为什么认为它存在」。

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:apk_parser/apk_parser.dart';

/// 一个待写入 SBOM 的组件（与应用自身解耦，便于单测）。
class SbomComponent {
  final String name;
  final String? version;
  final String? purl;
  final Map<String, String> properties;

  const SbomComponent({
    required this.name,
    this.version,
    this.purl,
    this.properties = const {},
  });
}

class SbomBuilder {
  static const String specVersion = '1.5';

  /// 从库识别结果提炼组件：原生库 / 组件 / DEX 三类分组都算「存在证据」。
  static List<SbomComponent> fromLibraryReport(LibraryReport? libraries) {
    if (libraries == null) return const [];
    final components = <SbomComponent>[];
    void addGroup(LibraryGroup group, String kind) {
      components.add(
        SbomComponent(
          name: group.label,
          purl: 'pkg:generic/${_encode(group.label)}',
          properties: {
            'appinfotool:matchKind': kind,
            'appinfotool:ruleId': '${group.rule.id}',
            'appinfotool:hitCount': '${group.count}',
          },
        ),
      );
    }

    for (final group in libraries.nativeGroups) {
      addGroup(group, 'nativeLibrary');
    }
    for (final group in libraries.componentGroups) {
      addGroup(group, 'component');
    }
    for (final group in libraries.dexGroups) {
      addGroup(group, 'dexPackage');
    }
    return components;
  }

  /// 生成 CycloneDX 1.5 JSON（Map，调用方负责编码）。
  static Map<String, dynamic> buildCycloneDx({
    required String appName,
    required List<SbomComponent> components,
    String? appVersion,
    String? packageName,
    String? packageSha256,
    String? toolVersion,
    DateTime? timestamp,
    String? serialNumber,
  }) {
    final at = (timestamp ?? DateTime.now()).toUtc();
    final appRef = packageName == null
        ? 'app'
        : 'pkg:generic/${_encode(packageName)}@${_encode(appVersion ?? 'unknown')}';

    return {
      'bomFormat': 'CycloneDX',
      'specVersion': specVersion,
      'serialNumber': serialNumber ??
          _serial(
            [appName, appVersion ?? '', packageName ?? '', packageSha256 ?? '']
                .join('|'),
          ),
      'version': 1,
      'metadata': {
        'timestamp': at.toIso8601String(),
        'tools': [
          {
            'vendor': 'AppInfoTool',
            'name': 'AppInfoTool',
            if (toolVersion != null) 'version': toolVersion,
          },
        ],
        'component': {
          'type': 'application',
          'bom-ref': appRef,
          'name': appName,
          if (appVersion != null) 'version': appVersion,
          if (packageName != null) 'purl': appRef,
        },
        'properties': [
          if (packageSha256 != null)
            {'name': 'appinfotool:packageSha256', 'value': packageSha256},
        ],
      },
      'components': [
        for (final component in components)
          () {
            final purl = component.purl ??
                'pkg:generic/${_encode(component.name)}'
                    '${component.version == null ? '' : '@${_encode(component.version!)}'}';
            return {
              'type': 'library',
              'bom-ref': purl,
              'name': component.name,
              if (component.version != null) 'version': component.version,
              'purl': purl,
              if (component.properties.isNotEmpty)
                'properties': [
                  for (final entry in component.properties.entries)
                    {'name': entry.key, 'value': entry.value},
                ],
            };
          }(),
      ],
    };
  }

  static String toJsonString(Map<String, dynamic> bom) =>
      const JsonEncoder.withIndent('  ').convert(bom);

  /// 稳定序列号：同样输入得到同样 UUID，便于跨次比对「同一份清单」。
  static String _serial(String seed) {
    final hex = sha256.convert(utf8.encode(seed)).toString();
    final s = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '5${hex.substring(13, 16)}-'
        'a${hex.substring(17, 20)}-${hex.substring(20, 32)}';
    return 'urn:uuid:$s';
  }

  /// purl 段编码：只保留 RFC3986 非保留字符。
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
