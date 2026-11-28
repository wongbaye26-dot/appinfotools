import 'dart:async';
import 'dart:io';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/pages/setting_page.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/utils/adb_install_error.dart';
import 'package:apk_info_tool/utils/adb_service.dart';
import 'package:apk_info_tool/utils/install_history.dart';
import 'package:apk_info_tool/utils/ipa_install_metadata.dart';
import 'package:apk_info_tool/utils/ios_install_service.dart';
import 'package:apk_info_tool/utils/known_devices.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/xapk_installer.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 安装日志控制台的深色底。
///
/// 固定深色、不跟随主题：V4 原型里它是一块「终端」，浅色主题下也要保持
/// 这种材质对比，否则日志和页面卡片会糊成一片。
const _logSurface = Color(0xFF131118);
const _logInk = Color(0xFFCFC8E6);
const _logMuted = Color(0xFF8E86A5);
const _logAccent = Color(0xFFC4F36A);
const _logViolet = Color(0xFFB7A4FF);

/// 一台设备在本页里的进度状态。
enum _Phase { idle, installing, success, failed, stopped }

class _DeviceState {
  _Phase phase = _Phase.idle;
  String? message;
}

/// 「安装」页。
///
/// ## 为什么是独立页面而不是对话框
///
/// 安装这件事有三段独立的前置动作 —— **选包、连设备、配无线**。对话框只能
/// 承载最后一段（在已连好的设备上点确定），所以「无线调试」一直没地方放：
/// 用户必须先自己开终端敲 `adb pair`，再回到应用里安装。
///
/// 独立页面之后，三件事在同一个平面上：选包 → 连设备（USB 自动出现，
/// 无线在这里配对）→ 安装。
class InstallPage extends StatefulWidget {
  const InstallPage({
    super.key,
    this.deviceLoader,
    this.deviceInfoLoader,
    this.apkInfoLoader,
    this.iosToolchain,
    this.ipaMetaLoader,
  });

  /// 设备枚举实现。
  ///
  /// 默认走真实的 `adb devices -l`；提供此参数可注入替身，让测试能精确控制
  /// 「加载未完成时页面被销毁」这类时序 —— 真实 `Process.run` 在 widget
  /// 测试的 fake-async 区里会留下未触发的 Timer，无法稳定复现。
  final Future<List<AdbDevice>> Function()? deviceLoader;

  /// 设备品牌 / 型号 / 系统版本的读取实现。
  final Future<AdbDeviceInfo?> Function(String deviceId)? deviceInfoLoader;

  /// 安装包信息（图标 / 名称 / 版本）的读取实现。
  final Future<ApkInfo?> Function(String path)? apkInfoLoader;

  /// iOS 工具链探测结果。
  ///
  /// 默认按 `PATH` 真实探测；测试注入空工具链，避免 `idevice_id` 子进程在
  /// fake-async 区留下悬挂的 Timer。
  final IosToolchain? iosToolchain;

  /// `.ipa` 元数据（应用名 / Bundle ID / 版本）的读取实现。
  ///
  /// 默认真实读 Info.plist；测试注入固定值，避免在 fake-async 区里做真实
  /// 文件 IO（实测会互相等待、把测试挂住）。
  final Future<IpaInstallMetadata> Function(String path)? ipaMetaLoader;

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  // ---- 安装包 ----
  String? _filePath;
  bool _isXapk = false;
  ApkInfo? _apkInfo;

  /// .ipa 的应用名 / Bundle ID / 版本（只读 Info.plist，解析失败为 null）。
  IpaInstallMetadata? _ipaMeta;
  bool _parsing = false;
  bool _parseFailed = false;

  /// 解析序号：用户连续换文件时，丢掉旧的那次结果。
  int _parseGeneration = 0;

  /// XAPK 分包勾选（只在分包包上有内容）。
  final Map<String, bool> _selectedSplits = {};

  // ---- 设备 ----
  List<AdbDevice> _devices = const [];
  final Map<String, AdbDeviceInfo> _deviceInfo = {};
  List<KnownAdbDevice> _known = const [];
  final Set<String> _selected = {};
  final Map<String, _DeviceState> _states = {};
  bool _loadingDevices = false;
  bool _adbMissing = false;

  /// `adb version` 的版本号，只取一次。取不到就保持 `null`，页脚只写 `ADB`。
  String? _adbVersion;

  // ---- iOS（libimobiledevice）----
  /// 选中的是 .ipa 时走这条链路：`ideviceinstaller` 代替 `adb install`。
  bool get _isIpa => (_filePath ?? '').toLowerCase().endsWith('.ipa');
  IosToolchain? _iosToolchain;
  List<IosDevice> _iosDevices = const [];
  bool _iosLoading = false;

  // ---- 选项 ----
  bool _allowDowngrade = false;

  /// 覆盖安装（`-r`）。**默认开**：分析工具反复装同一个包是常态，
  /// 关着会让第二次安装直接失败（`INSTALL_FAILED_ALREADY_EXISTS`）。
  bool _forceInstall = true;
  bool _allowTest = false;

  /// 安装时授予全部运行权限（`-g`，API 23+）。
  bool _grantAllPermissions = false;

  /// 安装前先卸载。签名不一致时 `-r` 必然失败，重打包的包尤其常见。
  bool _uninstallFirst = false;

  // ---- 安装过程 ----
  bool _installing = false;
  bool _cancelled = false;
  Process? _currentProcess;
  XapkInstaller? _currentInstaller;
  final List<String> _logs = [];

  /// 最近安装记录（落盘，见 [InstallHistoryManager]）。
  List<InstallRecord> _recent = const [];
  final ScrollController _logScroll = ScrollController();
  bool _dragging = false;

  /// 上一次已知的可见状态，用于「刚被切到前台」时刷新设备。
  bool _wasVisible = false;

