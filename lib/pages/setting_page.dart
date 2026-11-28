import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/providers/setting_provider.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/providers/ui_config_provider.dart';
import 'package:apk_info_tool/theme/theme_manager.dart';
import 'package:apk_info_tool/utils/app_links.dart';
import 'package:apk_info_tool/utils/cache_manager.dart';
import 'package:apk_info_tool/utils/file_association.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/platform.dart';
import 'package:apk_info_tool/utils/system_thumbnail.dart';
import 'package:apk_info_tool/widgets/system_icon_section.dart';
import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:apk_info_tool/utils/diagnostics_report.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/java_runtime.dart';
import 'package:apk_info_tool/utils/tool_downloader.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:apk_info_tool/widgets/title_width_setting.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

class SettingPage extends ConsumerStatefulWidget {
  const SettingPage({super.key});

  @override
  ConsumerState<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends ConsumerState<SettingPage> {
  final _maxLinesController = TextEditingController();
  final _settingsScroll = ScrollController();
  final _sectionKeys = List.generate(6, (_) => GlobalKey());
  int _activeSection = 0;

  /// 文件关联是否已登记；`null` 表示还没试过（Windows 之外的平台一直是 `null`）。
  ///
  /// 只在用户点「重新登记」后更新，不在 build 里查 —— 每次重建都打一次
  /// 方法通道既浪费，也会让副标题在「已登记 / 未登记」之间闪。
  bool? _fileAssociationRegistered;

  /// 系统文件图标（Windows 缩略图处理器）的当前状态。
  ///
  /// 与 [_fileAssociationRegistered] 同样**不在 build 里查**：由
  /// [initState] 查一次，之后只在用户操作后更新。默认是 `unknown`
  /// （全 false）—— 「没查」不能显示成「可用」。
  SystemThumbnailStatus _thumbnailStatus =
      const SystemThumbnailStatus.unknown();

  /// 正在执行注册 / 注销 / 刷新，用于禁用按钮并显示进度。
  ///
  /// 不加这个的话，连点两次「启用」会并发写注册表 —— 第二次读到的状态
  /// 取决于第一次写到哪里，结果不可预测。
  bool _thumbnailBusy = false;

  /// 缓存占用（图标缩略图 + 日志备份），用于「清理缓存」这一行。
  ///
  /// 首次在 [initState] 里盘点，清理后重算。取不到目录时保持 0。
  CacheUsage _cacheUsage = const CacheUsage();

  /// `codesign` 的路径；非 macOS 或确实没有时为 `null`。
  ///
  /// 不提供配置项：macOS 上它固定在 `/usr/bin/codesign`，配错只会更糟。
  /// 列出来是为了回答「iOS 签名验证为什么不可用」。
  String? _codesignPath;

  @override
  void initState() {
    super.initState();
    _maxLinesController.text = ref.read(
        uiConfigStateProvider.select((value) => value.textMaxLines.toString()));
    _loadThumbnailStatus();
    _loadCacheUsage();
    // codesign 是纯文件系统判断（不拉子进程），同步做完即可 —— 异步化反而会
    // 在 widget 测试里留下未完成的 Timer。Java 的探测跟着配置走，放在
    // `_buildEnvironmentSection` 里（`JavaRuntime.detect` 自己带缓存）。
    _codesignPath = IosCodeSignAnalyzer.findCodesignPath();
  }

  /// 盘点缓存占用。
  ///
  /// 不 await：统计目录大小可能在网络盘上很慢，设置页不该因此延迟首帧。
  Future<void> _loadCacheUsage() async {
    final usage = await CacheManager.inspect();
    if (!mounted) return;
    setState(() => _cacheUsage = usage);
  }

  /// 首次查询缩略图处理器状态。
  ///
  /// 用 `unawaited` 语义（不 await）：设置页不该因为一次方法通道往返而
  /// 延迟首帧。查完 `setState` 刷新即可。
  Future<void> _loadThumbnailStatus() async {
    if (!SystemThumbnailManager.isSupported) return;
    final status = await SystemThumbnailManager.getStatus();
    if (!mounted) return;
    setState(() => _thumbnailStatus = status);
  }

  void openFilePicker(ValueChanged<String> cb) async {
    var result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      dialogTitle: t.settings.select_exe_path,
      allowedExtensions: getExecutableExtensions(),
      lockParentWindow: true,
    );
    log.info('openFilePicker: result=$result');
    var file = result?.files.single;
    if (file != null && file.path != null) {
      cb(file.path!);
    }
  }

  void resetToDefaultPath(String toolType) async {
    final downloadDir = ToolPaths.resolveDownloadDir(Config.downloadDir.value);
    switch (toolType) {
      case 'aapt2':
        _autoDetectTool(
          systemPath: ToolPaths.findSystemTool(CommandTools.aapt2),
          builtinPath: ToolPaths.getDownloadedAapt2Path(baseDir: downloadDir) ??
              ToolPaths.getBundledToolPath(
                  Platform.isWindows ? 'aapt2.exe' : 'aapt2'),
          customPath: Config.aapt2Path.value,
          onSource: ref.read(settingStateProvider.notifier).setAapt2Source,
        );
        break;
      case 'adb':
        _autoDetectTool(
          systemPath: ToolPaths.findSystemTool(CommandTools.adb),
          builtinPath: ToolPaths.getDownloadedAdbPath(baseDir: downloadDir) ??
              ToolPaths.getBundledToolPath(
                  Platform.isWindows ? 'adb.exe' : 'adb'),
          customPath: Config.adbPath.value,
          onSource: ref.read(settingStateProvider.notifier).setAdbSource,
        );
        break;
      case 'apksigner':
        _autoDetectTool(
          systemPath: ToolPaths.findSystemTool(CommandTools.apksigner),
          builtinPath:
              ToolPaths.getDownloadedApksignerPath(baseDir: downloadDir) ??
                  ToolPaths.getBundledToolPath(
                      Platform.isWindows ? 'apksigner.bat' : 'apksigner'),
          customPath: Config.apksignerPath.value,
          onSource: ref.read(settingStateProvider.notifier).setApksignerSource,
        );
        break;
      case 'java':
        // Java 的「内置」只有下载的 JRE（没有随包分发的那一份），
        // 所以 builtinPath 可能为 null —— `_autoDetectTool` 会据此退回
        // 「系统环境」，而不是把一个不存在的路径写成内置。
        _autoDetectTool(
          systemPath: JavaRuntime.probeSystemPath(),
          builtinPath: ToolPaths.getDownloadedJavaPath(baseDir: downloadDir),
          customPath: Config.javaPath.value,
          onSource: ref.read(settingStateProvider.notifier).setJavaSource,
        );
        break;
    }
  }

  List<String> getExecutableExtensions() {
    if (Platform.isWindows) {
      return ['exe', 'bat'];
    } else if (Platform.isMacOS || Platform.isLinux) {
      return ['*'];
    }
    return [''];
  }

  void _showColorPicker() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Consumer(builder: (context, ref, child) {
          final themeColor = ref
              .watch(themeManagerProvider.select((value) => value.themeColor));
          return AlertDialog(
            title: Text(t.settings.theme_color),
            content: SingleChildScrollView(
              child: ColorPicker(
                pickerColor: Color(themeColor),
                onColorChanged: (Color color) {
                  ref
                      .read(themeManagerProvider.notifier)
                      .updateThemeColor(color);
                },
                pickerAreaHeightPercent: 0.8,
                enableAlpha: false,
                displayThumbColor: true,
                paletteType: PaletteType.hsvWithHue,
                pickerAreaBorderRadius:
                    const BorderRadius.all(Radius.circular(10)),
              ),
            ),
            actions: <Widget>[
              TextButton(
                child: Text(t.base.ok),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        });
      },
    );
  }

