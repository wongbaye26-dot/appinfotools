import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'tool_paths.dart';

/// 从上游 `portable-v5.zip` 导入规则，写入应用数据目录，供 [LibCheckerData]
/// 优先于内置资产加载。
///
/// 为什么不直接读 zip：应用启动后每次识别都要规则，解析 4.6 MB zip 只该发生
/// 一次。导入时把上游结构折成与内置资产相同的紧凑 JSON，之后加载路径完全一致。
class LibCheckerImportException implements Exception {
  const LibCheckerImportException(this.code, this.detail);

  /// 稳定错误码，界面据此给文案（`not_zip` / `schema` / `empty` / `io`）。
  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

class LibCheckerImportResult {
  const LibCheckerImportResult({
    required this.bundle,
    required this.icons,
    required this.dataVersion,
    required this.sourceRevision,
    required this.ruleCount,
    required this.sha256,
  });

  final Map<String, dynamic> bundle;
  final Map<String, String> icons;
  final int dataVersion;
  final String? sourceRevision;
  final int ruleCount;
  final String sha256;
}

/// 上游 portable zip → 紧凑 bundle（与 `assets/libchecker/libchecker_v5.json` 同构）。
class LibCheckerRulesImporter {
  LibCheckerRulesImporter._();

  static const maxBytes = 64 * 1024 * 1024;

  static Future<LibCheckerImportResult> fromPortableZip(Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw const LibCheckerImportException('not_zip', 'empty file');
    }
    if (bytes.length > maxBytes) {
      throw const LibCheckerImportException('too_large', null);
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
    } catch (e) {
      throw LibCheckerImportException('not_zip', e.toString());
    }

    final files = <String, ArchiveFile>{
      for (final file in archive.files)
        if (file.isFile) file.name: file,
    };

    Map<String, dynamic>? readJson(String name) {
      final file = files[name];
      if (file == null) return null;
      try {
        return jsonDecode(utf8.decode(file.content)) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }

    final metadata = readJson('metadata.json');
    final core = readJson('core.json');
    if (core == null) {
      throw const LibCheckerImportException('not_zip', 'missing core.json');
    }
    const supportedSchema = 5;
    final schema = core['schemaVersion'];
    if (schema != supportedSchema) {
      throw LibCheckerImportException(
        'schema',
        'schemaVersion=$schema, expected $supportedSchema',
      );
    }

    final rawRules = (core['rules'] as List?)?.cast<Map<String, dynamic>>();
    if (rawRules == null || rawRules.isEmpty) {
      throw const LibCheckerImportException('empty', 'no rules');
    }

    final detailIndex = <String, int>{};
    final details = <Map<String, dynamic>>[];
    final rows = <List<dynamic>>[];
    final regexIds = <int>[];
    var usable = 0;

    for (final rule in rawRules) {
      final id = rule['id'];
      final type = rule['type'];
      if (id is! int || type is! int) continue;

      var index = -1;
      final detailPath = rule['detailPath'];
      if (detailPath is String && detailPath.isNotEmpty) {
        final detailFile = files[detailPath];
        final raw = detailFile == null
            ? null
            : _decodeDetail(utf8.decode(detailFile.content));
        if (raw != null) {
          final key = jsonEncode(raw);
          index = detailIndex[key] ??= () {
            details.add(raw);
            return details.length - 1;
          }();
        }
      }

      rows.add([
        id,
        rule['name'] ?? '',
        rule['label'] ?? '',
        type,
        rule['iconId'] ?? '',
        (rule['isSimpleColorIcon'] == true) ? 1 : 0,
        index,
        rule['priority'] ?? id,
      ]);
      if (rule['isRegexRule'] == true) regexIds.add(id);
      if (LibCheckerRuleType.supported.contains(type)) usable++;
    }

    if (rows.isEmpty) {
      throw const LibCheckerImportException('empty', 'no usable rules');
    }

    final icons = <String, String>{};
    for (final entry in files.entries) {
      final name = entry.key;
      if (!name.startsWith('icons/') || !name.endsWith('.svg')) continue;
      final iconId = p.basenameWithoutExtension(name);
      try {
        icons[iconId] = utf8.decode(entry.value.content);
      } catch (_) {
        // 单个图标解码失败不影响识别；缺失时界面退回字母牌。
      }
    }

    final dataVersion = (metadata?['dataVersion'] as num?)?.toInt() ??
        (core['dataVersion'] as num?)?.toInt() ??
        0;

    return LibCheckerImportResult(
      bundle: {
        'meta': {
          'dataVersion': dataVersion,
          'sourceRevision': metadata?['sourceRevision'],
          'schemaVersion': supportedSchema,
          'ruleCount': rows.length,
          'source': 'imported:portable-v5.zip',
          'license': 'Apache-2.0',
        },
        'rules': rows,
        'regexIds': regexIds,
        'details': details,
      },
      icons: icons,
      dataVersion: dataVersion,
      sourceRevision: metadata?['sourceRevision'] as String?,
      ruleCount: usable,
      sha256: sha256.convert(bytes).toString(),
    );
  }

