import 'package:apk_info_tool/utils/analysis_run_recorder.dart';
import 'package:apk_info_tool/utils/analysis_run_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 生产环境的 run 仓库：应用支持目录下的 `analysis_runs/`。
final analysisRunRepositoryProvider =
    FutureProvider<AnalysisRunRepository>((ref) async {
  final support = await getApplicationSupportDirectory();
  final repository = AnalysisRunRepository(support);
  await repository.ensureInitialized();
  return repository;
});

/// 当前应用版本 + 仓库组成的 recorder。
///
/// 版本读取失败时退回 `unknown`，不阻断分析；run 里保留真实空值比编版本号诚实。
final analysisRunRecorderProvider =
    FutureProvider<AnalysisRunRecorder>((ref) async {
  final repository = await ref.watch(analysisRunRepositoryProvider.future);
  var version = 'unknown';
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    // 没有 package_info 的测试/嵌入环境仍允许记录，但版本必须显式未知。
  }
  return AnalysisRunRecorder(repository: repository, toolVersion: version);
});