  /// 首次可见时自动枚举设备，之后每次切回来都刷新一次。
  ///
  /// **不能在 `initState` 里做**：`AppShell` 用 `IndexedStack` 承载全部页面，
  /// 它会把每个子页都建起来（只是不可见），于是每个「渲染到外壳」的 widget
  /// 测试都会拉起一个 adb 子进程 —— 而 `Process.start` 在测试的 fake-async
  /// 区里会留下一个永不完成的零延迟 Timer，撞上
  /// `A Timer is still pending even after the widget tree was disposed`。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = Visibility.of(context);
    if (visible && !_wasVisible) {
      _wasVisible = true;
      _known = KnownDeviceStore.load();
      _recent = InstallHistoryManager.load();
      // 注入的 fake loader 只在测试里出现：此时不要再去碰真实 adb，
      // 否则 Process 的超时定时器会活得比 widget 树更久。
      if (widget.deviceLoader == null) unawaited(_loadAdbVersion());
      if (_isIpa) {
        unawaited(_refreshIos());
      } else {
        unawaited(_refreshDevices());
      }
    } else if (!visible) {
      _wasVisible = false;
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    _currentProcess?.kill();
    _currentInstaller?.cancel();
    _apkInfo?.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 文件

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['apk', 'xapk', 'apks', 'ipa'],
      dialogTitle: t.install.pick_file,
    );
    final path = result?.files.single.path;
    if (path != null) await _setFile(path);
  }

  Future<void> _setFile(String path) async {
    final lower = path.toLowerCase();
    if (!lower.endsWith('.apk') &&
        !lower.endsWith('.xapk') &&
        !lower.endsWith('.apks') &&
        !lower.endsWith('.ipa')) {
      _snack(t.install.unsupported_file);
      return;
    }
    if (lower.endsWith('.ipa')) {
      // .ipa 不走 APK 解析流水线（那是 aapt2/zip 的活）；文件条只需名字与
      // 大小，设备列表换由 libimobiledevice 提供。
      setState(() {
        _apkInfo?.dispose();
        _apkInfo = null;
        _ipaMeta = null;
        _filePath = path;
        _isXapk = false;
        _parsing = false;
        _parseFailed = false;
        _selectedSplits.clear();
      });
      unawaited(_loadIpaMeta(path));
      await _refreshIos();
      return;
    }
    final isXapk = lower.endsWith('.xapk') || lower.endsWith('.apks');
    final generation = ++_parseGeneration;

    setState(() {
      _apkInfo?.dispose();
      _apkInfo = null;
      _parseFailed = false;
      _parsing = true;
      _filePath = path;
      _isXapk = isXapk;
      _selectedSplits.clear();
    });

    if (isXapk) unawaited(_loadSplits(path));
    await _loadApkInfo(path, generation);
  }

  /// 读 IPA 的 Info.plist。失败静默（文件条退回文件名），只记日志。
  Future<void> _loadIpaMeta(String path) async {
    final loader = widget.ipaMetaLoader ?? IpaInstallMetadata.read;
    final meta = await loader(path);
    if (!mounted || _filePath != path) return; // 期间换了包
    setState(() => _ipaMeta = meta);
  }

  Future<void> _loadSplits(String path) async {
    try {
      final splits = await XapkInstaller().getSplitApks(path);
      if (!mounted || splits == null) return;
      setState(() {
        for (final split in splits) {
          _selectedSplits[split] = true;
        }
      });
    } catch (e) {
      log.warning('InstallPage: 读取分包失败: $e');
    }
  }

  /// 读应用信息（图标 / 名称 / 版本 / 包名）。
  ///
  /// 走的是与分析页同一条 `getApkInfo` 流水线 —— 安装页不该为了「显示个
  /// 图标」另写一套解析。代价是分包包会走 aapt2、大包要几秒，因此有
  /// [_parsing] 状态；且**失败不影响安装**（安装只用路径）。
  Future<void> _loadApkInfo(String path, int generation) async {
    try {
      final info = await (widget.apkInfoLoader ?? getApkInfo).call(path);
      if (!mounted || generation != _parseGeneration) {
        info?.dispose();
        return;
      }
      setState(() {
        _apkInfo = info;
        _parsing = false;
        _parseFailed = info == null;
      });
    } catch (e) {
      log.warning('InstallPage: 读取应用信息失败: $e');
      if (!mounted || generation != _parseGeneration) return;
      setState(() {
        _parsing = false;
        _parseFailed = true;
      });
    }
  }

  void _clearFile() {
    _parseGeneration++;
    setState(() {
      _apkInfo?.dispose();
      _apkInfo = null;
      _ipaMeta = null;
      _filePath = null;
      _isXapk = false;
      _parsing = false;
      _parseFailed = false;
      _selectedSplits.clear();
    });
  }

  // ---------------------------------------------------------------- 设备

  /// 读一次 adb 版本，失败保持空（页脚退化为 `ADB · LOCAL`）。
  Future<void> _loadAdbVersion() async {
    try {
      final version = await AdbService.version();
      if (!mounted) return;
      if (version != null && version.isNotEmpty) {
        setState(() => _adbVersion = version);
      }
    } catch (e) {
      log.fine('InstallPage: 读取 adb 版本失败: $e');
    }
  }

  Future<void> _refreshDevices() async {
    if (_loadingDevices) return;
    setState(() => _loadingDevices = true);
    // 生产路径：adb 可执行文件缺失要显性化，不能折成“没有找到设备”。
    final adbMissing =
        widget.deviceLoader == null && AdbService.adbExecutable == null;
    if (adbMissing) {
      setState(() {
        _adbMissing = true;
        _loadingDevices = false;
      });
      return;
    }
    try {
      final devices =
          await (widget.deviceLoader ?? AdbService.listDevices).call();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _adbMissing = false;
        _loadingDevices = false;
        final usable = {
          for (final device in devices)
            if (device.isUsable) device.id,
        };
        _selected.removeWhere((id) => !usable.contains(id));
        _states.removeWhere((id, _) => !usable.contains(id));
        for (final id in usable) {
          if (!_states.containsKey(id)) _selected.add(id);
        }
      });
      await _loadDeviceInfo(devices);
    } catch (e) {
      log.warning('InstallPage: 枚举设备失败: $e');
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  /// 读取每台可用设备的品牌 / 型号 / 系统版本。
  ///
  /// 这些信息只用于展示，**拿不到就不显示**，绝不因此把设备标成不可用。
  Future<void> _loadDeviceInfo(List<AdbDevice> devices) async {
    final loader = widget.deviceInfoLoader ?? AdbService.deviceInfo;
    for (final device in devices.where((d) => d.isUsable)) {
      if (_deviceInfo.containsKey(device.id)) continue;
      try {
        final info = await loader(device.id);
        if (!mounted) return;
        if (info == null) continue;
        setState(() => _deviceInfo[device.id] = info);
        await KnownDeviceStore.remember(
          id: device.id,
          wireless: device.isWireless,
          info: info,
        );
      } catch (e) {
        log.warning('InstallPage: 读取 ${device.id} 信息失败: $e');
      }
    }
    if (!mounted) return;
    setState(() => _known = KnownDeviceStore.load());
  }

  Future<void> _connectKnown(KnownAdbDevice device) async {
    final result = await AdbService.connect(device.id);
    if (!mounted) return;
    if (!result.ok) {
      _snack('${t.install.wireless_connect}: ${result.output}');
      return;
    }
    await _refreshDevices();
  }

  Future<void> _forgetKnown(KnownAdbDevice device) async {
    await KnownDeviceStore.forget(device.id);
    if (!mounted) return;
    setState(() => _known = KnownDeviceStore.load());
  }

  Future<void> _openPairDialog() async {
    // 对话框返回**配对成功的 IP**（不是 bool）：配对之后还要用这个 IP
    // 引导用户去连接。
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => const _WirelessPairDialog(),
    );
    if (ip == null) return;
    await _refreshDevices();
    if (!mounted) return;

    // 配对成功后 adb 通常会自动把设备连上。没连上的话，用户多半不知道
    // 下一步该填什么 —— 必须明确告诉他「去手机抄连接端口」。
    final connected =
        _devices.any((d) => d.isWireless && d.id.startsWith('$ip:'));
    if (connected) return;

    final goConnect = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.install.pair_done_no_connection),
        content: Text(t.install.pair_done_no_connection_hint),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.base.close),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.install.pair_done_go_connect),
          ),
        ],
      ),
    );
    if (goConnect == true) await _openConnectDialog(initialAddress: ip);
  }

  Future<void> _openConnectDialog({String? initialAddress}) async {
    final connected = await showDialog<bool>(
      context: context,
      builder: (context) =>
          _WirelessConnectDialog(initialAddress: initialAddress),
    );
    if (connected == true) await _refreshDevices();
  }

  Future<void> _disconnect(AdbDevice device) async {
    final result = await AdbService.disconnect(device.id);
    if (!mounted) return;
    if (!result.ok) {
      _snack('${t.install.wireless_disconnect_failed}: ${result.output}');
      return;
    }
    await _refreshDevices();
  }

  // ---------------------------------------------------------------- 安装

  bool get _canInstall =>
      !_installing && _filePath != null && _selected.isNotEmpty;

  void _appendLog(String line) {
    final text = line.trimRight();
    if (text.isEmpty) return;
    if (!mounted) return;
    setState(() => _logs.add(text));
    // 新行进来后滚到底：用户盯着的是最后一行。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScroll.hasClients) return;
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  Future<void> _startInstall() async {
    if (!_canInstall) return;
    setState(() {
      _installing = true;
      _cancelled = false;
      _logs.clear();
      for (final id in _selected) {
        _states[id] = _DeviceState();
      }
    });

    final options = <String>[
      if (_allowDowngrade) '-d',
      if (_forceInstall) '-r',
      if (_allowTest) '-t',
      if (_grantAllPermissions) '-g',
    ];

    try {
      for (final id in _selected.toList()) {
        if (_cancelled || !mounted) break;
        await _installOn(id, options);
      }
    } finally {
      if (mounted) {
        setState(() {
          _installing = false;
          _currentProcess = null;
          _currentInstaller = null;
        });
      }
    }
  }

  Future<void> _installOn(String deviceId, List<String> options) async {
    AdbDevice? device;
    for (final candidate in _devices) {
      if (candidate.id == deviceId) {
        device = candidate;
        break;
      }
    }
    _appendLog(t.install.log_install_started(
      device: _deviceLabel(device, deviceId),
    ));

    setState(() {
      _states[deviceId] = _DeviceState()
        ..phase = _Phase.installing
        ..message = t.install.installing;
    });

    try {
      // 先卸载：签名不一致时 `-r` 必然失败，而重打包的包几乎一定签名不同。
      if (_uninstallFirst) {
        final packageName = _apkInfo?.packageName;
        if (packageName == null || packageName.isEmpty) {
          _appendLog('uninstall skipped: package name unknown');
        } else {
          _appendLog(t.install.log_uninstall(package: packageName));
          await AdbService.uninstall(deviceId, packageName);
        }
      }

      bool ok;
      String? error;
      if (_isXapk) {
        final installer = XapkInstaller();
        _currentInstaller = installer;
        ok = await installer.install(
          _filePath!,
          deviceId,
          options,
          selectedSplits: _selectedSplits,
          isCancelled: () => _cancelled,
          onLog: _appendLog,
        );
        _currentInstaller = null;
        if (!ok && !_cancelled) {
          error = _localizedInstallError(
            installer.lastOutput,
            t,
            -1,
          );
        }
      } else {
        final process = await Process.start(
          _adbExecutable,
          ['-s', deviceId, 'install', ...options, _filePath!],
        );
        _currentProcess = process;
        final stdoutBuffer = StringBuffer();
        final stderrBuffer = StringBuffer();
        process.stdout
            .transform(const SystemEncoding().decoder)
            .listen((chunk) {
          stdoutBuffer.write(chunk);
          _appendLog(chunk);
        });
        process.stderr
            .transform(const SystemEncoding().decoder)
            .listen((chunk) {
          stderrBuffer.write(chunk);
          _appendLog(chunk);
        });
        final exitCode = await process.exitCode;
        _currentProcess = null;
        ok = exitCode == 0;
        _appendLog('exit code: $exitCode');
        if (!ok) {
          final raw = stderrBuffer.toString().trim().isNotEmpty
              ? stderrBuffer.toString().trim()
              : stdoutBuffer.toString().trim();
          error = _localizedInstallError(raw, t, exitCode);
        }
      }

      if (!mounted) return;
      if (_cancelled) {
        setState(() {
          _states[deviceId] = _DeviceState()
            ..phase = _Phase.stopped
            ..message = t.install.stopped;
        });
        return;
      }
      _rememberInstall(deviceId, ok: ok);
      setState(() {
        _states[deviceId] = _DeviceState()
          ..phase = ok ? _Phase.success : _Phase.failed
          ..message = ok ? t.install.success : (error ?? t.install.failed);
        if (ok) _selected.remove(deviceId);
      });
    } catch (e) {
      if (!mounted) return;
      _appendLog('$e');
      if (!_cancelled) _rememberInstall(deviceId, ok: false);
      setState(() {
        _states[deviceId] = _DeviceState()
          ..phase = _cancelled ? _Phase.stopped : _Phase.failed
          ..message = _cancelled ? t.install.stopped : '$e';
      });
    }
  }

  String get _adbExecutable => _adbPath ?? 'adb';

  String? get _adbPath => AdbService.adbExecutable;

  void _stopInstall() {
    setState(() => _cancelled = true);
    _currentProcess?.kill();
    _currentInstaller?.cancel();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 被 `IndexedStack` 盖住时必须把 target 关掉。
    //
    // `desktop_drop` 的通道是**全局扇出**的：每个 `DropTarget` 各自按渲染盒
    // 判「是否在界内」，而 `IndexedStack` 里各页尺寸完全重叠，于是不可见的页
    // 也会收到同一次拖放 —— 拖一个 APK 到概览页会同时被安装页接住。
    final visible = Visibility.of(context);
    return DropTarget(
      enable: visible,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        if (details.files.isEmpty) return;
        unawaited(_setFile(details.files.first.path));
      },
      child: Container(
        color: _dragging
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
            : null,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 宽窗走 V4 的两栏：左栏自己滚，右栏控制台拉满高度。
            // 高度无界时（被塞进外层 Column/ScrollView）必须退回单列，
            // 否则这里的 `Expanded` 会直接抛 unbounded height。
            final wide =
                constraints.maxWidth >= 1000 && constraints.hasBoundedHeight;
            final header = _buildHeader(theme);
            final column = _buildLeftColumn(theme);
            final console = _buildConsole(theme);
            return Padding(
              padding: const EdgeInsets.all(18),
              child: wide
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        const SizedBox(height: 16),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: SingleChildScrollView(child: column),
                              ),
                              const SizedBox(width: 14),
                              SizedBox(width: 430, child: console),
                            ],
                          ),
                        ),
                      ],
                    )
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          header,
                          const SizedBox(height: 14),
                          column,
                          const SizedBox(height: 12),
                          SizedBox(height: 240, child: console),
                        ],
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }

  /// 页头：kicker + 标题 + 副标题 + 右侧「adb 状态 chip + 刷新」。
  Widget _buildHeader(ThemeData theme) {
    final connected = _devices.any((device) => device.isUsable);
    final String label;
    final Color color;
    final IconData icon;
    if (_adbMissing) {
      label = t.install.adb_missing_chip;
      color = V4Colors.danger;
      icon = Icons.error_outline;
    } else if (connected) {
      label = t.install.adb_connected;
      color = V4Colors.mint;
      icon = Icons.check_circle_outline;
    } else {
      label = t.install.adb_idle;
      color = V4Colors.amber;
      icon = Icons.usb;
    }
    return PageHeader(
      kicker: t.install.kicker,
      title: t.nav.install,
      subtitle: t.install.subtitle,
      actions: [
        _chip(
          label,
          icon: icon,
          color: color,
          background: color.withValues(alpha: 0.09),
        ),
        _squareIconButton(
          icon: Icons.refresh,
          tooltip: t.install.refresh_devices,
          busy: _loadingDevices,
          onPressed: _loadingDevices ? null : _refreshDevices,
        ),
      ],
    );
  }

  Widget _buildLeftColumn(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFileCard(theme),
        const SizedBox(height: 12),
        if (_isIpa) _buildIosCard(theme) else _buildDeviceCard(theme),
        if (!_isIpa) ...[
          const SizedBox(height: 12),
          _buildOptionsCard(theme),
        ],
        const SizedBox(height: 12),
        _buildRecentCard(theme),
      ],
    );
  }

  // ---- 通用小件 ----

  /// 等宽小字：V4 里所有技术味的信息（包名、序列号、flag）都用它。
  static TextStyle _mono({
    double size = 8.5,
    Color? color,
    FontWeight weight = FontWeight.w600,
    double letterSpacing = 0.4,
    double? height,
  }) {
    return TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Courier'],
      fontSize: size,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      height: height,
      color: color,
    );
  }

  Widget _chip(
    String label, {
    IconData? icon,
    Color? color,
    Color? background,
    bool bordered = true,
  }) {
    final theme = Theme.of(context);
    final fg = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      height: 22,
      padding: EdgeInsets.symmetric(horizontal: icon == null ? 8 : 6),
      decoration: BoxDecoration(
        color: background ?? Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        border: bordered
            ? Border.all(
                color: color == null
                    ? theme.colorScheme.outlineVariant
                    : color.withValues(alpha: 0.32),
              )
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 9, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            maxLines: 1,
            style: _mono(size: 8.5, color: fg, letterSpacing: 0.5),
          ),
        ],
      ),
    );
  }

  /// 方形的描边图标按钮（页头刷新、清除安装包、断开无线）。
  Widget _squareIconButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
    bool busy = false,
    double size = 32,
  }) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: IconButton(
          onPressed: onPressed,
          iconSize: size * 0.46,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.surface,
            disabledBackgroundColor: theme.colorScheme.surface,
            side: BorderSide(color: theme.colorScheme.outlineVariant),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            minimumSize: Size.square(size),
            maximumSize: Size.square(size),
            padding: EdgeInsets.zero,
          ),
          icon: busy
              ? SizedBox(
                  width: size * 0.4,
                  height: size * 0.4,
                  child: const CircularProgressIndicator(strokeWidth: 1.6),
                )
              : Icon(icon),
        ),
      ),
    );
  }

  Widget _smallButton({
    required IconData icon,
    required String label,
    VoidCallback? onPressed,
    bool busy = false,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 30,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: busy
            ? const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            : Icon(icon, size: 13),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          textStyle:
              const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  /// 卡片外壳：白底 + 1px 描边 + 20px 圆角（V4 `.card`）。
  ///
  /// 用 `Material` 而不是裸 `Container`：卡片里到处是 `InkWell`（选项行、
  /// 文件条、已保存设备），没有 Material 祖先它们连水波纹都建不出来。
  Widget _card(
    ThemeData theme, {
    required List<Widget> children,
    EdgeInsets? padding,
  }) {
    return Material(
      color: theme.colorScheme.surface,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(V4Radius.card),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: padding ?? EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _cardHead(
    ThemeData theme, {
    required IconData icon,
    required String title,
    List<Widget> trailing = const [],
    EdgeInsets padding = const EdgeInsets.fromLTRB(18, 15, 14, 10),
  }) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }

  /// 复选方框：20×20、6px 圆角，勾上时用主题强调色。
  Widget _checkBox({
    required bool value,
    required bool enabled,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final accent = V4Colors.violet;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: value ? accent : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: value ? accent : theme.colorScheme.outline,
                width: 1.5,
              ),
            ),
            child: value
                ? const Icon(Icons.check, size: 11, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }

  // ---- 安装包 ----

  Widget _buildFileCard(ThemeData theme) {
    final path = _filePath;
    if (path == null) {
      return _card(
        theme,
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
        children: [
          Text(
            t.install.file_section,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 10),
          InkWell(
            onTap: _pickFile,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 84,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.upload_file_outlined,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t.install.drop_hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final info = _apkInfo;
    final ipa = _ipaMeta;
    // .ipa 的元数据来自 Info.plist（`_ipaMeta`），APK 来自 aapt2/内置解析。
    // 两侧都取不到时退回文件名 —— 不显示空标题。
    final name = _isIpa
        ? ((ipa?.displayName?.isNotEmpty ?? false)
            ? ipa!.displayName!
            : p.basename(path))
        : ((info?.label?.isNotEmpty ?? false)
            ? info!.label!
            : p.basename(path));
    final version = _isIpa ? ipa?.version : info?.versionName;
    final title =
        (version == null || version.isEmpty) ? name : '$name · $version';
    final abis =
        _isIpa ? const <String>[] : (info?.nativeCodes ?? const <String>[]);
    final minSdk = _isIpa ? null : info?.sdkVersion;
    final packageId = _isIpa ? ipa?.bundleIdentifier : info?.packageName;
    return _card(
      theme,
      padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
      children: [
        Row(
          children: [
            Expanded(
              // 整条文件条就是「换一个包」，但只有一个可点区域不够明显：
              // 补一条 Tooltip，键盘/读屏用户也能知道点它有反应。
              child: Tooltip(
                message: t.install.change_file,
                child: InkWell(
                  onTap: _installing ? null : _pickFile,
                  borderRadius: BorderRadius.circular(10),
                  child: Row(
                    children: [
                      _formatBadge(theme),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _fileText(
                          theme,
                          title,
                          packageId,
                          abis,
                          build: _isIpa ? ipa?.buildNumber : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _chip(_splitCountLabel()),
            if (minSdk != null) ...[
              const SizedBox(width: 6),
              _chip('minSdk $minSdk'),
            ],
            if (packageId != null && packageId.isNotEmpty) ...[
              const SizedBox(width: 6),
              _chip(
                _installedBefore(packageId)
                    ? t.install.installed_before
                    : t.install.never_installed,
              ),
            ],
            const SizedBox(width: 8),
            _squareIconButton(
              icon: Icons.close,
              tooltip: t.install.clear_file,
              onPressed: _installing ? null : _clearFile,
              size: 30,
            ),
          ],
        ),
      ],
    );
  }

  /// 本机是否装过这个包。
  ///
  /// 只认本工具自己记录过的成功安装 —— 「设备上有没有这个包」要连上设备问
  /// `pm list packages`，那是另一个需要授权与耗时的动作，不能塞进选包流程。
  /// 所以这个提示措辞是「未安装过」，不是「设备上没有」。
  bool _installedBefore(String packageName) {
    return _recent.any((r) => r.ok && r.packageName == packageName);
  }

  /// 格式角标：有图标时显示图标，底部压一条格式带（APK / XAPK / APKS）。
  Widget _formatBadge(ThemeData theme) {
    final lower = (_filePath ?? '').toLowerCase();
    final format = lower.endsWith('.ipa')
        ? 'IPA'
        : _isXapk
            ? (lower.endsWith('.apks') ? 'APKS' : 'XAPK')
            : 'APK';
    final image = _apkInfo?.mainIconImage;
    return Container(
      width: 38,
      height: 42,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: V4Colors.gradient,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null) RawImage(image: image, fit: BoxFit.cover),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              color: const Color(0x99000000),
              alignment: Alignment.center,
              child: Text(
                format,
                style: _mono(
                  size: 6.5,
                  color: Colors.white,
                  weight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileText(
    ThemeData theme,
    String title,
    String? package,
    List<String> abis, {
    String? build,
  }) {
    final info = _apkInfo;
    final size = _formatBytes(info?.apkSize ?? _fileSize(_filePath));
    final meta = <String>[
      if (package != null && package.isNotEmpty) package,
      if (size.isNotEmpty) size,
      if (build != null && build.isNotEmpty) 'build $build',
      if (_parsing) t.install.app_parsing,
      if (!_parsing && _parseFailed) t.install.app_info_failed,
      if (abis.isNotEmpty) abis.take(2).join(' + '),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          meta.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _mono(
            size: 8.5,
            weight: FontWeight.w500,
            color: _parseFailed
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 分包包的 `已勾选 / 总数`；单 APK 固定 `1 / 1`。
  ///
  /// `getSplitApks` 返回的就是安装时要逐个装的全部条目（base 排在第一个），
  /// 所以总数直接取勾选表的长度，不能再 +1。
  String _splitCountLabel() {
    if (_isXapk && _selectedSplits.isNotEmpty) {
      final total = _selectedSplits.length;
      final picked = _selectedSplits.values.where((v) => v).length;
      return '$picked / $total';
    }
    return '1 / 1';
  }

  static int _fileSize(String? path) {
    if (path == null) return 0;
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  // ---- 设备 ----

  // ---------------------------------------------------------------- iOS

  /// 探测 libimobiledevice 并枚举 iOS 设备。
  ///
  /// 工具缺失不是错误：页面要能说清楚「缺什么、怎么装」，而不是只显示空列表。
  Future<void> _refreshIos() async {
    if (!_isIpa) return;
    setState(() => _iosLoading = true);
    final toolchain = widget.iosToolchain ?? IosToolchain.detect();
    var devices = const <IosDevice>[];
    if (toolchain.available) {
      devices = await IosInstallService(toolchain: toolchain).listDevices();
    }
    if (!mounted) return;
    setState(() {
      _iosToolchain = toolchain;
      _iosDevices = devices;
      _iosLoading = false;
    });
  }

  Widget _buildIosCard(ThemeData theme) {
    final toolchain = _iosToolchain;
    final ready = toolchain?.available ?? false;
    return _card(
      theme,
      children: [
        _cardHead(
          theme,
          icon: Icons.phone_iphone,
          title: t.install.ios_section,
          trailing: [
            _chip(
              ready ? t.install.ios_status_ready : t.install.ios_status_missing,
              color: ready ? V4Colors.mint : V4Colors.amber,
              background: (ready ? V4Colors.mint : V4Colors.amber).withValues(
                alpha: 0.09,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 15),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!ready)
                _iosMissingBlock(theme)
              else if (_iosDevices.isEmpty)
                _iosNoDeviceBlock(theme)
              else
                for (final device in _iosDevices)
                  _buildIosDeviceRow(theme, device),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _smallButton(
                    icon: Icons.refresh,
                    label: t.install.refresh_devices,
                    busy: _iosLoading,
                    onPressed: _iosLoading || _installing ? null : _refreshIos,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _iosMissingBlock(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: V4Colors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: V4Colors.amber.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.install.ios_toolchain_hint,
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 6),
          SelectableText(
            'brew install libimobiledevice ideviceinstaller',
            style: _mono(size: 9, color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _iosNoDeviceBlock(ThemeData theme) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      alignment: Alignment.center,
      child: Text(
        t.install.ios_no_devices,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 10.5,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildIosDeviceRow(ThemeData theme, IosDevice device) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.phone_iphone,
              size: 17,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'iOS ${device.version}'
                  '${device.model == null ? '' : ' · ${device.model}'}',
                  style: _mono(
                    size: 8,
                    weight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _installing ? null : () => _installIos(device),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            child: Text(t.install.ios_install),
          ),
        ],
      ),
    );
  }

  Future<void> _installIos(IosDevice device) async {
    final path = _filePath;
    final toolchain = _iosToolchain;
    if (path == null || toolchain == null || !toolchain.available) return;
    setState(() {
      _installing = true;
      _logs.clear();
    });
    _appendLog(t.install.log_install_started(device: device.name));
    bool ok = false;
    try {
      ok = await IosInstallService(toolchain: toolchain).install(
        path,
        udid: device.udid,
        onLine: _appendLog,
      );
    } catch (e) {
      _appendLog('$e');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
    if (!mounted || !ok) return;
    final record = InstallRecord(
      fileName: p.basename(path),
      size: _formatBytes(_fileSize(path)),
      device: device.name,
      packageName: null,
      ok: true,
      at: DateTime.now(),
    );
    final records = await InstallHistoryManager.add(record);
    if (!mounted) return;
    setState(() => _recent = records);
    _snack(t.install.ios_installed);
  }

  Widget _buildDeviceCard(ThemeData theme) {
    final knownWireless = _known
        .where((d) => d.wireless && !_devices.any((x) => x.id == d.id))
        .toList();
    return _card(
      theme,
      children: [
        _cardHead(
          theme,
          icon: Icons.phone_iphone,
          title: t.install.device_section,
          trailing: _deviceHeadChips(theme),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 15),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_adbMissing)
                _adbMissingBlock(theme)
              else if (_devices.isEmpty)
                _noDeviceBlock(theme)
              else
                for (var i = 0; i < _devices.length; i++)
                  _buildDeviceRow(theme, _devices[i], first: i == 0),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _smallButton(
                    icon: Icons.refresh,
                    label: t.install.refresh_devices,
                    busy: _loadingDevices,
                    onPressed: _loadingDevices ? null : _refreshDevices,
                  ),
                  _smallButton(
                    icon: Icons.wifi_password,
                    label: t.install.wireless_pair,
                    onPressed: _installing ? null : _openPairDialog,
                  ),
                  _smallButton(
                    icon: Icons.link,
                    label: t.install.wireless_connect,
                    onPressed: _installing ? null : _openConnectDialog,
                  ),
                ],
              ),
              if (knownWireless.isNotEmpty) ...[
                const SizedBox(height: 12),
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
                const SizedBox(height: 9),
                Text(
                  t.install.saved_devices,
                  style: _mono(
                    size: 8,
                    weight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.8,
                    ),
                  ),
                ),
                for (final device in knownWireless)
                  _buildKnownRow(theme, device),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 卡片头右侧：第一台设备的传输方式与状态（原型是 `ONLINE` + `USB`）。
  List<Widget> _deviceHeadChips(ThemeData theme) {
    if (_devices.isEmpty) return const [];
    final first = _devices.first;
    final Color color;
    if (first.isUsable) {
      color = V4Colors.mint;
    } else if (first.isUnauthorized) {
      color = V4Colors.danger;
    } else {
      color = V4Colors.amber;
    }
    return [
      _chip(
        first.isUsable ? 'ONLINE' : _statusLabel(first),
        color: color,
        background: color.withValues(alpha: 0.09),
      ),
      const SizedBox(width: 6),
      _chip(first.isWireless ? 'WIFI' : 'USB'),
    ];
  }

  String _statusLabel(AdbDevice device) {
    if (device.isUnauthorized) return t.install.status_unauthorized;
    if (device.isOffline) return t.install.status_offline;
    return device.status.toUpperCase();
  }

  Widget _buildDeviceRow(
    ThemeData theme,
    AdbDevice device, {
    bool first = false,
  }) {
    final state = _states[device.id];
    final info = _deviceInfo[device.id];
    final selected = _selected.contains(device.id);
    final selectable = device.isUsable && !_installing;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: first
            ? null
            : Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          _checkBox(
            value: selected,
            enabled: selectable,
            onTap: selectable
                ? () => setState(() {
                      if (selected) {
                        _selected.remove(device.id);
                      } else {
                        _selected.add(device.id);
                      }
                    })
                : null,
          ),
          const SizedBox(width: 10),
          Container(
            width: 40,
            height: 46,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.18),
                width: 1.2,
              ),
            ),
            child: Icon(
              device.isWireless ? Icons.smartphone : Icons.usb,
              size: 17,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _deviceLabel(device, device.id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    if (!device.isUsable) ...[
                      const SizedBox(width: 6),
                      _statusChip(theme, device),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _deviceSubtitle(device, info, state?.message),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _mono(
                    size: 8.5,
                    weight: FontWeight.w500,
                    color: _messageColor(theme, state),
                  ),
                ),
              ],
            ),
          ),
          if (device.isWireless)
            _squareIconButton(
              icon: Icons.wifi_off,
              tooltip: t.install.wireless_disconnect,
              onPressed: _installing ? null : () => _disconnect(device),
              size: 28,
            ),
        ],
      ),
    );
  }

  Widget _adbMissingBlock(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.install.adb_missing,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          t.install.adb_missing_hint,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 10.5,
            height: 1.45,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        _smallButton(
          icon: Icons.settings_outlined,
          label: t.install.open_settings,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingPage()),
          ),
        ),
      ],
    );
  }

  Widget _noDeviceBlock(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.install.no_devices,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          t.install.no_devices_hint,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 10.5,
            height: 1.45,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// `samsung SM_G9910` —— 品牌 + 型号；读不到时退回 adb 给的代号。
  String _deviceLabel(AdbDevice? device, String fallbackId) {
    final info = _deviceInfo[fallbackId];
    final model = info?.model;
    if (model != null && model.isNotEmpty) {
      final brand = info?.brand;
      return (brand == null || brand.isEmpty) ? model : '$brand $model';
    }
    return device?.displayName ?? fallbackId;
  }

  /// `Android 15 · 192.168.1.5:5555 · <本次提示>`。
  String _deviceSubtitle(
    AdbDevice device,
    AdbDeviceInfo? info,
    String? message,
  ) {
    final system = info?.systemVersion;
    final abi = info?.abi;
    final free = info?.freeBytes;
    final parts = <String>[
      if (system != null && system.isNotEmpty) 'Android $system',
      if (abi != null && abi.isNotEmpty) abi,
      if (free != null) '${_formatBytes(free)} ${t.install.free_space_suffix}',
      device.id,
      if (message != null && message.isNotEmpty) message,
    ];
    return parts.join(' · ');
  }

  AdbDevice? _deviceById(String id) {
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  Widget _buildKnownRow(ThemeData theme, KnownAdbDevice device) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            Icons.wifi,
            size: 13,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _knownLabel(device),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  _knownSubtitle(device),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _mono(
                    size: 8,
                    weight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _installing ? null : () => _connectKnown(device),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 26),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle:
                  const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
            ),
            child: Text(t.install.saved_connect),
          ),
          _squareIconButton(
            icon: Icons.close,
            tooltip: t.install.saved_forget,
            onPressed: _installing ? null : () => _forgetKnown(device),
            size: 24,
          ),
        ],
      ),
    );
  }

  String _knownLabel(KnownAdbDevice device) {
    final model = device.info.model;
    if (model == null || model.isEmpty) return device.id;
    final brand = device.info.brand;
    return (brand == null || brand.isEmpty) ? model : '$brand $model';
  }

  String _knownSubtitle(KnownAdbDevice device) {
    final parts = <String>[device.id];
    final system = device.info.systemVersion;
    if (system != null && system.isNotEmpty) parts.add('Android $system');
    return parts.join(' · ');
  }

  Color _messageColor(ThemeData theme, _DeviceState? state) {
    switch (state?.phase) {
      case _Phase.failed:
        return theme.colorScheme.error;
      case _Phase.success:
        return V4Colors.mint;
      default:
        return theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8);
    }
  }

  Widget _statusChip(ThemeData theme, AdbDevice device) {
    final color = device.isUnauthorized ? V4Colors.danger : V4Colors.amber;
    return _chip(
      _statusLabel(device),
      color: color,
      background: color.withValues(alpha: 0.09),
    );
  }

  // ---- 选项 ----

  Widget _buildOptionsCard(ThemeData theme) {
    final packageName = _apkInfo?.packageName;
    final canUninstall = packageName != null && packageName.isNotEmpty;
    return _card(
      theme,
      children: [
        _cardHead(
          theme,
          icon: Icons.tune,
          title: t.install.advanced_options,
          trailing: [
            _chip(
              t.install.on_demand,
              color: theme.colorScheme.onSurfaceVariant,
              bordered: false,
            ),
          ],
        ),
        _optionRow(
          theme,
          title: t.install.force_install,
          flag: '-r',
          value: _forceInstall,
          onChanged: _installing
              ? null
              : () => setState(() => _forceInstall = !_forceInstall),
        ),
        _optionRow(
          theme,
          title: t.install.uninstall_first,
          subtitle: canUninstall
              ? t.install.uninstall_first_desc
              : t.install.app_info_failed,
          value: _uninstallFirst,
          // 没有包名就没法卸载 —— 灰掉而不是让用户点了才发现没生效。
          onChanged: (_installing || !canUninstall)
              ? null
              : () => setState(() => _uninstallFirst = !_uninstallFirst),
        ),
        _optionRow(
          theme,
          title: t.install.allow_downgrade,
          flag: '-d',
          value: _allowDowngrade,
          onChanged: _installing
              ? null
              : () => setState(() => _allowDowngrade = !_allowDowngrade),
        ),
        _optionRow(
          theme,
          title: t.install.allow_test,
          flag: '-t',
          value: _allowTest,
          onChanged: _installing
              ? null
              : () => setState(() => _allowTest = !_allowTest),
        ),
        _optionRow(
          theme,
          title: t.install.grant_all_permissions,
          subtitle: t.install.grant_all_permissions_desc,
          flag: '-g',
          value: _grantAllPermissions,
          onChanged: _installing
              ? null
              : () => setState(
                    () => _grantAllPermissions = !_grantAllPermissions,
                  ),
        ),
        if (_selectedSplits.isNotEmpty) ...[
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 10, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t.install.split_options,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _installing
                      ? null
                      : () => setState(() {
                            final all = _selectedSplits.values.every((v) => v);
                            for (final key in _selectedSplits.keys.toList()) {
                              _selectedSplits[key] = !all;
                            }
                          }),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: Text(
                    _selectedSplits.values.every((v) => v)
                        ? t.install.base_only
                        : t.install.select_all,
                  ),
                ),
              ],
            ),
          ),
          for (final split in _selectedSplits.keys) _splitRow(theme, split),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          child: _installCta(theme),
        ),
        _ctaCaption(theme),
        _installNote(theme),
      ],
    );
  }

  Widget _optionRow(
    ThemeData theme, {
    required String title,
    String? subtitle,
    String? flag,
    required bool value,
    required VoidCallback? onChanged,
  }) {
    final enabled = onChanged != null;
    return InkWell(
      onTap: onChanged,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _checkBox(value: value, enabled: enabled, onTap: onChanged),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? null
                          : theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 9.5,
                        height: 1.45,
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (flag != null)
              Padding(
                padding: const EdgeInsets.only(left: 10, top: 3),
                child: Text(
                  flag,
                  style: _mono(
                    size: 8,
                    weight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _splitRow(ThemeData theme, String split) {
    final value = _selectedSplits[split] ?? false;
    return InkWell(
      onTap: _installing
          ? null
          : () => setState(() => _selectedSplits[split] = !value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(44, 3, 18, 3),
        child: Row(
          children: [
            _checkBox(value: value, enabled: !_installing, onTap: null),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                split,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _mono(
                  size: 8.5,
                  weight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 主按钮：渐变底 + 上传图标；安装中变成「停止」。
  Widget _installCta(ThemeData theme) {
    final enabled = _canInstall || _installing;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Container(
        height: 45,
        decoration: BoxDecoration(
          gradient: V4Colors.gradient,
          borderRadius: BorderRadius.circular(13),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: V4Colors.violet.withValues(alpha: 0.35),
                    blurRadius: 26,
                    offset: const Offset(0, 12),
                    spreadRadius: -14,
                  ),
                ]
              : null,
        ),
        child: SizedBox(
          width: double.infinity,
          height: 45,
          child: FilledButton.icon(
            onPressed: _installing
                ? _stopInstall
                : (_canInstall ? _startInstall : null),
            icon: Icon(
              _installing ? Icons.stop_rounded : Icons.upload_rounded,
              size: 15,
            ),
            label: Text(
              _ctaLabel(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.transparent,
              disabledBackgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white,
              shadowColor: Colors.transparent,
              elevation: 0,
              minimumSize: const Size(0, 45),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
              ),
              textStyle: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _ctaLabel() {
    if (_installing) return t.install.stop;
    if (_selected.length == 1) {
      final id = _selected.first;
      return '${t.install.start} · ${_deviceLabel(_deviceById(id), id)}';
    }
    return t.install.start;
  }

  /// 按钮下面那一行：不能安装时说清原因，安装中说明进度。
  Widget _ctaCaption(ThemeData theme) {
    final text = _installing ? t.install.installing : _blockReason();
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 11,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 琥珀色底注：这一页只负责「传输」，不负责「运行」。
  Widget _installNote(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 10, 18, 14),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: V4Colors.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.priority_high_rounded,
              size: 11,
              color: V4Colors.amber,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              t.install.note_install_not_run,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 9,
                height: 1.45,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 最近安装 ----

  Widget _buildRecentCard(ThemeData theme) {
    return _card(
      theme,
      children: [
        _cardHead(
          theme,
          icon: Icons.history,
          title: 'RECENT INSTALLS',
          trailing: [
            _chip(
              t.install.local_only,
              color: theme.colorScheme.onSurfaceVariant,
              bordered: false,
            ),
          ],
        ),
        Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.symmetric(
              horizontal: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              _th(theme, t.install.column_file, 3),
              _th(theme, t.install.column_device, 2),
              _th(theme, t.install.column_result, 2),
              _th(theme, t.install.column_when, 2),
            ],
          ),
        ),
        if (_recent.isEmpty)
          Container(
            height: 44,
            alignment: Alignment.center,
            child: Text(
              '—',
              style: _mono(
                size: 10,
                weight: FontWeight.w500,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.6,
                ),
              ),
            ),
          )
        else
          for (var i = 0; i < _recent.length; i++)
            _recentRow(theme, _recent[i], first: i == 0),
      ],
    );
  }

  Widget _th(ThemeData theme, String label, int flex) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        style: _mono(
          size: 7.5,
          weight: FontWeight.w600,
          letterSpacing: 1,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _recentRow(
    ThemeData theme,
    InstallRecord record, {
    bool first = false,
  }) {
    final color = record.ok ? V4Colors.mint : V4Colors.danger;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: first
            ? null
            : Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (record.size.isNotEmpty)
                  Text(
                    record.size,
                    maxLines: 1,
                    style: _mono(
                      size: 8,
                      weight: FontWeight.w500,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              record.device,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _chip(
                record.ok ? t.install.result_success : t.install.result_failed,
                color: color,
                background: color.withValues(alpha: 0.10),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _whenLabel(record.at),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _mono(
                size: 8,
                weight: FontWeight.w500,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 安装日志（深色控制台） ----

  Widget _buildConsole(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 11),
      decoration: BoxDecoration(
        color: _logSurface,
        borderRadius: BorderRadius.circular(V4Radius.panel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal_rounded, size: 12, color: _logViolet),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  t.install.log_title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _mono(
                    size: 8.5,
                    color: Colors.white.withValues(alpha: 0.65),
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: _logAccent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                'LIVE',
                style: _mono(
                  size: 7.5,
                  color: _logAccent,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Expanded(child: _buildLogBody(theme)),
          const SizedBox(height: 9),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.10)),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: Text(
                  _adbVersion == null
                      ? 'ADB · LOCAL'
                      : 'ADB $_adbVersion · LOCAL',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _mono(size: 7.5, color: _logMuted, letterSpacing: 0.9),
                ),
              ),
              _copyLogButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLogBody(ThemeData theme) {
    if (_logs.isEmpty) {
      return Center(
        child: Text(
          t.install.log_empty,
          style: _mono(
            size: 9,
            weight: FontWeight.w500,
            color: _logMuted,
            letterSpacing: 0.6,
          ),
        ),
      );
    }
    return Scrollbar(
      controller: _logScroll,
      child: SingleChildScrollView(
        controller: _logScroll,
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in _logs)
                Text(
                  line,
                  style: _mono(
                    size: 9.5,
                    weight: FontWeight.w500,
                    height: 1.75,
                    letterSpacing: 0.1,
                    color: _logLineColor(line),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Color _logLineColor(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('success') ||
        lower.contains('exit code: 0') ||
        line.contains('完成')) {
      return _logAccent;
    }
    if (lower.contains('failed') ||
        lower.contains('failure') ||
        lower.contains('error') ||
        lower.contains('exception')) {
      return const Color(0xFFFF9AA9);
    }
    return _logInk;
  }

  Widget _copyLogButton() {
    return SizedBox(
      height: 28,
      child: TextButton.icon(
        onPressed: _logs.isEmpty ? null : _copyLog,
        icon: const Icon(Icons.content_copy_rounded, size: 10),
        label: Text(t.install.copy_log),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white.withValues(alpha: 0.92),
          disabledForegroundColor: Colors.white.withValues(alpha: 0.35),
          backgroundColor: Colors.white.withValues(alpha: 0.10),
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.05),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: _mono(
            size: 7.5,
            weight: FontWeight.w700,
            letterSpacing: 0.9,
          ),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        ),
      ),
    );
  }

  Future<void> _copyLog() async {
    if (_logs.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _logs.join('\n')));
    if (!mounted) return;
    _snack(t.home.copied_content(content: t.install.log_title));
  }

  /// 往「最近安装」里插一条（落盘，最多 10 条）。
  ///
  /// 记录的是**已经发生过的安装尝试**：成功与失败都记，失败那条正是用户
  /// 回头排查时要看的东西。
  Future<void> _rememberInstall(String deviceId, {required bool ok}) async {
    final path = _filePath;
    final name = (_apkInfo?.label?.isNotEmpty ?? false)
        ? _apkInfo!.label!
        : (path == null ? t.install.file_section : p.basename(path));
    final records = await InstallHistoryManager.add(
      InstallRecord(
        fileName: name,
        size: _formatBytes(_apkInfo?.apkSize ?? _fileSize(path)),
        device: _deviceLabel(_deviceById(deviceId), deviceId),
        packageName: _apkInfo?.packageName,
        ok: ok,
        at: DateTime.now(),
      ),
    );
    if (!mounted) return;
    setState(() => _recent = records);
  }

  /// 当天只给 `14:32`，跨天补上 `11/21 14:32`。
  String _whenLabel(DateTime at) {
    final now = DateTime.now();
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    if (at.year == now.year && at.month == now.month && at.day == now.day) {
      return '$hh:$mm';
    }
    return '${at.month}/${at.day} $hh:$mm';
  }

  /// 不能安装时给出**具体原因**，而不是让按钮灰着不说话。
  String? _blockReason() {
    if (_filePath == null) return t.install.reason_no_file;
    if (_selected.isEmpty) return t.install.reason_no_device;
    return null;
  }
}

/// 无线配对对话框（Android 11+ 的「无线调试 → 使用配对码配对设备」）。
class _WirelessPairDialog extends StatefulWidget {
  const _WirelessPairDialog();

  @override
  State<_WirelessPairDialog> createState() => _WirelessPairDialogState();
}

class _WirelessPairDialogState extends State<_WirelessPairDialog> {
  final _addressController = TextEditingController();
  final _codeController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _addressController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // 配对端口是随机的（手机屏幕上那个），因此这里**不补默认端口** ——
    // 补了反而会连到一个不存在的端口上，报一句误导人的错。
    final address = AdbService.normalizeAddress(
      _addressController.text,
      defaultPort: null,
    );
    final code = _codeController.text.trim();
    if (address == null) {
      setState(() => _error = t.install.pair_invalid_address);
      return;
    }
    if (code.isEmpty) {
      setState(() => _error = t.install.pair_invalid_code);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AdbService.pair(address: address, code: code);
    if (!mounted) return;
    if (result.ok) {
      // 把 IP 传回去：配对之后还要用它引导「去连接」。
      final colon = address.lastIndexOf(':');
      Navigator.of(context).pop(
        colon > 0 ? address.substring(0, colon) : address,
      );
      return;
    }
    setState(() {
      _busy = false;
      _error = _describePairError(result.output);
    });
  }

  /// 把 `adb pair` 的原文翻成人话。
  ///
  /// 四种失败对应四种完全不同的动作，直接甩英文等于让用户自己猜：
  /// - 配对码错 → 重开一次配对弹窗（码会变）；
  /// - 连不上配对端口 → 手机可能已经退出了那个弹窗；
  /// - `protocol fault` → **填的是连接端口**（实测：拿连接端口去 pair 就是这句）；
  /// - 已配对 → 直接去连接。
  String _describePairError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('invalid code') || lower.contains('wrong password')) {
      return t.install.pair_error_invalid_code;
    }
    if (lower.contains('protocol fault')) {
      return t.install.pair_error_not_pairing_port;
    }
    if (lower.contains('already paired')) {
      return t.install.pair_error_already_paired;
    }
    if (lower.contains('unable to connect') ||
        lower.contains('connection refused') ||
        lower.contains('timed out') ||
        lower.contains('timeout')) {
      return t.install.pair_error_unreachable;
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.install.wireless_pair),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.install.pair_hint,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).hintColor)),
          const SizedBox(height: 12),
          TextField(
            controller: _addressController,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: t.install.pair_address,
              hintText: '192.168.1.5:37123',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _codeController,
            enabled: !_busy,
            decoration: InputDecoration(labelText: t.install.pair_code),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          // **必须 `pop()` 不带值**：外层是 `showDialog<String>`，路由的类型
          // 参数是 `String`。`pop(false)` 会在 `didPop` 里做 `result as String?`，
          // 直接抛 TypeError —— 对话框**关不掉**，界面卡在「对话框还在、下层
          // 不重绘」的状态（用户看到的就是黑屏）。
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(t.base.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? t.install.working : t.base.confirm),
        ),
      ],
    );
  }
}

/// 无线连接对话框（配对之后，或已知端口的旧式无线调试）。
class _WirelessConnectDialog extends StatefulWidget {
  const _WirelessConnectDialog({this.initialAddress});

  /// 预填的 IP（来自刚配对的那台设备）。
  ///
  /// 只填 IP、不填端口：连接端口和配对端口**不是同一个**，预填一个错的端口
  /// 只会让人直接点确定然后失败 —— 那正是这个对话框最初的问题。
  final String? initialAddress;

  @override
  State<_WirelessConnectDialog> createState() => _WirelessConnectDialogState();
}

class _WirelessConnectDialogState extends State<_WirelessConnectDialog> {
  late final TextEditingController _addressController =
      TextEditingController(text: widget.initialAddress ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  /// 把 adb 的原文翻成人话。
  ///
  /// 这三个错误各自对应一种**不同的用户动作**，直接甩 `No route to host`
  /// 只会让人以为是网络坏了 —— 而实际最常见的原因是「填了配对端口」。
  String _describeError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('no route to host')) {
      return t.install.connect_error_no_route;
    }
    if (lower.contains('connection refused')) {
      return t.install.connect_error_refused;
    }
    if (lower.contains('failed to authenticate')) {
      return t.install.connect_error_auth;
    }
    return raw;
  }

  Future<void> _submit() async {
    final address = AdbService.normalizeAddress(
      _addressController.text,
      defaultPort: AdbService.defaultConnectPort,
    );
    if (address == null) {
      setState(() => _error = t.install.pair_invalid_address);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AdbService.connect(address);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      // 重启过后台进程仍然失败，说明不是 adb 的问题 —— 文案要跟着换，
      // 否则用户会照着「端口不对」的提示反复改端口。
      _error = result.serverRestarted
          ? t.install.connect_error_after_restart
          : _describeError(result.output);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.install.wireless_connect),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.install.connect_hint,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).hintColor)),
          const SizedBox(height: 12),
          TextField(
            controller: _addressController,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: t.install.connect_address,
              hintText: '192.168.1.35:37123',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(t.base.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? t.install.working : t.base.confirm),
        ),
      ],
    );
  }
}

/// 把 adb 原始失败输出转成用户可读的本地化句子。
String _localizedInstallError(
  String raw,
  Translations t,
  int exitCode,
) {
  final code = adbInstallFailureCode(raw);
  if (code == null) {
    return raw.isNotEmpty ? raw : 'adb install exited with $exitCode';
  }
  return switch (code) {
    'INSTALL_FAILED_ALREADY_EXISTS' => t.install.error_already_exists,
    'INSTALL_FAILED_INSUFFICIENT_STORAGE' =>
      t.install.error_insufficient_storage,
    'INSTALL_FAILED_INVALID_APK' ||
    'INSTALL_PARSE_FAILED_NOT_APK' ||
    'INSTALL_PARSE_FAILED_NO_CERTIFICATES' ||
    'INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES' =>
      t.install.error_invalid_apk,
    'INSTALL_FAILED_VERSION_DOWNGRADE' => t.install.error_version_downgrade,
    'INSTALL_FAILED_UPDATE_INCOMPATIBLE' => t.install.error_update_incompatible,
    'INSTALL_FAILED_NO_MATCHING_ABIS' => t.install.error_no_matching_abis,
    'INSTALL_FAILED_SHARED_USER_INCOMPATIBLE' => t.install.error_signature,
    _ => t.install.error_generic(code: code),
  };
}
