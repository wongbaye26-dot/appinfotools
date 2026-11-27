import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:analysis_model/analysis_model.dart';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/ipaparser/ios_codesign_step.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:apk_info_tool/models/analysis/analysis_run.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/pages/pages.dart';
import 'package:apk_info_tool/pages/text_info.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/ui/shell/shell_navigation.dart';
import 'package:apk_info_tool/providers/analysis_run_provider.dart';
import 'package:apk_info_tool/providers/home_page_provider.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/providers/setting_provider.dart';
import 'package:apk_info_tool/providers/ui_config_provider.dart';
import 'package:apk_info_tool/utils/android_version.dart';
import 'package:apk_info_tool/utils/architecture_label.dart';
import 'package:apk_info_tool/utils/cancellable_task.dart';
import 'package:apk_info_tool/utils/analysis_page_status.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/field_value_text.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/ios_icon_decoder.dart';
import 'package:apk_info_tool/utils/format.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/official_baseline_store.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:apk_info_tool/utils/parse_request_gate.dart';
import 'package:apk_info_tool/utils/platform.dart';
import 'package:apk_info_tool/utils/recent_icon_cache.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:ipa_parser/ipa_parser.dart' show IosBundle;
import 'package:apk_info_tool/widgets/analysis_state_panel.dart';
import 'package:apk_info_tool/widgets/manifest_partial_banner.dart';
import 'package:apk_info_tool/widgets/security_evidence_card.dart';
import 'package:apk_info_tool/widgets/security_evidence_center.dart';
import 'package:apk_info_tool/widgets/security_notice_banner.dart';
import 'package:apk_info_tool/widgets/android_detail_widgets.dart';
import 'package:apk_info_tool/widgets/copy_icon_button.dart';
import 'package:apk_info_tool/widgets/detail_tab_view.dart';
import 'package:apk_info_tool/widgets/export_report_dialog.dart';
import 'package:apk_info_tool/widgets/ios_detail_widgets.dart';
import 'package:apk_info_tool/widgets/rename_file_dialog.dart';
import 'package:apk_info_tool/widgets/security_finding_card.dart';
import 'package:apk_info_tool/widgets/crypto_theft_card.dart';
import 'package:apk_info_tool/widgets/title_value_layout.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

class APKInfoPage extends ConsumerStatefulWidget implements PageBase {
  const APKInfoPage({super.key});

  @override
  ConsumerState<APKInfoPage> createState() => _APKInfoPageState();

  @override
  Pages get page => Pages.info;
}

class _APKInfoPageState extends ConsumerState<APKInfoPage> {
  int _loadGeneration = 0;

  /// 当前正在执行的可取消任务。
  ///
  /// 三种任务的取消机制完全不同（杀 isolate / 杀子进程 / 协作式标志），
  /// 但 UI 只需要知道「现在有没有可取消的东西」。用一个统一句柄而不是三个
  /// 字段，是为了让「显示取消按钮」与「取消真的有效」永远是同一件事。
  ///
  /// 为 `null` 表示当前没有可取消的任务（解析未开始或已结束）。
  CancellableParseTask? _currentTask;

  /// `codesign` 步骤的取消标志。
  ///
  /// 这一步跑在主 isolate 上（会写临时目录），没法靠杀 isolate 取消，
  /// 只能靠一个协作式标志：解包器每写一条检查一次。取消后仍会走完
  /// `finally` 清理，因此不会留下临时目录。
  bool _iosCodeSignCancelled = false;

  /// 最近一次打开/解析失败的用户可读原因。
  ///
  /// 之所以要显式保存而不是只用 SnackBar：SnackBar 会消失，而详情页此前在
  /// 失败后仍会渲染一屏 `-`，用户既不知道失败过，也无法重试。这个字段只在
  /// **没有可用结果**时驱动页面级失败态；已有结果时不会把结果页替换掉。
  String? _failureMessage;

  /// 同一个文件的重复触发去重。
  ///
  /// 双击包启动时路径会从命令行参数与文件关联事件**两条入口**同时到达，
  /// 不去重就会把同一个大包并行解析两遍（实测 Windows 上 75 MB 的包被
  /// 解析两次，各约 19 s，前一份结果被代际号丢弃）。
  final ParseRequestGate _requestGate = ParseRequestGate();

  /// 取消上一次仍在进行的解析。
  ///
  /// 换文件时新请求只把代际号加一，旧任务要等**它自己跑完**才在 `finally`
  /// 里被取消 —— 那时它已经白跑了整个解析。这里提前停掉。
  void _cancelInFlightTask() {
    final task = _currentTask;
    if (task == null || task.isFinished) return;
    log.info('loadApkInfo: 取消上一次仍在进行的解析');
    task.cancel();
  }

  /// 更新失败原因；`null` 表示清除。
  ///
  /// 只在挂载时调用 `setState`：解析任务结束后仍可能有回调落到已销毁的页面。
  void _setFailure(String? message) {
    if (!mounted || _failureMessage == message) return;
    setState(() => _failureMessage = message);
  }

