import 'dart:convert';

import 'package:apk_info_tool/models/analysis/analysis_run.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/analysis_run_repository.dart';
import 'package:apk_info_tool/gen/strings.g.dart';

/// 把一次真实解析结果落成 AnalysisRun。
///
/// 约束：
/// - 不伪造 snapshot：分析结果为空时 snapshot 必须为 null。
/// - 快照生成失败不阻断解析，只记 limitation。
/// - running → terminal 通过同一个 id 更新，历史列表不会多出一条。
class AnalysisRunRecorder {
  final AnalysisRunRepository repository;
  final String toolVersion;

  const AnalysisRunRecorder({
    required this.repository,
    required this.toolVersion,
  });

  Future<AnalysisRun> start({
    required String packagePath,
    required PackagePlatform platform,
  }) async {
    final startedAt = DateTime.now().toUtc();
    final run = AnalysisRun(
      id: AnalysisRun.createId(startedAt: startedAt),
      toolVersion: toolVersion,
      platform: platform,
      packagePath: packagePath,
      startedAt: startedAt,
      status: AnalysisRunStatus.running,
    );
    await repository.save(run);
    return run;
  }

  Future<AnalysisRun> finish({
    required AnalysisRun run,
    required AnalysisRunStatus status,
    required PackageAnalysisResult? result,
    required Translations t,
    String? packageSha256,
    List<String> limitations = const [],
  }) async {
    final completedAt = DateTime.now().toUtc();
    Map<String, dynamic>? snapshot;
    final limitationsOut = <String>[...limitations];

    if (result != null && status != AnalysisRunStatus.failed) {
      try {
        final snapshotRun = run.copyWith(
          status: status,
          completedAt: completedAt,
          appName: result.appName.value,
          packageSha256: packageSha256,
          platform: result.platform,
        );
        snapshot = jsonDecode(
          AnalysisReport.renderJson(
            result,
            generatedAt: completedAt,
            t: t,
            analysisRun: snapshotRun,
          ),
        ) as Map<String, dynamic>;
      } catch (error) {
        // 快照失败不能把解析结果本身判成失败；但必须在 run 上留痕。
        limitationsOut.add('report.snapshot.failed: $error');
      }
    }

    final updated = run.copyWith(
      status: status,
      completedAt: completedAt,
      snapshot: snapshot,
      limitations: List.unmodifiable(limitationsOut),
      appName: result?.appName.value,
      packageSha256: packageSha256,
      platform: result?.platform,
    );
    await repository.save(updated);
    return updated;
  }
}
