// 从 APK / IPA 提取官方基线条目（只存公开指纹，不存二进制）。
//
// 用法：
//   dart run tool/import_baseline.dart <apk|ipa> \
//     --source-type official-site|app-store|google-play|public-fingerprint|other \
//     --source-url https://... --out /tmp/entry.json
//
//   dart run tool/import_baseline.dart <apk|ipa> \
//     --source-type ... --source-url ... --merge
//
// `--merge` 会把条目并入 assets/baseline/official_baseline_v1.json；
// 已存在同 platform + packageId 的条目时拒绝覆盖（需要人工先删除/更新）。
//
// 边界：这是**提取工具**，不会自动判断“是否官方”。来源类型/URL 由调用方给，
// 输出 entry 的 notes 会明确写 caller-provided，除非传 --official.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'dart:io';

import 'package:apk_info_tool/utils/baseline_entry_extractor.dart';

const _baselinePath = 'assets/baseline/official_baseline_v1.json';

Future<void> main(List<String> args) async {
  final result = await _run(args);
  if (result != null) {
    // ignore: avoid_print
    print(result);
  }
}

Future<String?> _run(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('-')) {
    stderr.writeln('usage: dart run tool/import_baseline.dart <apk|ipa> '
        '--source-type <type> --source-url <url> [--out file] [--merge]');
    exitCode = 64;
    return null;
  }
  final path = args.first;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('file not found: $path');
    exitCode = 66;
    return null;
  }
  final opts = <String, String>{};
  var merge = false;
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--merge') {
      merge = true;
      continue;
    }
    if (arg == '--official') {
      opts['official'] = '1';
      continue;
    }
    if (arg.startsWith('--') && i + 1 < args.length) {
      opts[arg.substring(2)] = args[++i];
    }
  }

  final sourceType = opts['source-type'] ?? 'other';
  final sourceUrl = opts['source-url'];
  if (sourceUrl == null || sourceUrl.isEmpty) {
    stderr.writeln('--source-url is required (stable official URL or '
        'public fingerprint reference)');
    exitCode = 64;
    return null;
  }
  final retrievedAt =
      opts['retrieved-at'] ?? DateTime.now().toUtc().toIso8601String();
  final official = opts['official'] == '1';

  late Map<String, Object?> entry;
  try {
    entry = path.toLowerCase().endsWith('.ipa')
        ? buildIosBaselineEntrySync(
            path: path,
            sourceType: sourceType,
            sourceUrl: sourceUrl,
            retrievedAt: retrievedAt,
            official: official,
          )
        : await buildAndroidBaselineEntry(
            path: path,
            sourceType: sourceType,
            sourceUrl: sourceUrl,
            retrievedAt: retrievedAt,
            official: official,
          );
  } catch (e) {
    stderr.writeln('extract failed: $e');
    exitCode = 70;
    return null;
  }
  final encoded = const JsonEncoder.withIndent('  ').convert(entry);
  final out = opts['out'];
  if (out != null && out.isNotEmpty) {
    File(out).writeAsStringSync('$encoded\n');
    stderr.writeln('entry written: $out');
  }
  if (merge) {
    _merge(entry, official);
  }
  return '$encoded\n';
}

void _merge(Map<String, Object?> entry, bool official) {
  final file = File(_baselinePath);
  final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final entries = (raw['entries'] as List).cast<Map<String, dynamic>>();
  final platform = entry['platform'];
  final packageId = entry['packageId'];
  if (entries
      .any((e) => e['platform'] == platform && e['packageId'] == packageId)) {
    stderr.writeln('refusing to overwrite existing baseline entry '
        '$platform/$packageId; edit $_baselinePath manually');
    exitCode = 65;
    return;
  }
  entries.add(entry.cast<String, dynamic>());
  raw['entries'] = entries;
  raw['integritySha256'] =
      sha256.convert(utf8.encode(jsonEncode(entries))).toString();
  raw['reviewedBy'] = [
    ...((raw['reviewedBy'] as List?) ?? const []).cast<String>(),
    official ? 'official-site' : 'caller-provided',
  ];
  file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(raw)}\n');
  stderr.writeln('merged into $_baselinePath');
}
