import 'dart:io';

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/main.dart';
import 'package:apk_info_tool/providers/setting_provider.dart';
import 'package:apk_info_tool/providers/ui_config_provider.dart';
import 'package:apk_info_tool/theme/theme_manager.dart';
import 'package:apk_info_tool/utils/app_links.dart';
import 'package:apk_info_tool/utils/file_association.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/platform.dart';
import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:apk_info_tool/utils/tool_downloader.dart';
import 'package:apk_info_tool/utils/tool_paths.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:apk_info_tool/widgets/title_value_layout.dart';
import 'package:apk_info_tool/widgets/title_width_setting.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _maxLinesController.text = ref.read(
        uiConfigStateProvider.select((value) => value.textMaxLines.toString()));
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
          systemPath: ToolPaths.findInPath(CommandTools.aapt2),
          builtinPath: ToolPaths.getDownloadedAapt2Path(baseDir: downloadDir) ??
              ToolPaths.getBundledToolPath(
                  Platform.isWindows ? 'aapt2.exe' : 'aapt2'),
          customPath: Config.aapt2Path.value,
          onSource: ref.read(settingStateProvider.notifier).setAapt2Source,
        );
        break;
      case 'adb':
        _autoDetectTool(
          systemPath: ToolPaths.findInPath(CommandTools.adb),
          builtinPath: ToolPaths.getDownloadedAdbPath(baseDir: downloadDir) ??
              ToolPaths.getBundledToolPath(
                  Platform.isWindows ? 'adb.exe' : 'adb'),
          customPath: Config.adbPath.value,
          onSource: ref.read(settingStateProvider.notifier).setAdbSource,
        );
        break;
      case 'apksigner':
        _autoDetectTool(
          systemPath: ToolPaths.findInPath(CommandTools.apksigner),
          builtinPath:
              ToolPaths.getDownloadedApksignerPath(baseDir: downloadDir) ??
                  ToolPaths.getBundledToolPath(
                      Platform.isWindows ? 'apksigner.bat' : 'apksigner'),
          customPath: Config.apksignerPath.value,
          onSource: ref.read(settingStateProvider.notifier).setApksignerSource,
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

  Widget _buildToolSelector({
    required String title,
    required String source,
    required String? systemPath,
    required String? builtinPath,
    required String customPath,
    required bool singleLine,
    required ValueChanged<String> onSourceChanged,
    required VoidCallback onCustomPick,
    required VoidCallback onReset,
  }) {
    final displayPath = _displayPathForSource(
      source: source,
      systemPath: systemPath,
      builtinPath: builtinPath,
      customPath: customPath,
    );
    return TitleValueLayout(
      title: title,
      value: displayPath,
      singleLine: singleLine,
      end: Wrap(
        spacing: 8,
        children: [
          DropdownButton<String>(
            value: source,
            isDense: true,
            onChanged: (value) {
              if (value != null) {
                onSourceChanged(value);
              }
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
            SizedBox(
              height: 36,
              child: Center(
                child: TextButton(
                  onPressed: onCustomPick,
                  child: Text(t.base.select),
                ),
              ),
            ),
          SizedBox(
            height: 36,
            child: Center(
              child: TextButton(
                onPressed: onReset,
                child: Text(t.settings.auto_detect),
              ),
            ),
          ),
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

  Widget _buildSettingCard({
    required String title,
    required List<Widget> children,
    required IconData icon,
    bool initiallyExpanded = false,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icon),
          title: Text(title),
          initiallyExpanded: initiallyExpanded,
          children: children,
        ),
      ),
    );
  }

  Widget _buildEnvironmentSection() {
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
    final downloadDir =
        ref.watch(settingStateProvider.select((value) => value.downloadDir));
    final resolvedDownloadDir = ToolPaths.resolveDownloadDir(downloadDir);

    final aapt2System = ToolPaths.findInPath(CommandTools.aapt2);
    final apksignerSystem = ToolPaths.findInPath(CommandTools.apksigner);
    final adbSystem = ToolPaths.findInPath(CommandTools.adb);

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

    return _buildSettingCard(
      title: t.settings.environment,
      icon: Icons.computer,
      initiallyExpanded: true,
      children: [
        ListTile(
          title: Row(
            children: [
              Text(t.settings.download_dependencies),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.settings.download_dependencies_desc,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).hintColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          trailing: TextButton(
            onPressed: _openDownloadDialog,
            child: Text(t.settings.download_dependencies_manage),
          ),
        ),
        _buildToolSelector(
          title: t.settings.aapt_path,
          source: aapt2Source,
          systemPath: aapt2System,
          builtinPath: aapt2Builtin,
          customPath: aapt2Path,
          singleLine: true,
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
        _buildToolSelector(
          title: t.settings.apksigner_path,
          source: apksignerSource,
          systemPath: apksignerSystem,
          builtinPath: apksignerBuiltin,
          customPath: apksignerPath,
          singleLine: true,
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
        _buildToolSelector(
          title: t.settings.adb_path,
          source: adbSource,
          systemPath: adbSystem,
          builtinPath: adbBuiltin,
          customPath: adbPath,
          singleLine: true,
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
    return _buildSettingCard(
      title: t.settings.features,
      icon: Icons.featured_play_list,
      children: [
        ListTile(
          title: Text(t.settings.parser_engine),
          trailing: DropdownButton<String>(
            value: parserEngine,
            isDense: true,
            onChanged: (value) {
              if (value != null) {
                ref.read(settingStateProvider.notifier).setParserEngine(value);
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
        SwitchListTile(
          title: Text(t.settings.enable_signature),
          value: enableSignature,
          onChanged: (bool value) {
            ref.read(settingStateProvider.notifier).setEnableSignature(value);
          },
        ),
        SwitchListTile(
          title: Text(t.settings.enable_hash),
          value: enableHash,
          onChanged: (bool value) {
            ref.read(settingStateProvider.notifier).setEnableHash(value);
          },
        ),
        SwitchListTile(
          title: Text(t.settings.enable_security_audit),
          value: ref.watch(settingStateProvider
              .select((value) => value.enableSecurityAudit)),
          onChanged: (bool value) {
            ref
                .read(settingStateProvider.notifier)
                .setEnableSecurityAudit(value);
          },
        ),
        if (FileAssociationManager.isSupported)
          ListTile(
            title: Text(t.settings.file_association),
            trailing: TextButton(
              onPressed: () async {
                try {
                  await FileAssociationManager.openDefaultAppsSettings();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(t.settings.cannot_open_settings),
                    ),
                  );
                }
              },
              child: Text(t.settings.open_settings),
            ),
          ),
      ],
    );
  }

  Widget _buildAppearanceSection() {
    final themeColor =
        ref.watch(themeManagerProvider.select((value) => value.themeColor));
    final themeMode =
        ref.watch(settingStateProvider.select((value) => value.themeMode));

    return _buildSettingCard(
      title: t.settings.appearance,
      icon: Icons.palette,
      children: [
        ListTile(
          title: Text(t.settings.language),
          trailing: DropdownButton<String>(
            value: ref
                .watch(settingStateProvider.select((value) => value.language)),
            items: [
              DropdownMenuItem(
                value: Config.kLanguageAuto,
                child: Text(t.settings.language_auto),
              ),
              DropdownMenuItem(
                value: AppLocale.en.languageCode,
                child: Text('English'),
              ),
              DropdownMenuItem(
                value: AppLocale.zhCn.languageCode,
                child: Text('简体中文'),
              ),
            ],
            onChanged: (String? value) {
              if (value != null) {
                ref.read(settingStateProvider.notifier).setLanguage(value);
              }
            },
          ),
        ),
        // 主题模式切换
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(child: Text(t.settings.theme_mode)),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: Config.kThemeModeLight,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode, size: 16),
                  ),
                  ButtonSegment(
                    value: Config.kThemeModeDark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode, size: 16),
                  ),
                  ButtonSegment(
                    value: Config.kThemeModeSystem,
                    label: Text('Auto'),
                    icon: Icon(Icons.brightness_auto, size: 16),
                  ),
                ],
                selected: {themeMode},
                onSelectionChanged: (Set<String> value) {
                  final selected = value.first;
                  ref
                      .read(settingStateProvider.notifier)
                      .setThemeMode(selected);
                  final mode = switch (selected) {
                    Config.kThemeModeLight => ThemeMode.light,
                    Config.kThemeModeDark => ThemeMode.dark,
                    _ => ThemeMode.system,
                  };
                  ref.read(themeManagerProvider.notifier).setThemeMode(mode);
                },
              ),
            ],
          ),
        ),
        ListTile(
          title: Text(t.settings.theme_color),
          trailing: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Color(themeColor),
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
          ),
          onTap: _showColorPicker,
        ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: Text(t.settings.max_lines),
              ),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _maxLinesController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
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
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0),
          child: TitleWidthSetting(),
        ),
      ],
    );
  }

  Widget _buildDebugSection() {
    final enableDebug =
        ref.watch(settingStateProvider.select((value) => value.enableDebug));
    return _buildSettingCard(
      title: t.settings.debug,
      icon: Icons.bug_report,
      children: [
        SwitchListTile(
          title: Text(t.settings.enable_debug),
          value: enableDebug,
          onChanged: (bool value) async {
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
        ListTile(
          enabled: enableDebug,
          title: Text(t.settings.open_debug_log),
          leading: const Icon(Icons.description),
          onTap: () {
            final logPath = LoggerInit.instance.logFilePath;
            if (logPath != null) {
              openFileInExplorer(logPath);
            }
          },
        ),
        ListTile(
          enabled: enableDebug,
          title: Text(t.settings.open_debug_directory),
          leading: const Icon(Icons.folder),
          onTap: () {
            final logPath = LoggerInit.instance.logFilePath;
            if (logPath != null) {
              openFileInExplorer(logPath);
            }
          },
        ),
      ],
    );
  }

  Widget _buildAboutSection() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ListTile(
          leading: const Icon(Icons.info),
          title: Text(t.settings.about),
          onTap: _showAboutDialog,
        ),
      ),
    );
  }

  /// 关于对话框。
  ///
  /// 结构：应用标识 + 版本 → 一句话定位 → 功能列表 → 项目地址。
  ///
  /// 不用 `showAboutDialog`：它固定带一个「查看开源许可」按钮，而许可
  /// 全文在这个对话框里既放不下也不是用户点开「关于」想看的东西。
  ///
  /// **项目地址必须在这里**：早先的版本刻意去掉了仓库链接（理由写在
  /// 旧注释里），但那让用户想找源码 / 提 issue 时无处可去 —— 桌面工具的
  /// 「关于」正是放这个的地方。
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.settings.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildEnvironmentSection(),
          _buildFeaturesSection(),
          _buildAppearanceSection(),
          _buildDebugSection(),
          _buildAboutSection(),
        ],
      ),
    );
  }
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
  bool _downloading = false;
  String _installDir = '';
  String _installDirDisplay = '';
  double? _platformProgress;
  double? _buildProgress;

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
    if (!_downloadPlatformTools && !_downloadBuildTools) {
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
  }) {
    final percentText = !value
        ? t.settings.download_disabled
        : _downloading
            ? '${((progress ?? 0) * 100).toStringAsFixed(1)}%'
            : '';
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