  String _formatBuiltinPath(String? value) {
    if (value == null || value.isEmpty) {
      return t.settings.path_not_found;
    }
    if (path.isWithin(ToolPaths.appSupportDir, value)) {
      return path.relative(value, from: ToolPaths.appSupportDir);
    }
    if (path.isWithin(ToolPaths.appDir, value)) {
      return path.relative(value, from: ToolPaths.appDir);
    }
    return value;
  }

  String _displayPathForSource({
    required String source,
    required String? systemPath,
    required String? builtinPath,
    required String customPath,
  }) {
    String? resolved;
    switch (source) {
      case Config.kToolSourceBuiltin:
        resolved = builtinPath ??
            systemPath ??
            (customPath.isNotEmpty ? customPath : null);
        break;
      case Config.kToolSourceCustom:
        resolved =
            customPath.isNotEmpty ? customPath : systemPath ?? builtinPath;
        break;
      case Config.kToolSourceSystem:
      default:
        resolved = systemPath ??
            builtinPath ??
            (customPath.isNotEmpty ? customPath : null);
        break;
    }
    if (resolved == null || resolved.isEmpty) {
      return t.settings.path_not_found;
    }
    if (resolved == builtinPath) {
      return _formatBuiltinPath(builtinPath);
    }
    return resolved;
  }

  void _autoDetectTool({
    required String? systemPath,
    required String? builtinPath,
    required String customPath,
    required ValueChanged<String> onSource,
  }) {
    if (builtinPath != null && builtinPath.isNotEmpty) {
      onSource(Config.kToolSourceBuiltin);
      return;
    }
    if (systemPath != null && systemPath.isNotEmpty) {
      onSource(Config.kToolSourceSystem);
      return;
    }
    if (customPath.isNotEmpty) {
      onSource(Config.kToolSourceCustom);
      return;
    }
    onSource(Config.kToolSourceBuiltin);
  }

