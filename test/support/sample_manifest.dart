// 固定样本清单：把「这批样本应该证明什么」从测试代码里拆出来。
//
// 样本本身通常不能进仓库（版权/体积/隐私），所以清单通过环境变量提供：
//   APPINFOTOOL_SAMPLE_MANIFEST=/path/to/manifest.json
//   APPINFOTOOL_SAMPLES=/path/to/samples       # 可选，默认取清单同目录
//
// 清单格式见 test/samples/manifest.example.json。本文件只做解析与校验，
// 不依赖测试框架，因此可以被任意 release gate 复用。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

enum ManifestSampleKind { android, ios }

class ManifestSample {
  final String file;
  final ManifestSampleKind kind;
  final String sha256;
  final List<String> expectedFindingRules;
  final List<String> expectedEvidenceSources;
  final List<String> expectedCoverageIds;

  const ManifestSample({
    required this.file,
    required this.kind,
    required this.sha256,
    this.expectedFindingRules = const [],
    this.expectedEvidenceSources = const [],
    this.expectedCoverageIds = const [],
  });

  factory ManifestSample.fromJson(Map<String, dynamic> json) {
    final file = json['file'];
    final kind = json['kind'];
    final sha = json['sha256'];
    if (file is! String || file.isEmpty) {
      throw const FormatException('sample.file 必须是非空字符串');
    }
    if (kind != 'android' && kind != 'ios') {
      throw FormatException('sample.kind 必须是 android 或 ios：$kind');
    }
    if (sha is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) {
      throw const FormatException('sample.sha256 必须是 64 位十六进制');
    }
    List<String> strings(Object? raw) => raw is List
        ? raw.whereType<String>().toList(growable: false)
        : const [];
    return ManifestSample(
      file: file,
      kind: kind == 'android'
          ? ManifestSampleKind.android
          : ManifestSampleKind.ios,
      sha256: sha.toLowerCase(),
      expectedFindingRules: strings(json['expectedFindingRules']),
      expectedEvidenceSources: strings(json['expectedEvidenceSources']),
      expectedCoverageIds: strings(json['expectedCoverageIds']),
    );
  }
}

class SampleManifest {
  final String path;
  final List<ManifestSample> samples;

  const SampleManifest({required this.path, required this.samples});

  static SampleManifest? fromEnvironment() {
    final path = Platform.environment['APPINFOTOOL_SAMPLE_MANIFEST'];
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) {
      throw FormatException('APPINFOTOOL_SAMPLE_MANIFEST 不存在：$path');
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic> || decoded['samples'] is! List) {
      throw const FormatException('样本清单必须是 {"samples": [...]}');
    }
    final samples = (decoded['samples'] as List)
        .whereType<Map<String, dynamic>>()
        .map(ManifestSample.fromJson)
        .toList(growable: false);
    if (samples.isEmpty) {
      throw const FormatException('样本清单为空');
    }
    return SampleManifest(path: path, samples: samples);
  }

  /// 清单所在目录；`APPINFOTOOL_SAMPLES` 显式设置时以它为准。
  String get sampleDirectory {
    final override = Platform.environment['APPINFOTOOL_SAMPLES'];
    if (override != null && override.isNotEmpty) return override;
    return File(path).parent.path;
  }

  File fileOf(ManifestSample sample) =>
      File('$sampleDirectory${Platform.pathSeparator}${sample.file}');

  /// 返回 null 表示 SHA 匹配；否则返回可读原因。
  Future<String?> verifySha(ManifestSample sample) async {
    final file = fileOf(sample);
    if (!file.existsSync()) return '文件不存在：${file.path}';
    final digest = sha256.convert(await file.readAsBytes()).toString();
    if (digest != sample.sha256) {
      return 'SHA-256 不匹配：期望 ${sample.sha256}，实际 $digest';
    }
    return null;
  }
}