  void openFilePicker() async {
    var result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      dialogTitle: t.open.select_apk_file,
      allowedExtensions: kPickableExtensions,
      lockParentWindow: true,
    );
    log.fine('openFilePicker: result=$result');
    var file = result?.files.single;
    // 打开文件选择
    if (file != null) {
      log.fine('openFilePicker: filePaths=$file');
      if (file.path != null) {
        openApk(file.path!);
      }
    }
  }

  void openApk(String path) {
    final file = File(path);
    final state = ref.read(currentFileStateProvider.notifier);
    _setFailure(null);
    if (file.existsSync()) {
      final fileSize = file.lengthSync();
      state.update(FileState(filePath: path, fileSize: fileSize));
      if (path.isNotEmpty) {
        loadApkInfo(path);
      }
    } else {
      // 选中一个不存在的文件也必须让旧解析停下：否则旧任务完成时会把
      // 「上一条路径的结果」写回 FileState，用户看到的失败原因与详情对不上。
      _cancelInFlightTask();
      ++_loadGeneration;
      ref.read(isParsingProvider.notifier).update(false);
      ref.read(parseStageProvider.notifier).update(null);
      ref.read(iosParseStageProvider.notifier).update(null);
      state.update(FileState(filePath: path));
      _setFailure(t.analysis_state.file_not_found);
    }
  }

  void closeApk() {
    _cancelInFlightTask();
    ++_loadGeneration;
    _setFailure(null);
    ref.read(isParsingProvider.notifier).update(false);
    ref.read(parseStageProvider.notifier).update(null);
    ref.read(iosParseStageProvider.notifier).update(null);
    ref.read(currentFileStateProvider.notifier).update(FileState());
    ref.read(currentApkInfoProvider.notifier).reset();
    ref.read(selectedIconIndexProvider.notifier).reset();
    ref.read(selectedLabelLocaleProvider.notifier).reset();
  }

  String getSdkVersionText(int? sdkVersion) {
    if (sdkVersion == null) return "";
    return "$sdkVersion (${AndroidVersion.getAndroidVersion(sdkVersion)})";
  }

  /// 开始一条 run。失败只记日志，绝不让“历史写不进去”变成“解析失败”。
  Future<AnalysisRun?> _beginAnalysisRun(
    String filePath,
    PackagePlatform platform,
  ) async {
    try {
      final recorder = await ref.read(analysisRunRecorderProvider.future);
      final run =
          await recorder.start(packagePath: filePath, platform: platform);
      if (mounted) {
        final state = ref.read(currentFileStateProvider);
        if (state.filePath == filePath) {
          ref.read(currentFileStateProvider.notifier).update(
                state.copyWith(
                  analysisRunId: run.id,
                  analysisRunStatus: run.status,
                ),
              );
        }
      }
      return run;
    } catch (e) {
      log.warning('_beginAnalysisRun: $e');
      return null;
    }
  }

  /// 结束一条 run，并保存当前真实结果的报告快照。
  Future<void> _finishAnalysisRun({
    required Future<AnalysisRun?> runFuture,
    required AnalysisRunStatus status,
    String? limitation,
  }) async {
    try {
      final run = await runFuture;
      if (run == null || !mounted) return;
      final state = ref.read(currentFileStateProvider);
      // 用户已经切走：绝不能把新文件的结果写进旧 run。
      if (state.filePath != run.packagePath) return;
      final recorder = await ref.read(analysisRunRecorderProvider.future);
      final updated = await recorder.finish(
        run: run,
        status: status,
        result: state.analysis,
        t: t,
        packageSha256: state.sha256Hash,
        limitations: [if (limitation != null) limitation],
      );
      if (!mounted) return;
      final current = ref.read(currentFileStateProvider);
      if (current.analysisRunId == updated.id) {
        ref.read(currentFileStateProvider.notifier).update(
              current.copyWith(analysisRunStatus: updated.status),
            );
      }
    } catch (e) {
      log.warning('_finishAnalysisRun: $e');
    }
  }

  Future<void> loadApkInfo(String filePath) async {
    _setFailure(null);
    // 同一个文件已经在解析：直接返回，复用那一次的结果。
    //
    // 双击包启动时路径会从命令行参数与文件关联事件两条入口同时到达
    // （见 [ParseRequestGate]）。不拦的话两份都跑到完成，前一份被代际号
    // 丢弃 —— 大包上那是白烧十几秒。
    if (_requestGate.isDuplicate(filePath)) {
      log.info('loadApkInfo: 同一文件已在解析中，跳过重复触发: $filePath');
      return;
    }
    _cancelInFlightTask();
    _requestGate.begin(filePath);

    // IPA 走自己的解析流水线。分支点放在这里而不是更深处：两条流水线的
    // 阶段、工具、结论语义都不同，混在一个方法里只会让两边都难读。
    if (_looksLikeIpa(filePath)) {
      try {
        await _loadIpaInfo(filePath);
      } finally {
        _requestGate.finish(filePath);
      }
      return;
    }

    final gen = ++_loadGeneration;
    final apkInfoState = ref.read(currentApkInfoProvider.notifier);
    final isParsingState = ref.read(isParsingProvider.notifier);
    final parseStageState = ref.read(parseStageProvider.notifier);
    final fileState = ref.read(currentFileStateProvider.notifier);
    final enableSignature =
        ref.read(settingStateProvider.select((value) => value.enableSignature));
    final enableHash =
        ref.read(settingStateProvider.select((value) => value.enableHash));
    final enableSecurityAudit = ref.read(
        settingStateProvider.select((value) => value.enableSecurityAudit));
    apkInfoState.reset();
    ref.read(selectedIconIndexProvider.notifier).reset();
    ref.read(selectedLabelLocaleProvider.notifier).reset();
    isParsingState.update(true);
    parseStageState.update(null);
    _currentTask = null;

    // 初始化文件状态
    final isXapk = filePath.toLowerCase().endsWith('.xapk');
    fileState.update(FileState(
      filePath: filePath,
      fileSize: File(filePath).lengthSync(),
      isComputingHash: enableHash,
      isComputingSignature: enableSignature && !isXapk,
    ));
    final runFuture = _beginAnalysisRun(filePath, PackagePlatform.android);

    // 如果启用哈希计算，异步计算哈希值（与 APK 解析并行）
    if (enableHash) {
      computeFileHashes(filePath).then((hashes) {
        if (mounted) {
          final currentState = ref.read(currentFileStateProvider);
          if (_loadGeneration == gen) {
            fileState.update(currentState.copyWith(
              md5Hash: hashes.md5,
              sha1Hash: hashes.sha1,
              sha256Hash: hashes.sha256,
              isComputingHash: false,
            ));
          }
        }
      }).catchError((e) {
        log.warning('loadApkInfo: failed to compute hashes: $e');
        if (mounted) {
          final currentState = ref.read(currentFileStateProvider);
          fileState.update(currentState.copyWith(
            isComputingHash: false,
          ));
        }
      });
    }

    // 如果启用签名检查，异步获取签名信息（与 APK 解析并行）
    if (enableSignature && !isXapk) {
      SignatureAnalyzer.analyze(filePath).then((analysis) {
        if (!mounted || _loadGeneration != gen) return;
        fileState.update(ref.read(currentFileStateProvider).copyWith(
              signature: analysis,
              isComputingSignature: false,
            ));
      }).catchError((e) {
        // analyze 内部已兜住各类失败，这里只防未捕获的异步错误。
        log.warning('loadApkInfo: signature analysis failed: $e');
        if (!mounted || _loadGeneration != gen) return;
        fileState.update(ref.read(currentFileStateProvider).copyWith(
              signature: SignatureAnalysis(
                status: SignatureStatus.unknown,
                error: '$e',
              ),
              isComputingSignature: false,
            ));
      });
    }

    // 这一次运行自己的任务句柄。`_currentTask` 是给「取消按钮」用的共享
    // 槽位，切文件后会被新一次运行占走；要取消**这一次**的任务得单独留一份。
    CancellableParseTask? taskForThisRun;
    try {
      final apkInfo = await getApkInfo(
        filePath,
        // 阶段由解析器在真正推进到该步时上报，不是定时器编出来的。
        onStage: (stage) {
          if (_loadGeneration == gen) parseStageState.update(stage);
        },
        // 拿到可取消的任务句柄后，取消按钮才可用。
        onTaskStarted: (task) {
          taskForThisRun = task;
          if (_loadGeneration == gen) _currentTask = task;
        },
      );
      if (apkInfo == null) {
        if (_loadGeneration == gen) {
          _setFailure(t.parse.parse_apk_info_fail);
          unawaited(_finishAnalysisRun(
            runFuture: runFuture,
            status: AnalysisRunStatus.failed,
            limitation: 'parse.no_result',
          ));
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.parse.parse_apk_info_fail)),
          );
        }
      } else if (apkInfo.parseFailureReason != null) {
        // Manifest 没读出来。审计结论（只有局限说明，没有发现项）仍然有效，
        // 挂上去让用户看到**为什么**没有结果，而不是安全 Tab 一片空白 ——
        // 「没查到」与「没查」的结论完全相反，不能长得一样。
        if (_loadGeneration == gen) {
          if (!enableSecurityAudit) {
            apkInfo.securityResult = null;
          }
          apkInfoState.update(apkInfo);
          fileState.update(
            ref.read(currentFileStateProvider).copyWith(apkInfo: apkInfo),
          );
          unawaited(_finishAnalysisRun(
            runFuture: runFuture,
            status: AnalysisRunStatus.partial,
            limitation: 'manifest.partial',
          ));
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.parse.parse_apk_info_fail)),
          );
        }
      } else {
        if (_loadGeneration == gen) {
          // 安全检测开关：关闭时清空 worker 产出的结果。
          if (!enableSecurityAudit) {
            apkInfo.securityResult = null;
          }
          apkInfoState.update(apkInfo);
          // 更新 FileState 中的 apkInfo（保留哈希值）
          final currentState = ref.read(currentFileStateProvider);
          fileState.update(currentState.copyWith(
            apkInfo: apkInfo,
          ));
          final afterUpdate = ref.read(currentFileStateProvider);
          final pending =
              afterUpdate.isComputingHash || afterUpdate.isComputingSignature;
          unawaited(_finishAnalysisRun(
            runFuture: runFuture,
            status:
                pending ? AnalysisRunStatus.partial : AnalysisRunStatus.success,
          ));
          // 追加到最近文件列表。走 provider 而不是直接写 Config ——
          // 概览页常驻 IndexedStack，只有 provider 变化才会让它重建。
          //
          // **必须接住异常**：这里原先只写 `unawaited(...)`，于是
          // `RecentFilesManager.add` 抛出的 `UnsupportedError`（空列表返回
          // `const []` 导致 `removeWhere` 失败）被彻底吞掉，用户看到的是
          // 「最近文件永远为空」而日志里什么都没有。失败至少要说出来。
          unawaited(_recordRecentFile(
            path: currentState.filePath ?? '',
            size: currentState.fileSize ?? 0,
            platform: 'android',
            icon: apkInfo.mainIconImage,
          ));
        }
      }
    } on ApkParseCancelledException {
      // 用户主动取消 —— 不弹错误提示，但页面不能停在「有文件、没结果」的
      // 空白状态；给一个可重试的取消态。
      log.info('loadApkInfo: cancelled by user');
      if (_loadGeneration == gen) {
        _setFailure(t.analysis_state.cancelled);
        unawaited(_finishAnalysisRun(
          runFuture: runFuture,
          status: AnalysisRunStatus.cancelled,
        ));
      }
    } catch (e) {
      log.warning('loadApkInfo: $e');
      // 只有容器打开失败有结构化原因；其余异常只写进日志。把
      // `e.toString()` 直接放到页面上，用户看到的是英文类名和内部路径，
      // 既不可操作也不一定不泄露信息。
      final message = e is ApkOpenException
          ? DetailRenderer.openFailure(e.result, t, detail: e.detail)
          : t.analysis_state.failure_body;
      if (_loadGeneration == gen) {
        _setFailure(message);
        unawaited(_finishAnalysisRun(
          runFuture: runFuture,
          status: AnalysisRunStatus.failed,
          limitation: 'parse.exception',
        ));
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (_loadGeneration == gen) {
        isParsingState.update(false);
        parseStageState.update(null);
        _currentTask = null;
      } else {
        // 用户又切了文件：这次解析的结果已经没人要了，但任务还在跑。
        // 必须显式取消，否则一个 worker isolate（XAPK 路径上还有 aapt2
        // 子进程）会白跑到底，而结果只会被丢掉。
        taskForThisRun?.cancel();
      }
      // 只清自己那一条：换文件后闸门已经指向新文件了（见 [ParseRequestGate]）。
      _requestGate.finish(filePath);
    }
  }

  /// 是否按 IPA 处理。
  ///
  /// 只看扩展名：内容层面的判断由容器解析做（`Payload/` 是否存在），
  /// 这里只决定走哪条流水线。因此一个改名为 `.ipa` 的 APK 会走 IPA 流水线
  /// 并如实报告「没有 Payload/ 目录」，而不是被静默当成 APK。
  bool _looksLikeIpa(String filePath) =>
      filePath.toLowerCase().endsWith('.ipa');

  /// IPA 的解析流程。
  ///
  /// 与 Android 侧一样分三条并行线（哈希 / 静态解析 / 签名验证），
  /// 每条线只更新自己那一项，`FileState.analysis` 作为派生值自动反映最新情况。
  Future<void> _loadIpaInfo(String filePath) async {
    final gen = ++_loadGeneration;
    final fileState = ref.read(currentFileStateProvider.notifier);
    final isParsingState = ref.read(isParsingProvider.notifier);
    final iosStageState = ref.read(iosParseStageProvider.notifier);
    final enableSignature =
        ref.read(settingStateProvider.select((value) => value.enableSignature));
    final enableHash =
        ref.read(settingStateProvider.select((value) => value.enableHash));
    final enableSecurityAudit = ref.read(
        settingStateProvider.select((value) => value.enableSecurityAudit));

    // 切文件时先把上一个文件的状态清干净。用显式 null 而不是不传 ——
    // 不传会保留上一个文件的 ipaAnalysis，造成跨文件串数据。
    fileState.update(FileState(
      filePath: filePath,
      fileSize: File(filePath).lengthSync(),
      isComputingHash: enableHash,
    ));
    ref.read(currentApkInfoProvider.notifier).reset();
    ref.read(selectedIconIndexProvider.notifier).reset();
    isParsingState.update(true);
    iosStageState.update(null);
    _currentTask = null;
    _iosCodeSignCancelled = false;

    if (enableHash) {
      computeFileHashes(filePath).then((hashes) {
        if (!mounted || _loadGeneration != gen) return;
        fileState.update(ref.read(currentFileStateProvider).copyWith(
              md5Hash: hashes.md5,
              sha1Hash: hashes.sha1,
              sha256Hash: hashes.sha256,
              isComputingHash: false,
            ));
      }).catchError((e) {
        log.warning('_loadIpaInfo: failed to compute hashes: $e');
        if (!mounted || _loadGeneration != gen) return;
        fileState.update(ref
            .read(currentFileStateProvider)
            .copyWith(isComputingHash: false));
      });
    }

    IpaParseTask task;
    try {
      final baselineDb = await OfficialBaselineStore.load();
      task = await IpaParseTask.start(
        filePath,
        securityAudit: enableSecurityAudit,
        baselineDb: baselineDb,
      );
    } catch (e) {
      log.warning('_loadIpaInfo: failed to start the IPA task: $e');
      if (_loadGeneration == gen) {
        _setFailure(t.parse.parse_apk_info_fail);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.parse.parse_apk_info_fail)),
        );
      }
      if (_loadGeneration == gen) {
        isParsingState.update(false);
        iosStageState.update(null);
      }
      return;
    }

    if (_loadGeneration != gen) {
      // 在 worker 起来的这段时间里用户又切了文件 —— 直接丢掉这次任务。
      task.cancel();
      return;
    }
    _currentTask = task;
    final runFuture = _beginAnalysisRun(filePath, PackagePlatform.ios);

    IpaAnalysis? parsed;
    SecurityAnalysisResult? security;
    var applied = false;
    var runTerminal = false;
    await for (final event in task.events) {
      if (_loadGeneration != gen) break;

      switch (event) {
        case IpaStageReached(:final stage):
          iosStageState.update(stage);
        case IpaOpenFailed(:final result, :final detail):
          // 容器打不开：显示**具体原因**，而不是笼统的「解析失败」。
          final message = DetailRenderer.openFailure(result, t, detail: detail);
          _setFailure(message);
          runTerminal = true;
          unawaited(_finishAnalysisRun(
            runFuture: runFuture,
            status: AnalysisRunStatus.failed,
            limitation: 'ipa.open_failed',
          ));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
          }
        case IpaParseFailed(:final reason):
          log.warning('_loadIpaInfo: parse failed: $reason');
          _setFailure(t.parse.parse_apk_info_fail);
          runTerminal = true;
          unawaited(_finishAnalysisRun(
            runFuture: runFuture,
            status: AnalysisRunStatus.failed,
            limitation: 'ipa.parse_failed',
          ));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t.parse.parse_apk_info_fail)),
            );
          }
        case IpaParseSucceeded(:final analysis):
          // 两阶段：静态结果先到，安全审计随后。先让用户看到包内容。
          parsed = analysis;
          security = analysis.security;
          final currentState = ref.read(currentFileStateProvider);
          fileState.update(currentState.copyWith(
            ipaAnalysis: analysis,
            securityResult: security,
          ));
          unawaited(_recordIosRecentFile(
            analysis,
            currentState.filePath ?? '',
            currentState.fileSize ?? 0,
          ));
          isParsingState.update(false);
          iosStageState.update(null);
          applied = true;
          _setFailure(null);
        case IpaSecurityReady(:final security):
          if (parsed == null) break;
          final currentState = ref.read(currentFileStateProvider);
          fileState.update(currentState.copyWith(
            securityResult: security,
          ));
        case IpaParseCancelled():
          // 用户主动取消 —— 不弹错误提示，但页面要能说明为什么没有结果。
          log.info('_loadIpaInfo: cancelled by user');
          _setFailure(t.analysis_state.cancelled);
          runTerminal = true;
          unawaited(_finishAnalysisRun(
            runFuture: runFuture,
            status: AnalysisRunStatus.cancelled,
          ));
      }
    }

    if (_loadGeneration != gen) {
      // 用户在这段时间里又切了文件：这次的结果已经没人要了，但任务还在跑。
      // 必须显式取消 —— `break` 只是不再读事件流，worker isolate 会继续把
      // 整个解析做完（真样本上是几秒的 CPU 与几十 MB 内存），而结果只会被
      // 丢掉。连续拖入两个文件时，这就是两条流水线同时在跑。
      task.cancel();
      return;
    }

    if (parsed == null && _failureMessage == null) {
      // 事件流结束却没有结果，也没有显式错误：仍然要把页面从空白里救出来，
      // 否则用户看到的是「文件已选中 + 一屏 '-'」。
      _setFailure(t.parse.parse_apk_info_fail);
    }
    if (parsed == null && !runTerminal) {
      unawaited(_finishAnalysisRun(
        runFuture: runFuture,
        status: AnalysisRunStatus.failed,
        limitation: 'ipa.no_result',
      ));
    }

    if (parsed != null) {
      // 正常情况下 `IpaParseSucceeded` 已经在循环里应用过了；这里只兜底
      // 处理“事件顺序被未来改动打乱”的情况，不重复记录最近文件。
      if (!applied) {
        fileState.update(ref.read(currentFileStateProvider).copyWith(
              ipaAnalysis: parsed,
              securityResult: security,
            ));
        isParsingState.update(false);
        iosStageState.update(null);
      }

      // 签名验证是单独一步：它要解包到磁盘，因此在主 isolate 上跑，
      // 并且在静态解析完成之后才开始 —— 静态结果先呈现给用户。
      final mainApp = parsed.mainApp;
      if (enableSignature && mainApp != null) {
        await _verifyIosSignature(filePath, gen, mainApp);
      }
      if (_loadGeneration == gen) {
        final state = ref.read(currentFileStateProvider);
        final pending = state.isComputingHash || state.isComputingSignature;
        unawaited(_finishAnalysisRun(
          runFuture: runFuture,
          status:
              pending ? AnalysisRunStatus.partial : AnalysisRunStatus.success,
        ));
      }
      return;
    }

    isParsingState.update(false);
    iosStageState.update(null);
  }

  /// 把这次解析记进「最近文件」，并顺手缓存真实应用图标。
  ///
  /// **图标只在这里存**：解析刚完成时它已经在手上（Android 是渲染好的
  /// `ui.Image`，iOS 是刚解出来的候选）。再晚一步，为了画列表里的一行就得
  /// 重新打开归档、重解资源表 —— 那是「打开一个包」的开销，不是「画一行」的
  /// 开销。因此缓存是**顺手**做的，不是列表按需去取的。
  ///
  /// 任何一步失败都只影响列表里那个小图标，不影响「记录最近文件」本身。
  Future<void> _recordRecentFile({
    required String path,
    required int size,
    required String platform,
    ui.Image? icon,
  }) async {
    String? iconFile;
    if (icon != null) {
      iconFile = await RecentIconCache.storeFromImage(path, size, icon);
    }
    try {
      await ref.read(recentFilesProvider.notifier).add(
            path,
            size,
            platform: platform,
            iconFile: iconFile,
          );
    } catch (e) {
      log.warning('_recordRecentFile: failed to record recent file: $e');
    }
  }

  /// iOS 侧：先把图标候选解出来，再走 [_recordRecentFile]。
  ///
  /// 解码失败（CgBI 异常、候选为空）时图标留空，列表退回平台通用图标 ——
  /// 那是「没缓存到」，不是「这个包有问题」。
  Future<void> _recordIosRecentFile(
    IpaAnalysis analysis,
    String path,
    int size,
  ) async {
    ui.Image? icon;
    try {
      final candidates = analysis.icon?.candidates ?? const [];
      if (candidates.isNotEmpty) {
        final decoded = await IosIconDecoder.decode(candidates.first);
        if (decoded.hasImage) icon = decoded.image;
      }
    } catch (e) {
      log.fine('_recordIosRecentFile: 图标解码失败，列表将使用平台图标: $e');
    }
    await _recordRecentFile(
      path: path,
      size: size,
      platform: 'ios',
      icon: icon,
    );
  }

  /// 解包主应用并调用 `codesign`。
  ///
  /// 失败/不可用时**不弹错误**：这不是「解析失败」，而是「这项检查没做成」，
  /// 结果会如实显示在详情页的签名卡片里。弹错误会让用户以为整个包有问题。
  Future<void> _verifyIosSignature(
    String filePath,
    int gen,
    IosBundle mainApp,
  ) async {
    final fileState = ref.read(currentFileStateProvider.notifier);
    try {
      final result = await IosCodeSignStep.run(
        filePath,
        mainApp,
        isCancelled: () => _iosCodeSignCancelled || _loadGeneration != gen,
      );
      if (!mounted || _loadGeneration != gen) return;
      fileState.update(
          ref.read(currentFileStateProvider).copyWith(iosCodeSign: result));
    } catch (e) {
      log.warning('_verifyIosSignature: $e');
      if (!mounted || _loadGeneration != gen) return;
      fileState.update(ref.read(currentFileStateProvider).copyWith(
            iosCodeSign: IosCodeSignResult(
              status: SignatureStatus.unknown,
              error: '$e',
            ),
          ));
    }
  }

  /// 取消当前解析。
  ///
  /// UI 依据 `_currentTask` 是否就绪决定显不显示取消按钮 —— 不显示伪可用按钮。
  ///
  /// 各路径的取消能力**并不相同**（见 `CancellableParseTask`）：
  /// - 内置解析器与 iOS 静态解析：`Isolate.immediate` 强杀 worker；
  /// - aapt2 子进程：`SIGKILL`；XAPK 路径已把句柄回调出来，因此**可取消**
  ///   （早先这里的注释说「暂不可取消」，那条已经过时）；
  /// - iOS 解包 + codesign：协作式标志 —— 它要写临时目录，不能被强杀。
  ///
  /// 已知缺口：XAPK 路径中 aapt2 **之前**的 ZIP 打开与解包是同步 IO，
  /// 不可中断。
  void _cancelParse() {
    // 解包 + codesign 那一步用协作式标志：它要写临时目录，不能被强杀。
    _iosCodeSignCancelled = true;

    final task = _currentTask;
    if (task == null) return;
    log.info('_cancelParse: requested by user');
    task.cancel();
  }

  /// iOS 平台的详情卡片。
  ///
  /// **与 Android 侧同一套版式**：同样的 `Card` + `TitleValueLayout`、同样的
  /// 卡片顺序（文件 → 平台 → 标识 → 版本 → 列表 → 哈希 → 诊断 → 结构 →
  /// 签名）、同样的复制按钮与「计算哈希 / 验证签名」开关。
  ///
  /// 两页的字段名大量重叠 —— 「版本名」在 Android 是 `versionName`、在 iOS 是
  /// `CFBundleShortVersionString`，「包标识」一边是包名一边是 Bundle ID ——
  /// 所以**区分靠的是最上面那一行平台标识**，而不是把两页做成两种样子。
  ///
  /// 只渲染**确实拿到了数据**的项：每一项都先判断状态，读不到就说明为什么，
  /// 而不是留一个空值 —— 空值会被读成「这个包没有这项信息」。
  List<Widget> _buildIosCards(FileState fileState) {
    // 分三层取值，含义不同，不能混：
    // - [parsed] 是 iOS 侧的结构化解析结果（可能有，也可能还没跑完）；
    // - [analysis] 是统一模型（解析结果 + 哈希 + 签名汇合后的派生值）；
    // - [ios] 是统一模型里的 iOS 部分，UI 只读它。
    final parsed = fileState.ipaAnalysis;
    final result = fileState.analysis;
    final ios = result?.ios;
    final cards = <Widget>[];

    // 与 Android 侧读同一组设置：两侧的开关语义必须一致，否则「对齐」只是
    // 看起来像。
    final enableHash =
        ref.watch(settingStateProvider.select((value) => value.enableHash));

    Widget card(String title, String value,
            {Widget? end, bool selectable = false}) =>
        Card(
          child: TitleValueLayout(
            title: title,
            value: value,
            end: end,
            selectable: selectable,
          ),
        );

    /// 把一个 [FieldValue] 渲染成「值」或「为什么没有值」。
    ///
    /// 实现只有一份（[FieldValueText]）—— 这里、Android 卡片、Markdown 报告、
    /// 差异页四处共用。此前四处各写一遍，其中三处把「原因」直接取
    /// `value.diagnostic`（硬编码英文），中文界面上就混进了英文。
    String field(FieldValue<Object?> value) =>
        FieldValueText.describe(value, t);

    // 平台标识放在最前：两页版式一致，这一行是用户分辨自己在看哪个平台的
    // 第一眼依据。
    cards.add(_buildPlatformRow(fileState));

    // FairPlay：即使后续统一模型还没汇合，只要 Mach-O 已解析出 cryptid=1，
    // 就要先告诉读者「字符串/符号看到的是密文」。这是范围说明，不是风险卡片。
    if (parsed != null && parsed.hasEncryptedExecutable) {
      cards.add(SecurityNoticeBanner(
        title: t.security.encryption_banner_title,
        body: t.security.encryption_banner_body(
          count: parsed.encryptedExecutablePaths.length,
        ),
      ));
    }

    // 还没解析出结果时，「应用信息」无从谈起，但**文件信息是事实** ——
    // 路径与大小在解析之前就已经知道了，照常显示。
    if (parsed == null || result == null || ios == null) {
      cards.add(_SectionHeader(title: t.file_info.group, tab: DetailTab.files));
      cards.add(card(t.file_info.file, fileState.filePath ?? '-',
          end: _buildFileActionMenu()));
      cards.add(card(
        t.file_info.size,
        fileState.fileSize != null
            ? "${formatFileSize(fileState.fileSize)}"
                " (${fileState.fileSize} Bytes)"
            : "",
      ));
      cards.add(card(t.ios_info.section, t.ios_info.unavailable));
      return cards;
    }

    // ===== 应用信息（归入「概览」，与 Android 侧对齐）=====
    //
    // **应用信息排在文件信息之前**（V2.4.6 调换）：用户打开一个包，第一眼
    // 要找的是「这是哪个应用、什么版本」，而不是「它在磁盘上的路径」——
    // 后者是排查时才需要的。Hero 卡片因此紧跟在平台行之后。
    cards.add(
        _SectionHeader(title: t.ios_info.group_app, tab: DetailTab.overview));

    // 容器里没有 `Payload/*.app` 时，后面每一项都会是「-」
    if (ios.mainApp == null) {
      cards.add(card(t.ios_info.unavailable, t.ios_info.no_main_app));
    }

    // Hero 卡片：大图标 + 应用名 + Bundle ID + 版本 + 架构位数
    //
    // 复制按钮**放进卡片里**（`trailing`）。早先它被 `Align` 贴在卡片下面，
    // 于是界面上是一个孤零零的复制图标飘在空白处，看不出属于哪一项。
    cards.add(IosHeroCard(
      appName: field(ios.preferredName),
      bundleId: field(ios.bundleIdentifier),
      version: ios.shortVersion.hasValue ? '${ios.shortVersion.value}' : '',
      buildNumber: ios.buildNumber.hasValue ? '${ios.buildNumber.value}' : '',
      architectureLabel: architectureLabelOf(result),
      icon: ios.icon,
      trailing: CopyIconButton(
        text: ios.bundleIdentifier.value ?? '',
        iconSize: 16,
      ),
      details: _FactsGrid(cells: [
        (t.ios_info.bundle_id, field(ios.bundleIdentifier)),
        (t.apk_info.version_name, field(ios.shortVersion)),
        (t.apk_info.version_code, field(ios.buildNumber)),
        (t.ios_info.minimum_os, field(ios.minimumOSVersion)),
        (t.ios_info.architectures, architectureLabelOf(result) ?? '-'),
        (t.ios_info.executable, field(ios.executableName)),
      ]),
    ));

    if (fileState.securityResult != null) {
      cards.add(_buildOverviewEvidence(fileState));
    }

    // ===== 文件信息 =====
    cards.add(_SectionHeader(title: t.file_info.group, tab: DetailTab.files));
    cards.add(card(t.file_info.file, fileState.filePath ?? '-',
        end: _buildFileActionMenu()));
    cards.add(card(
      t.file_info.size,
      fileState.fileSize != null
          ? "${formatFileSize(fileState.fileSize)} (${fileState.fileSize} Bytes)"
          : "",
    ));
    // ===== 应用详情（归入「应用」Tab，与 Android 侧对齐）=====
    cards.add(_SectionHeader(
        title: t.detail_tab.infoPlist, tab: DetailTab.infoPlist));

    // 版本栏。图标只在 Hero 卡片里出现一次 —— 早先这里右侧还挂着
    // 一张独立的图标卡，与 Hero 卡片是同一个图标，纯属重复。
    cards.add(card(t.apk_info.version_name, field(ios.shortVersion)));
    cards.add(card(t.apk_info.version_code, field(ios.buildNumber)));
    cards.add(card(t.ios_info.minimum_os, field(ios.minimumOSVersion)));

    cards.add(card(
        t.ios_info.device_family,
        ios.deviceFamily.hasValue
            ? DetailRenderer.deviceFamily(ios.deviceFamily.value, t)
            : field(ios.deviceFamily)));
    cards.add(IosInfoCard(
      title: t.ios_info.executable,
      value: field(ios.executableName),
      isIdentifier: true,
    ));

    // ===== 能力声明（归入「权限」Tab，与 Android 侧的权限/组件对位）=====
    if (ios.queriesSchemes.hasValue ||
        ios.urlSchemes.hasValue ||
        ios.backgroundModes.hasValue ||
        ios.requiredDeviceCapabilities.hasValue ||
        ios.hasMultipleMainApps) {}
    // 「注册的 scheme」与「查询的 scheme」是**两个方向**的事实：
    // 前者是本应用被外部唤起的入口，后者是本应用可以唤起别人的白名单。
    // 放在一起但分开陈述，避免读者把两者混为一谈。
    if (ios.urlSchemes.hasValue) {
      cards.add(card(
        t.ios_info.url_schemes,
        ios.urlSchemes.value!.join('\n'),
        selectable: true,
      ));
    }
    if (ios.queriesSchemes.hasValue) {
      cards.add(card(
        t.ios_info.queries_schemes,
        ios.queriesSchemes.value!.join('\n'),
        selectable: true,
      ));
    }
    if (ios.backgroundModes.hasValue) {
      cards.add(card(
        t.ios_info.background_modes,
        ios.backgroundModes.value!.join('\n'),
        selectable: true,
      ));
    }
    if (ios.requiredDeviceCapabilities.hasValue) {
      cards.add(card(
        t.ios_info.required_capabilities,
        ios.requiredDeviceCapabilities.value!.join('\n'),
        selectable: true,
      ));
    }
    if (ios.hasMultipleMainApps) {
      cards.add(card(
        t.ios_info.bundles,
        '${ios.container.payloadApps.length} '
        '${t.ios_info.bundle_kind_main_app}: '
        '${ios.container.payloadApps.map((b) => b.path).join(', ')}',
        selectable: true,
      ));
    }

    // 图标清单
    cards.add(card(
      t.ios_info.icon_section,
      DetailRenderer.iosIcon(ios.icon, t),
      selectable: true,
    ));

    // ===== 容器与二进制 =====
    cards.add(_SectionHeader(
        title: t.ios_info.group_container, tab: DetailTab.frameworks));
    final container = DetailRenderer.iosContainer(ios.container, t);
    if (container.isNotEmpty) {
      cards
          .add(card(t.ios_info.container_section, container, selectable: true));
    }
    final executable = DetailRenderer.iosExecutable(ios.executable, t);
    if (executable.isNotEmpty) {
      cards.add(card(t.ios_info.binary_section, executable, selectable: true));
    }
    final nested = DetailRenderer.iosNestedBinaries(ios.nestedBinaries, t);
    if (nested.isNotEmpty) {
      cards.add(card(t.ios_info.nested_binaries, nested, selectable: true));
    }

    // ===== 签名与授权（拆成两张卡片）=====
    cards.add(_SectionHeader(
        title: t.ios_info.group_signature, tab: DetailTab.signature));
    // 1. 静态签名材料（始终显示，哪怕没有材料也明确说明）
    final signatureBody = DetailRenderer.iosSignature(ios, t);
    cards.add(card(
      t.ios_info.signature_section,
      signatureBody.isNotEmpty ? signatureBody : '-',
      selectable: true,
    ));
    // 2. codesign 验证结果 + 状态徽章
    final codeSignBody = DetailRenderer.iosCodeSignBody(ios.codeSign, t);
    final codeSignStatus = ios.codeSign?.status;
    final bool? verified = codeSignStatus == null
        ? null
        : (codeSignStatus == SignatureStatus.verified);
    cards.add(card(
      t.ios_info.codesign_section,
      codeSignBody,
      selectable: true,
      end: IosSignatureBadge(verified: verified),
    ));

    // ===== 文件校验 =====
    if (enableHash) {
      cards.add(_SectionHeader(
          title: t.ios_info.group_integrity, tab: DetailTab.files));
      // 复制按钮由 `TitleValueLayout` 统一提供（默认就有），这里不再各挂一个
      // —— 否则同一张卡片上会出现两个一模一样的复制图标。
      cards.add(card(t.file_info.md5, fileState.md5Hash ?? ''));
      cards.add(card(t.file_info.sha1, fileState.sha1Hash ?? ''));
      cards.add(card(
        t.file_info.sha256,
        fileState.isComputingHash
            ? t.file_info.computing_hash
            : (fileState.sha256Hash ?? ''),
      ));
    }

    // ===== 分析覆盖 =====
    //
    // 覆盖率是**结构化**的（逐维度状态 + 覆盖量 + 说明），因此单独成一张
    // 卡片，而不是混进「解析诊断」的文本里 —— 后者是给人读的句子，
    // 从句子里反推「哪个维度没覆盖」既不可靠也没必要。
    final coverage = result.security?.coverage;
    if (coverage != null && !coverage.isEmpty) {
      cards.add(
          _SectionHeader(title: t.coverage.title, tab: DetailTab.security));
      cards.add(card(
        t.coverage.title,
        _coverageBody(coverage, t),
        selectable: true,
      ));
    }

    // ===== 解析诊断 =====
    final diagnostics = DetailRenderer.diagnostics(result.diagnostics, t);
    if (diagnostics.isNotEmpty) {
      cards.add(_SectionHeader(
          title: t.apk_info.diagnostics, tab: DetailTab.diagnostics));
      cards.add(card(t.apk_info.diagnostics, diagnostics, selectable: true));
    }

    // ===== 安全检测 =====
    cards.addAll(_buildSecurityCards(result.security, isIos: true));

    return cards;
  }

  /// 覆盖情况的正文：汇总句 + 逐维度一行。
  ///
  /// 汇总句、状态文案、维度名都从 [AnalysisReport] 取 —— Markdown 报告与界面
  /// 用同一份，两处各写一遍必然漂移。维度名尤其如此：直接写 `entry.id` 会
  /// 把 `android.dex.strings` 这种机器标识摆到用户面前。
  String _coverageBody(AnalysisCoverage coverage, Translations t) {
    final sb = StringBuffer()
      ..writeln(AnalysisReport.coverageSummary(coverage, t))
      ..writeln()
      ..writeln(t.coverage.hint)
      ..writeln();

    for (final entry in coverage.entries) {
      sb.writeln(AnalysisReport.coverageEntryLine(entry, t));
    }
    return sb.toString().trimRight();
  }

  /// 安全检测卡片组。
  ///
  /// 与平台无关：Android 与 iOS 共用同一套呈现逻辑，差异只来自
  /// [SecurityAnalysisResult] 本身的数据。
  ///
  /// 呈现分三层：
  /// 1. 总览卡片：发现数量与覆盖状态摘要
  /// 2. 发现卡片列表：每条发现独立成卡，含风险徽章、可展开证据
  /// 3. 局限卡片：引擎覆盖不足的说明
  List<Widget> _buildSecurityCards(
    SecurityAnalysisResult? security, {
    bool isIos = false,
  }) {
    if (security == null) return const [];

    final findings = security.findings;
    // **两个信号分开用**：`hasActualGaps` 决定总览卡要不要标「有缺口」，
    // `hasDeclaredLimitations` 决定要不要列方法论局限（它恒真，列出来是
    // 为了交代边界，不是为了报警）。混用会让警告永远亮着。
    final hasActualGaps = security.hasActualGaps;
    final gapCount = security.coverageGapCount;

    // 「盗 U 风险」单独一项：它跨平台、是用户明确关心的一类风险，
    // 埋在几十条发现里看不见。摘出来之后通用列表里就不重复列了。
    SecurityFinding? cryptoRisk;
    SecurityFinding? jailbreak;
    for (final f in findings) {
      if (f.category == SecurityCategory.cryptoAsset) {
        cryptoRisk ??= f;
      } else if (f.ruleId == 'IOS-JAILBREAK-TOOLKIT') {
        jailbreak = f;
      }
    }

    final cards = <Widget>[
      _SectionHeader(title: t.security.title, tab: DetailTab.security),
      // 总览摘要卡片
      _buildSecurityOverviewCard(findings, hasActualGaps, gapCount),
      // 结构化证据：制品清单 / 加载链。只有真正产出了才显示 —— `null` 是
      // 「本次未产出」，不是「包里没有」，不能渲染成一张空卡。
      if (security.artifacts != null || security.loadGraph != null)
        SecurityEvidenceCard(
          artifacts: security.artifacts,
          loadGraph: security.loadGraph,
        ),
      // 证据中心：只显示本次真实产出的证据，按稳定 evidenceId 去重。
      if (security.evidence.isNotEmpty)
        SecurityEvidenceCenterCard(evidence: security.evidence),
      // 「盗 U 风险」：优先用五段链评估卡；旧路径没有评估时退回小结。
      if (security.cryptoTheft case final assessment?)
        CryptoTheftCard(
          assessment: assessment,
          seal: security.seal,
          baseline: security.baseline,
        )
      else
        _buildCryptoRiskHeader(cryptoRisk),
      if (cryptoRisk != null) SecurityFindingCard(finding: cryptoRisk),
      // 越狱 / 漏洞利用组件：只有 iOS 包才查得到，Android 侧不显示这块
      // —— 显示一个永远「未发现」的卡片等于暗示「查过了」。
      if (isIos) ...[
        _buildJailbreakHeader(jailbreak),
        if (jailbreak != null) SecurityFindingCard(finding: jailbreak),
      ],
    ];

    // 按严重程度排序的发现卡片（P0 在前，INFO 在后）
    final sortedFindings = List<SecurityFinding>.from(findings)
      ..removeWhere((f) =>
          f.category == SecurityCategory.cryptoAsset ||
          f.ruleId == 'IOS-JAILBREAK-TOOLKIT')
      ..sort((a, b) => a.severity.index.compareTo(b.severity.index));

    for (final finding in sortedFindings) {
      cards.add(SecurityFindingCard(finding: finding));
    }

    // 方法论局限卡片：**只要引擎声明了就列**。
    //
    // 它曾经挂在 `hasCoverageGaps` 下面 —— 那个信号恒真，所以行为上没差别；
    // 拆开之后若继续用 `hasActualGaps`，覆盖全绿时这些「本次是离线静态分析」
    // 的交代就会消失，反而更容易被误读成「查全了」。
    if (security.hasDeclaredLimitations) {
      cards.add(Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 16,
                    color: Theme.of(context).hintColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    t.security.limitations,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...security.limitations.map(
                (l) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('·  ', style: Theme.of(context).textTheme.bodySmall),
                      Expanded(
                        child: Text(
                          // 结果级局限也走本地化：引擎给的是稳定 code +
                          // 英文回退，直接打印会在英文界面里显示中文。
                          AnalysisReport.limitationNoteText(l, t),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ));
    }

    return cards;
  }

  /// 「盗 U 风险」这一项的小结行。
  ///
  /// **没有发现时也要出现**：整块消失会让用户以为「没查」，而我们要说的是
  /// 「查了，没发现」。三档状态由发现项的有无与等级决定，颜色与文案都由
  /// i18n 给，不在这里拼字符串。
  Widget _buildCryptoRiskHeader(SecurityFinding? risk) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final highRisk =
        risk != null && risk.severity.index <= SecuritySeverity.p2.index;
    final (label, color) = risk == null
        ? (t.security.crypto_risk.state_none, theme.hintColor)
        : highRisk
            ? (t.security.crypto_risk.state_high, colorScheme.error)
            : (t.security.crypto_risk.state_review, Colors.amber.shade700);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.account_balance_wallet_outlined,
                    size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.security.crypto_risk.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (risk == null) ...[
              const SizedBox(height: 8),
              Text(
                t.security.crypto_risk.not_found,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 「越狱 / 漏洞利用组件」小结。
  ///
  /// 只在分析 iOS 包时出现 —— Android 侧这条规则不会产出发现，
  /// 显示一个永远「未发现」的卡片等于噪声。
  Widget _buildJailbreakHeader(SecurityFinding? risk) {
    final theme = Theme.of(context);
    final color =
        risk == null ? theme.hintColor : Theme.of(context).colorScheme.error;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory_outlined, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.security.jailbreak_risk.title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    risk == null
                        ? t.security.jailbreak_risk.state_none
                        : t.security.jailbreak_risk.state_found,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (risk == null) ...[
              const SizedBox(height: 8),
              Text(
                t.security.jailbreak_risk.not_found,
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 安全检测总览摘要卡片。
  ///
  /// [hasActualGaps] / [gapCount] 来自**结构化覆盖**（`AnalysisCoverage.gaps`），
  /// 不是恒真的方法论声明 —— 见 `SecurityAnalysisResult.hasActualGaps`。
  Widget _buildSecurityOverviewCard(
    List<SecurityFinding> findings,
    bool hasActualGaps,
    int gapCount,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final severityCounts = <SecuritySeverity, int>{};
    for (final f in findings) {
      severityCounts[f.severity] = (severityCounts[f.severity] ?? 0) + 1;
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.security,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  t.security.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (findings.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color:
                          colorScheme.primaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      t.report.findings_count(count: '${findings.length}'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            if (findings.isEmpty) ...[
              const SizedBox(height: 12),
              Text(
                t.security.no_findings,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
            if (severityCounts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in severityCounts.entries)
                    _SeverityCountChip(
                      severity: entry.key,
                      count: entry.value,
                    ),
                ],
              ),
            ],
            // 覆盖状态：**只在真有缺口时报警**。
            //
            // 这个参数此前一直是死参数（签名有、函数体 0 处引用），于是
            // 总览卡从不提覆盖 —— 用户要翻到「分析覆盖」卡片才知道结论
            // 只覆盖了一部分。现在接上结构化覆盖的真实缺口数。
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  hasActualGaps
                      ? Icons.warning_amber_outlined
                      : Icons.check_circle_outline,
                  size: 14,
                  color: hasActualGaps ? colorScheme.error : theme.hintColor,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    // 缺口可能来自「有 UNKNOWN 级发现」而不是覆盖维度 ——
                    // 那种情况 `gapCount` 是 0，直接拼「0 个维度有缺口」会
                    // 自相矛盾，改用「覆盖不完整」的措辞。
                    !hasActualGaps
                        ? t.coverage.no_gaps
                        : (gapCount > 0
                            ? t.coverage.gap_count(count: '$gapCount')
                            : t.security.coverage_incomplete),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          hasActualGaps ? colorScheme.error : theme.hintColor,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 平台标识行。
  ///
  /// 两页的版式与字段名都对齐之后，**这一行是唯一一眼能分辨的地方** ——
  /// 没有它，用户只能靠「版本名 / 版本代码」这类字段去猜自己在看哪个平台，
  /// 而这两个词在两个平台上指的是完全不同的东西。
  Widget _buildPlatformRow(FileState fileState) {
    final isIos = fileState.platform == PackagePlatform.ios;
    return Card(
      child: TitleValueLayout(
        title: t.file_info.platform,
        value: isIos ? t.file_info.platform_ios : t.file_info.platform_android,
        end: Icon(
          isIos ? Icons.apple : Icons.android,
          size: 20,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// 取「启动时要打开的文件」。
  ///
  /// 平台通道优先：Windows / macOS 的 native 侧都会把双击进来的路径解析好
  /// （Windows 还会在**第二个实例**被唤起时通过同一个通道推 `fileOpened`）。
  /// [fallbackPath] 是没有这个通道时（Linux）的退路 —— 来自 `main()` 的
  /// 命令行参数。
  Future<void> _initPlatformState({String fallbackPath = ''}) async {
    log.info("_initPlatformState: start");
    String? initialFilePath;
    try {
      // 使用方法通道获取文件路径
      initialFilePath = await const MethodChannel('file_association')
          .invokeMethod('getInitialFilePath');
    } on PlatformException catch (e) {
      log.info("PlatformException: $e");
      initialFilePath = null;
    } on MissingPluginException catch (e) {
      // 没有这个通道的平台（Linux）走兜底路径，不该在这里断掉。
      log.info("MissingPluginException: $e");
      initialFilePath = null;
    }

    if (initialFilePath == null || initialFilePath.isEmpty) {
      initialFilePath = fallbackPath;
    }

    log.info("_initPlatformState: initialFilePath=$initialFilePath");
    if (!mounted) return;

    // 到这里一定非空：要么通道给了路径，要么已经换成 fallbackPath。
    if (initialFilePath.isNotEmpty) {
      openApk(initialFilePath);
    }
  }

  void _setupFileAssociationHandler() {
    const MethodChannel('file_association').setMethodCallHandler((call) async {
      log.info("_setupFileAssociationHandler: call.method=${call.method}");
      if (call.method == 'fileOpened') {
        final path = call.arguments;
        if (path is String && path.isNotEmpty) {
          // 第二个实例转发进来的文件（Windows 单实例）—— 窗口已经存在，
          // 用户可能停在设置页或概览页。不切页的话，界面上看不出任何变化，
          // 用户会以为双击没生效。这里主动跳到分析页。
          ref.read(shellNavigationProvider.notifier).navigate('analysis');
          openApk(path);
        }
      }
      return null;
    });
  }

  @override
  void initState() {
    super.initState();
    // 延时以保证初始化一次
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) updateActions();
    });
    log.info("initState apkByArgs=$apkByArgs");
    // Windows 与 macOS 都走平台通道：native 侧解析好启动文件，Windows 还会在
    // **第二个实例**被唤起时通过同一个通道推 `fileOpened`（见
    // `windows/runner/single_instance.cpp`）—— 于是双击第二个包不会开新窗口，
    // 而是在这个窗口里直接换文件。
    //
    // Linux 没有这个通道，退回 `main()` 里的命令行参数。
    if (Platform.isMacOS || Platform.isWindows) {
      _initPlatformState(fallbackPath: apkByArgs);
      _setupFileAssociationHandler();
    } else if (apkByArgs.isNotEmpty) {
      openApk(apkByArgs);
    }
  }

  List<Widget> _buildActions(FileState fileState) {
    return [
      IconButton(
          // 「打开文件」用文件夹图标：`file_open` 是一个带折角的文件，
          // 在 20px 下和「更多」里的文档图标几乎分不出来。
          icon: const Icon(Icons.folder_open),
          tooltip: t.open.open_apk,
          onPressed: () async {
            openFilePicker();
          }),
      IconButton(
          // 「重新解析」曾经是放大镜（`Icons.search`）—— 那是「查找」的语义，
          // 而这里做的是把当前文件重新走一遍解析流水线。
          icon: const Icon(Icons.refresh),
          tooltip: t.parse.parse_apk,
          onPressed: fileState.filePath == null
              ? null
              : () {
                  openApk(fileState.filePath ?? '');
                }),
      // 安装入口**不在这里**：左侧导航有独立的「安装」页，选包、USB/无线
      // 连设备、安装都在那一页。同一件事两个入口，用户每次都要先判断
      // 「该点哪个」；而且这个按钮对 `.ipa` 也显示（`_buildActions` 不分
      // 平台），点下去执行的是 `adb install xxx.ipa`，必然失败。
      _buildMoreMenuButton(context),
    ];
  }

  PopupMenuItem<String> _buildMenuItem(
      String value, IconData icon, String title,
      {bool enabled = true}) {
    return PopupMenuItem(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        value: value,
        enabled: enabled,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ));
  }

  // 构建文件操作菜单
  Widget _buildFileActionMenu() {
    final fileState = ref.watch(currentFileStateProvider);
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, size: 18),
      enabled: fileState.filePath != null,
      // 设置菜单位置在按钮下方
      offset: const Offset(0, 0),
      position: PopupMenuPosition.under,
      // 设置菜单项更紧凑
      itemBuilder: (context) => [
        _buildMenuItem(
            'rename', Icons.drive_file_rename_outline, t.rename.rename_file),
        _buildMenuItem(
            'open_directory', Icons.folder_open, t.open.open_file_directory),
        _buildMenuItem('copy_path', Icons.content_copy, t.home.copy_file_path),
      ],
      onSelected: onMenuActionSelected,
    );
  }

  /// 获取当前显示的应用名称（根据用户选择的语言）。
  ///
  /// 返回 `null` 表示**拿不到名字**（资源里没有 label）—— 与「名字是空串」
  /// 分开：界面上前者渲染 `-`，而改名对话框要的是「没有可用的默认名」。
  String? _getDisplayLabel(ApkInfo? apkInfo) {
    if (apkInfo == null) return null;
    final selectedLocale = ref.read(selectedLabelLocaleProvider);
    if (selectedLocale != null && apkInfo.labels.containsKey(selectedLocale)) {
      return apkInfo.labels[selectedLocale];
    }
    return apkInfo.label;
  }

  static const _kDefaultLocale = '__default__';

  /// 构建应用名称语言切换菜单按钮
  Widget _buildLabelLocaleMenu(ApkInfo? apkInfo) {
    final hasLabels = apkInfo != null && apkInfo.labels.isNotEmpty;
    final selectedLocale = ref.watch(selectedLabelLocaleProvider);
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.translate,
        size: 16,
        color: hasLabels
            ? (selectedLocale != null
                ? Theme.of(context).colorScheme.primary
                : null)
            : Theme.of(context).disabledColor,
      ),
      tooltip: t.apk_info.switch_label_language,
      enabled: hasLabels,
      offset: const Offset(0, 0),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(maxHeight: 400, maxWidth: 300),
      itemBuilder: (context) {
        if (apkInfo == null) return [];
        final colorScheme = Theme.of(context).colorScheme;
        final items = <PopupMenuEntry<String>>[];
        // 默认名称选项
        items.add(PopupMenuItem<String>(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          value: _kDefaultLocale,
          child: Row(
            children: [
              if (selectedLocale == null)
                Icon(Icons.check, size: 14, color: colorScheme.primary)
              else
                const SizedBox(width: 14),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('default',
                    style: TextStyle(
                        fontSize: 11, color: colorScheme.onPrimaryContainer)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(apkInfo.label ?? '',
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ));
        items.add(const PopupMenuDivider(height: 1));
        // 各语言选项
        final sortedEntries = apkInfo.labels.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        for (final entry in sortedEntries) {
          // 跳过与默认名称相同的条目
          if (entry.value == apkInfo.label) continue;
          items.add(PopupMenuItem<String>(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            value: entry.key,
            child: Row(
              children: [
                if (selectedLocale == entry.key)
                  Icon(Icons.check, size: 14, color: colorScheme.primary)
                else
                  const SizedBox(width: 14),
                const SizedBox(width: 8),
                Container(
                  width: 44,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(entry.key,
                      style: TextStyle(
                          fontSize: 11, color: colorScheme.onSurfaceVariant)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(entry.value,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ));
        }
        return items;
      },
      onSelected: (locale) {
        ref
            .read(selectedLabelLocaleProvider.notifier)
            .select(locale == _kDefaultLocale ? null : locale);
      },
    );
  }

  /// 把卡片列表按 [_SectionHeader.tab] 切分为 Tab 内容。
  ///
  /// 切完之后会**丢掉每个 Tab 开头那个与 Tab 同名的分组标题**：Tab 栏本身
  /// 已经写着「应用」「权限」，内容里再来一行一模一样的字纯属噪音 ——
  /// 「界面上不该出现两行同样的字」是这个页面的既有约定。
  ///
  /// 去重放在这里而不是各调用点：两页（Android / iOS）都有这种标题，
  /// 靠人手记住哪几个要去掉迟早会漏。
  Map<DetailTab, List<Widget>> _groupCardsByTab(List<Widget> cards) {
    final tabs = <DetailTab, List<Widget>>{};
    var currentTab = DetailTab.overview;

    for (final widget in cards) {
      if (widget is _SectionHeader) {
        final tab = widget.tab;
        if (tab != null) {
          currentTab = tab;
        }
      }
      tabs.putIfAbsent(currentTab, () => []).add(widget);
    }

    for (final entry in tabs.entries) {
      final list = entry.value;
      if (list.isEmpty) continue;
      final first = list.first;
      if (first is _SectionHeader &&
          first.title == detailTabLabel(entry.key, t)) {
        list.removeAt(0);
      }
    }

    return tabs;
  }

  @override
  Widget build(BuildContext context) {
    // 在当前页/文件/APK信息变化时需要更新Actions, 因为Actions的变化会修改按钮的使能状态
    // 使用微任务合并连续变化，避免同一帧内多次重建 actions
    ref.listen(currentPageProvider, (_, __) => _scheduleUpdateActions());
    ref.listen(currentFileStateProvider, (_, __) => _scheduleUpdateActions());
    ref.listen(currentApkInfoProvider, (_, __) => _scheduleUpdateActions());
    // 概览页发起的「打开这个文件」请求。
    //
    // 必须由本页处理而不是概览页自己解析：任务句柄、阶段回调、取消、
    // 代际计数（`_loadGeneration`）这些状态都只存在于本页，别处再走一遍
    // 解析就等于把流水线的状态复制成了两份。
    ref.listen(pendingOpenRequestProvider, (_, next) {
      if (next == null) return;
      final path = ref.read(pendingOpenRequestProvider.notifier).consume();
      if (path != null && path.isNotEmpty) {
        openApk(path);
      }
    });
    final apkInfo = ref.watch(currentApkInfoProvider);
    final fileState = ref.watch(currentFileStateProvider);
    final isParsing = ref.watch(isParsingProvider);
    final parseStage = ref.watch(parseStageProvider);
    final iosParseStage = ref.watch(iosParseStageProvider);
    // 两条流水线的阶段名没有对应关系，各自映射，不硬合并成一个联合类型。
    final parseStageLabel = iosParseStage != null
        ? DetailRenderer.ipaParseStageLabel(iosParseStage, t)
        : parseStage == null
            ? t.parse.parsing
            : DetailRenderer.parseStageLabel(parseStage, t);
    final analysisNotes = DetailRenderer.analysisNotes(fileState.analysis, t);
    final structureText =
        DetailRenderer.structure(fileState.analysis?.android?.structure, t);
    final enableSignature = ref
        .watch(settingStateProvider.select((value) => value.enableSignature));
    final enableHash =
        ref.watch(settingStateProvider.select((value) => value.enableHash));
    final textMaxLines =
        ref.watch(uiConfigStateProvider.select((value) => value.textMaxLines));

    final hasParsedResult = apkInfo != null ||
        fileState.ipaAnalysis != null ||
        fileState.analysis != null;
    // 「部分解析」只表示解析本身没拿全，不代表安全覆盖存在缺口。安全覆盖
    // 缺口已经由 `hasActualGaps` 单独表达，两个概念不能混。
    final parsePartial = apkInfo?.parseFailureReason != null ||
        (fileState.ipaAnalysis?.diagnostics
                .any((d) => d.severity == DiagnosticSeverity.error) ??
            false);
    final pageStatus = resolveAnalysisPageStatus(
      filePath: fileState.filePath,
      isParsing: isParsing,
      hasParsedResult: hasParsedResult,
      parsePartial: parsePartial,
      hasFailure: _failureMessage != null,
    );
    final showDetails = pageStatus == AnalysisPageStatus.success ||
        pageStatus == AnalysisPageStatus.partial;

    final cards = !showDetails
        ? const <Widget>[]
        : fileState.platform == PackagePlatform.ios
            ? _buildIosCards(fileState)
            : _buildAndroidCards(fileState, apkInfo, analysisNotes,
                structureText, enableSignature, enableHash, textMaxLines);
    final tabContent = _groupCardsByTab(cards);

    // 页头 + 内容。页头与 概览 / 版本对比 / 设置 共用 `PageHeader`：
    // 左边标题 + 副标题，右边是这一页的四个动作（复制 / 搜索 / 导出 / 更多）。
    //
    // 这些动作原先挂在 `HomePage` 的 `AppBar` 上，于是「分析」这个标题和
    // 它的操作都在页面**外面**，和另外三个页面（标题与操作都在页面内）
    // 完全不是一个路数。现在并进来，四个页面的头部只差标题文字。
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 12, 0),
          child: Builder(
            builder: (context) {
              final apkInfo = fileState.apkInfo;
              final ios = fileState.analysis?.ios;
              final appName = apkInfo != null
                  ? _getDisplayLabel(apkInfo)
                  : ios?.preferredName.value;
              final subtitleParts = <String>[];
              if (apkInfo != null) {
                final pkg = apkInfo.packageName;
                if (pkg != null && pkg.isNotEmpty) subtitleParts.add(pkg);
                final ver = apkInfo.versionName;
                if (ver != null && ver.isNotEmpty) {
                  subtitleParts.add(
                    apkInfo.versionCode == null
                        ? 'v$ver'
                        : 'v$ver (${apkInfo.versionCode})',
                  );
                }
                subtitleParts.add('APK');
              } else if (ios != null) {
                final bundle = ios.bundleIdentifier.value;
                if (bundle != null && bundle.isNotEmpty) {
                  subtitleParts.add(bundle);
                }
                final ver = ios.shortVersion.value;
                if (ver != null && ver.isNotEmpty) {
                  subtitleParts.add('v$ver (${ios.buildNumber.value ?? '-'})');
                }
                subtitleParts.add('IPA');
              }
              if (fileState.fileSize != null) {
                subtitleParts.add(formatFileSize(fileState.fileSize));
              }
              return PageHeader(
                title: (appName != null && appName.isNotEmpty)
                    ? appName
                    : t.nav.analysis,
                subtitle: subtitleParts.isEmpty
                    ? t.home.subtitle
                    : subtitleParts.join(' · '),
                actions: ref.watch(pageActionsProvider),
              );
            },
          ),
        ),
        Expanded(
          child: DropTarget(
            // 只有当前可见时才接收拖放。三个页面同时活在 `IndexedStack` 里、
            // 布局尺寸完全重叠，而拖放事件是全局扇出的 —— 不关掉这一层，
            // 在概览页拖一个文件会**同时**触发本页的 `openApk` 和概览页发出的
            // `pendingOpenRequest`，同一个文件被解析两遍。
            enable: Visibility.of(context),
            onDragDone: (details) {
              // 只处理第一个文件
              if (details.files.isNotEmpty) {
                final file = details.files.first;
                // 判定抽到 `isSupportedPackagePath` —— 原先这串 `endsWith` 埋在
                // 这个闭包里，只能靠真的拖一个文件进去才碰得到。
                if (isSupportedPackagePath(file.path)) {
                  openApk(file.path);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(t.open.invalid_file_type),
                    ),
                  );
                }
              }
            },
            child: _buildAnalysisContent(
              status: pageStatus,
              tabs: tabContent,
              fileState: fileState,
              isParsing: isParsing,
              parseStageLabel: parseStageLabel,
              failureMessage: _failureMessage,
            ),
          ),
        ),
      ],
    );
  }

  /// 宽屏分析页右侧的上下文栏。
  ///
  /// 只显示「当前对象 + 静态分析边界」，不复制左侧卡片的数据；窄屏由
  /// [DetailTabView] 自动隐藏。
  Widget _buildOverviewEvidence(FileState fileState) {
    final security = fileState.securityResult;
    if (security == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final high = security.findings
        .where((f) =>
            f.severity == SecuritySeverity.p0 ||
            f.severity == SecuritySeverity.p1)
        .length;
    final review = security.findings
        .where((f) =>
            f.severity == SecuritySeverity.p2 ||
            f.severity == SecuritySeverity.p3)
        .length;
    final info = security.findings.length - high - review;
    final artifacts = security.artifacts;
    final graph = security.loadGraph;

    Widget metric(String label, String value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 8.5,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ],
          ),
        );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'STATIC FINDINGS',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    fontSize: 9,
                  ),
                ),
                const Spacer(),
                Text(
                  '${security.findings.length}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                metric('HIGH', '$high'),
                metric('REVIEW', '$review'),
                metric('INFO', '$info'),
                metric('GAPS', '${security.coverage.gaps.length}'),
              ],
            ),
            if (artifacts != null || graph != null) ...[
              const SizedBox(height: 14),
              Container(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 10),
              Text(
                'STRUCTURE EVIDENCE',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  fontSize: 9,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  metric('ENTRIES',
                      '${artifacts?.inventoriedEntries ?? '-'} / ${artifacts?.totalEntries ?? '-'}'),
                  metric('NODES', '${graph?.nodes.length ?? '-'}'),
                  metric('EDGES', '${graph?.edges.length ?? '-'}'),
                  metric('DANGLING', '${graph?.danglingEdgeIds.length ?? '-'}'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _asideKv(
    ThemeData theme,
    ColorScheme scheme,
    String key,
    String value,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(
            key,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 8.5,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontSize: 10.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAnalysisAside(FileState fileState) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final platform = fileState.platform == PackagePlatform.ios
        ? t.file_info.platform_ios
        : t.file_info.platform_android;
    final filePath = fileState.filePath ?? '';

    Widget card({required Widget child}) => Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: child,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CURRENT TARGET',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                filePath.isEmpty ? '-' : path.basename(filePath),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                filePath,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Container(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    fileState.platform == PackagePlatform.ios
                        ? Icons.phone_iphone
                        : Icons.android,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(platform, style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
        if (fileState.securityResult != null &&
            fileState.securityResult!.coverage.entries.isNotEmpty) ...[
          const SizedBox(height: 12),
          card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'COVERAGE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 58,
                      height: 58,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: fileState
                                    .securityResult!.coverage.entries.isEmpty
                                ? 0
                                : (fileState.securityResult!.coverage.entries
                                            .length -
                                        fileState.securityResult!.coverage.gaps
                                            .length) /
                                    fileState.securityResult!.coverage.entries
                                        .length,
                            strokeWidth: 6,
                            backgroundColor: scheme.surfaceContainerHighest,
                          ),
                          Text(
                            '${fileState.securityResult!.coverage.entries.length - fileState.securityResult!.coverage.gaps.length}/${fileState.securityResult!.coverage.entries.length}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        AnalysisReport.coverageSummary(
                          fileState.securityResult!.coverage,
                          t,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (fileState.securityResult?.seal != null ||
            fileState.securityResult?.baseline != null) ...[
          const SizedBox(height: 12),
          card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'INTEGRITY',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                if (fileState.securityResult?.seal != null) ...[
                  _asideKv(
                    theme,
                    scheme,
                    'SEAL',
                    '${fileState.securityResult!.seal!.state.name.toUpperCase()} · ${fileState.securityResult!.seal!.scheme}',
                  ),
                  const SizedBox(height: 8),
                ],
                if (fileState.securityResult?.baseline != null)
                  _asideKv(
                    theme,
                    scheme,
                    'BASELINE',
                    fileState.securityResult!.baseline!.status.name
                        .toUpperCase(),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'STATIC ONLY',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '不执行样本，不访问网络；结论只来自本地静态证据。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<DetailTab> _tabOrder(FileState fileState) {
    if (fileState.ipaAnalysis != null) {
      return const [
        DetailTab.overview,
        DetailTab.infoPlist,
        DetailTab.frameworks,
        DetailTab.signature,
        DetailTab.security,
        DetailTab.files,
        DetailTab.diagnostics,
      ];
    }
    return const [
      DetailTab.overview,
      DetailTab.manifest,
      DetailTab.components,
      DetailTab.permissions,
      DetailTab.security,
      DetailTab.files,
      DetailTab.diagnostics,
    ];
  }

  Map<DetailTab, int> _tabCounts(FileState fileState) {
    final counts = <DetailTab, int>{};
    final apk = fileState.apkInfo;
    if (apk != null) {
      if (apk.structure.fileEntryCount > 0) {
        counts[DetailTab.manifest] = apk.structure.fileEntryCount;
        counts[DetailTab.files] = apk.structure.fileEntryCount;
      }
      if (apk.components.isNotEmpty) {
        counts[DetailTab.components] = apk.components.length;
      }
      if (apk.usesPermissions.isNotEmpty) {
        counts[DetailTab.permissions] = apk.usesPermissions.length;
      }
    }
    final ios = fileState.ipaAnalysis;
    if (ios != null && ios.nestedBinaries.isNotEmpty) {
      counts[DetailTab.frameworks] = ios.nestedBinaries.length;
      counts[DetailTab.files] = 1;
    }
    final security = fileState.securityResult;
    if (security != null && security.findings.isNotEmpty) {
      counts[DetailTab.security] = security.findings.length;
    }
    return counts;
  }

  /// 按页面级状态决定渲染什么。
  ///
  /// 失败/空/加载态**不构建详情卡片**：构建了也只会得到一屏 `-`，而 `-` 在
  /// 详情页里的含义是「读取了，但包里没有这项」——拿它表示「没读到」会直接
  /// 误导结论。只有 [AnalysisPageStatus.success]/[partial] 才进入 `DetailTabView`。
  Widget _buildAnalysisContent({
    required AnalysisPageStatus status,
    required Map<DetailTab, List<Widget>> tabs,
    required FileState fileState,
    required bool isParsing,
    required String parseStageLabel,
    required String? failureMessage,
  }) {
    final path = fileState.filePath;
    final canRetry = path != null && path.isNotEmpty;
    final canCancel = _currentTask != null && !_currentTask!.isFinished;

    DetailTabView details() => DetailTabView(
          tabs: tabs,
          isParsing: isParsing,
          parseStageLabel: parseStageLabel,
          onCancelParse: canCancel ? _cancelParse : null,
          aside: _buildAnalysisAside(fileState),
          tabCounts: _tabCounts(fileState),
          tabOrder: _tabOrder(fileState),
        );

    switch (status) {
      case AnalysisPageStatus.empty:
        return AnalysisStatePanel(
          icon: Icons.folder_open,
          title: t.analysis_state.empty_title,
          body: t.analysis_state.empty_body,
          actionLabel: t.analysis_state.empty_action,
          onAction: openFilePicker,
        );
      case AnalysisPageStatus.loading:
        return AnalysisStatePanel(
          loading: true,
          title: t.analysis_state.loading_title,
          body: '$parseStageLabel\n${t.analysis_state.loading_body}',
          actionLabel: canCancel ? t.parse.cancel_parse : null,
          onAction: canCancel ? _cancelParse : null,
        );
      case AnalysisPageStatus.failure:
        return AnalysisStatePanel(
          icon: Icons.error_outline,
          title: t.analysis_state.failure_title,
          body: failureMessage ?? t.analysis_state.failure_body,
          actionLabel: t.analysis_state.retry,
          onAction: canRetry ? () => openApk(path) : openFilePicker,
        );
      case AnalysisPageStatus.partial:
        return Column(
          children: [
            AnalysisPartialBanner(
              title: t.analysis_state.partial_title,
              body: t.analysis_state.partial_body,
              retryLabel: t.analysis_state.retry,
              onRetry: canRetry ? () => openApk(path) : null,
            ),
            Expanded(child: details()),
          ],
        );
      case AnalysisPageStatus.success:
        return details();
    }
  }

  /// 渲染 Android 侧的 [FieldValue] 字段。
  ///
  /// Android 详情页此前直读 `ApkInfo` 的裸字段、用空字符串兜底 —— 于是
  /// 「文件里没有」与「我们没读到」在界面上长得一模一样，而这两件事的
  /// 结论完全相反（后者意味着结论不可靠）。这里改成走统一模型。
  ///
  /// 与 iOS 侧的局部 `field()` 共用 [FieldValueText]，只是这边要处理
  /// `analysis.android` 可能为 null 的情况。
  String _androidField(
    FieldValue<Object?>? value,
    String Function(Object value) format,
  ) =>
      value == null ? '-' : FieldValueText.describe(value, t, format: format);

  /// Android 详情卡片。
  List<Widget> _buildAndroidCards(
    FileState fileState,
    ApkInfo? apkInfo,
    String analysisNotes,
    String structureText,
    bool enableSignature,
    bool enableHash,
    int textMaxLines,
  ) {
    return [
      // 平台标识同样放在最前：两页版式一致，这一行是用户
      // 分辨自己在看哪个平台的第一眼依据。
      _buildPlatformRow(fileState),
      if (apkInfo?.parseFailureReason != null)
        ManifestPartialBanner(
          title: t.apk_info.partial_manifest_title,
          body: t.apk_info.partial_manifest_body,
        ),
      // ===== 应用信息 =====
      //
      // **应用信息排在文件信息之前**（V2.4.6 调换，与 iOS 侧一致）：用户
      // 打开一个包，第一眼要找的是「这是哪个应用、什么版本」，而不是「它在
      // 磁盘上的路径」—— 后者是排查时才需要的。
      _SectionHeader(title: t.apk_info.group_app, tab: DetailTab.overview),
      AndroidHeroCard(
        appName: _getDisplayLabel(apkInfo) ?? '-',
        packageName: apkInfo?.packageName ?? '',
        versionName: apkInfo?.versionName ?? '',
        versionCode: '${apkInfo?.versionCode ?? ''}',
        architectureLabel: architectureLabelOf(fileState.analysis),
        icon: apkInfo?.mainIconImage,
        // 候选图标切换与图标导出原先挂在版本栏那张独立图标卡上。
        // 图标去重后只剩 Hero 卡片这一处，能力因此挪到这里。
        onIconSecondaryTapUp: apkInfo == null
            ? null
            : (position) => _showIconContextMenu(context, position, apkInfo),
        // 复制按钮**放进卡片里**（`trailing`）。早先它被 `Align` 贴在卡片
        // 下面，于是界面上是一个孤零零的复制图标飘在空白处，看不出属于
        // 哪一项；而且 32×32 的最小尺寸还会把那一行撑高。
        trailing: CopyIconButton(
          text: apkInfo?.packageName ?? '',
          iconSize: 16,
        ),
        details: apkInfo == null
            ? null
            : _FactsGrid(cells: [
                (t.apk_info.package_name, apkInfo.packageName ?? '-'),
                (t.apk_info.version_name, apkInfo.versionName ?? '-'),
                (t.apk_info.target_sdk, '${apkInfo.targetSdkVersion ?? '-'}'),
                (t.apk_info.min_sdk, '${apkInfo.sdkVersion ?? '-'}'),
                (
                  t.apk_info.abi,
                  apkInfo.nativeCodes.isEmpty
                      ? '-'
                      : apkInfo.nativeCodes.join(', ')
                ),
                (t.apk_info.components, '${apkInfo.components.length}'),
              ]),
      ),
      // 语言切换菜单
      if (apkInfo != null && apkInfo.labels.isNotEmpty)
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: _buildLabelLocaleMenu(apkInfo),
          ),
        ),
      // ICP 备案号（工信部要求应用在界面展示的那一串）。
      //
      // **取不到就整行不显示**：`absent` 的语义是「扫过字符串池、包里确实
      // 没有」，不是「我们没读到」—— 显示一个空值会让用户以为这项检查失败了。
      // 放在「应用信息」组里、Hero 卡片之后：它是应用的身份信息，不是文件的。
      if (fileState.analysis?.android?.icpFiling.hasValue ?? false)
        Card(
            child: TitleValueLayout(
          title: t.apk_info.icp_filing,
          value: _androidField(
            fileState.analysis?.android?.icpFiling,
            (v) => '$v',
          ),
          selectable: true,
          minLines: 1,
          maxLines: 3,
        )),
      if (fileState.securityResult != null) _buildOverviewEvidence(fileState),
      // ===== 文件信息 =====
      _SectionHeader(title: t.file_info.group, tab: DetailTab.files),
      Card(
          child: TitleValueLayout(
              title: t.file_info.file,
              value: fileState.filePath ?? '-',
              end: _buildFileActionMenu())),
      Card(
          child: TitleValueLayout(
        title: t.file_info.size,
        value: fileState.fileSize != null
            ? "${formatFileSize(fileState.fileSize)}"
                " (${fileState.fileSize} Bytes)"
            : "",
      )),
      // ===== 应用详情（归入「应用」Tab，与 iOS 侧对齐）=====
      _SectionHeader(title: t.detail_tab.manifest, tab: DetailTab.manifest),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.version_code,
        // 走统一模型：`absent` → `-`，`failed` / `unsupported` → 带状态与原因。
        // 直读 `apkInfo?.versionCode` 会把「文件里没有」与「我们没读到」混成
        // 同一个空白。
        value: _androidField(fileState.analysis?.buildNumber, (v) => '$v'),
      )),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.version_name,
        value: _androidField(fileState.analysis?.version, (v) => '$v'),
      )),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.min_sdk,
        value: _androidField(
          fileState.analysis?.android?.minSdkVersion,
          (v) => getSdkVersionText(v as int),
        ),
      )),
      if (apkInfo?.isXapk ?? false)
        Card(
            child: TitleValueLayout(
          title: t.apk_info.archive_type,
          value: _androidField(
            fileState.analysis?.android?.archiveType,
            (v) => '$v',
          ),
        )),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.target_sdk,
        value: _androidField(
          fileState.analysis?.android?.targetSdkVersion,
          (v) => getSdkVersionText(v as int),
        ),
      )),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.screen_size,
        value: _androidField(
          fileState.analysis?.android?.supportsScreens,
          (v) => (v as List).join(' '),
        ),
      )),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.screen_density,
        value: _androidField(
          fileState.analysis?.android?.densities,
          (v) => (v as List).join(' '),
        ),
      )),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.abi,
        value: _androidField(
          fileState.analysis?.android?.nativeCodes,
          (v) => (v as List).join(' '),
        ),
      )),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.languages,
        value: _androidField(
          fileState.analysis?.android?.locales,
          (v) => (v as List).join(' '),
        ),
      )),
      // `null` 是「资源表没读到」，与「没有夜间资源」结论相反，必须分开呈现 ——
      // 与 D5 的字段状态处理同一个道理，只是这里的载体是个 bool?。
      Card(
          child: TitleValueLayout(
        title: t.apk_info.night_mode,
        value: switch (apkInfo?.hasNightMode) {
          true => t.apk_info.night_mode_yes,
          false => t.apk_info.night_mode_no,
          null => t.apk_info.night_mode_unknown,
        },
      )),
      if (apkInfo?.uiModeTypes.isNotEmpty ?? false)
        Card(
            child: TitleValueLayout(
          title: t.apk_info.ui_mode_types,
          value: apkInfo!.uiModeTypes.join(" "),
        )),
      _SectionHeader(title: t.apk_info.permissions, tab: DetailTab.permissions),
      Card(
          child: TitleValueLayout(
        title: t.apk_info.permissions,
        value: _androidField(
          fileState.analysis?.android?.permissions,
          (v) => (v as List).join('\n'),
        ),
        minLines: 1,
        maxLines: textMaxLines,
        selectable: true,
      )),
      // 只有「文件里确实没有」才整张卡片不显示。`unsupported` / `failed`
      // 这类「我们没读到」**必须显示出来并说明原因** —— 否则读者会以为
      // 文件里没有声明（缺陷 D5 的其中一半）。
      if (fileState.analysis?.android?.maxSdkVersion.status !=
          FieldStatus.absent)
        Card(
            child: TitleValueLayout(
          title: t.apk_info.max_sdk,
          value: _androidField(
            fileState.analysis?.android?.maxSdkVersion,
            (v) => getSdkVersionText(v as int),
          ),
        )),
      if (apkInfo?.components.isNotEmpty ?? false) ...[
        _SectionHeader(
            title: t.detail_tab.components, tab: DetailTab.components),
        Card(
            child: TitleValueLayout(
          title: t.apk_info.components,
          value: DetailRenderer.components(apkInfo, t),
          minLines: 1,
          maxLines: textMaxLines,
          selectable: true,
        )),
      ],
      _SectionHeader(title: t.apk_info.structure, tab: DetailTab.files),
      // XAPK / OBB / 结构
      if (apkInfo?.isXapk ?? false)
        Card(
            child: TitleValueLayout(
          title: t.apk_info.split_apks,
          value: _androidField(
            fileState.analysis?.android?.splitApks,
            (v) => (v as List).join('\n'),
          ),
          minLines: 1,
          maxLines: textMaxLines,
          selectable: true,
        )),
      if ((apkInfo?.obbFiles.isNotEmpty ?? false))
        Card(
            child: TitleValueLayout(
          title: t.apk_info.obb_files,
          value: _androidField(
            fileState.analysis?.android?.obbFiles,
            (v) => (v as List).join('\n'),
          ),
          minLines: 1,
          maxLines: textMaxLines,
          selectable: true,
        )),
      if (structureText.isNotEmpty)
        Card(
            child: TitleValueLayout(
          title: t.apk_info.structure,
          value: structureText,
          minLines: 1,
          maxLines: textMaxLines,
          selectable: true,
        )),
      _SectionHeader(title: t.apk_info.signature_info, tab: DetailTab.files),
      // MD5 哈希值
      if (enableHash)
        Card(
            child: TitleValueLayout(
          title: t.file_info.md5,
          value: fileState.isComputingHash
              ? t.file_info.computing_hash
              : (fileState.md5Hash ?? '-'),
        )),
      // SHA1 哈希值
      if (enableHash)
        Card(
            child: TitleValueLayout(
          title: t.file_info.sha1,
          value: fileState.isComputingHash
              ? t.file_info.computing_hash
              : (fileState.sha1Hash ?? '-'),
        )),
      // SHA-256 哈希值（规范 4.1 要求）
      if (enableHash)
        Card(
            child: TitleValueLayout(
          title: t.file_info.sha256,
          value: fileState.isComputingHash
              ? t.file_info.computing_hash
              : (fileState.sha256Hash ?? '-'),
        )),
      if (enableSignature && !(apkInfo?.isXapk ?? false))
        Card(
            child: TitleValueLayout(
          title: t.apk_info.signature_info,
          value: fileState.isComputingSignature
              ? t.file_info.computing_hash
              : DetailRenderer.signature(fileState.signature, t),
          minLines: 1,
          maxLines: textMaxLines,
          selectable: !fileState.isComputingSignature,
        )),
      _SectionHeader(title: t.apk_info.diagnostics, tab: DetailTab.diagnostics),
      // 解析诊断：加固线索 + 诊断记录
      if (analysisNotes.isNotEmpty)
        Card(
            child: TitleValueLayout(
          title: t.apk_info.diagnostics,
          value: analysisNotes,
          minLines: 1,
          maxLines: textMaxLines,
          selectable: true,
        )),
      ..._buildSecurityCards(fileState.analysis?.security),
    ];
  }

  PopupMenuButton<String> _buildMoreMenuButton(BuildContext context) {
    final apkInfo = ref.watch(currentApkInfoProvider);
    final state = ref.watch(currentFileStateProvider);
    log.fine("_buildMoreMenuButton: state.filePath=${state.filePath}");
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz),
      tooltip: t.home.more_actions,
      enabled: state.filePath != null,
      offset: const Offset(0, 0),
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        // 重命名移到了「文件信息 → 文件」那一行后面的菜单里
        // （它操作的就是那个文件，放在文件旁边比放在全局「更多」里更直白）。
        _buildMenuItem('text_info', Icons.text_snippet, t.apk_info.text_info,
            enabled: state.filePath != null && apkInfo != null),
        // 只有真的拿到了分析结果才让点。
        _buildMenuItem(
            'export_report', Icons.description_outlined, t.report.export_action,
            enabled: state.analysis != null),
        _buildMenuItem('close_file', Icons.close, t.open.close_file,
            enabled: state.filePath != null),
      ],
      onSelected: onMenuActionSelected,
    );
  }

  // 显示重命名对话框。
  //
  // 同时支持 Android（APK/XAPK/APKM/APKS）与 iOS（IPA）。
  // 重命名使用异步 `File.rename()` 而非 `renameSync()`：
  // - Windows 上文件被占用时 `renameSync` 会抛异常；
  // - macOS 上跨文件系统（如从 /tmp 到 ~/Desktop）时 `renameSync` 会失败。
  // `File.rename()` 在跨文件系统时会自动回退到复制+删除。
  /// 重命名还没就绪时的提示。
  ///
  /// 解析未完成或失败时 `apkInfo` / `ipaAnalysis` 都还是空的，这时不能
  /// 悄悄什么都不做 —— 用户会以为按钮坏了。
  void _toastRenameNotReady() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.rename.not_ready)),
    );
  }

  /// 弹出重命名对话框（入口在「文件信息 → 文件」那一行的菜单里）。
  ///
  /// 对话框本体与分析页共用一份实现（`showRenameFileDialog`），这里只负责
  /// 准备「应用名 / 版本号」两个默认名的输入，以及改名成功后的重新打开方式。
  Future<void> _showRenameDialog() async {
    final state = ref.read(currentFileStateProvider);
    final filePath = state.filePath;
    if (filePath == null) return;

    // 从 APK 或 IPA 解析结果中提取应用名与版本号。
    //
    // 拿不到结果时**必须给出提示**：早先这里直接 `return`，用户看到的是
    // 「点了没反应」—— 解析还没跑完、或解析失败时都会命中这条路径。
    final String displayName;
    final String versionName;
    if (_looksLikeIpa(filePath)) {
      final ipa = state.ipaAnalysis;
      if (ipa == null) {
        _toastRenameNotReady();
        return;
      }
      displayName = ipa.infoPlist?.preferredName.value ??
          ipa.infoPlist?.bundleIdentifier.value ??
          '';
      versionName = ipa.infoPlist?.shortVersionString.value ?? '';
    } else {
      final apkInfo = ref.read(currentApkInfoProvider);
      if (apkInfo == null) {
        _toastRenameNotReady();
        return;
      }
      // 改名默认名里「拿不到名字」就是空串（`'-.apk'` 也好过 `'null-.apk'`）——
      // 与界面上渲染 `-` 是两种不同的表达，各取所需。
      displayName = _getDisplayLabel(apkInfo) ?? '';
      versionName = apkInfo.versionName ?? '';
    }

    final result = await showRenameFileDialog(
      context,
      filePath: filePath,
      displayName: displayName,
      versionName: versionName,
    );
    if (!mounted || result == null) return;

    // 提示文案三态统一（见 `reportRenameOutcome`）；分析页的重新打开走
    // `openApk` —— 它会就地重跑整条流水线并更新本页的所有卡片。
    final newPath = reportRenameOutcome(context, result);
    if (newPath != null) openApk(newPath);
  }

  @override
  void dispose() {
    const MethodChannel('file_association').setMethodCallHandler(null);
    super.dispose();
  }

  bool _updateActionsPending = false;

  void _scheduleUpdateActions() {
    if (_updateActionsPending) return;
    _updateActionsPending = true;
    Future.microtask(() {
      _updateActionsPending = false;
      if (mounted) updateActions();
    });
  }

  void updateActions() {
    final page = ref.read(currentPageProvider);
    final fileState = ref.read(currentFileStateProvider);
    if (page == widget.page) {
      ref
          .read(pageActionsProvider.notifier)
          .setActions(_buildActions(fileState));
    }
  }

  void _showIconContextMenu(
      BuildContext context, Offset position, ApkInfo apkInfo) {
    final candidates = apkInfo.iconCandidates;
    final selectedIndex = ref.read(selectedIconIndexProvider);

    final items = <PopupMenuEntry<String>>[];

    // 切换图标分组（仅多候选时显示）
    if (candidates.length > 1) {
      for (int i = 0; i < candidates.length; i++) {
        items.add(PopupMenuItem(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          value: 'select_$i',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                i == selectedIndex
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                candidates[i].displayLabel,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ));
      }
      items.add(const PopupMenuDivider());
    }

    // 导出分组
    items.add(_buildMenuItem('export_png', Icons.image, t.icon.export_as_png,
        enabled: apkInfo.mainIconImage != null));

    // SVG 导出（仅 XML 矢量图候选可用）
    final isXmlVector = selectedIndex >= 0 &&
        selectedIndex < candidates.length &&
        candidates[selectedIndex].type == IconCandidateType.xmlVector;
    items.add(_buildMenuItem('export_svg', Icons.code, t.icon.export_as_svg,
        enabled: apkInfo.mainIconImage != null && isXmlVector));

    items.add(_buildMenuItem(
        'export_original', Icons.file_download, t.icon.export_original,
        enabled: apkInfo.mainIconImage != null));

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: items,
    ).then((value) {
      if (value != null) {
        _handleIconMenuAction(value, apkInfo);
      }
    });
  }

  Future<void> _handleIconMenuAction(String value, ApkInfo apkInfo) async {
    if (value.startsWith('select_')) {
      final index = int.parse(value.substring(7));
      await _switchIcon(apkInfo, index);
    } else if (value == 'export_png') {
      await _exportAsPng(apkInfo);
    } else if (value == 'export_svg') {
      await _exportAsSvg(apkInfo);
    } else if (value == 'export_original') {
      await _exportOriginal(apkInfo);
    }
  }

  Future<void> _switchIcon(ApkInfo apkInfo, int index) async {
    if (index < 0 || index >= apkInfo.iconCandidates.length) return;
    final candidate = apkInfo.iconCandidates[index];

    if (candidate.renderedImage != null) {
      apkInfo.mainIconImage = candidate.renderedImage;
      ref.read(selectedIconIndexProvider.notifier).select(index);
      setState(() {});
    } else {
      // 异步渲染
      final image = await apkInfo.renderIcon(index);
      if (image != null && mounted) {
        apkInfo.mainIconImage = image;
        ref.read(selectedIconIndexProvider.notifier).select(index);
        setState(() {});
      }
    }
  }

  Future<void> _exportAsPng(ApkInfo apkInfo) async {
    final selectedIndex = ref.read(selectedIconIndexProvider);

    try {
      // 使用高清渲染导出（XML 矢量图 1024x1024 + 透明背景）
      ui.Image? exportImage;
      bool needDisposeExport = false;
      if (selectedIndex >= 0 && selectedIndex < apkInfo.iconCandidates.length) {
        exportImage = await apkInfo.renderIconForExport(selectedIndex);
        if (exportImage != null) {
          needDisposeExport = true;
        }
      }
      // 回退到当前显示图标
      exportImage ??= apkInfo.mainIconImage;
      if (exportImage == null) return;

      final byteData =
          await exportImage.toByteData(format: ui.ImageByteFormat.png);
      // 如果是新渲染的导出图，释放它
      if (needDisposeExport) {
        exportImage.dispose();
      }
      if (byteData == null) return;

      final fileName = '${apkInfo.label ?? "icon"}_icon.png';
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.icon.export_icon,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['png'],
        lockParentWindow: true,
      );
      if (savePath == null) return;

      await File(savePath).writeAsBytes(byteData.buffer.asUint8List());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.icon.export_success)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.icon.export_failed(error: e.toString()))),
        );
      }
    }
  }

  Future<void> _exportAsSvg(ApkInfo apkInfo) async {
    final selectedIndex = ref.read(selectedIconIndexProvider);

    try {
      final svgString = await apkInfo.exportSvgString(selectedIndex);
      if (svgString == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    t.icon.export_failed(error: t.icon.error_svg_conversion))),
          );
        }
        return;
      }

      final fileName = '${apkInfo.label ?? "icon"}_icon.svg';
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.icon.export_icon,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['svg'],
        lockParentWindow: true,
      );
      if (savePath == null) return;

      await File(savePath).writeAsString(svgString);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.icon.export_success)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.icon.export_failed(error: e.toString()))),
        );
      }
    }
  }

  Future<void> _exportOriginal(ApkInfo apkInfo) async {
    final selectedIndex = ref.read(selectedIconIndexProvider);

    try {
      Uint8List? bytes;
      String ext = '.png';

      // 尝试从 APK 中读取原始文件字节
      if (selectedIndex >= 0 && selectedIndex < apkInfo.iconCandidates.length) {
        final candidate = apkInfo.iconCandidates[selectedIndex];
        if (candidate.rawBytes == null) {
          final zip = ZipHelper();
          try {
            await zip.open(apkInfo.apkPath);
            candidate.rawBytes = await zip.readFileContent(candidate.path);
          } finally {
            zip.close();
          }
        }
        if (candidate.rawBytes != null) {
          bytes = candidate.rawBytes;
          ext = path.extension(candidate.path);
        }
      }

      // 回退：无法获取原始字节（如 XAPK/APKM），导出渲染后的 PNG
      if (bytes == null) {
        final image = apkInfo.mainIconImage;
        if (image == null) return;
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return;
        bytes = byteData.buffer.asUint8List();
        ext = '.png';
      }

      final fileName = '${apkInfo.label ?? "icon"}_icon$ext';
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.icon.export_icon,
        fileName: fileName,
        lockParentWindow: true,
      );
      if (savePath == null) return;

      await File(savePath).writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.icon.export_success)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.icon.export_failed(error: e.toString()))),
        );
      }
    }
  }

  void onMenuActionSelected(String value) async {
    switch (value) {
      case 'close_file':
        closeApk();
        break;
      case 'rename':
        _showRenameDialog();
        break;
      case 'text_info':
        final apkInfo = ref.read(currentApkInfoProvider);
        if (apkInfo != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => TextInfoPage(
                text: apkInfo.originalText,
              ),
            ),
          );
        }
        break;
      case 'export_report':
        final analysis = ref.read(currentFileStateProvider).analysis;
        if (analysis != null && mounted) {
          final result = await showDialog(
            context: context,
            builder: (_) => ExportReportDialog(analysis: analysis),
          );
          if (result == true && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t.report.export_success)),
            );
          } else if (result != null && result != true && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(t.report.export_failed(error: '$result')),
              ),
            );
          }
        }
        break;
      case 'open_directory':
        final fileState = ref.read(currentFileStateProvider);
        openFileInExplorer(fileState.filePath!);
        break;
      case 'copy_path':
        final fileState = ref.read(currentFileStateProvider);
        await Clipboard.setData(ClipboardData(text: fileState.filePath!));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  t.home.copied_content(content: fileState.filePath ?? '')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        break;
    }
  }
}