  /// 一行工具路径：名称 + 当前解析到的路径 + 来源/选择/检测。
  ///
  /// 原型的 `.set-row` 只有一行，所以路径作为副标题与工具名同排，
  /// 不再像旧版那样让下拉框单独占一行（半宽卡片里会挤成三行）。
  Widget _buildToolRow({
    required String name,
    required String source,
    required String? systemPath,
    required String? builtinPath,
    required String customPath,
    required ValueChanged<String> onSourceChanged,
    required VoidCallback onCustomPick,
    required VoidCallback onReset,
  }) {
    final theme = Theme.of(context);
    final displayPath = _displayPathForSource(
      source: source,
      systemPath: systemPath,
      builtinPath: builtinPath,
      customPath: customPath,
    );
    final missing = displayPath == t.settings.path_not_found;
    return _V4SetRow(
      title: name,
      desc: displayPath,
      descStyle: theme.textTheme.labelSmall?.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Menlo', 'Courier'],
        fontSize: 10.5,
        color: missing ? theme.colorScheme.error : theme.hintColor,
      ),
      control: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<String>(
            value: source,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
            onChanged: (value) {
              if (value != null) onSourceChanged(value);
            },
            items: [
              DropdownMenuItem(
                value: Config.kToolSourceBuiltin,
                child: Text(t.settings.tool_source_builtin),
              ),
              DropdownMenuItem(
                value: Config.kToolSourceSystem,
                child: Text(t.settings.tool_source_system),
              ),
              DropdownMenuItem(
                value: Config.kToolSourceCustom,
                child: Text(t.settings.tool_source_custom),
              ),
            ],
          ),
          if (source == Config.kToolSourceCustom)
            _v4IconAction(
                Icons.file_open_outlined, t.base.select, onCustomPick),
          _v4IconAction(Icons.refresh, t.settings.auto_detect, onReset),
        ],
      ),
    );
  }

  Future<void> _openDownloadDialog() async {
    await showDialog(
      context: context,
      builder: (context) => const DependencyDownloadDialog(),
    );
    if (!mounted) return;
    ref
        .read(settingStateProvider.notifier)
        .setDownloadDir(Config.downloadDir.value);
    setState(() {});
  }

  /// 设置页的分组卡片。
  ///
  /// 版式与另外两页对齐：
  /// - 圆角用 12（`Card` 的 M3 默认值），此前写死 8，比别处的卡片更方；
  /// - 分组标题用 `titleSmall` + w600，与概览页的 `_SectionLabel`、详情页的
  ///   `_SectionHeader` 同一套字号与字重 —— 三页的「分组」看起来才是同一件事；
  /// - 前置图标缩到 18 并统一用主色，默认的 24 号灰色图标会把标题压得很小。
  Widget _buildEnvironmentSection() {
    final theme = Theme.of(context);
    final aapt2Path =
        ref.watch(settingStateProvider.select((value) => value.aapt2Path));
    final apksignerPath =
        ref.watch(settingStateProvider.select((value) => value.apksignerPath));
    final adbPath =
        ref.watch(settingStateProvider.select((value) => value.adbPath));
    final aapt2Source =
        ref.watch(settingStateProvider.select((value) => value.aapt2Source));
    final apksignerSource = ref
        .watch(settingStateProvider.select((value) => value.apksignerSource));
    final adbSource =
        ref.watch(settingStateProvider.select((value) => value.adbSource));
    final javaPath =
        ref.watch(settingStateProvider.select((value) => value.javaPath));
    final javaSource =
        ref.watch(settingStateProvider.select((value) => value.javaSource));
    final downloadDir =
        ref.watch(settingStateProvider.select((value) => value.downloadDir));
    final resolvedDownloadDir = ToolPaths.resolveDownloadDir(downloadDir);

    final aapt2System = ToolPaths.findSystemTool(CommandTools.aapt2);
    final apksignerSystem = ToolPaths.findSystemTool(CommandTools.apksigner);
    final adbSystem = ToolPaths.findSystemTool(CommandTools.adb);

    final aapt2Builtin =
        ToolPaths.getDownloadedAapt2Path(baseDir: resolvedDownloadDir) ??
            ToolPaths.getBundledToolPath(
                Platform.isWindows ? 'aapt2.exe' : 'aapt2');
    final apksignerBuiltin =
        ToolPaths.getDownloadedApksignerPath(baseDir: resolvedDownloadDir) ??
            ToolPaths.getBundledToolPath(
                Platform.isWindows ? 'apksigner.bat' : 'apksigner');
    final adbBuiltin = ToolPaths.getDownloadedAdbPath(
            baseDir: resolvedDownloadDir) ??
        ToolPaths.getBundledToolPath(Platform.isWindows ? 'adb.exe' : 'adb');

    // Java 与另外三项的区别：**没有「系统 PATH」这一档以外的探测**。
    // `probeSystemPath` 会走 JAVA_HOME → PATH → 各平台常见安装目录 ——
    // Windows 上「装了 JDK 但没配环境变量」正是靠最后一档救回来的。
    final javaSystem = JavaRuntime.probeSystemPath();
    final javaBuiltin =
        ToolPaths.getDownloadedJavaPath(baseDir: resolvedDownloadDir);
    final javaInfo = JavaRuntime.detect();

    return _V4SetCard(
      title: t.settings.tool_paths,
      icon: Icons.tune,
      children: [
        _V4SetRow(
          title: t.settings.download_dependencies,
          desc: t.settings.download_dependencies_desc,
          control: _v4TextAction(
            t.settings.download_dependencies_manage,
            _openDownloadDialog,
          ),
        ),
        _buildToolRow(
          name: 'aapt2',
          source: aapt2Source,
          systemPath: aapt2System,
          builtinPath: aapt2Builtin,
          customPath: aapt2Path,
          onSourceChanged: (value) {
            ref.read(settingStateProvider.notifier).setAapt2Source(value);
          },
          onCustomPick: () => openFilePicker((path) {
            ref.read(settingStateProvider.notifier).setAapt2Path(path);
            ref
                .read(settingStateProvider.notifier)
                .setAapt2Source(Config.kToolSourceCustom);
          }),
          onReset: () => resetToDefaultPath('aapt2'),
        ),
        _buildToolRow(
          name: 'apksigner',
          source: apksignerSource,
          systemPath: apksignerSystem,
          builtinPath: apksignerBuiltin,
          customPath: apksignerPath,
          onSourceChanged: (value) {
            ref.read(settingStateProvider.notifier).setApksignerSource(value);
          },
          onCustomPick: () => openFilePicker((path) {
            ref.read(settingStateProvider.notifier).setApksignerPath(path);
            ref
                .read(settingStateProvider.notifier)
                .setApksignerSource(Config.kToolSourceCustom);
          }),
          onReset: () => resetToDefaultPath('apksigner'),
        ),
        _buildToolRow(
          name: 'adb',
          source: adbSource,
          systemPath: adbSystem,
          builtinPath: adbBuiltin,
          customPath: adbPath,
          onSourceChanged: (value) {
            ref.read(settingStateProvider.notifier).setAdbSource(value);
          },
          onCustomPick: () => openFilePicker((path) {
            ref.read(settingStateProvider.notifier).setAdbPath(path);
            ref
                .read(settingStateProvider.notifier)
                .setAdbSource(Config.kToolSourceCustom);
          }),
          onReset: () => resetToDefaultPath('adb'),
        ),
        // Java 与 codesign 只报状态：换一个 java 路径不会改变「装没装 JDK」
        // 这个事实，而 codesign 在 macOS 上固定 `/usr/bin/codesign`。
        _buildToolRow(
          name: t.settings.java_runtime,
          source: javaSource,
          systemPath: javaSystem,
          builtinPath: javaBuiltin,
          customPath: javaPath,
          onSourceChanged: (value) {
            ref.read(settingStateProvider.notifier).setJavaSource(value);
          },
          onCustomPick: () => openFilePicker((path) {
            ref.read(settingStateProvider.notifier).setJavaPath(path);
            ref
                .read(settingStateProvider.notifier)
                .setJavaSource(Config.kToolSourceCustom);
          }),
          onReset: () => resetToDefaultPath('java'),
        ),
        if (!javaInfo.usable)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              JavaRuntime.supportsDownload
                  ? t.settings.java_missing_hint
                  : t.settings.java_missing_hint_manual,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                height: 1.4,
              ),
            ),
          ),
        _V4SetRow(
          title: t.settings.codesign_path,
          desc: _codesignPath ?? t.settings.codesign_unavailable,
          descStyle: theme.textTheme.labelSmall?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
            fontSize: 10.5,
            color: _codesignPath == null && Platform.isMacOS
                ? theme.colorScheme.error
                : theme.hintColor,
          ),
        ),
      ],
    );
  }

  Widget _buildFeaturesSection() {
    final enableSignature = ref
        .watch(settingStateProvider.select((value) => value.enableSignature));
    final enableHash =
        ref.watch(settingStateProvider.select((value) => value.enableHash));
    final parserEngine =
        ref.watch(settingStateProvider.select((value) => value.parserEngine));
    final theme = Theme.of(context);
    return _V4SetCard(
      title: t.settings.system_integration,
      icon: Icons.widgets_outlined,
      children: [
        _V4SetRow(
          title: t.settings.parser_engine,
          control: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: DropdownButton<String>(
              value: parserEngine,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
              onChanged: (value) {
                if (value != null) {
                  ref
                      .read(settingStateProvider.notifier)
                      .setParserEngine(value);
                }
              },
              items: [
                DropdownMenuItem(
                  value: Config.kParserBuiltin,
                  child: Text(t.settings.parser_engine_builtin),
                ),
                DropdownMenuItem(
                  value: Config.kParserAapt2,
                  child: Text(t.settings.parser_engine_aapt2),
                ),
              ],
            ),
          ),
        ),
        _v4SwitchRow(
          t.settings.enable_signature,
          enableSignature,
          (bool value) {
            ref.read(settingStateProvider.notifier).setEnableSignature(value);
          },
        ),
        _v4SwitchRow(
          t.settings.enable_hash,
          enableHash,
          (bool value) {
            ref.read(settingStateProvider.notifier).setEnableHash(value);
          },
        ),
        _v4SwitchRow(
          t.settings.enable_security_audit,
          ref.watch(settingStateProvider
              .select((value) => value.enableSecurityAudit)),
          (bool value) {
            ref
                .read(settingStateProvider.notifier)
                .setEnableSecurityAudit(value);
          },
        ),
        if (FileAssociationManager.isSupported)
          _V4SetRow(
            title: t.settings.file_association,
            desc: _fileAssociationHint,
            control: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 只有 Windows 能由应用自己写注册表（macOS 的关联由
                // `Info.plist` 在打包时声明，运行时改不了）。
                if (FileAssociationManager.canRegisterItself)
                  _v4TextAction(
                    t.settings.file_association_register,
                    _registerFileAssociations,
                  ),
                _v4IconAction(
                  Icons.settings_outlined,
                  FileAssociationManager.hasSettingsPanel
                      ? t.settings.open_settings
                      : t.settings.how_to_set,
                  () => _openFileAssociationSettings(context),
                ),
              ],
            ),
          ),
        // 安装器默认注册：这是打包行为，运行时可查不可改 —— 与其放一个
        // 永远灰着的开关，不如把「为什么改不了」写清楚。
        _V4SetRow(
          title: t.settings.installer_registration,
          desc: t.settings.installer_registration_desc,
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _V4Chip(
                Platform.isWindows ? 'CANDIDATE' : 'BUILD TIME',
                tone: _V4ChipTone.violet,
              ),
              const SizedBox(width: 6),
              _v4IconAction(
                Icons.info_outline,
                t.settings.installer_registration_help,
                () => _showInstallerRegistrationHelp(context),
              ),
            ],
          ),
        ),
        // Windows 的缩略图处理器开关仍嵌在「系统集成」里，出错时整块可见。
        if (SystemThumbnailManager.isSupported)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: _buildSystemIconSection(),
          ),
      ],
    );
  }

  /// 文件关联那一行的副标题。
  ///
  /// 三种状态分开说，**不混成一句「打开设置」**：
  ///
  /// - Windows 且已登记：说明「已是候选，设为默认要在系统里选」——
  ///   用户点完「打开设置」看到列表里没有我们时，才知道去哪找；
  /// - Windows 但登记失败：如实说失败。静默失败会让人以为已经好了；
  /// - macOS：系统里没有这个面板，指向 Finder。
  String get _fileAssociationHint {
    if (!FileAssociationManager.hasSettingsPanel) {
      return t.settings.file_association_hint_manual;
    }
    final registered = _fileAssociationRegistered;
    if (registered == null) return t.settings.file_association_hint_panel;
    return registered
        ? t.settings.file_association_hint_registered
        : t.settings.file_association_hint_register_failed;
  }

  /// 主动重新登记文件关联（Windows）。
  ///
  /// 应用启动时会自动做一次（见 `main.dart`），这个按钮是给
  /// 「关联被别的程序抢了 / 被系统清理了」的情况用的 ——
  /// 用户不必卸载重装。
  Future<void> _registerFileAssociations() async {
    final registered = await FileAssociationManager.registerAssociations();
    if (!mounted) return;
    setState(() => _fileAssociationRegistered = registered);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(registered
            ? t.settings.file_association_register_ok
            : t.settings.file_association_register_failed_hint),
      ),
    );
  }

  /// 打开「文件关联」设置，并按**实际结果**给出反馈。
  ///
  /// 三种结果分开处理，不混成一句「打不开」：
  ///
  /// - Windows：系统有「默认应用」面板，真跳过去，只在失败时给指引；
  /// - macOS：**系统里没有这个面板**（详见 [FileAssociationManager] 的类注释），
  ///   直接给四步手动操作 —— 原先这里会跳一个失效的旧锚点，
  ///   系统设置停默认页，用户看到的就是「点了没反应」；
  /// - 其它平台：如实说不支持。
  Future<void> _openFileAssociationSettings(BuildContext context) async {
    final outcome = await FileAssociationManager.openDefaultAppsSettings();
    if (!context.mounted) return;

    switch (outcome) {
      case FileAssociationOutcome.openedSettings:
        return; // 已经跳到系统面板，不需要额外提示。
      case FileAssociationOutcome.needsManualGuidance:
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t.settings.file_association),
            content: Text(t.settings.file_association_steps),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t.settings.got_it),
              ),
            ],
          ),
        );
      case FileAssociationOutcome.unsupported:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.settings.cannot_open_settings)),
        );
    }
  }

  /// 「系统文件图标」区块（Windows）。
  ///
  /// 实体在 [SystemIconSection] —— 抽出去是为了能在任意平台真实渲染与驱动：
  /// 留在本文件里时整块被 `Platform.isWindows` 门控，测试只能跳过，
  /// 那是「没验证」而不是「通过」。
  Widget _buildSystemIconSection() {
    return SystemIconSection(
      status: _thumbnailStatus,
      busy: _thumbnailBusy,
      onToggle: _toggleThumbnailProvider,
      onRefresh: _refreshThumbnailAssociations,
    );
  }

  /// 启用 / 停用。
  ///
  /// 用返回的**实际状态**刷新界面，而不是假定操作成功 ——
  /// 原生侧会拒绝「DLL 不在却写注册表」这类请求，这里必须如实反映。
  ///
  /// 停用比启用多一层：原生注销会尝试删 HKCU，也会尝试删旧版写在 HKLM 的
  /// 机器级注册。没有管理员权限时 HKLM 删不掉，原生会返回错误；此时必须再查
  /// 一次真实状态，不能因为拿到的结果不是 usable 就说「已停用」。
  Future<void> _toggleThumbnailProvider() async {
    if (_thumbnailBusy) return;
    setState(() => _thumbnailBusy = true);
    final wasUsable = _thumbnailStatus.usable;
    var next = wasUsable
        ? await SystemThumbnailManager.unregister()
        : await SystemThumbnailManager.register();

    // 通道异常/注销部分失败会退化成 unknown；再查一次，让提示语基于注册表
    // 的真实状态，而不是基于「我们猜它成功了」。
    if (!next.isKnown || (wasUsable && !next.usable)) {
      final actual = await SystemThumbnailManager.getStatus();
      if (actual.isKnown) next = actual;
    }

    final outcome = SystemThumbnailManager.classifyToggle(
      wasUsable: wasUsable,
      status: next,
    );
    // 记录**实际**是否可用，不是记录用户点了哪一边。失败后仍写 true 会让
    // 下次设置页显示一个从未生效的「已启用」。
    await Config.systemIconEnabled.updateValue(next.usable);
    if (!mounted) return;
    setState(() {
      _thumbnailStatus = next;
      _thumbnailBusy = false;
    });

    final String message;
    switch (outcome) {
      case ThumbnailToggleOutcome.enabled:
        message = t.settings.system_icon.enabled_ok;
      case ThumbnailToggleOutcome.disabled:
        message = t.settings.system_icon.disabled_ok;
      case ThumbnailToggleOutcome.disabledMachineWide:
        message = t.settings.system_icon.disabled_machine_wide;
      case ThumbnailToggleOutcome.failed:
        message = t.settings.system_icon
            .failed(reason: SystemIconSection.stateLabel(next, t));
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 通知 Shell 重新读取关联（不清缓存，见 [SystemThumbnailManager] 注释）。
  Future<void> _refreshThumbnailAssociations() async {
    if (_thumbnailBusy) return;
    setState(() => _thumbnailBusy = true);
    final next = await SystemThumbnailManager.refreshCache();
    if (!mounted) return;
    setState(() {
      _thumbnailStatus = next;
      _thumbnailBusy = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.settings.system_icon.refresh_done)),
    );
  }

  Widget _buildAppearanceSection() {
    final theme = Theme.of(context);
    final themeColor =
        ref.watch(themeManagerProvider.select((value) => value.themeColor));
    final themeMode =
        ref.watch(settingStateProvider.select((value) => value.themeMode));
    // 旧版本只存了 `zh`；现在用完整 locale 标签区分 CN/HK/TW。
    final rawLanguage =
        ref.watch(settingStateProvider.select((value) => value.language));
    final language = rawLanguage == 'zh' ? 'zh-CN' : rawLanguage;

    return _V4SetCard(
      title: t.settings.appearance_language,
      icon: Icons.palette_outlined,
      children: [
        _V4SetRow(
          title: t.settings.theme_mode,
          control: SegmentedButton<String>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 9),
              ),
              textStyle: WidgetStatePropertyAll(theme.textTheme.labelSmall),
            ),
            segments: [
              ButtonSegment(
                value: Config.kThemeModeLight,
                label: Text(t.settings.theme_light),
              ),
              ButtonSegment(
                value: Config.kThemeModeDark,
                label: Text(t.settings.theme_dark),
              ),
              ButtonSegment(
                value: Config.kThemeModeSystem,
                label: Text(t.settings.theme_follow_system),
              ),
            ],
            selected: {themeMode},
            onSelectionChanged: (Set<String> value) {
              final selected = value.first;
              ref.read(settingStateProvider.notifier).setThemeMode(selected);
              final mode = switch (selected) {
                Config.kThemeModeLight => ThemeMode.light,
                Config.kThemeModeDark => ThemeMode.dark,
                _ => ThemeMode.system,
              };
              ref.read(themeManagerProvider.notifier).setThemeMode(mode);
            },
          ),
        ),
        _V4SetRow(
          title: t.settings.language,
          control: SizedBox(
            width: 150,
            child: DropdownButton<String>(
              value: language,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
              items: [
                DropdownMenuItem(
                  value: Config.kLanguageAuto,
                  child: Text(t.settings.language_auto),
                ),
                const DropdownMenuItem(value: 'en', child: Text('English')),
                const DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
                const DropdownMenuItem(
                  value: 'zh-HK',
                  child: Text('繁體中文（香港）'),
                ),
                const DropdownMenuItem(
                  value: 'zh-TW',
                  child: Text('繁體中文（台灣）'),
                ),
                const DropdownMenuItem(value: 'ja', child: Text('日本語')),
                const DropdownMenuItem(value: 'ko', child: Text('한국어')),
              ],
              onChanged: (String? value) {
                if (value != null) {
                  ref.read(settingStateProvider.notifier).setLanguage(value);
                }
              },
            ),
          ),
        ),
        _V4SetRow(
          title: t.settings.theme_color,
          control: InkWell(
            onTap: _showColorPicker,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Color(themeColor),
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.2),
                ),
              ),
            ),
          ),
        ),
        _V4SetRow(
          title: t.settings.max_lines,
          control: SizedBox(
            width: 84,
            height: 34,
            child: TextField(
              controller: _maxLinesController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              onChanged: (value) {
                final lines = int.tryParse(value);
                if (lines != null) {
                  ref
                      .read(uiConfigStateProvider.notifier)
                      .updateTextMaxLines(lines);
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDebugSection() {
    final enableDebug =
        ref.watch(settingStateProvider.select((value) => value.enableDebug));
    return _V4SetCard(
      title: t.settings.diagnostics_logs,
      icon: Icons.bug_report_outlined,
      children: [
        _v4SwitchRow(
          t.settings.enable_debug,
          enableDebug,
          (bool value) async {
            ref.read(settingStateProvider.notifier).setEnableDebug(value);
            // 重新初始化日志系统
            if (!value) {
              await LoggerInit.instance.dispose();
            } else {
              await LoggerInit.instance.dispose();
              await LoggerInit.instance.init();
            }
          },
        ),
        _V4SetRow(
          title: t.settings.open_debug_log,
          control: _v4IconAction(
            Icons.description_outlined,
            t.settings.open_debug_log,
            !enableDebug
                ? null
                : () {
                    final logPath = LoggerInit.instance.logFilePath;
                    if (logPath != null) {
                      openFileInExplorer(logPath);
                    }
                  },
          ),
        ),
        _V4SetRow(
          title: t.settings.open_debug_directory,
          control: _v4IconAction(
            Icons.folder_outlined,
            t.settings.open_debug_directory,
            !enableDebug
                ? null
                : () {
                    final logPath = LoggerInit.instance.logFilePath;
                    if (logPath != null) {
                      // 这一项要打开的是目录；此前误传了文件本身，两个入口行为
                      // 完全一样，用户没法自己翻 debug.log.1 之类的轮换文件。
                      openFileInExplorer(File(logPath).parent.path);
                    }
                  },
          ),
        ),
        _V4SetRow(
          title: t.settings.export_diagnostics,
          desc: t.settings.export_diagnostics_desc,
          control: _v4TextAction(
            t.settings.export_diagnostics,
            _exportDiagnostics,
          ),
        ),
        _V4SetRow(
          title: t.settings.copy_diagnostics,
          control: _v4IconAction(
            Icons.copy_all_outlined,
            t.settings.copy_diagnostics,
            !enableDebug
                ? null
                : () async {
                    final logPath = LoggerInit.instance.logFilePath;
                    if (logPath == null || !File(logPath).existsSync()) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t.settings.diagnostics_none)),
                      );
                      return;
                    }
                    // 刚打开的包可能还停在 IOSink 缓冲里，先落盘再读。
                    await LoggerInit.instance.flush();
                    final file = File(logPath);
                    final report = collectDiagnostics(file.readAsStringSync());
                    if (!mounted) return;
                    if (report.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t.settings.diagnostics_none)),
                      );
                      return;
                    }
                    // 头部带版本、平台与日志修改时间：旧日志一眼可辨，不用再来回猜。
                    final header = 'AppInfoTool ${packageInfo.version}'
                        ' | platform=${Platform.operatingSystem}'
                        ' | logModified=${file.lastModifiedSync().toIso8601String()}';
                    await Clipboard.setData(
                      ClipboardData(text: '$header\n$report'),
                    );
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t.settings.diagnostics_copied)),
                    );
                  },
          ),
        ),
        _V4SetRow(
          title: t.settings.clear_cache,
          desc: _cacheUsage.isEmpty
              ? t.settings.cache_empty
              : t.settings.cache_usage(
                  icons: CacheManager.formatBytes(_cacheUsage.iconBytes),
                  logs: CacheManager.formatBytes(_cacheUsage.logBytes),
                ),
          control: _v4TextAction(
            t.settings.clear_cache_action,
            _cacheUsage.isEmpty ? null : _clearCache,
          ),
        ),
      ],
    );
  }

  /// 缓存清理：先确认，再删，最后报释放了多少。
  ///
  /// 删除范围见 [CacheManager]；这里刻意只删「可重建」的东西 —— 配置、
  /// 最近分析、安装记录、下载的工具都不动，避免清了缓存还得重下 adb。
  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.settings.clear_cache),
        content: Text(
          t.settings.cache_confirm_body(
            size: CacheManager.formatBytes(_cacheUsage.total),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.base.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t.settings.clear_cache_action),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final freed = await CacheManager.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          t.settings.cache_cleared(size: CacheManager.formatBytes(freed.total)),
        ),
      ),
    );
    await _loadCacheUsage();
  }

  /// 把诊断日志另存为文本文件（原型里的「导出」）。
  ///
  /// 与「复制诊断」用同一份 [collectDiagnostics]，区别只是落地成文件 ——
  /// 用户报 issue 时附文件比贴一大段九行剪贴板内容更合适。
  Future<void> _exportDiagnostics() async {
    final logPath = LoggerInit.instance.logFilePath;
    if (logPath == null || !File(logPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.settings.diagnostics_none)),
      );
      return;
    }
    await LoggerInit.instance.flush();
    final file = File(logPath);
    final report = collectDiagnostics(file.readAsStringSync());
    if (report.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.settings.diagnostics_none)),
      );
      return;
    }
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final stamp = '${now.year}$month$day-$hour$minute';
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: t.settings.export_diagnostics,
      fileName: 'appinfotool-diagnostics-$stamp.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    if (savePath == null) return;
    try {
      final header = 'AppInfoTool $_versionText'
          ' | platform=${Platform.operatingSystem}'
          ' | logModified=${file.lastModifiedSync().toIso8601String()}';
      await File(savePath).writeAsString('$header\n$report');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t.settings.export_diagnostics_saved(file: path.basename(savePath)),
          ),
        ),
      );
    } catch (e) {
      log.warning('导出诊断日志失败: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.settings.export_diagnostics_failed)),
      );
    }
  }

  /// 「安装器默认注册」的说明：为什么这一项在界面上改不了。
  Future<void> _showInstallerRegistrationHelp(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.settings.installer_registration),
        content: Text(t.settings.installer_registration_help_body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.base.close),
          ),
        ],
      ),
    );
  }

  /// 真实语料目录：只由测试侧的 `APPINFOTOOL_SAMPLES` 环境变量提供。
  ///
  /// 应用本体不读外部样本 —— 那不是产品能力，而是测试夹具。这里显示它，
  /// 是为了让「NOT SET」有据可查：设了环境变量的人能看到路径，没设的人
  /// 能看到这句解释，而不是一个来路不明的 NOT SET。
  String? get _samplesDir {
    final value = Platform.environment['APPINFOTOOL_SAMPLES'];
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  /// 隐私分组：原型里是独立卡片，内容只有「本机」与「外部样本目录」两行，
  /// 都是只读陈述，因此没有可交互控件。
  Widget _buildPrivacySection() {
    return _V4SetCard(
      title: t.settings.privacy,
      icon: Icons.lock_outline,
      children: [
        _V4SetRow(
          title: t.overview.recent_local_only,
          desc: t.overview.session_local,
          control: const _V4Chip('ALWAYS ON', tone: _V4ChipTone.mint),
        ),
        _V4SetRow(
          title: t.overview.env_baseline,
          desc: _samplesDir == null
              ? t.settings.sample_dir_desc
              : t.settings.sample_dir_set(path: _samplesDir!),
          control: _V4Chip(
            _samplesDir == null ? 'NOT SET' : 'SET',
            tone: _samplesDir == null ? _V4ChipTone.neutral : _V4ChipTone.mint,
          ),
        ),
      ],
    );
  }

  Widget _buildAboutSection() {
    final theme = Theme.of(context);
    return _V4SetCard(
      title: t.settings.about,
      icon: Icons.info_outline,
      onHeaderTap: _showAboutDialog,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              const AppLogo(size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _versionText.isEmpty
                          ? 'STATIC INSPECTOR'
                          : '$_versionText · STATIC INSPECTOR',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                        fontFamilyFallback: const ['Menlo', 'Courier'],
                        fontSize: 9.5,
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const _V4Chip('STABLE', tone: _V4ChipTone.mint),
              _v4IconAction(
                Icons.info_outline,
                t.settings.about,
                _showAboutDialog,
              ),
            ],
          ),
        ),
        _V4SetRow(
          title: t.about.repository,
          desc: kRepositoryUrl,
          descMaxLines: 1,
          descStyle: theme.textTheme.labelSmall?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
            fontSize: 9.5,
            color: theme.hintColor,
          ),
          control: _v4IconAction(
            Icons.open_in_new,
            t.about.open_repository,
            () => launchUrl(
              Uri.parse(kRepositoryUrl),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
        _V4SetRow(
          title: t.about.license,
          control: _v4IconAction(
            Icons.article_outlined,
            t.about.license,
            _showAboutDialog,
          ),
        ),
      ],
    );
  }

  void _showAboutDialog() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final features = [
      t.about.features.android,
      t.about.features.ios,
      t.about.features.details,
      t.about.features.hash_signature,
      t.about.features.hardening_report,
      t.about.features.security_audit,
    ];

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 应用标识 + 版本
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const AppLogo(size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            t.title,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          SelectableText(
                            'v${packageInfo.version}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.hintColor,
                              fontFamily: 'monospace',
                              fontFamilyFallback: const ['Menlo', 'Courier'],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  t.about.tagline,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                const SizedBox(height: 20),
                // 功能
                Text(
                  t.settings.features,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                for (final feature in features)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 15,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            feature,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
                // 项目地址
                Text(
                  t.about.repository,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => launchUrl(
                    Uri.parse(kRepositoryUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.dividerColor.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.code, size: 16, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            kRepositoryUrl,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                              fontFamily: 'monospace',
                              fontFamilyFallback: const ['Menlo', 'Courier'],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(
                          Icons.open_in_new,
                          size: 14,
                          color: theme.hintColor,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  t.about.license,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.base.close),
          ),
        ],
      ),
    );
  }

  /// 导航项到卡片索引的映射：四个分组分别落在 [外观, 工具路径, 诊断, 关于]。
  static const List<int> _navTargets = <int>[0, 2, 3, 5];

  void _jumpToSection(int index) {
    if (index < 0 || index >= _navTargets.length) return;
    setState(() => _activeSection = index);
    final target = _sectionKeys[_navTargets[index]].currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: 0.04,
    );
  }

  /// 没有独立的更新检查通道：先打开 releases 页，至少让用户知道去哪看新版。
  Future<void> _openReleasesPage() async {
    await launchUrl(
      Uri.parse(kReleasesUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  /// 版本号文本。`packageInfo` 在单元测试里没有初始化，返回空串而不是抛错。
  String get _versionText {
    try {
      return 'v${packageInfo.version}';
    } catch (_) {
      return '';
    }
  }

  Widget _buildPageHeader() {
    final theme = Theme.of(context);
    return PageHeader(
      kicker: t.settings.kicker,
      title: t.settings.title,
      subtitle: t.settings.subtitle,
      actions: [
        Text(
          _versionText,
          style: theme.textTheme.labelSmall?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Courier'],
            fontSize: 10.5,
            color: theme.hintColor,
          ),
        ),
        IconButton.outlined(
          onPressed: _openReleasesPage,
          icon: const Icon(Icons.system_update_alt, size: 16),
          tooltip: 'Check for updates',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        ),
      ],
    );
  }

  Widget _buildSubNav() {
    final labels = [
      t.settings.nav_general,
      t.settings.nav_devices_install,
      t.settings.nav_security_diagnostics,
      t.settings.about,
    ];
    final icons = [
      Icons.grid_view_outlined,
      Icons.desktop_windows_outlined,
      Icons.shield_outlined,
      Icons.info_outline,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++)
          _buildNavItem(i, labels[i], icons[i]),
        const SizedBox(height: 16),
        _buildPrivacyNote(),
      ],
    );
  }

  Widget _buildNavItem(int index, String label, IconData icon) {
    final theme = Theme.of(context);
    final selected = _activeSection == index;
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: () => _jumpToSection(index),
          child: SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 12,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrivacyNote() {
    final theme = Theme.of(context);
    final mint = _v4MintColor(theme);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: theme.colorScheme.surface.withValues(alpha: 0.55),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, size: 12, color: mint),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  t.settings.privacy_boundary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['Menlo', 'Courier'],
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: mint,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            t.settings.privacy_boundary_note,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10.5,
              height: 1.6,
              color: theme.hintColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsGrid(double width) {
    final cards = <Widget>[
      _buildAppearanceSection(),
      _buildFeaturesSection(),
      _buildEnvironmentSection(),
      _buildDebugSection(),
      _buildPrivacySection(),
      _buildAboutSection(),
    ];
    if (width < 680) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            KeyedSubtree(key: _sectionKeys[i], child: cards[i]),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 12),
          // IntrinsicHeight 让同一行的两张卡片等高，与原型 grid 的
          // align-items: stretch 一致。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: KeyedSubtree(key: _sectionKeys[i], child: cards[i]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: KeyedSubtree(
                    key: _sectionKeys[i + 1],
                    child: cards[i + 1],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTitleWidthCard() {
    return _V4SetCard(
      title: t.settings.title_width,
      icon: Icons.view_column_outlined,
      children: const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: TitleWidthSetting(showLabel: false),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    final theme = Theme.of(context);
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Courier'],
      fontSize: 9,
      letterSpacing: 0.6,
      color: theme.hintColor,
    );
    final mint = _v4MintColor(theme);
    final localOnly = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check, size: 13, color: mint),
        const SizedBox(width: 6),
        Text(
          'LOCAL ONLY',
          style: mono.copyWith(color: mint, fontWeight: FontWeight.w700),
        ),
      ],
    );
    return CustomPaint(
      painter: _DashedRibbonBorder(color: theme.colorScheme.outlineVariant),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tail = Text(
              _versionText.isEmpty
                  ? 'STATIC INSPECTOR'
                  : 'STATIC INSPECTOR · $_versionText',
              style: mono,
            );
            if (constraints.maxWidth < 520) {
              return Wrap(
                spacing: 16,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  localOnly,
                  Text('NOTHING SYNCED', style: mono),
                  Text('NO ACCOUNT', style: mono),
                  tail,
                ],
              );
            }
            return Row(
              children: [
                localOnly,
                const SizedBox(width: 18),
                Text('NOTHING SYNCED', style: mono),
                const SizedBox(width: 18),
                Text('NO ACCOUNT', style: mono),
                const Spacer(),
                tail,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _v4SwitchRow(
    String title,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return _V4SetRow(
      title: title,
      control: Switch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _v4TextAction(String label, VoidCallback? onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 30),
        textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  Widget _v4IconAction(IconData icon, String tooltip, VoidCallback? onPressed) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 17),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }

  @override
  void dispose() {
    _settingsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 原型：内容区左侧 190px 分区导航 + 右侧两列卡片；窄窗口退回单列。
        final showNav = constraints.maxWidth >= 1000;
        // 与原型 `.page` 的内边距一致：左 26、右 30。
        final contentWidth = constraints.maxWidth - 56;
        final gridWidth = showNav ? contentWidth - 210 : contentWidth;
        final grid = _buildSettingsGrid(gridWidth);
        return SingleChildScrollView(
          controller: _settingsScroll,
          padding: const EdgeInsets.fromLTRB(26, 4, 30, 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPageHeader(),
              const SizedBox(height: 16),
              if (showNav)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 190, child: _buildSubNav()),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          grid,
                          const SizedBox(height: 12),
                          _buildTitleWidthCard(),
                          const SizedBox(height: 18),
                          _buildFooter(),
                        ],
                      ),
                    ),
                  ],
                )
              else ...[
                grid,
                const SizedBox(height: 12),
                _buildTitleWidthCard(),
                const SizedBox(height: 18),
                _buildFooter(),
              ],
            ],
          ),
        );
      },
    );
  }
}

