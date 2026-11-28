// V3 统一组件身份。
//
// 为什么要单独建：现有 `LibraryReport` 的命中项（`LibraryHit`）是「识别结果」，
// 字段是 label / iconId / 规则 id，没有版本、没有生态、没有 PURL，也没有
// 「这个字段从哪来、可信到什么程度」。SBOM、漏洞匹配、SDK 差异都需要一个
// 可序列化、可比较的组件身份，所以在这里补一层，而不是让每个功能各自拼。
//
// 约束：
// - 拿不到的字段就是 null，不用 "unknown" 之类的字符串占位。
// - `confidence` 是识别可信度，不是版本可信度；版本未知时不能给 high。
// - `id` 不含分析 id 与文件路径，跨 run 稳定，便于差异对比。

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 组件所属生态。PURL 的 type 与之一一对应。
enum ComponentEcosystem {
  maven,
  npm,
  cocoapods,
  swift,
  generic;

  String get purlType => name;

  static ComponentEcosystem? fromName(String? value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return null;
  }
}

/// 组件所在平台。iOS 与 Android 的识别路径差异很大，保留在身份里。
enum ComponentPlatform {
  android,
  ios,
  unknown;

  static ComponentPlatform fromName(String? value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return unknown;
  }
}

/// 识别方式。写进 SBOM 的 evidence，也用于判断可信度上限。
enum ComponentIdentificationMethod {
  manifestName,
  mavenPom,
  dexPackage,
  nativeLibrary,
  componentClass,
  frameworkBundle,
  ruleMatch,
  userImport;

  static ComponentIdentificationMethod? fromName(String? value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return null;
  }
}

/// 识别可信度。
///
/// `high` 只允许在「名字与版本都可证实」时使用；只有包名前缀命中的，
/// 最多 `medium`。
enum ComponentConfidence {
  high,
  medium,
  low,
  unknown;

  static ComponentConfidence fromName(String? value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return unknown;
  }
}

/// 组件之间的关系类型。
enum ComponentRelationType {
  contains,
  dependsOn,
  evidencedBy;

  static ComponentRelationType? fromName(String? value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return null;
  }
}

/// PURL（Package URL）构造器。
///
/// 只实现本项目用得到的四种生态，但编码规则按 PURL 规范做，避免出现
/// 「看起来像 PURL、实际解析不了」的字符串。
class ComponentPurl {
  const ComponentPurl._();

  /// 构造 PURL；缺少名称时返回 null。
  ///
  /// - `namespace` 只对 maven 有意义（groupId）。
  /// - `qualifiers` 会按键名排序，保证同一身份生成同一字符串。
  /// - 没有版本时**不输出** `@`：`pkg:generic/foo` 表示「版本未知」。
  static String? build({
    required String? name,
    required ComponentEcosystem ecosystem,
    String? namespace,
    String? version,
    ComponentPlatform? platform,
    Map<String, String> qualifiers = const {},
  }) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;

    final segments = <String>[ecosystem.purlType];
    final ns = namespace?.trim();
    if (ns != null && ns.isNotEmpty) {
      segments.addAll(ns.split('/').where((s) => s.isNotEmpty).map(_encode));
    }
    segments.add(_encode(trimmed));

    final buffer = StringBuffer('pkg:${segments.join('/')}');
    final v = version?.trim();
    if (v != null && v.isNotEmpty) buffer.write('@${_encode(v)}');

    final q = <String, String>{
      if (platform != null && platform != ComponentPlatform.unknown)
        'platform': platform.name,
      ...qualifiers,
    };
    if (q.isNotEmpty) {
      final keys = q.keys.toList()..sort();
      buffer.write('?');
      buffer
          .write(keys.map((k) => '${_encode(k)}=${_encode(q[k]!)}').join('&'));
    }
    return buffer.toString();
  }

  /// PURL 的百分号编码：保留 RFC 3986 的非保留字符，其余全部编码。
  ///
  /// 说明：`/` 在这里也会被编码，命名空间的分隔由调用方用 `split('/')` 处理，
  /// 这样「名字里带斜杠」不会被误当成命名空间。
  static String _encode(String value) {
    const unreserved =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final char = String.fromCharCode(byte);
      if (unreserved.contains(char)) {
        buffer.write(char);
      } else {
        buffer
            .write('%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}');
      }
    }
    return buffer.toString();
  }
}

/// 一个可比较、可序列化的软件组件身份。
class Component {
  /// 本地稳定 id，不含分析 id 与路径。
  final String id;

  final String name;

  /// 版本未知必须为 null —— 不能写空串冒充「已知为空」。
  final String? version;

  final ComponentEcosystem ecosystem;
  final ComponentPlatform platform;

  /// 由 [ComponentPurl] 生成；名称缺失或生态未知时为 null。
  final String? purl;

  final String? supplier;

  /// SPDX 许可证标识（如 `Apache-2.0`）或原始许可证字符串。
  final List<String> licenses;

  /// 算法 → 小写十六进制摘要。
  final Map<String, String> hashes;

  /// 包内来源路径（`/` 分隔、去重、排序）。
  final List<String> sourceArtifacts;

  final ComponentIdentificationMethod? identification;
  final ComponentConfidence confidence;

  /// 识别所依赖的数据源版本（LibChecker dataVersion、内置规则版本等）。
  final String? sourceDatabaseVersion;

  /// 关系：[ComponentRelationType] → 目标组件 id 列表。
  final Map<ComponentRelationType, List<String>> relations;