  /// 上游 details 文件是 `{data:[{locale,data:{...}}]}`；折成
  /// `{locale: [label, dev_team, description, source_link, contributors]}`，
  /// 与内置资产同构（读取端只认这一种形状）。
  static Map<String, dynamic>? _decodeDetail(String raw) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final list = (decoded['data'] as List?)?.cast<Map<String, dynamic>>();
      if (list == null || list.isEmpty) return null;
      final out = <String, dynamic>{};
      for (final item in list) {
        final locale = item['locale'];
        final data = item['data'];
        if (locale is! String || data is! Map) continue;
        final contributors =
            (data['rule_contributors'] as List?)?.cast<Object?>() ?? const [];
        out[locale] = [
          data['label'] ?? '',
          data['dev_team'] ?? '',
          data['description'] ?? '',
          data['source_link'] ?? '',
          contributors,
        ];
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }
}

/// 导入规则在应用数据目录的落盘位置。
///
/// 只存两份文件：`bundle.json`（规则 + 详情）与 `icons.json`（SVG）。
/// 另有一份 `meta.json` 记录版本与来源，供设置页展示；它不参与匹配。
class LibCheckerRuleStore {
  LibCheckerRuleStore._();

  /// 测试注入的目录；生产环境走应用数据目录。
  static Directory? debugDir;

  static Directory get _dir =>
      debugDir ?? Directory(p.join(ToolPaths.appSupportDir, 'libchecker'));

  static File get bundleFile => File(p.join(_dir.path, 'bundle.json'));
  static File get iconsFile => File(p.join(_dir.path, 'icons.json'));
  static File get metaFile => File(p.join(_dir.path, 'meta.json'));

  static bool get hasOverride =>
      bundleFile.existsSync() && bundleFile.lengthSync() > 0;

  static Future<Map<String, dynamic>?> loadMeta() async {
    try {
      final file = metaFile;
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<LibCheckerRules?> loadRules() async {
    try {
      final file = bundleFile;
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final bundle = jsonDecode(raw) as Map<String, dynamic>;
      return LibCheckerRules.fromBundle(bundle);
    } catch (e) {
      debugPrint('LibChecker: 导入的规则加载失败，回退内置：$e');
      return null;
    }
  }

  static Future<Map<String, String>?> loadIcons() async {
    try {
      final file = iconsFile;
      if (!await file.exists()) return null;
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return {
        for (final entry in decoded.entries)
          if (entry.value is String) entry.key: entry.value as String,
      };
    } catch (e) {
      debugPrint('LibChecker: 导入的图标加载失败：$e');
      return null;
    }
  }

  static Future<void> save(
    LibCheckerImportResult result, {
    required String fileName,
  }) async {
    await _dir.create(recursive: true);
    // 先写临时文件再改名：中途失败不会留下半个 JSON，让下次启动读到坏数据。
    final tempBundle = File('${bundleFile.path}.tmp');
    await tempBundle.writeAsString(jsonEncode(result.bundle), flush: true);
    await tempBundle.rename(bundleFile.path);

    final tempIcons = File('${iconsFile.path}.tmp');
    await tempIcons.writeAsString(jsonEncode(result.icons), flush: true);
    await tempIcons.rename(iconsFile.path);

    await metaFile.writeAsString(
      jsonEncode({
        'dataVersion': result.dataVersion,
        'sourceRevision': result.sourceRevision,
        'ruleCount': result.ruleCount,
        'importedAt': DateTime.now().toUtc().toIso8601String(),
        'fileName': fileName,
        'sha256': result.sha256,
      }),
      flush: true,
    );
  }

  static Future<void> clear() async {
    if (await _dir.exists()) {
      await _dir.delete(recursive: true);
    }
  }
}