Color _v4MintColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF5AD6AE)
    : const Color(0xFF119C72);

Color _v4AmberColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFFE9A15C)
    : const Color(0xFFD6731E);

/// 卡片：标题栏（图标 + 标题 + 可选 chip）与分隔线，行之间用 1px 线分隔。
class _V4SetCard extends StatelessWidget {
  const _V4SetCard({
    required this.title,
    required this.icon,
    required this.children,
    this.onHeaderTap,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final VoidCallback? onHeaderTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onHeaderTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(15, 12, 12, 12),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: theme.colorScheme.primary),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: theme.colorScheme.outlineVariant,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: theme.colorScheme.outlineVariant,
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置行：左侧名称/说明，右侧控件；与原型 `.set-row` 的排布一致。
class _V4SetRow extends StatelessWidget {
  const _V4SetRow({
    required this.title,
    this.desc,
    this.descStyle,
    this.descMaxLines = 2,
    this.control,
  });

  final String title;
  final String? desc;
  final TextStyle? descStyle;
  final int descMaxLines;
  final Widget? control;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (desc != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      desc!,
                      maxLines: descMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: descStyle ??
                          theme.textTheme.bodySmall?.copyWith(
                            fontSize: 10.5,
                            height: 1.45,
                            color: theme.hintColor,
                          ),
                    ),
                  ),
              ],
            ),
          ),
          if (control != null) ...[
            const SizedBox(width: 12),
            control!,
          ],
        ],
      ),
    );
  }
}

