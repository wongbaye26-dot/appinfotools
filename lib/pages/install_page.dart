import 'dart:async';
import 'dart:io';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/utils/adb_service.dart';
import 'package:apk_info_tool/utils/known_devices.dart';
import 'package:apk_info_tool/utils/logger.dart';
import 'package:apk_info_tool/utils/xapk_installer.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

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

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  // ---- 安装包 ----
  String? _filePath;
  bool _isXapk = false;
  ApkInfo? _apkInfo;
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

  // ---- 选项 ----
  bool _allowDowngrade = false;

  /// 覆盖安装（`-r`）。**默认开**：分析工具反复装同一个包是常态，
  /// 关着会让第二次安装直接失败（`INSTALL_FAILED_ALREADY_EXISTS`）。
  bool _forceInstall = true;
  bool _allowTest = false;

  /// 安装前先卸载。签名不一致时 `-r` 必然失败，重打包的包尤其常见。
  bool _uninstallFirst = false;

  // ---- 安装过程 ----
  bool _installing = false;
  bool _cancelled = false;
  Process? _currentProcess;
  XapkInstaller? _currentInstaller;
  final List<String> _logs = [];
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
      unawaited(_refreshDevices());
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
      allowedExtensions: const ['apk', 'xapk', 'apks'],
      dialogTitle: t.install.pick_file,
    );
    final path = result?.files.single.path;
    if (path != null) await _setFile(path);
  }

  Future<void> _setFile(String path) async {
    final lower = path.toLowerCase();
    if (!lower.endsWith('.apk') &&
        !lower.endsWith('.xapk') &&
        !lower.endsWith('.apks')) {
      _snack(t.install.unsupported_file);
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
      _filePath = null;
      _isXapk = false;
      _parsing = false;
      _parseFailed = false;
      _selectedSplits.clear();
    });
  }

  // ---------------------------------------------------------------- 设备

  Future<void> _refreshDevices() async {
    if (_loadingDevices) return;
    setState(() => _loadingDevices = true);
    try {
      final devices =
          await (widget.deviceLoader ?? AdbService.listDevices).call();
      if (!mounted) return;
      setState(() {
        _devices = devices;
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
        if (!ok && !_cancelled) error = t.install.error;
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
          error = stderrBuffer.toString().trim();
          if (error.isEmpty) error = stdoutBuffer.toString().trim();
          if (error.isEmpty) error = 'adb install exited with $exitCode';
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
      setState(() {
        _states[deviceId] = _DeviceState()
          ..phase = ok ? _Phase.success : _Phase.failed
          ..message = ok ? t.install.success : (error ?? t.install.failed);
        if (ok) _selected.remove(deviceId);
      });
    } catch (e) {
      if (!mounted) return;
      _appendLog('$e');
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
    return Scaffold(
      body: DropTarget(
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PageHeader(
                  title: t.nav.install,
                  subtitle: t.install.subtitle,
                  actions: [
                    IconButton(
                      tooltip: t.install.refresh_devices,
                      onPressed: _loadingDevices ? null : _refreshDevices,
                      icon: _loadingDevices
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildFileCard(theme),
                const SizedBox(height: 12),
                _buildDeviceCard(theme),
                const SizedBox(height: 12),
                _buildOptionsCard(theme),
                const SizedBox(height: 12),
                _buildLogCard(theme),
                const SizedBox(height: 20),
                _buildInstallBar(theme),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _card({required ThemeData theme, required List<Widget> children}) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      );

  // ---- 安装包 ----

  Widget _buildFileCard(ThemeData theme) {
    final path = _filePath;
    return _card(
      theme: theme,
      children: [
        _sectionTitle(theme, t.install.file_section),
        const SizedBox(height: 12),
        if (path == null)
          InkWell(
            onTap: _pickFile,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 28),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
              ),
              child: Column(
                children: [
                  Icon(Icons.file_upload_outlined,
                      size: 28, color: theme.hintColor),
                  const SizedBox(height: 8),
                  Text(t.install.drop_hint,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.hintColor)),
                ],
              ),
            ),
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAppIcon(theme),
              const SizedBox(width: 14),
              Expanded(child: _buildAppText(theme, path)),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                      onPressed: _installing ? null : _pickFile,
                      child: Text(t.install.change_file)),
                  TextButton(
                      onPressed: _installing ? null : _clearFile,
                      child: Text(t.install.clear_file)),
                ],
              ),
            ],
          ),
      ],
    );
  }

  /// 应用图标 —— 与概览页 Hero 同一套渲染（`RawImage` + cover）。
  Widget _buildAppIcon(ThemeData theme) {
    final image = _apkInfo?.mainIconImage;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: image != null
          ? RawImage(image: image, fit: BoxFit.cover)
          : Center(
              child: Icon(
                _isXapk ? Icons.folder_zip_outlined : Icons.android,
                size: 26,
                color: theme.hintColor.withValues(alpha: 0.5),
              ),
            ),
    );
  }

  Widget _buildAppText(ThemeData theme, String path) {
    final info = _apkInfo;
    final name =
        (info?.label?.isNotEmpty ?? false) ? info!.label! : p.basename(path);
    final package = info?.packageName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (package != null && package.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            package,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          _parsing
              ? t.install.app_parsing
              : _parseFailed
                  ? t.install.app_info_failed
                  : _versionLine(info),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: _parseFailed ? theme.colorScheme.error : theme.hintColor,
          ),
        ),
      ],
    );
  }

  /// `v1.2.3 (123) · 100.6 MB`。
  String _versionLine(ApkInfo? info) {
    final parts = <String>[];
    final versionName = info?.versionName;
    final versionCode = info?.versionCode;
    if (versionName != null && versionName.isNotEmpty) {
      parts.add(
        versionCode == null ? 'v$versionName' : 'v$versionName ($versionCode)',
      );
    }
    final size = _formatBytes(info?.apkSize ?? _fileSize(_filePath));
    if (size.isNotEmpty) parts.add(size);
    if (_isXapk) parts.insert(0, 'XAPK / APKS');
    return parts.join(' · ');
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

  Widget _buildDeviceCard(ThemeData theme) {
    final knownWireless = _known
        .where((d) => d.wireless && !_devices.any((x) => x.id == d.id))
        .toList();
    return _card(
      theme: theme,
      children: [
        Row(
          children: [
            Expanded(child: _sectionTitle(theme, t.install.device_section)),
            TextButton.icon(
              onPressed: _openPairDialog,
              icon: const Icon(Icons.wifi_password, size: 18),
              label: Text(t.install.wireless_pair),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: _openConnectDialog,
              icon: const Icon(Icons.link, size: 18),
              label: Text(t.install.wireless_connect),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.install.no_devices,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.hintColor)),
                const SizedBox(height: 6),
                Text(
                  t.install.no_devices_hint,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          )
        else
          ..._devices.map((device) => _buildDeviceRow(theme, device)),
        if (knownWireless.isNotEmpty) ...[
          const Divider(height: 24),
          Text(
            t.install.saved_devices,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 4),
          ...knownWireless.map((device) => _buildKnownRow(theme, device)),
        ],
      ],
    );
  }

  Widget _buildDeviceRow(ThemeData theme, AdbDevice device) {
    final state = _states[device.id];
    final selectable = device.isUsable && !_installing;
    final info = _deviceInfo[device.id];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Checkbox(
            value: _selected.contains(device.id),
            onChanged: selectable
                ? (value) {
                    setState(() {
                      if (value == true) {
                        _selected.add(device.id);
                      } else {
                        _selected.remove(device.id);
                      }
                    });
                  }
                : null,
          ),
          Icon(
            device.isWireless ? Icons.wifi : Icons.usb,
            size: 18,
            color: theme.hintColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _deviceLabel(device, device.id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!device.isUsable) _statusChip(theme, device),
                  ],
                ),
                Text(
                  _deviceSubtitle(device, info, state?.message),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _messageColor(theme, state),
                  ),
                ),
              ],
            ),
          ),
          if (device.isWireless)
            IconButton(
              tooltip: t.install.wireless_disconnect,
              onPressed: _installing ? null : () => _disconnect(device),
              icon: const Icon(Icons.wifi_off, size: 18),
            ),
        ],
      ),
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

  String _deviceSubtitle(
    AdbDevice device,
    AdbDeviceInfo? info,
    String? message,
  ) {
    final parts = <String>[device.id];
    final system = info?.systemVersion;
    if (system != null && system.isNotEmpty) {
      parts.add('Android $system');
    }
    if (message != null && message.isNotEmpty) parts.add(message);
    return parts.join(' · ');
  }

  Widget _buildKnownRow(ThemeData theme, KnownAdbDevice device) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.wifi_off, size: 16, color: theme.hintColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _knownLabel(device),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                Text(
                  _knownSubtitle(device),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _connectKnown(device),
            child: Text(t.install.saved_connect),
          ),
          IconButton(
            tooltip: t.install.saved_forget,
            onPressed: () => _forgetKnown(device),
            icon: const Icon(Icons.close, size: 16),
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
        return theme.colorScheme.primary;
      default:
        return theme.hintColor;
    }
  }

  Widget _statusChip(ThemeData theme, AdbDevice device) {
    final label = device.isUnauthorized
        ? t.install.status_unauthorized
        : device.isOffline
            ? t.install.status_offline
            : device.status;
    final color =
        device.isUnauthorized ? theme.colorScheme.error : theme.hintColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall?.copyWith(color: color)),
    );
  }

  // ---- 选项 ----

  Widget _buildOptionsCard(ThemeData theme) {
    final packageName = _apkInfo?.packageName;
    final canUninstall = packageName != null && packageName.isNotEmpty;
    return _card(
      theme: theme,
      children: [
        _sectionTitle(theme, t.install.advanced_options),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(t.install.force_install),
          value: _forceInstall,
          onChanged: _installing
              ? null
              : (value) => setState(() => _forceInstall = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(t.install.uninstall_first),
          subtitle: Text(
            canUninstall
                ? t.install.uninstall_first_desc
                : t.install.app_info_failed,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          value: _uninstallFirst,
          // 没有包名就没法卸载 —— 灰掉而不是让用户点了才发现没生效。
          onChanged: (_installing || !canUninstall)
              ? null
              : (value) => setState(() => _uninstallFirst = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(t.install.allow_downgrade),
          value: _allowDowngrade,
          onChanged: _installing
              ? null
              : (value) => setState(() => _allowDowngrade = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(t.install.allow_test),
          value: _allowTest,
          onChanged: _installing
              ? null
              : (value) => setState(() => _allowTest = value),
        ),
        if (_selectedSplits.isNotEmpty) ...[
          const Divider(height: 24),
          Row(
            children: [
              Expanded(child: _sectionTitle(theme, t.install.split_options)),
              TextButton(
                onPressed: _installing
                    ? null
                    : () => setState(() {
                          final all = _selectedSplits.values.every((v) => v);
                          for (final key in _selectedSplits.keys.toList()) {
                            _selectedSplits[key] = !all;
                          }
                        }),
                child: Text(_selectedSplits.values.every((v) => v)
                    ? t.install.base_only
                    : t.install.select_all),
              ),
            ],
          ),
          ..._selectedSplits.keys.map(
            (split) => CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _selectedSplits[split] ?? false,
              title: Text(split, maxLines: 1, overflow: TextOverflow.ellipsis),
              onChanged: _installing
                  ? null
                  : (value) =>
                      setState(() => _selectedSplits[split] = value ?? false),
            ),
          ),
        ],
      ],
    );
  }

  // ---- 日志 ----

  Widget _buildLogCard(ThemeData theme) {
    return _card(
      theme: theme,
      children: [
        Row(
          children: [
            Expanded(child: _sectionTitle(theme, t.install.log_title)),
            if (_logs.isNotEmpty)
              Text(
                '${_logs.length}',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_logs.isEmpty)
          Text(
            t.install.log_empty,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          )
        else
          Container(
            width: double.infinity,
            height: 160,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Scrollbar(
              controller: _logScroll,
              child: SingleChildScrollView(
                controller: _logScroll,
                child: SelectableText(
                  _logs.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---- 底栏 ----

  Widget _buildInstallBar(ThemeData theme) {
    return Row(
      children: [
        if (_installing)
          Expanded(
            child: Text(
              t.install.installing,
              style:
                  theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
          )
        else
          Expanded(
            child: Text(
              _blockReason() ?? '',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
        if (_installing)
          OutlinedButton.icon(
            onPressed: _stopInstall,
            icon: const Icon(Icons.stop, size: 18),
            label: Text(t.install.stop),
          )
        else
          FilledButton.icon(
            onPressed: _canInstall ? _startInstall : null,
            icon: const Icon(Icons.install_mobile, size: 18),
            label: Text(t.install.start),
          ),
      ],
    );
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