  const Component({
    required this.id,
    required this.name,
    required this.ecosystem,
    required this.platform,
    this.version,
    this.purl,
    this.supplier,
    this.licenses = const [],
    this.hashes = const {},
    this.sourceArtifacts = const [],
    this.identification,
    this.confidence = ComponentConfidence.unknown,
    this.sourceDatabaseVersion,
    this.relations = const {},
  });

  /// 用可证实字段生成身份：名称 + 版本 + 生态 + 平台。
  ///
  /// 不带路径、不带分析 id —— 同一组件在不同包里应得到同一个 id，
  /// 这样版本差异才能按组件对齐。
  static Component create({
    required String name,
    ComponentEcosystem ecosystem = ComponentEcosystem.generic,
    ComponentPlatform platform = ComponentPlatform.unknown,
    String? version,
    String? namespace,
    String? supplier,
    List<String> licenses = const [],
    Map<String, String> hashes = const {},
    List<String> sourceArtifacts = const [],
    ComponentIdentificationMethod? identification,
    ComponentConfidence confidence = ComponentConfidence.unknown,
    String? sourceDatabaseVersion,
    Map<ComponentRelationType, List<String>> relations = const {},
  }) {
    final trimmedName = name.trim();
    final trimmedVersion = _trimToNull(version);
    final id = componentId(
      name: trimmedName,
      version: trimmedVersion,
      ecosystem: ecosystem,
      platform: platform,
    );
    final artifacts = sourceArtifacts
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return Component(
      id: id,
      name: trimmedName,
      version: trimmedVersion,
      ecosystem: ecosystem,
      platform: platform,
      purl: ComponentPurl.build(
        name: trimmedName,
        ecosystem: ecosystem,
        namespace: namespace,
        version: trimmedVersion,
        platform: platform,
      ),
      supplier: _trimToNull(supplier),
      licenses: List<String>.unmodifiable(licenses),
      hashes: Map<String, String>.unmodifiable(hashes),
      sourceArtifacts: List<String>.unmodifiable(artifacts),
      identification: identification,
      confidence: confidence,
      sourceDatabaseVersion: sourceDatabaseVersion,
      relations: Map<ComponentRelationType, List<String>>.unmodifiable({
        for (final entry in relations.entries)
          entry.key: List<String>.unmodifiable(entry.value),
      }),
    );
  }

  static String componentId({
    required String name,
    required ComponentEcosystem ecosystem,
    required ComponentPlatform platform,
    String? version,
  }) {
    // 用 \u0000 作分隔，避免 "a|b" 与 "a" + "|b" 撞车。
    final canonical = [
      ecosystem.name,
      platform.name,
      name.trim().toLowerCase(),
      (version ?? '').trim().toLowerCase(),
    ].join('\u0000');
    final digest = sha1.convert(utf8.encode(canonical)).toString();
    return 'cmp_${digest.substring(0, 16)}';
  }

  /// 展示用标签。版本未知时不拼 `@`。
  String get label => version == null ? name : '$name@$version';

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'ecosystem': ecosystem.name,
        'platform': platform.name,
        'purl': purl,
        'supplier': supplier,
        'licenses': licenses,
        'hashes': hashes,
        'sourceArtifacts': sourceArtifacts,
        'identification': identification?.name,
        'confidence': confidence.name,
        'sourceDatabaseVersion': sourceDatabaseVersion,
        'relations': {
          for (final entry in relations.entries) entry.key.name: entry.value,
        },
      };

  static Component fromJson(Map<String, Object?> json) {
    final name = (json['name'] as String?)?.trim();
    if (name == null || name.isEmpty) {
      throw const FormatException('component.name is required');
    }
    final ecosystem =
        ComponentEcosystem.fromName(json['ecosystem'] as String?) ??
            ComponentEcosystem.generic;
    final platform = ComponentPlatform.fromName(json['platform'] as String?);
    final id = (json['id'] as String?)?.trim();
    final relations = <ComponentRelationType, List<String>>{};
    final rawRelations = json['relations'];
    if (rawRelations is Map) {
      for (final entry in rawRelations.entries) {
        final type = ComponentRelationType.fromName(entry.key.toString());
        if (type == null) continue;
        final values = entry.value;
        if (values is List) {
          relations[type] = values.map((e) => e.toString()).toList();
        }
      }
    }
    return Component(
      id: (id == null || id.isEmpty)
          ? componentId(
              name: name,
              ecosystem: ecosystem,
              platform: platform,
              version: json['version'] as String?,
            )
          : id,
      name: name,
      version: _trimToNull(json['version'] as String?),
      ecosystem: ecosystem,
      platform: platform,
      purl: _trimToNull(json['purl'] as String?),
      supplier: _trimToNull(json['supplier'] as String?),
      licenses: _stringList(json['licenses']),
      hashes: _stringMap(json['hashes']),
      sourceArtifacts: _stringList(json['sourceArtifacts']),
      identification: ComponentIdentificationMethod.fromName(
          json['identification'] as String?),
      confidence: ComponentConfidence.fromName(json['confidence'] as String?),
      sourceDatabaseVersion:
          _trimToNull(json['sourceDatabaseVersion'] as String?),
      relations: relations,
    );
  }

  static String? _trimToNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    final out = <String, String>{};
    for (final entry in value.entries) {
      final v = entry.value;
      if (v is String && v.isNotEmpty) out[entry.key.toString()] = v;
    }
    return out;
  }
}