enum _V4ChipTone { neutral, mint, amber, violet }

/// 原型 chip：等宽小字、紧贴右侧，颜色只用来区分状态。
class _V4Chip extends StatelessWidget {
  const _V4Chip(this.label, {this.tone = _V4ChipTone.neutral});

  final String label;
  final _V4ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (tone) {
      _V4ChipTone.mint => _v4MintColor(theme),
      _V4ChipTone.amber => _v4AmberColor(theme),
      _V4ChipTone.violet => theme.colorScheme.primary,
      _V4ChipTone.neutral => theme.hintColor,
    };
    return Container(
      height: 23,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        color: tone == _V4ChipTone.neutral
            ? Colors.transparent
            : color.withValues(alpha: 0.12),
        border: Border.all(
          color: tone == _V4ChipTone.neutral
              ? theme.colorScheme.outlineVariant
              : Colors.transparent,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Menlo', 'Courier'],
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: color,
        ),
      ),
    );
  }
}

/// 页脚虚线边框：原型是 1px 虚线，Material 没有现成的实现。
class _DashedRibbonBorder extends CustomPainter {
  _DashedRibbonBorder({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(14)),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 4), paint);
        distance += 8;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRibbonBorder oldDelegate) =>
      oldDelegate.color != color;
}

class DependencyDownloadDialog extends StatefulWidget {
  const DependencyDownloadDialog({super.key});

