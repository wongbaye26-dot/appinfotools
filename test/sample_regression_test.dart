// 固定样本回归：清单驱动，仓库里不保存样本本身。
//
// 运行：
//   APPINFOTOOL_SAMPLE_MANIFEST=test/samples/manifest.json \
//   APPINFOTOOL_SAMPLES=/path/to/samples \
//   flutter test test/sample_regression_test.dart
//
// 未设置 APPINFOTOOL_SAMPLE_MANIFEST 时整个文件跳过；发布门禁应设置
// APPINFOTOOL_REQUIRE_SAMPLES=1（由 real_samples_smoke_test 负责）并显式提供清单。

import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_manifest.dart';

final SampleManifest? _manifest = SampleManifest.fromEnvironment();
final DateTime _generatedAt = DateTime.utc(2026, 11, 27, 12);

void main() {
  final manifest = _manifest;
  if (manifest == null) {
    test('固定样本回归未配置', () {}, skip: '未设置 APPINFOTOOL_SAMPLE_MANIFEST，固定样本回归未执行');
    return;
  }
  group('固定样本清单', () {
    test('清单中的文件存在且 SHA-256 匹配', () async {
      for (final sample in manifest.samples) {
        expect(
          await manifest.verifySha(sample),
          isNull,
          reason: sample.file,
        );
      }
    });

    test('每个样本都能解析并生成带能力证据的报告', () async {
      for (final sample in manifest.samples) {
        final file = manifest.fileOf(sample);
        final result = switch (sample.kind) {
          ManifestSampleKind.android => await _androidResult(file.path),
          ManifestSampleKind.ios => await _iosResult(file.path),
        };
        final json = jsonDecode(AnalysisReport.renderJson(
          result,
          generatedAt: _generatedAt,
          t: t,
        )) as Map<String, dynamic>;

        final findings =
            (json['findings'] as List? ?? const []).whereType<Map>().toList();
        final ruleIds =
            findings.map((f) => f['ruleId']).whereType<String>().toSet();
        for (final rule in sample.expectedFindingRules) {
          expect(ruleIds, contains(rule), reason: sample.file);
        }

        final sources = <String>{};
        for (final finding in findings) {
          for (final evidence
              in (finding['evidence'] as List? ?? const []).whereType<Map>()) {
            final source = evidence['source'];
            if (source is String) sources.add(source);
          }
        }
        for (final source in sample.expectedEvidenceSources) {
          expect(sources, contains(source), reason: sample.file);
        }

        final coverage = json['coverage'] as Map?;
        final coverageIds = (coverage?['entries'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => e['id'])
            .whereType<String>()
            .toSet();
        for (final id in sample.expectedCoverageIds) {
          expect(coverageIds, contains(id), reason: sample.file);
        }
      }
    });
  });
}

Future<dynamic> _androidResult(String path) async {
  final info = await getApkInfo(path);
  final size = await File(path).length();
  return AnalysisBuilder.buildAndroid(
    filePath: path,
    fileSize: size,
    manifestSource: info?.manifestSource ?? FieldSource.unknown,
    appName: info?.label,
    packageId: info?.packageName,
    version: info?.versionName,
    buildNumber: info?.versionCode?.toString(),
    minSdkVersion: info?.sdkVersion,
    targetSdkVersion: info?.targetSdkVersion,
    maxSdkVersion: info?.maxSdkVersion,
    debuggable: info?.applicationDebuggable,
    permissions: info?.usesPermissions ?? const [],
    components: info?.components ?? const [],
    hardeningObservations: info?.hardeningObservations ?? const [],
    structure: info?.structure,
  );
}

Future<dynamic> _iosResult(String path) async {
  final size = await File(path).length();
  final task = await IpaParseTask.start(path);
  final succeeded =
      (await task.events.toList()).whereType<IpaParseSucceeded>().single;
  return AnalysisBuilder.buildIos(
    filePath: path,
    fileSize: size,
    analysis: succeeded.analysis,
  );
}
