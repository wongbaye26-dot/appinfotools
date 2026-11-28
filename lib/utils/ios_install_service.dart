import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/utils/logger.dart';

/// 一台通过 usbmuxd 连接的 iOS 设备。
class IosDevice {
  final String udid;
  final String name;
  final String version;

  /// 机型标识，如 `iPhone15,2`；取不到时为 `null`。
  final String? model;

  const IosDevice({
    required this.udid,
    required this.name,
    required this.version,
    this.model,
  });

  @override
  String toString() => '$name (${model ?? 'iOS'}) $version · $udid';
}

/// iOS 安装所需的外部命令，都来自 libimobiledevice。
///
/// macOS 上 `brew install libimobiledevice ideviceinstaller` 即可；
/// 本应用不代下载，只检测与调用。
class IosToolchain {
  final String? ideviceId;
  final String? ideviceInfo;
  final String? ideviceinstaller;

  const IosToolchain({this.ideviceId, this.ideviceInfo, this.ideviceinstaller});

  bool get available => ideviceId != null && ideviceinstaller != null;

  /// 在 `PATH` 里查找命令。
  ///
  /// 手动扫目录而不是起 `which` 子进程：探测要在首帧前跑完，起进程慢一个
  /// 量级；也便于测试注入。
  factory IosToolchain.detect({String? pathEnv, bool Function(String)? exists}) {
    final env = pathEnv ?? Platform.environment['PATH'] ?? '';
    final check = exists ?? (String path) => File(path).existsSync();
    String? look(String name) {
      for (final dir in env.split(Platform.isWindows ? ';' : ':')) {
        if (dir.isEmpty) continue;
        final candidate = '$dir${Platform.pathSeparator}$name';
        if (check(candidate)) return candidate;
      }
      return null;
    }

    return IosToolchain(
      ideviceId: look('idevice_id'),
      ideviceInfo: look('ideviceinfo'),
      ideviceinstaller: look('ideviceinstaller'),
    );
  }
}

/// `idevice_id -l` 的输出 → UDID 列表。
///
/// 输出是「一行一个 UDID」，但有的版本会先打印警告，所以只接受形如 UDID
/// 的 token，避免把警告文案当成设备。
List<String> parseIosUdidList(String output) {
  final result = <String>[];
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (!RegExp(r'^[0-9a-fA-F][0-9a-fA-F-]{15,63}$').hasMatch(line)) continue;
    result.add(line);
  }
  return result;
}

/// `ideviceinfo` 的 `Key: Value` 输出 → [IosDevice]。
///
/// 取不到 DeviceName / ProductVersion 时给出明确占位，而不是拼出一个
/// 空壳名字。
IosDevice parseIosDeviceInfo(String udid, String output) {
  final values = <String, String>{};
  for (final raw in const LineSplitter().convert(output)) {
    final index = raw.indexOf(':');
    if (index <= 0) continue;
    values[raw.substring(0, index).trim()] = raw.substring(index + 1).trim();
  }
  final name = values['DeviceName'];
  final version = values['ProductVersion'];
  return IosDevice(
    udid: udid,
    name: (name == null || name.isEmpty) ? udid : name,
    version: (version == null || version.isEmpty) ? '-' : version,
    model: values['ProductType'],
  );
}

/// 通过 libimobiledevice 安装 .ipa。
///
/// 与 adb 一样是「把包送到设备」，不启动应用。失败原因保留工具原始输出，
/// 便于区分签名问题、设备未信任、工具缺失。
class IosInstallService {
  final IosToolchain toolchain;
  final Duration timeout;

  const IosInstallService({
    required this.toolchain,
    this.timeout = const Duration(minutes: 5),
  });

  /// 枚举设备。工具缺失时返回空列表（调用方看 [toolchain] 判断原因）。
  Future<List<IosDevice>> listDevices() async {
    final idTool = toolchain.ideviceId;
    if (idTool == null) return const [];
    try {
      final result = await Process.run(idTool, const ['-l'])
          .timeout(const Duration(seconds: 10));
      final udids = parseIosUdidList('${result.stdout}');
      final devices = <IosDevice>[];
      final infoTool = toolchain.ideviceInfo;
      for (final udid in udids) {
        if (infoTool == null) {
          devices.add(IosDevice(udid: udid, name: udid, version: '-'));
          continue;
        }
        try {
          final info = await Process.run(infoTool, ['-u', udid])
              .timeout(const Duration(seconds: 10));
          devices.add(parseIosDeviceInfo(udid, '${info.stdout}'));
        } catch (e) {
          log.warning('ideviceinfo failed for $udid: $e');
          devices.add(IosDevice(udid: udid, name: udid, version: '-'));
        }
      }
      return devices;
    } catch (e) {
      log.warning('idevice_id failed: $e');
      return const [];
    }
  }

  /// 安装，逐行回调输出。返回 `true` 表示 `ideviceinstaller` 退出码为 0。
  Future<bool> install(
    String ipaPath, {
    String? udid,
    void Function(String line)? onLine,
  }) async {
    final tool = toolchain.ideviceinstaller;
    if (tool == null) return false;
    final args = ['-i', ipaPath, if (udid != null) ...['-u', udid]];
    onLine?.call('$tool ${args.join(' ')}');
    final process = await Process.start(tool, args);
    final outSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => onLine?.call(line));
    final errSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) => onLine?.call(line));
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await outSub.cancel();
    await errSub.cancel();
    onLine?.call('exit code: $exitCode');
    return exitCode == 0;
  }
}