  @override
  State<DependencyDownloadDialog> createState() =>
      _DependencyDownloadDialogState();
}

class _DependencyDownloadDialogState extends State<DependencyDownloadDialog> {
  static const String _autoSourceValue = '__auto__';

  late List<String> _sourceOptions;
  late String _selectedSource;
  final _installDirController = TextEditingController();
  bool _downloadPlatformTools = true;
  bool _downloadBuildTools = true;

  /// 是否下载 JRE。只在 Windows 上提供 —— Adoptium 给 Windows 的是 `.zip`，
  /// 能复用现有的校验 + 解包链路；macOS / Linux 只有 `.tar.gz`，为它另写一套
  /// 安全解包是另一个面，见 [JavaRuntime.supportsDownload]。
  ///
  /// 默认值跟着当前状态走：**已经能用就不勾**（多数机器有 java），
  /// 不能用才默认勾上 —— 用户打开这个对话框通常正是为了补它。
  late bool _downloadJre =
      JavaRuntime.supportsDownload && !JavaRuntime.detect().usable;
  bool _downloading = false;
  String _installDir = '';
  String _installDirDisplay = '';
  double? _platformProgress;
  double? _buildProgress;
  double? _jreProgress;

  @override
  void initState() {
    super.initState();
    final sources = ToolPaths.loadExtraRepositoryUrls();
    sources.add(ToolDownloader.mirrorRepositoryIndexUrl);
    sources.add(ToolDownloader.repositoryIndexUrl);
    _sourceOptions = sources.toSet().toList();
    _selectedSource = _autoSourceValue;
    final configDir = Config.downloadDir.value;
    if (configDir.isEmpty) {
      _installDir = ToolPaths.installBinDir;
      _installDirDisplay = ToolPaths.toRelativeDownloadDir(_installDir);
    } else if (path.isAbsolute(configDir)) {
      final defaultDir = ToolPaths.installBinDir;
      if (path.normalize(configDir) == path.normalize(defaultDir)) {
        _installDir = defaultDir;
        _installDirDisplay = ToolPaths.toRelativeDownloadDir(defaultDir);
      } else {
        _installDir = configDir;
        _installDirDisplay = configDir;
      }
    } else {
      _installDir = ToolPaths.resolveDownloadDir(configDir);
      _installDirDisplay = configDir;
    }
    _installDirController.text = _installDirDisplay;
  }