/// 风险等级计数徽章。
///
/// 用于安全总览卡片，展示各等级的发现数量。
class _SeverityCountChip extends StatelessWidget {
  final SecuritySeverity severity;
  final int count;

  const _SeverityCountChip({required this.severity, required this.count});

  Color _color(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    return switch (severity) {
      SecuritySeverity.p0 =>
        isDark ? const Color(0xFFEF5350) : const Color(0xFFD32F2F),
      SecuritySeverity.p1 =>
        isDark ? const Color(0xFFFF7043) : const Color(0xFFE64A19),
      SecuritySeverity.p2 =>
        isDark ? const Color(0xFFFFCA28) : const Color(0xFFFBC02D),
      SecuritySeverity.p3 =>
        isDark ? const Color(0xFF90A4AE) : const Color(0xFF607D8B),
      SecuritySeverity.info =>
        isDark ? const Color(0xFF4DB6AC) : const Color(0xFF00897B),
      SecuritySeverity.unknown =>
        isDark ? const Color(0xFFB0BEC5) : const Color(0xFF78909C),
    };
  }

  String get _label => switch (severity) {
        SecuritySeverity.p0 => 'P0',
        SecuritySeverity.p1 => 'P1',
        SecuritySeverity.p2 => 'P2',
        SecuritySeverity.p3 => 'P3',
        SecuritySeverity.info => 'INFO',
        SecuritySeverity.unknown => '?',
      };

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
          ),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color.withValues(alpha: 0.9),
                ),
          ),
        ],
      ),
    );
  }
}

/// 分组标题分隔组件。
///
/// 用于 iOS 详情页将卡片组织成逻辑组：文件信息、应用信息、容器与二进制、
/// 签名与授权、文件校验、解析诊断。
class _SectionHeader extends StatelessWidget {
  final String title;
  final DetailTab? tab;

  const _SectionHeader({required this.title, this.tab});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 9),
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(height: 1, color: colorScheme.outlineVariant),
          ),
        ],
      ),
    );
  }
}

/// V4 三列事实网格：短字段集中展示，窄窗口退化为两列。
class _FactsGrid extends StatelessWidget {
  final List<(String, String)> cells;

  const _FactsGrid({required this.cells});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 560 ? 3 : 2;
          final width = constraints.maxWidth / columns;
          return Wrap(
            children: [
              for (final cell in cells)
                SizedBox(
                  width: width,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                    decoration: BoxDecoration(
                      border: Border(
                        right: BorderSide(color: scheme.outlineVariant),
                        bottom: BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cell.$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          cell.$2.isEmpty ? '-' : cell.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
