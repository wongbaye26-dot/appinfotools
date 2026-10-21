import 'dart:async';
import 'dart:io';

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ui/shell/page_header.dart';
import 'package:apk_info_tool/utils/adb_service.dart';
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
///
/// 分析页顶栏的安装按钮**已移除**：同一件事两个入口，用户每次都要判断
/// 「该点哪个」。
class InstallPage extends StatefulWidget {
  const InstallPage({super.key, this.deviceLoader});

  /// 设备枚举实现。
  ///
  /// 默认走真实的 `adb devices -l`；提供此参数可注入替身，让测试能精确控制
  /// 「加载未完成时页面被销毁」这类时序 —— 真实 `Process.run` 在 widget
  /// 测试的 fake-async 区里会留下未触发的 Timer，无法稳定复现。
  final Future<List<AdbDevice>> Function()? deviceLoader;

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  String? _filePath;
  bool _isXapk = false;

  List<AdbDevice> _devices = const [];
  final Set<String> _selected = {};
  final Map<String, _DeviceState> _states = {};
  bool _loadingDevices = false;

  bool _allowDowngrade = false;
  bool _forceInstall = false;
  bool _allowTest = false;

  List<String> _splitApks = const [];
  final Map<String, bool> _selectedSplits = {};

  bool _installing = false;
  bool _cancelled = false;
  Process? _currentProcess;
  XapkInstaller? _currentInstaller;
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
  /// 实测一次撞挂 10 个既有测试。
  ///
  /// 用 `Visibility.of` 当信号还顺带解决了另一个问题：不可见的页面**不该**
  /// 抢拖放（见 [build] 里的 `enable`）。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = Visibility.of(context);
    if (visible && !_wasVisible) {
      _wasVisible = true;
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
    setState(() {
      _filePath = path;
      _isXapk = isXapk;
      _splitApks = const [];
      _selectedSplits.clear();
    });
    if (isXapk) await _loadSplits(path);
  }

  void _clearFile() {
    setState(() {
      _filePath = null;
      _isXapk = false;
      _splitApks = const [];
      _selectedSplits.clear();
    });
  }

  Future<void> _loadSplits(String path) async {
    try {
      final installer = XapkInstaller();
      final splits = await installer.getSplitApks(path);
      if (!mounted || splits == null) return;
      setState(() {
        _splitApks = splits;
        for (final split in splits) {
          _selectedSplits[split] = true;
        }
      });
    } catch (e) {
      log.warning('InstallPage: 读取分包失败: $e');
    }
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
        // 只保留仍然存在**且可用**的设备的选择与状态。
        //
        // 两种都要清：拔掉的设备（id 消失）和状态退化的设备（`device` →
        // `unauthorized` / `offline`）。后者尤其重要 —— 手机在列表返回前被
        // 锁屏，设备就变成 `unauthorized` 了，但选择集里还留着它，点安装
        // 会对着一台没授权的设备发命令，失败信息还很难懂。
        final usable = {
          for (final device in devices)
            if (device.isUsable) device.id,
        };
        _selected.removeWhere((id) => !usable.contains(id));
        _states.removeWhere((id, _) => !usable.contains(id));
        // 首次枚举时，把可用设备默认勾上（与旧对话框一致）。
        for (final id in usable) {
          if (!_states.containsKey(id)) _selected.add(id);
        }
      });
    } catch (e) {
      log.warning('InstallPage: 枚举设备失败: $e');
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  Future<void> _openPairDialog() async {
    final paired = await showDialog<bool>(
      context: context,
      builder: (context) => const _WirelessPairDialog(),
    );
    if (paired == true) await _refreshDevices();
  }

  Future<void> _openConnectDialog() async {
    final connected = await showDialog<bool>(
      context: context,
      builder: (context) => const _WirelessConnectDialog(),
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

  Future<void> _startInstall() async {
    if (!_canInstall) return;
    setState(() {
      _installing = true;
      _cancelled = false;
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
    setState(() {
      _states[deviceId] = _DeviceState()
        ..phase = _Phase.installing
        ..message = t.install.installing;
    });

    try {
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
            .listen(stdoutBuffer.write);
        process.stderr
            .transform(const SystemEncoding().decoder)
            .listen(stderrBuffer.write);
        final exitCode = await process.exitCode;
        _currentProcess = null;
        ok = exitCode == 0;
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
      setState(() {
        _states[deviceId] = _DeviceState()
          ..phase = _cancelled ? _Phase.stopped : _Phase.failed
          ..message = _cancelled ? t.install.stopped : '$e';
      });
    }
  }

  String get _adbExecutable {
    // 与安装对话框时期一致：解析失败时退回裸命令名，让 adb 自己报
    // 「command not found」比我们编一个路径更诚实。
    return _adbPath ?? 'adb';
  }

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
    // 概览页与分析页早就按这个约定做了，新页面必须一致。
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
                  style: BorderStyle.solid,
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
            children: [
              Icon(
                _isXapk ? Icons.folder_zip_outlined : Icons.android,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.basename(path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      _fileSubtitle(path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              TextButton(
                  onPressed: _pickFile, child: Text(t.install.change_file)),
              TextButton(
                  onPressed: _clearFile, child: Text(t.install.clear_file)),
            ],
          ),
      ],
    );
  }

  String _fileSubtitle(String path) {
    final type = _isXapk ? 'XAPK / APKS' : 'APK';
    try {
      final size = File(path).lengthSync();
      return '$type · ${_formatBytes(size)}';
    } catch (_) {
      return type;
    }
  }

  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  Widget _buildDeviceCard(ThemeData theme) {
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
            padding: const EdgeInsets.symmetric(vertical: 16),
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
      ],
    );
  }

  Widget _buildDeviceRow(ThemeData theme, AdbDevice device) {
    final state = _states[device.id];
    final selectable = device.isUsable && !_installing;
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
                        device.displayName,
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
                  state?.message ?? device.id,
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

  Widget _buildOptionsCard(ThemeData theme) {
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
        if (_splitApks.isNotEmpty) ...[
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
          ..._splitApks.map(
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
      // 配对端口必须显式给出：它是设备随机生成的。
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
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.output;
    });
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
  const _WirelessConnectDialog();

  @override
  State<_WirelessConnectDialog> createState() => _WirelessConnectDialogState();
}

class _WirelessConnectDialogState extends State<_WirelessConnectDialog> {
  final _addressController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
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
      _error = result.output;
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
              labelText: t.install.pair_address,
              hintText: '192.168.1.5:5555',
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