  @override
  void dispose() {
    _installDirController.dispose();
    super.dispose();
  }

  Future<void> _selectDirectory() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: t.settings.select_download_directory,
    );
    if (result != null && result.isNotEmpty) {
      setState(() {
        _installDir = result;
        _installDirDisplay = result;
        _installDirController.text = result;
      });
      await Config.downloadDir.updateValue(_installDirDisplay);
    }
  }

  void _resetInstallDir() {
    final relative = ToolPaths.toRelativeDownloadDir(ToolPaths.installBinDir);
    setState(() {
      _installDir = ToolPaths.installBinDir;
      _installDirDisplay = relative;
      _installDirController.text = relative;
    });
    Config.downloadDir.updateValue(_installDirDisplay);
  }

  String _formatSourceLabel(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null || !uri.hasScheme) {
      return source;
    }
    final host = uri.host.isEmpty ? source : uri.host;
    final segments = uri.pathSegments;
    if (segments.isEmpty) {
      return host;
    }
    final tail = segments.length >= 2
        ? segments.sublist(segments.length - 2).join('/')
        : segments.join('/');
    return '$host/$tail';
  }

  void _updateProgress(ToolDownloadProgress progress) {
    if (!mounted) return;
    setState(() {
      if (progress.task == 'platform-tools') {
        _platformProgress = progress.percent;
      } else if (progress.task == 'build-tools') {
        _buildProgress = progress.percent;
      } else if (progress.task == 'jre') {
        _jreProgress = progress.percent;
      }
    });
  }

  List<String> _getExistingDownloadItems() {
    final existing = <String>[];
    if (_downloadPlatformTools) {
      final adbPath = ToolPaths.getDownloadedAdbPath(baseDir: _installDir);
      final platformDir = Directory(path.join(_installDir, 'platform-tools'));
      if (adbPath != null || platformDir.existsSync()) {
        existing.add(t.settings.download_platform_tools);
      }
    }
    if (_downloadBuildTools) {
      final buildRoot = Directory(path.join(_installDir, 'build-tools'));
      if (buildRoot.existsSync() &&
          buildRoot.listSync().whereType<Directory>().isNotEmpty) {
        existing.add(t.settings.download_build_tools);
      }
    }
    if (_downloadJre) {
      if (ToolPaths.getDownloadedJavaPath(baseDir: _installDir) != null) {
        existing.add(t.settings.download_java_runtime);
      }
    }
    return existing;
  }

  Future<bool> _confirmRedownload(List<String> items) async {
    final message =
        t.settings.download_dependencies_overwrite(items: items.join(', '));
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.settings.download_dependencies_title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.base.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.base.confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _startDownload() async {
    if (!_downloadPlatformTools && !_downloadBuildTools && !_downloadJre) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.settings.download_select_empty)),
      );
      return;
    }
    final existing = _getExistingDownloadItems();
    if (existing.isNotEmpty) {
      final confirmed = await _confirmRedownload(existing);
      if (!confirmed) {
        return;
      }
    }
    setState(() {
      _downloading = true;
      _platformProgress = _downloadPlatformTools ? 0.0 : null;
      _buildProgress = _downloadBuildTools ? 0.0 : null;
      _jreProgress = _downloadJre ? 0.0 : null;
    });
    try {
      final urls = _selectedSource == _autoSourceValue
          ? _sourceOptions
          : [_selectedSource];
      await ToolDownloader.downloadDependencies(
        ToolDownloadOptions(
          sourceUrls: urls,
          installDir: _installDir,
          downloadPlatformTools: _downloadPlatformTools,
          downloadBuildTools: _downloadBuildTools,
          downloadJre: _downloadJre,
          onProgress: _updateProgress,
        ),
      );
      await Config.downloadDir.updateValue(_installDirDisplay);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(t.settings.download_dependencies_success(path: _installDir)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      String reason = t.settings.download_error_generic;
      if (e is ToolDownloadException) {
        switch (e.code) {
          case ToolDownloadError.repositoryIndex:
            reason = t.settings.download_error_repository;
            break;
          case ToolDownloadError.platformToolsMissing:
            reason = t.settings.download_error_platform_tools;
            break;
          case ToolDownloadError.buildToolsMissing:
            reason = t.settings.download_error_build_tools;
            break;
          case ToolDownloadError.archiveDownload:
            reason = t.settings.download_error_archive;
            break;
          case ToolDownloadError.fileNotFound:
            reason = t.settings.download_error_file_missing;
            break;
          case ToolDownloadError.checksumMismatch:
            // 下载产物与仓库索引声明的校验和不符（或索引未提供校验和）。
            // 这是安全相关的拒绝路径，必须让用户看到真实原因。
            reason = t.settings.download_error_checksum;
            break;
          case ToolDownloadError.unknown:
            reason = t.settings.download_error_generic;
            break;
        }
        log.warning('download failed: code=${e.code}, detail=${e.detail}');
      } else {
        log.warning('download failed: $e');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t.settings.download_dependencies_failed(error: reason)),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
        });
      }
    }
  }

  Future<bool> _confirmDeleteDownloads() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.settings.download_dependencies_title),
        content: Text(t.settings.download_dependencies_delete_confirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.base.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.base.confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _deleteDownloads() async {
    final confirmed = await _confirmDeleteDownloads();
    if (!confirmed) return;
    try {
      final platformDir = Directory(path.join(_installDir, 'platform-tools'));
      final buildDir = Directory(path.join(_installDir, 'build-tools'));
      if (platformDir.existsSync()) {
        await platformDir.delete(recursive: true);
      }
      if (buildDir.existsSync()) {
        await buildDir.delete(recursive: true);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.settings.download_dependencies_deleted)),
      );
    } catch (e) {
      log.warning('delete downloads failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t.settings.download_dependencies_delete_failed(error: '$e'),
          ),
        ),
      );
    }
  }

  Widget _buildDownloadOption({
    required bool value,
    required String title,
    required double? progress,
    required ValueChanged<bool?> onChanged,
    String? subtitle,
  }) {
    final percentText = !value
        ? t.settings.download_disabled
        : _downloading
            ? '${((progress ?? 0) * 100).toStringAsFixed(1)}%'
            : '';
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: value,
          title: Row(
            children: [
              Expanded(child: Text(title)),
              if (percentText.isNotEmpty) Text(percentText),
            ],
          ),
          // 副标题解释「这一项为什么需要」—— JRE 尤其需要：它不是 Android
          // 工具，用户看到它出现在这里会以为下错了东西。
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
          onChanged: _downloading ? null : onChanged,
        ),
        if (_downloading && value)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 8, bottom: 8),
            child: LinearProgressIndicator(value: progress),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.settings.download_dependencies_title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.settings.download_source),
              const SizedBox(height: 8),
              DropdownButton<String>(
                isExpanded: true,
                value: _selectedSource,
                onChanged: _downloading
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() {
                            _selectedSource = value;
                          });
                        }
                      },
                items: [
                  DropdownMenuItem(
                    value: _autoSourceValue,
                    child: Text(t.settings.download_source_auto),
                  ),
                  for (final source in _sourceOptions)
                    DropdownMenuItem(
                      value: source,
                      child: Tooltip(
                        message: source,
                        child: Text(
                          _formatSourceLabel(source),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text(t.settings.download_directory)),
                  TextButton(
                    onPressed: _downloading ? null : _resetInstallDir,
                    child: Text(t.base.reset),
                  ),
                  TextButton(
                    onPressed: _downloading ? null : _selectDirectory,
                    child: Text(t.base.select),
                  ),
                  TextButton(
                    onPressed: _downloading
                        ? null
                        : () => openDirectoryInExplorer(_installDir),
                    child: Text(t.settings.open_download_directory),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _installDirController,
                readOnly: true,
                maxLines: 1,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              Text(t.settings.download_content),
              _buildDownloadOption(
                value: _downloadPlatformTools,
                title: t.settings.download_platform_tools,
                progress: _platformProgress,
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _downloadPlatformTools = value;
                    });
                  }
                },
              ),
              _buildDownloadOption(
                value: _downloadBuildTools,
                title: t.settings.download_build_tools,
                progress: _buildProgress,
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _downloadBuildTools = value;
                    });
                  }
                },
              ),
              if (JavaRuntime.supportsDownload)
                _buildDownloadOption(
                  value: _downloadJre,
                  title: t.settings.download_java_runtime,
                  subtitle: t.settings.download_java_runtime_desc,
                  progress: _jreProgress,
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _downloadJre = value;
                      });
                    }
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Row(
            children: [
              TextButton(
                onPressed: _downloading ? null : _deleteDownloads,
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: Text(t.settings.download_dependencies_delete),
              ),
              const Spacer(),
              TextButton(
                onPressed:
                    _downloading ? null : () => Navigator.of(context).pop(),
                child: Text(t.base.close),
              ),
              TextButton(
                onPressed: _downloading ? null : _startDownload,
                child: Text(t.settings.download_dependencies_start),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
