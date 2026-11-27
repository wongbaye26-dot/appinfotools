import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/analysis_run.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_run_recorder.dart';
import 'package:apk_info_tool/utils/analysis_run_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AnalysisRunRepository repository;
  late AnalysisRunRecorder recorder;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('analysis_run_recorder_');
    repository = AnalysisRunRepository(root);
    recorder =
        AnalysisRunRecorder(repository: repository, toolVersion: '2.11.0');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('start 立即保存 running run', () async {
    final run = await recorder.start(
      packagePath: '/tmp/Aurora.apk',
      platform: PackagePlatform.android,
    );

    expect(run.status, AnalysisRunStatus.running);
    final loaded = await repository.read(run.id);
    expect(loaded, isNotNull);
    expect(loaded!.status, AnalysisRunStatus.running);
    expect(loaded.snapshot, isNull);
    expect(loaded.toolVersion, '2.11.0');
  });

  test('没有结果时 finish 为 failed，不伪造 snapshot', () async {
    final run = await recorder.start(
      packagePath: '/tmp/Aurora.apk',
      platform: PackagePlatform.android,
    );
    final finished = await recorder.finish(
      run: run,
      status: AnalysisRunStatus.failed,
      result: null,
      t: AppLocale.en.buildSync(),
      limitations: const ['parse.no_result'],
    );

    expect(finished.status, AnalysisRunStatus.failed);
    expect(finished.snapshot, isNull);
    expect(finished.completedAt, isNotNull);
    expect(finished.limitations, contains('parse.no_result'));
    final loaded = await repository.read(finished.id);
    expect(loaded!.snapshot, isNull);
  });

  test('有真实结果时保存 renderJson 快照和真实元数据', () async {
    final sha = 'a' * 64;
    final result = PackageAnalysisResult(
      platform: PackagePlatform.android,
      fileName: FieldValue.extracted(
        'Aurora.apk',
        source: FieldSource.fileSystem,
      ),
      fileSize: FieldValue.extracted(1024, source: FieldSource.fileSystem),
      sha256: FieldValue.extracted(
        sha,
        source: FieldSource.fileSystem,
      ),
      appName: FieldValue.extracted(
        'Aurora Notes',
        source: FieldSource.builtinParser,
      ),
      packageId: FieldValue.extracted(
        'com.aurora.notes',
        source: FieldSource.builtinParser,
      ),
      version:
          FieldValue.extracted('3.20.0', source: FieldSource.builtinParser),
      buildNumber:
          FieldValue.extracted('320', source: FieldSource.builtinParser),
    );

    final run = await recorder.start(
      packagePath: '/tmp/Aurora.apk',
      platform: PackagePlatform.android,
    );
    final finished = await recorder.finish(
      run: run,
      status: AnalysisRunStatus.success,
      result: result,
      t: AppLocale.en.buildSync(),
      packageSha256: sha,
    );

    expect(finished.status, AnalysisRunStatus.success);
    expect(finished.appName, 'Aurora Notes');
    expect(finished.packageSha256, 'a' * 64);
    expect(finished.snapshot, isNotNull);
    expect(finished.snapshot!['reportSchemaVersion'], 8);
    expect(finished.snapshot!['application'], isNotNull);
  });
}
