// 真实样本的通用冒烟测试：不针对某个样本的特定特征，只回答两个问题：
//
// 1. 目录里的每个真实样本能不能走完解析流水线；
// 2. 解析结果能不能生成 Markdown 与 JSON 报告，且 JSON 可被解析。
//
// 与 `real_samples_test.dart` 的区别：那个文件还会断言各平台的业务不变量；
// 这个文件只做「不炸、能出报告」的最低保证，适合放进发布门禁，避免某天
// 样本换了一批后，所有断言都因为样本特征消失而失效。
//
// 未配置样本时跳过；但设置 `APPINFOTOOL_REQUIRE_SAMPLES=1` 后，缺样本会
// **明确失败**，不会静默当成通过。

import 'dart:convert';
import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_directory.dart';

final SampleDirectory _samples = SampleDirectory.discover();

DateTime get _generatedAt => DateTime.utc(2026, 11, 27, 12);

void _expectRenderable(PackageAnalysisResult result, String label) {
  final markdown = AnalysisReport.render(
    result,
    t,
    generatedAt: _generatedAt,
  );
  expect(markdown, isNotEmpty, reason: '$label 的 Markdown 报告为空');

  final json = AnalysisReport.renderJson(
    result,
    generatedAt: _generatedAt,
    t: t,
  );
  final decoded = jsonDecode(json) as Map<String, dynamic>;
  expect(
    decoded['reportSchemaVersion'],
    AnalysisReport.reportSchemaVersion,
    reason: '$label 的报告 schema 版本不对',
  );
  expect(decoded['inputArtifact'], isA<Map<String, dynamic>>());
}

void main() {
  // ignore: avoid_print
  print('[samples] ${_samples.summary}');

  group('真实 Android 样本通用冒烟', () {
    final samples = _samples.samplesOf(SampleKind.android);

    test('每个样本都能解析并生成可解码报告', () async {
      for (final sample in samples) {
        final size = await sample.length();
        ApkInfo? info;
        Object? failure;
        try {
          info = await getApkInfo(sample.path);
        } catch (e) {
          failure = e;
        }

        final result = AnalysisBuilder.buildAndroid(
          filePath: sample.path,
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
          structure: (info?.structure.fileEntryCount ?? 0) == 0
              ? null
              : info!.structure,
        );

        // 解析失败可以接受（畸形包也可能是真实结论），但报告必须还能生成。
        _expectRenderable(result, '${sample.path}（解析失败: $failure）');
      }
    }, skip: _samples.skipReasonFor(SampleKind.android));
  });

  group('真实 IPA 样本通用冒烟', () {
    final samples = _samples.samplesOf(SampleKind.ios);

    test('每个样本都能解析并生成可解码报告', () async {
      for (final sample in samples) {
        final size = await sample.length();
        final task = await IpaParseTask.start(sample.path);
        final events = await task.events.toList();
        final succeeded = events.whereType<IpaParseSucceeded>().toList();

        expect(
          succeeded,
          hasLength(1),
          reason: '${sample.path} 没有产出一个成功解析结果',
        );

        final result = AnalysisBuilder.buildIos(
          filePath: sample.path,
          fileSize: size,
          analysis: succeeded.single.analysis,
        );
        _expectRenderable(result, sample.path);
      }
    }, skip: _samples.skipReasonFor(SampleKind.ios));
  });

  group('真实样本发布门禁', () {
    test('要求样本时，缺样本必须明确失败而不是跳过', () {
      final required =
          Platform.environment['APPINFOTOOL_REQUIRE_SAMPLES'] == '1';
      if (!required) {
        markTestSkipped(
          '未设置 APPINFOTOOL_REQUIRE_SAMPLES=1：本地运行显式豁免真实样本门禁',
        );
        return;
      }

      expect(
        _samples.status,
        SampleDirStatus.ready,
        reason: 'APPINFOTOOL_REQUIRE_SAMPLES=1，但样本目录不可用：'
            '${_samples.summary}',
      );

      // 默认要求两个平台；显式声明平台列表时只对清单内的平台负责。
      //
      // 为什么允许收窄：CI 能合法获取的公开样本目前只有 Android 侧
      // （F-Droid 的版本化仓库）。iOS 侧没有可再分发的真实 .ipa，
      // 平台列表收窄时必须由调用方写清"哪个平台这次不覆盖"，
      // 而不是让整套门禁悄悄通过 —— 收窄本身也会在 CI 日志里 warning。
      final raw = Platform.environment['APPINFOTOOL_REQUIRED_SAMPLE_PLATFORMS'];
      final requiredKinds = <SampleKind>[];
      if (raw == null || raw.trim().isEmpty) {
        requiredKinds.addAll(SampleKind.values);
      } else {
        for (final token in raw.split(',')) {
          final name = token.trim().toLowerCase();
          if (name.isEmpty) continue;
          final kind =
              SampleKind.values.where((k) => k.name == name).firstOrNull;
          expect(
            kind,
            isNotNull,
            reason: 'APPINFOTOOL_REQUIRED_SAMPLE_PLATFORMS 含未知平台：$name',
          );
          requiredKinds.add(kind!);
        }
        expect(requiredKinds, isNotEmpty,
            reason: 'APPINFOTOOL_REQUIRED_SAMPLE_PLATFORMS 不能为空');
      }

      for (final kind in requiredKinds) {
        expect(
          _samples.samplesOf(kind),
          isNotEmpty,
          reason: 'APPINFOTOOL_REQUIRE_SAMPLES=1，但缺少 ${kind.label} 样本；'
              '不能把「没有样本」当成「通过」',
        );
      }
      for (final kind in SampleKind.values) {
        if (!requiredKinds.contains(kind)) {
          // ignore: avoid_print
          print('[samples] 本次不要求 ${kind.label} 样本（'
              'APPINFOTOOL_REQUIRED_SAMPLE_PLATFORMS=${raw!.trim()}）；'
              '该平台的端到端覆盖未包含在本次门禁里');
        }
      }
    });
  });
}
