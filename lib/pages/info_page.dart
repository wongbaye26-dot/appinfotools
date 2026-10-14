import 'dart:io';
import 'dart:ui' as ui;

import 'package:analysis_model/analysis_model.dart';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/ipaparser/ios_codesign_step.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/pages/install_dialog.dart';
import 'package:apk_info_tool/pages/pages.dart';
import 'package:apk_info_tool/pages/text_info.dart';
import 'package:apk_info_tool/providers/home_page_provider.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/providers/setting_provider.dart';
import 'package:apk_info_tool/providers/ui_config_provider.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/android_version.dart';
import 'package:apk_info_tool/utils/cancellable_task.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/format.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:apk_info_tool/utils/platform.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show IosBundle, IosIconResolution, IosPrivacyAudit;
import 'package:apk_info_tool/widgets/ios_icon_preview.dart';
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
    if (file.existsSync()) {
      final fileSize = file.lengthSync();
      state.update(FileState(filePath: path, fileSize: fileSize));
      if (path.isNotEmpty) {
        loadApkInfo(path);
      }
    } else {
      state.update(FileState(filePath: path));
    }
  }

  void closeApk() {
    ref.read(currentFileStateProvider.notifier).update(FileState());
    ref.read(currentApkInfoProvider.notifier).reset();
    ref.read(selectedIconIndexProvider.notifier).reset();
    ref.read(selectedLabelLocaleProvider.notifier).reset();
  }

  String getSdkVersionText(int? sdkVersion) {
    if (sdkVersion == null) return "";
    return "$sdkVersion (${AndroidVersion.getAndroidVersion(sdkVersion)})";
  }

  Future<void> loadApkInfo(String filePath) async {
    // IPA 走自己的解析流水线。分支点放在这里而不是更深处：两条流水线的
    // 阶段、工具、结论语义都不同，混在一个方法里只会让两边都难读。
    if (_looksLikeIpa(filePath)) {
      await _loadIpaInfo(filePath);
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

    try {
      final apkInfo = await getApkInfo(
        filePath,
        // 阶段由解析器在真正推进到该步时上报，不是定时器编出来的。
        onStage: (stage) {
          if (_loadGeneration == gen) parseStageState.update(stage);
        },
        // 拿到可取消的任务句柄后，取消按钮才可用。
        onTaskStarted: (task) {
          if (_loadGeneration == gen) _currentTask = task;
        },
      );
      if (apkInfo == null) {
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
        }
      }
    } on ApkParseCancelledException {
      // 用户主动取消 —— 不该弹错误提示，界面上也没有需要清理的残留状态。
      log.info('loadApkInfo: cancelled by user');
    } catch (e) {
      log.warning('loadApkInfo: $e');
      if (mounted) {
        final message = e is ApkOpenException
            ? DetailRenderer.openFailure(e.result, t)
            : e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (_loadGeneration == gen) {
        isParsingState.update(false);
        parseStageState.update(null);
        _currentTask = null;
      }
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
      task = await IpaParseTask.start(filePath);
    } catch (e) {
      log.warning('_loadIpaInfo: failed to start the IPA task: $e');
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

    IpaAnalysis? parsed;
    await for (final event in task.events) {
      if (_loadGeneration != gen) break;

      switch (event) {
        case IpaStageReached(:final stage):
          iosStageState.update(stage);
        case IpaOpenFailed(:final result):
          // 容器打不开：显示**具体原因**，而不是笼统的「解析失败」。
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(DetailRenderer.openFailure(result, t))),
            );
          }
        case IpaParseFailed(:final reason):
          log.warning('_loadIpaInfo: parse failed: $reason');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t.parse.parse_apk_info_fail)),
            );
          }
        case IpaParseSucceeded(:final analysis):
          parsed = analysis;
        case IpaParseCancelled():
          // 用户主动取消 —— 不弹错误提示。
          log.info('_loadIpaInfo: cancelled by user');
      }
    }

    if (_loadGeneration != gen) return;

    if (parsed != null) {
      // iOS 安全分析是同步的，在更新状态前完成。
      SecurityAnalysisResult? security;
      if (enableSecurityAudit && parsed.infoPlist != null) {
        security = IosPrivacyAudit.audit(
          infoPlist: parsed.infoPlist!,
          executableBytes: parsed.executableBytes,
          executablePath: parsed.executablePath,
        );
      }
      fileState.update(ref.read(currentFileStateProvider).copyWith(
            ipaAnalysis: parsed,
            securityResult: security,
          ));
      isParsingState.update(false);
      iosStageState.update(null);

      // 签名验证是单独一步：它要解包到磁盘，因此在主 isolate 上跑，
      // 并且在静态解析完成之后才开始 —— 静态结果先呈现给用户。
      final mainApp = parsed.mainApp;
      if (enableSignature && mainApp != null) {
        await _verifyIosSignature(filePath, gen, mainApp);
      }
      return;
    }

    isParsingState.update(false);
    iosStageState.update(null);
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
  /// 只在真的拿到可取消的任务时才有意义 —— XAPK/APKM/APKS 路径仍走 aapt2
  /// 子进程，暂不可取消，因此 UI 在该路径下不显示取消按钮（未实现的功能不得
  /// 出现伪可用按钮）。
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
    final textMaxLines =
        ref.watch(uiConfigStateProvider.select((value) => value.textMaxLines));
    final iconRowSpan =
        ref.watch(uiConfigStateProvider.select((value) => value.iconRowSpan));

    Widget card(String title, String value,
            {Widget? end, int? maxLines, bool selectable = false}) =>
        Card(
          child: TitleValueLayout(
            title: title,
            value: value,
            end: end,
            maxLines: maxLines,
            selectable: selectable,
          ),
        );

    /// 把一个 [FieldValue] 渲染成「值」或「为什么没有值」。
    ///
    /// 关键在于**不把「读不到」渲染成空串**：`absent` 与 `failed` 对用户的
    /// 含义完全不同，前者是「文件里没有」，后者是「我们没读出来」。
    String field(FieldValue<Object?> value) {
      if (value.hasValue) return '${value.value}';
      // `absent` 显示为「-」：文件里确实没有这一项，空着是准确的。
      // 其余状态一律**带上状态名与原因** —— 它们意味着「我们没读到」。
      if (value.status == FieldStatus.absent) return '-';
      final reason = value.diagnostic;
      return reason == null
          ? '[${value.status.name}]'
          : '[${value.status.name}] $reason';
    }

    // 平台标识放在最前 —— 两页版式相同，这是第一眼能分辨的地方。
    cards.add(_buildPlatformRow(fileState));

    cards.add(card(t.file_info.file, fileState.filePath ?? "",
        end: _buildFileActionMenu()));
    cards.add(card(
      t.file_info.size,
      fileState.fileSize != null
          ? "${formatFileSize(fileState.fileSize)} (${fileState.fileSize} Bytes)"
          : "",
    ));

    if (parsed == null || result == null || ios == null) {
      // 解析还没完成或整体失败：只说明原因，不渲染一堆空卡片 ——
      // 一排空值会被读成「这个包什么都没有」。
      cards.add(card(t.ios_info.section, t.ios_info.unavailable));
      return cards;
    }

    // 容器里没有 `Payload/*.app` 时，后面每一项都会是「-」，而「-」的含义是
    // 「文件里没有这一项」—— 与「我们没找到应用」是两件事。先说清楚原因，
    // 而不是让用户对着一页短横线猜。
    if (ios.mainApp == null) {
      cards.add(card(t.ios_info.unavailable, t.ios_info.no_main_app));
    }

    cards.add(card(t.apk_info.app_name, field(ios.preferredName)));
    cards.add(card(t.ios_info.bundle_id, field(ios.bundleIdentifier),
        end: _buildCopyButton(
            ios.bundleIdentifier.value, ios.bundleIdentifier.hasValue)));

    // 与 Android 的「版本号 / 版本名 + 图标」一栏对位：图标固定放在右侧。
    cards.add(Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            children: [
              card(t.apk_info.version_name, field(ios.shortVersion)),
              card(t.apk_info.version_code, field(ios.buildNumber)),
              // Android 在图标占三行以上时把 minSdk 收进这一栏；这里照做。
              if (iconRowSpan >= 3)
                card(t.ios_info.minimum_os, field(ios.minimumOSVersion)),
            ],
          ),
        ),
        _buildIosIconWidget(ios.icon, iconRowSpan),
      ],
    ));
    if (iconRowSpan < 3) {
      cards.add(card(t.ios_info.minimum_os, field(ios.minimumOSVersion)));
    }

    cards.add(card(
        t.ios_info.device_family,
        ios.deviceFamily.hasValue
            ? DetailRenderer.deviceFamily(ios.deviceFamily.value, t)
            : field(ios.deviceFamily)));
    cards.add(card(t.ios_info.executable, field(ios.executableName)));

    if (ios.queriesSchemes.hasValue) {
      cards.add(card(
        t.ios_info.queries_schemes,
        ios.queriesSchemes.value!.join('\n'),
        maxLines: textMaxLines,
        selectable: true,
      ));
    }
    if (ios.requiredDeviceCapabilities.hasValue) {
      cards.add(card(
        t.ios_info.required_capabilities,
        ios.requiredDeviceCapabilities.value!.join('\n'),
        maxLines: textMaxLines,
        selectable: true,
      ));
    }
    if (ios.hasMultipleMainApps) {
      cards.add(card(
        t.ios_info.bundles,
        '${ios.container.payloadApps.length} '
        '${t.ios_info.bundle_kind_main_app}: '
        '${ios.container.payloadApps.map((b) => b.path).join(', ')}',
        maxLines: textMaxLines,
        selectable: true,
      ));
    }

    // 图标清单。Android 把候选放在图标的右键菜单里，iOS 没有那个入口，
    // 因此把同样的信息直接列出来 —— 包括「哪些取不到、为什么」。
    cards.add(card(
      t.ios_info.icon_section,
      DetailRenderer.iosIcon(ios.icon, t),
      maxLines: textMaxLines,
      selectable: true,
    ));

    if (enableHash) {
      cards.add(card(t.file_info.md5, fileState.md5Hash ?? '',
          end: _buildCopyButton(fileState.md5Hash, fileState.md5Hash != null)));
      cards.add(card(t.file_info.sha1, fileState.sha1Hash ?? '',
          end: _buildCopyButton(
              fileState.sha1Hash, fileState.sha1Hash != null)));
      cards.add(card(
        t.file_info.sha256,
        fileState.isComputingHash
            ? t.file_info.computing_hash
            : (fileState.sha256Hash ?? ''),
        end: _buildCopyButton(
            fileState.sha256Hash, fileState.sha256Hash != null),
      ));
    }

    final diagnostics = DetailRenderer.diagnostics(result.diagnostics, t);
    if (diagnostics.isNotEmpty) {
      cards.add(card(t.apk_info.diagnostics, diagnostics,
          maxLines: textMaxLines, selectable: true));
    }

    // 结构：Android 是「文件结构」（DEX / 原生库 / 顶层目录），iOS 对位的是
    // 容器 + 可执行文件（Mach-O）+ 嵌套二进制。
    final container = DetailRenderer.iosContainer(ios.container, t);
    if (container.isNotEmpty) {
      cards.add(card(t.ios_info.container_section, container,
          maxLines: textMaxLines, selectable: true));
    }
    final executable = DetailRenderer.iosExecutable(ios.executable, t);
    if (executable.isNotEmpty) {
      cards.add(card(t.ios_info.binary_section, executable,
          maxLines: textMaxLines, selectable: true));
    }
    final nested = DetailRenderer.iosNestedBinaries(ios.nestedBinaries, t);
    if (nested.isNotEmpty) {
      cards.add(card(t.ios_info.nested_binaries, nested,
          maxLines: textMaxLines, selectable: true));
    }

    // 签名与授权。
    //
    // 与 Android 的差别是**平台本身带来的**，不是版式差别：Android 的签名
    // 信息全部来自 `apksigner`，工具不跑就什么都没有，所以那张卡片整张隐藏；
    // iOS 的签名材料与授权比对来自静态解析，一直都有。因此这里始终显示
    // 「有什么」，`codesign` 那一段由「验证签名」开关决定**跑不跑**，
    // 没跑就如实说「未执行」—— 而不是把整张卡片藏起来，让用户以为这个包
    // 没有签名信息。
    final signatureParts = <String>[
      DetailRenderer.signatureVerdictLabel(result.signatureVerdict, t),
      DetailRenderer.iosSignature(ios, t),
      DetailRenderer.iosCodeSign(ios.codeSign, t),
    ].where((part) => part.isNotEmpty);
    cards.add(card(
      t.apk_info.signature_info,
      signatureParts.join('\n\n'),
      maxLines: textMaxLines,
      selectable: true,
    ));

    cards.addAll(_buildSecurityCards(result.security));

    return cards;
  }

  /// 安全检测卡片组。
  ///
  /// 与平台无关：Android 与 iOS 共用同一套呈现逻辑，差异只来自
  /// [SecurityAnalysisResult] 本身的数据。
  List<Widget> _buildSecurityCards(SecurityAnalysisResult? security) {
    if (security == null) return const [];

    final textMaxLines =
        ref.watch(uiConfigStateProvider.select((value) => value.textMaxLines));
    final findings = security.findings;
    final hasCoverageGaps = security.hasCoverageGaps;

    // 风险总览文本。
    final overviewLines = <String>[
      if (findings.isEmpty) t.security.no_findings,
      for (final finding in findings)
        '[${finding.severity.name}] ${finding.finding}',
    ];

    final cards = <Widget>[
      Card(
        child: TitleValueLayout(
          title: t.security.title,
          value: overviewLines.join('\n'),
          minLines: 1,
          maxLines: textMaxLines,
          selectable: true,
        ),
      ),
    ];

    if (hasCoverageGaps) {
      cards.add(Card(
        child: TitleValueLayout(
          title: t.security.limitations,
          value: security.limitations.join('\n'),
          minLines: 1,
          maxLines: textMaxLines,
          selectable: true,
        ),
      ));
    }

    return cards;
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

  /// iOS 图标槽位。
  ///
  /// 与 Android 的 [_buildIconWidget] 同一个尺寸公式，好让两页的图标看起来
  /// 一样大。区别只有一处：iOS 没有候选切换（见 `IosIconThumbnail` 的说明），
  /// 因此没有右键菜单。
  Widget _buildIosIconWidget(IosIconResolution? icon, int iconRowSpan) {
    final iconSize = iconRowSpan * 44.0;
    final radius = iconSize * 0.22;
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        clipBehavior: Clip.antiAlias,
        child: IosIconThumbnail(resolution: icon, size: iconSize),
      ),
    );
  }

  Future<void> _initPlatformState() async {
    log.info("_initPlatformState: start");
    String? initialFilePath;
    try {
      // 使用方法通道获取文件路径
      initialFilePath = await const MethodChannel('file_association')
          .invokeMethod('getInitialFilePath');
    } on PlatformException catch (e) {
      log.info("PlatformException: $e");
      initialFilePath = null;
    }

    log.info("_initPlatformState: initialFilePath=$initialFilePath");
    if (!mounted) return;

    if (initialFilePath != null && initialFilePath.isNotEmpty) {
      openApk(initialFilePath);
    }
  }

  void _setupFileAssociationHandler() {
    const MethodChannel('file_association').setMethodCallHandler((call) async {
      log.info("_setupFileAssociationHandler: call.method=${call.method}");
      if (call.method == 'fileOpened') {
        openApk(call.arguments);
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
    if (Platform.isMacOS) {
      _initPlatformState();
      _setupFileAssociationHandler();
    } else if (apkByArgs.isNotEmpty) {
      openApk(apkByArgs);
    }
  }

  List<Widget> _buildActions(FileState fileState) {
    return [
      IconButton(
          icon: const Icon(Icons.file_open),
          tooltip: t.open.open_apk,
          onPressed: () async {
            openFilePicker();
          }),
      IconButton(
          icon: const Icon(Icons.search),
          tooltip: t.parse.parse_apk,
          onPressed: fileState.filePath == null
              ? null
              : () {
                  openApk(fileState.filePath ?? '');
                }),
      IconButton(
          icon: const Icon(Icons.install_mobile),
          tooltip: t.install.apk,
          onPressed: fileState.filePath == null
              ? null
              : () {
                  showDialog(
                    context: context,
                    builder: (context) => InstallDialog(
                      apkPath: fileState.filePath!,
                      isXapk: fileState.apkInfo?.isXapk ?? false,
                    ),
                  );
                }),
      _buildMoreMenuButton(context),
      IconButton(
          icon: const Icon(Icons.settings),
          tooltip: t.settings.open_settings,
          onPressed: () {
            Navigator.pushNamed(context, 'setting');
          }),
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
            'open_directory', Icons.folder_open, t.open.open_file_directory),
        _buildMenuItem('copy_path', Icons.content_copy, t.home.copy_file_path),
      ],
      onSelected: onMenuActionSelected,
    );
  }

  // 构建复制按钮
  Widget _buildCopyButton(String? text, bool enable) {
    return Tooltip(
      message: t.home.copy_content,
      waitDuration: const Duration(seconds: 1),
      textStyle: TextStyle(
        color: Colors.white,
        fontSize: 12,
      ),
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
        icon: Icon(
          Icons.content_copy,
          size: 16,
          color: enable ? null : Theme.of(context).disabledColor,
        ),
        onPressed: enable
            ? () async {
                await Clipboard.setData(ClipboardData(text: text ?? ''));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(t.home.copied_content(content: text ?? '')),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              }
            : null,
      ),
    );
  }

  /// 获取当前显示的应用名称（根据用户选择的语言）
  String _getDisplayLabel(ApkInfo? apkInfo) {
    if (apkInfo == null) return "";
    final selectedLocale = ref.read(selectedLabelLocaleProvider);
    if (selectedLocale != null && apkInfo.labels.containsKey(selectedLocale)) {
      return apkInfo.labels[selectedLocale]!;
    }
    return apkInfo.label ?? "";
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

  @override
  Widget build(BuildContext context) {
    // 在当前页/文件/APK信息变化时需要更新Actions, 因为Actions的变化会修改按钮的使能状态
    // 使用微任务合并连续变化，避免同一帧内多次重建 actions
    ref.listen(currentPageProvider, (_, __) => _scheduleUpdateActions());
    ref.listen(currentFileStateProvider, (_, __) => _scheduleUpdateActions());
    ref.listen(currentApkInfoProvider, (_, __) => _scheduleUpdateActions());
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
    final iconRowSpan =
        ref.watch(uiConfigStateProvider.select((value) => value.iconRowSpan));

    return Stack(
      children: [
        DropTarget(
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
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    children: [
                      // 平台分支：IPA 走自己的一组卡片。
                      //
                      // 不复用 Android 那组再逐张判空 —— 那些卡片读的是
                      // `apkInfo?.x`，在 iOS 上会渲染成一排空值卡片，
                      // 看起来像「这个包什么都没有」，而不是「这里不适用」。
                      if (fileState.platform == PackagePlatform.ios) ...[
                        ..._buildIosCards(fileState),
                      ] else ...[
                        // 平台标识同样放在最前：两页版式一致，这一行是用户
                        // 分辨自己在看哪个平台的第一眼依据。
                        _buildPlatformRow(fileState),
                        Card(
                            child: TitleValueLayout(
                                title: t.file_info.file,
                                value: fileState.filePath ?? "",
                                end: _buildFileActionMenu())),
                        Card(
                            child: TitleValueLayout(
                          title: t.file_info.size,
                          value: fileState.fileSize != null
                              ? "${formatFileSize(fileState.fileSize)} (${fileState.fileSize} Bytes)"
                              : "",
                        )),
                        Card(
                            child: TitleValueLayout(
                          title: t.apk_info.app_name,
                          value: _getDisplayLabel(apkInfo),
                          end: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildLabelLocaleMenu(apkInfo),
                              _buildCopyButton(_getDisplayLabel(apkInfo),
                                  apkInfo?.label != null),
                            ],
                          ),
                        )),
                        Card(
                            child: TitleValueLayout(
                          title: t.apk_info.package_name,
                          value: apkInfo?.packageName ?? "",
                          end: _buildCopyButton(apkInfo?.packageName,
                              apkInfo?.packageName != null),
                        )),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                                child: Column(
                              children: [
                                Card(
                                    child: TitleValueLayout(
                                  title: t.apk_info.version_code,
                                  value: "${apkInfo?.versionCode ?? ""}",
                                )),
                                Card(
                                    child: TitleValueLayout(
                                  title: t.apk_info.version_name,
                                  value: apkInfo?.versionName ?? "",
                                )),
                                if (iconRowSpan >= 3)
                                  Card(
                                    child: TitleValueLayout(
                                      title: t.apk_info.min_sdk,
                                      value: getSdkVersionText(
                                          apkInfo?.sdkVersion),
                                    ),
                                  ),
                                if (apkInfo?.isXapk ?? false)
                                  Card(
                                      child: TitleValueLayout(
                                    title: t.apk_info.archive_type,
                                    value: apkInfo?.archiveType ?? "",
                                  )),
                              ],
                            )),
                            _buildIconWidget(apkInfo, iconRowSpan),
                          ],
                        ),
                        if (iconRowSpan < 3)
                          Card(
                            child: TitleValueLayout(
                              title: t.apk_info.min_sdk,
                              value: getSdkVersionText(apkInfo?.sdkVersion),
                            ),
                          ),
                        Card(
                            child: TitleValueLayout(
                          title: t.apk_info.target_sdk,
                          value: getSdkVersionText(apkInfo?.targetSdkVersion),
                        )),
                        if (apkInfo?.isXapk ?? false)
                          Card(
                              child: TitleValueLayout(
                            title: t.apk_info.split_apks,
                            value: apkInfo?.splitApks.join("\n") ?? "",
                            minLines: 1,
                            maxLines: textMaxLines,
                            selectable: true,
                          )),
                        if ((apkInfo?.obbFiles.isNotEmpty ?? false))
                          Card(
                              child: TitleValueLayout(
                            title: t.apk_info.obb_files,
                            value: apkInfo?.obbFiles.join("\n") ?? "",
                            minLines: 1,
                            maxLines: textMaxLines,
                            selectable: true,
                          )),
                        Card(
                            child: TitleValueLayout(
                          title: t.apk_info.screen_size,
                          value: apkInfo?.supportsScreens.join(" ") ?? "",
                        )),
                        Card(
                            child: TitleValueLayout(
                          title: t.apk_info.screen_density,
                          value: apkInfo?.densities.join(" ") ?? "",
                        )),
                        Card(
                            child: TitleValueLayout(
                          title: t.apk_info.abi,
                          value: apkInfo?.nativeCodes.join(" ") ?? "",
                        )),
                        Card(
                            child: TitleValueLayout(
                          title: t.apk_info.languages,
                          value: apkInfo?.locales.join(" ") ?? "",
                        )),
                        Card(
                            child: TitleValueLayout(
                          title: t.apk_info.permissions,
                          value: apkInfo?.usesPermissions.join("\n") ?? "",
                          minLines: 1,
                          maxLines: textMaxLines,
                          selectable: true,
                        )),
                        if (apkInfo?.maxSdkVersion != null)
                          Card(
                              child: TitleValueLayout(
                            title: t.apk_info.max_sdk,
                            value: getSdkVersionText(apkInfo?.maxSdkVersion),
                          )),
                        if (apkInfo?.components.isNotEmpty ?? false)
                          Card(
                              child: TitleValueLayout(
                            title: t.apk_info.components,
                            value: DetailRenderer.components(apkInfo, t),
                            minLines: 1,
                            maxLines: textMaxLines,
                            selectable: true,
                          )),
                        // MD5 哈希值
                        if (enableHash)
                          Card(
                              child: TitleValueLayout(
                            title: t.file_info.md5,
                            value: fileState.isComputingHash
                                ? t.file_info.computing_hash
                                : (fileState.md5Hash ?? ""),
                            end: _buildCopyButton(
                                fileState.md5Hash,
                                fileState.md5Hash != null &&
                                    !fileState.isComputingHash),
                          )),
                        // SHA1 哈希值
                        if (enableHash)
                          Card(
                              child: TitleValueLayout(
                            title: t.file_info.sha1,
                            value: fileState.isComputingHash
                                ? t.file_info.computing_hash
                                : (fileState.sha1Hash ?? ""),
                            end: _buildCopyButton(
                                fileState.sha1Hash,
                                fileState.sha1Hash != null &&
                                    !fileState.isComputingHash),
                          )),
                        // SHA-256 哈希值（规范 4.1 要求）
                        if (enableHash)
                          Card(
                              child: TitleValueLayout(
                            title: t.file_info.sha256,
                            value: fileState.isComputingHash
                                ? t.file_info.computing_hash
                                : (fileState.sha256Hash ?? ""),
                            end: _buildCopyButton(
                                fileState.sha256Hash,
                                fileState.sha256Hash != null &&
                                    !fileState.isComputingHash),
                          )),
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
                        // 文件结构：DEX / 原生库 / ABI / 顶层目录
                        if (structureText.isNotEmpty)
                          Card(
                              child: TitleValueLayout(
                            title: t.apk_info.structure,
                            value: structureText,
                            minLines: 1,
                            maxLines: textMaxLines,
                            selectable: true,
                          )),
                        if (enableSignature && !(apkInfo?.isXapk ?? false))
                          Card(
                              child: TitleValueLayout(
                            title: t.apk_info.signature_info,
                            value: fileState.isComputingSignature
                                ? t.file_info.computing_hash
                                : DetailRenderer.signature(
                                    fileState.signature, t),
                            minLines: 1,
                            maxLines: textMaxLines,
                            selectable: !fileState.isComputingSignature,
                          )),
                        ..._buildSecurityCards(fileState.analysis?.security),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 解析状态指示器
        if (isParsing)
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(parseStageLabel),
                  // 只有真的拿到可取消的任务时才显示取消按钮：
                  // XAPK/APKM/APKS 路径仍走 aapt2 子进程，暂不可取消，
                  // 在那里显示一个按不动的按钮属于伪可用。
                  if (_currentTask != null && !_currentTask!.isFinished) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: t.parse.cancel_parse,
                      child: InkWell(
                        onTap: _cancelParse,
                        borderRadius: BorderRadius.circular(12),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(Icons.close, size: 16),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
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
        _buildMenuItem(
            'rename', Icons.drive_file_rename_outline, t.rename.rename_file,
            enabled: state.filePath != null),
        _buildMenuItem('text_info', Icons.text_snippet, t.apk_info.text_info,
            enabled: state.filePath != null && apkInfo != null),
        // 只有真的拿到了分析结果才让点 —— 未实现/无数据的功能不得出现
        // 伪可用按钮。
        _buildMenuItem(
            'export_report', Icons.description_outlined, t.report.export_action,
            enabled: state.analysis != null),
        _buildMenuItem(
            'export_json_report', Icons.code, t.report.export_json_action,
            enabled:
                state.analysis != null && state.analysis!.security != null),
        _buildMenuItem('close_file', Icons.close, t.open.close_file,
            enabled: state.filePath != null),
      ],
      onSelected: onMenuActionSelected,
    );
  }

  /// 导出解析报告。
  ///
  /// 报告里带**字段状态与来源**，以及「哪些检查没做」—— 那是它与界面截图的
  /// 区别所在：截图看不出某个空白是「文件里没有」还是「我们没读出来」。
  Future<void> _exportAnalysisReport() async {
    final state = ref.read(currentFileStateProvider);
    final analysis = state.analysis;
    if (analysis == null) return;

    try {
      final now = DateTime.now();
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.report.export_action,
        fileName: AnalysisReport.suggestedFileName(analysis, now),
        type: FileType.custom,
        allowedExtensions: ['md'],
        lockParentWindow: true,
      );
      // 用户取消保存 —— 不是错误，不提示。
      if (savePath == null) return;

      await File(savePath).writeAsString(
        AnalysisReport.render(analysis, t, generatedAt: now),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.report.export_success)),
        );
      }
    } catch (e) {
      log.warning('_exportAnalysisReport: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.report.export_failed(error: '$e'))),
        );
      }
    }
  }

  /// 导出 JSON 安全报告。
  Future<void> _exportJsonReport() async {
    final state = ref.read(currentFileStateProvider);
    final analysis = state.analysis;
    if (analysis == null || analysis.security == null) return;

    try {
      final now = DateTime.now();
      final base = analysis.fileName.value ?? 'package';
      final stem = path.basenameWithoutExtension(base);
      final fileName = '${stem}_${analysis.platform.name}_security.json';
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.report.export_json_action,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        lockParentWindow: true,
      );
      if (savePath == null) return;

      await File(savePath).writeAsString(
        AnalysisReport.renderJson(analysis, generatedAt: now),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.report.export_success)),
        );
      }
    } catch (e) {
      log.warning('_exportJsonReport: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.report.export_failed(error: '$e'))),
        );
      }
    }
  }

  // 显示重命名对话框
  void _showRenameDialog() {
    final apkInfo = ref.read(currentApkInfoProvider);
    final state = ref.read(currentFileStateProvider);
    if (state.filePath == null || apkInfo == null) return;

    final fileName = _getDisplayLabel(apkInfo);
    final versionName = apkInfo.versionName ?? '';
    final extension = path.extension(state.filePath!).toLowerCase();
    final targetExtension = extension.isNotEmpty ? extension : '.apk';
    final defaultName = '$fileName-$versionName$targetExtension';

    final controller = TextEditingController(text: defaultName);
    final formKey = GlobalKey<FormFieldState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.rename.rename_file),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: controller,
              decoration: InputDecoration(
                labelText: t.rename.new_file_name,
                suffixText: '',
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return t.rename.name_cannot_be_empty;
                }
                if (!(value.toLowerCase().endsWith('.apk') ||
                    value.toLowerCase().endsWith('.xapk') ||
                    value.toLowerCase().endsWith('.apkm') ||
                    value.toLowerCase().endsWith('.apks'))) {
                  return t.rename.must_end_with_apk;
                }
                return null;
              },
              key: formKey,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () {
                    controller.text = defaultName;
                  },
                  child: Text(t.rename.default_name),
                ),
                OutlinedButton(
                  onPressed: () {
                    controller.text = '$fileName$targetExtension';
                  },
                  child: Text(t.rename.app_name_only),
                ),
                OutlinedButton(
                  onPressed: () {
                    controller.text = '$fileName-v$versionName$targetExtension';
                  },
                  child: Text(t.rename.name_with_version),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.base.cancel),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                final newName = controller.text;
                final oldFile = File(state.filePath!);
                final directory = oldFile.parent;
                final newPath =
                    '${directory.path}${Platform.pathSeparator}$newName';

                try {
                  oldFile.renameSync(newPath);
                  // 更新当前文件路径
                  openApk(newPath);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t.rename.success)),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${t.rename.failed}: $e')),
                  );
                }
              }
            },
            child: Text(t.base.confirm),
          ),
        ],
      ),
    );
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

  Widget _buildIconWidget(ApkInfo? apkInfo, int iconRowSpan) {
    final iconSize = iconRowSpan * 44.0;
    final radius = iconSize * 0.22;
    return GestureDetector(
      onSecondaryTapUp: (details) {
        if (apkInfo != null) {
          _showIconContextMenu(context, details.globalPosition, apkInfo);
        }
      },
      child: SizedBox(
        width: iconSize,
        height: iconSize,
        child: Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          clipBehavior: Clip.antiAlias,
          child: RawImage(
            image: apkInfo?.mainIconImage,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
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
                content:
                    Text(t.icon.export_failed(error: 'SVG conversion failed'))),
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
        await _exportAnalysisReport();
        break;
      case 'export_json_report':
        await _exportJsonReport();
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
