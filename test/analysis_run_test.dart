import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/models/analysis/analysis_run.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_run_repository.dart';
import 'package:flutter_test/flutter_test.dart';

AnalysisRun _run({
  required String id,
  required DateTime startedAt,
  AnalysisRunStatus status = AnalysisRunStatus.success,
  DateTime? completedAt,
  Map<String, dynamic>? snapshot,
  String? sha,
  String appName = 'Aurora Notes',
}) {
  return AnalysisRun(
    id: id,
    toolVersion: '2.11.0',
    appName: appName,
    platform: PackagePlatform.android,
    packagePath: '/tmp/Aurora Notes.apk',
    packageSha256: sha ?? 'a' * 64,
    startedAt: startedAt,
    completedAt: completedAt ?? startedAt.add(const Duration(seconds: 2)),
    status: status,
    snapshot: snapshot ??
        {
          'reportSchemaVersion': 8,
          'inputArtifact': {'fileName': 'Aurora Notes.apk'},
        },
    limitations: const ['android.payloadProbe partial'],
  );
}

void main() {
  late Directory root;
  late AnalysisRunRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('analysis_run_test_');
    repository = AnalysisRunRepository(root, maxRuns: 100);
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  test('run JSON roundtrip 保留快照、时间、状态和限制', () {
    final startedAt = DateTime.utc(2026, 11, 27, 12, 0, 0);
    final run = _run(
      id: AnalysisRun.createId(
          startedAt: startedAt, packageSha256: 'abcdef123456'),
      startedAt: startedAt,
    );

    final decoded = AnalysisRun.fromJson(
      jsonDecode(jsonEncode(run.toJson())) as Map<String, dynamic>,
    );

    expect(decoded.id, run.id);
    expect(decoded.toolVersion, '2.11.0');
    expect(decoded.appName, 'Aurora Notes');
    expect(decoded.platform, PackagePlatform.android);
    expect(decoded.packagePath, run.packagePath);
    expect(decoded.packageSha256, run.packageSha256);
    expect(decoded.startedAt, startedAt);
    expect(decoded.completedAt, startedAt.add(const Duration(seconds: 2)));
    expect(decoded.status, AnalysisRunStatus.success);
    expect(decoded.snapshot, run.snapshot);
    expect(decoded.limitations, run.limitations);
  });

  test('createId 可读、稳定、无路径字符', () {
    final startedAt = DateTime.utc(2026, 11, 27, 12, 0, 0);
    final id = AnalysisRun.createId(
      startedAt: startedAt,
      packageSha256: 'ABCDEF123456',
    );
    expect(id, 'analysis_${startedAt.microsecondsSinceEpoch}_abcdef12');
    expect(AnalysisRunRepository.isValidId(id), isTrue);
  });

  test('save/read/list 保留完整 run，并按时间倒序', () async {
    final base = DateTime.utc(2026, 11, 27, 12);
    await repository.save(_run(id: 'run_a', startedAt: base));
    await repository.save(_run(
      id: 'run_b',
      startedAt: base.add(const Duration(minutes: 1)),
      appName: 'Second',
    ));

    final loaded = await repository.read('run_a');
    expect(loaded, isNotNull);
    expect(loaded!.snapshot!['reportSchemaVersion'], 8);
    expect(loaded.limitations, hasLength(1));

    final list = await repository.list();
    expect(list.map((e) => e.id), ['run_b', 'run_a']);
  });

  test('delete 删除文件并同步索引', () async {
    await repository
        .save(_run(id: 'run_a', startedAt: DateTime.utc(2026, 1, 1)));
    await repository
        .save(_run(id: 'run_b', startedAt: DateTime.utc(2026, 1, 2)));

    await repository.delete('run_a');
    expect(await repository.read('run_a'), isNull);
    expect((await repository.list()).map((e) => e.id), ['run_b']);
  });

  test('索引缺失或损坏时可从 run 文件重建', () async {
    await repository
        .save(_run(id: 'run_a', startedAt: DateTime.utc(2026, 1, 1)));
    await repository
        .save(_run(id: 'run_b', startedAt: DateTime.utc(2026, 1, 2)));

    final index = File(
      '${root.path}${Platform.pathSeparator}analysis_runs'
      '${Platform.pathSeparator}index.json',
    );
    await index.delete();
    expect((await repository.list()).map((e) => e.id), ['run_b', 'run_a']);

    await index.writeAsString('{broken json');
    expect((await repository.list()).map((e) => e.id), ['run_b', 'run_a']);
  });

  test('索引重建跳过损坏 run，但保留其他记录', () async {
    await repository
        .save(_run(id: 'run_a', startedAt: DateTime.utc(2026, 1, 1)));
    final broken = File(
      '${root.path}${Platform.pathSeparator}analysis_runs'
      '${Platform.pathSeparator}broken.json',
    );
    await broken.writeAsString('not-json');

    final list = await repository.rebuildIndex();
    expect(list.map((e) => e.id), ['run_a']);
    expect(broken.existsSync(), isTrue);
  });

  test('非法 id 拒绝读写删，防止路径穿越', () async {
    for (final id in ['../outside', 'a/b', '', 'a' * 81]) {
      expect(AnalysisRunRepository.isValidId(id), isFalse);
      expect(() => repository.read(id), throwsFormatException);
      expect(() => repository.delete(id), throwsFormatException);
      expect(
        () =>
            repository.save(_run(id: id, startedAt: DateTime.utc(2026, 1, 1))),
        throwsFormatException,
      );
    }
  });

  test('超过 maxRuns 时删除最旧 run 并更新索引', () async {
    final limited = AnalysisRunRepository(root, maxRuns: 2);
    final base = DateTime.utc(2026, 1, 1);
    for (var i = 0; i < 3; i++) {
      await limited
          .save(_run(id: 'run_$i', startedAt: base.add(Duration(minutes: i))));
    }

    final list = await limited.list();
    expect(list.map((e) => e.id), ['run_2', 'run_1']);
    expect(
      File(
        '${root.path}${Platform.pathSeparator}analysis_runs'
        '${Platform.pathSeparator}run_0.json',
      ).existsSync(),
      isFalse,
    );
  });

  test('running run 不因 maxRuns 被删除', () async {
    final limited = AnalysisRunRepository(root, maxRuns: 2);
    final base = DateTime.utc(2026, 1, 1);
    await limited.save(_run(
      id: 'old_running',
      startedAt: base,
      status: AnalysisRunStatus.running,
      completedAt: null,
    ));
    await limited.save(
        _run(id: 'run_1', startedAt: base.add(const Duration(minutes: 1))));
    await limited.save(
        _run(id: 'run_2', startedAt: base.add(const Duration(minutes: 2))));

    final list = await limited.list();
    expect(list.map((e) => e.id), contains('old_running'));
    expect(list, hasLength(3));
  });

  test('坏 JSON 字段抛出 FormatException，而不是静默成功', () {
    expect(
      () => AnalysisRun.fromJson(const {'schemaVersion': 1}),
      throwsFormatException,
    );
    expect(
      () => AnalysisRunStatus.fromCode('something-else'),
      throwsFormatException,
    );
  });
}
