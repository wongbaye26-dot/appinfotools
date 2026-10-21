import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/utils/command_tools.dart';
import 'package:apk_info_tool/utils/logger.dart';

/// 一台通过 adb 可见的设备。
///
/// [status] 直接取 `adb devices -l` 的第二列，**不做归一化** ——
/// `device` / `offline` / `unauthorized` / `bootloader` 等取值本身就有意义，
/// 折成 bool 会把「没授权」和「离线」混成同一句话，而这两种的用户动作
/// 完全不同（一个要在手机上点允许，一个要重插线）。
class AdbDevice {
  final String id;
  final String status;
  final String? product;
  final String? model;
  final String? device;

  /// 本次会话里最后一次操作的提示（安装结果、连接结果）。
  String? note;

  AdbDevice({
    required this.id,
    required this.status,
    this.product,
    this.model,
    this.device,
    this.note,
  });

  /// `offline`：设备在列表里但连不上（线松了、无线信号断了）。
  bool get isOffline => status == 'offline';

  /// `unauthorized`：设备没信任这台电脑。**必须在手机上点「允许调试」。**
  bool get isUnauthorized => status == 'unauthorized';

  /// 只有 `device` 状态能装东西。
  bool get isUsable => status == 'device';

  /// 无线设备的 id 形如 `192.168.1.5:5555`；USB 设备是序列号。
  bool get isWireless => id.contains(':');

  String get displayName {
    final parts = <String>[
      if (model != null && model!.isNotEmpty) model!,
      if (device != null && device!.isNotEmpty) device!,
    ];
    return parts.isEmpty ? id : parts.join(' ');
  }

  @override
  String toString() => 'AdbDevice($id, $status)';
}

/// 一台设备的品牌 / 型号 / 系统版本。
///
/// `adb devices -l` 只给 `model:SM_G9910` 这种代号，用户认不出是哪台机器；
/// 真正的营销名与系统版本要 `getprop`。三者都允许为空 —— 部分定制 ROM 会
/// 删掉 `ro.product.brand`，那时用 `ro.product.manufacturer` 兜底。
class AdbDeviceInfo {
  final String? brand;
  final String? model;
  final String? systemVersion;

  const AdbDeviceInfo({this.brand, this.model, this.systemVersion});

  bool get hasAny =>
      (brand?.isNotEmpty ?? false) ||
      (model?.isNotEmpty ?? false) ||
      (systemVersion?.isNotEmpty ?? false);

  Map<String, dynamic> toJson() => {
        if (brand != null) 'brand': brand,
        if (model != null) 'model': model,
        if (systemVersion != null) 'system': systemVersion,
      };

  static AdbDeviceInfo fromJson(Map<String, dynamic> json) => AdbDeviceInfo(
        brand: json['brand'] as String?,
        model: json['model'] as String?,
        systemVersion: json['system'] as String?,
      );

  @override
  String toString() => 'AdbDeviceInfo($brand, $model, $systemVersion)';
}

/// 保存下来的设备（历史记录）。
///
/// 只对**无线**设备有「重连」价值：USB 设备插上就在，序列号也是固定的，
/// 保存它只是为了让列表里能显示「上次那台机器叫什么」。
class KnownAdbDevice {
  final String id;
  final bool wireless;
  final AdbDeviceInfo info;
  final DateTime lastSeen;

  const KnownAdbDevice({
    required this.id,
    required this.wireless,
    required this.info,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'wireless': wireless,
        'lastSeen': lastSeen.millisecondsSinceEpoch,
        ...info.toJson(),
      };

  static KnownAdbDevice? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final millis = json['lastSeen'];
    return KnownAdbDevice(
      id: id,
      wireless: json['wireless'] == true,
      info: AdbDeviceInfo.fromJson(json),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(
        millis is int ? millis : 0,
      ),
    );
  }
}

/// 一次 adb 命令的结果。
///
/// 刻意不抛异常：adb 的失败绝大多数是**可预期的环境问题**（没授权、端口错、
/// 设备离线），调用方要的是「拿一句话展示给用户」，而不是 catch 一堆分支。
class AdbCommandResult {
  final bool ok;
  final String output;

  /// 这次调用**重启过 adb 后台进程**才成功。
  ///
  /// 界面据此说清楚「我们做了什么」—— 否则用户会以为第一次失败是自己填错了。
  final bool serverRestarted;

  const AdbCommandResult({
    required this.ok,
    required this.output,
    this.serverRestarted = false,
  });

  /// adb 可执行文件找不到 —— 与「命令执行失败」是两件事。
  static const AdbCommandResult adbMissing =
      AdbCommandResult(ok: false, output: 'adb not found');

  @override
  String toString() => 'AdbCommandResult(ok: $ok, output: $output)';
}

/// adb 的薄封装：设备枚举、无线配对/连接/断开。
///
/// ## 为什么单独一层
///
/// 早先这些逻辑长在安装对话框里，于是「无线调试」想加也没地方放 ——
/// 对话框只关心「选一台已连上的设备」。抽出来之后，[parseDevices] /
/// [parsePairResult] / [parseConnectResult] 都是**纯函数**，可以拿真实输出
/// 样本做单元测试，不必本机插着手机。
class AdbService {
  AdbService._();

  /// 设备枚举 / 连接的默认超时。
  ///
  /// `adb connect` 在地址不可达时会**卡满超时**才返回（实测 20–60 秒），
  /// 因此必须有上限，否则界面会一直转圈。
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// 无线调试的默认端口。
  ///
  /// `adb connect` 不写端口时用 5555（Android 11 之前的无线调试）。
  /// **配对端口不是它** —— 配对端口由设备随机生成，必须照抄手机屏幕上那个。
  static const int defaultConnectPort = 5555;

  static bool get isAvailable => CommandTools.findAdbPath() != null;

  /// 解析到的 adb 可执行文件路径；找不到时为 `null`。
  ///
  /// 调用方需要**自己启动进程**时（例如要边读输出边支持中断的安装），
  /// 拿这个路径，而不是再走一遍 `CommandTools`。
  static String? get adbExecutable => CommandTools.findAdbPath();

  /// 解析 `adb devices -l`。
  ///
  /// 真实输出：
  /// ```
  /// List of devices attached
  /// R58M12ABCDE            device product:beyond1q model:SM_G9730 device:beyond1q
  /// 192.168.1.5:5555       device product:beyond1q model:SM_G9730 device:beyond1q
  /// R58M99ZZZZZ            unauthorized usb:1-1
  /// ```
  static List<AdbDevice> parseDevices(String output) {
    final devices = <AdbDevice>[];
    for (final line in const LineSplitter().convert(output)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // 首行是 `List of devices attached`；`adb` 自己的错误信息也会混进来
      // （daemon 启动提示），因此只认「至少两列且第二列是已知状态」的行。
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final status = parts[1];
      if (!_knownStates.contains(status)) continue;

      String? product;
      String? model;
      String? device;
      for (final info in parts.skip(2)) {
        if (info.startsWith('product:')) {
          product = info.substring('product:'.length);
        } else if (info.startsWith('model:')) {
          model = info.substring('model:'.length);
        } else if (info.startsWith('device:')) {
          device = info.substring('device:'.length);
        }
      }
      devices.add(AdbDevice(
        id: parts[0],
        status: status,
        product: product,
        model: model,
        device: device,
      ));
    }
    return devices;
  }

  static const Set<String> _knownStates = {
    'device',
    'offline',
    'unauthorized',
    'recovery',
    'sideload',
    'bootloader',
    'no',
  };

  /// 解析 `adb pair <addr> <code>`。
  ///
  /// 成功输出：`Successfully paired to 192.168.1.5:37123 [guid=adb-…]`
  /// 失败常见两种：
  /// - `Failed to pair to …: Invalid code`（配对码错了）
  /// - `Failed: unable to connect to …`（端口不对 / 不在同一网络）
  static AdbCommandResult parsePairResult(int exitCode, String output) {
    final text = output.trim();
    if (exitCode == 0 && text.toLowerCase().contains('successfully paired')) {
      return AdbCommandResult(ok: true, output: text);
    }
    return AdbCommandResult(
        ok: false,
        output: text.isEmpty ? 'adb pair exited with $exitCode' : text);
  }

  /// 解析 `adb connect <addr>`。
  ///
  /// 注意：**`adb connect` 对「已连接」也会返回 0**，且部分版本在失败时
  /// 同样返回 0（只把原因写进 stdout）。因此判据以文本为准，不看退出码。
  static AdbCommandResult parseConnectResult(int exitCode, String output) {
    final text = output.trim();
    final lower = text.toLowerCase();
    if (lower.contains('connected to')) {
      return AdbCommandResult(ok: true, output: text);
    }
    if (lower.contains('failed') ||
        lower.contains('cannot') ||
        lower.contains('unable')) {
      return AdbCommandResult(ok: false, output: text);
    }
    return AdbCommandResult(
      ok: false,
      output: text.isEmpty ? 'adb connect exited with $exitCode' : text,
    );
  }

  /// 解析 `adb disconnect <addr>`。
  static AdbCommandResult parseDisconnectResult(int exitCode, String output) {
    final text = output.trim();
    if (text.toLowerCase().contains('disconnected')) {
      return AdbCommandResult(ok: true, output: text);
    }
    return AdbCommandResult(
      ok: false,
      output: text.isEmpty ? 'adb disconnect exited with $exitCode' : text,
    );
  }

  /// 把用户输入的地址补成 `host:port`。
  ///
  /// [defaultPort] 为 `null` 时**必须**显式给出端口，否则返回 `null` ——
  /// 无线**配对**端口是设备随机生成的（手机屏幕上那个），补一个默认值只会
  /// 连到不存在的端口上，换回一句误导人的报错。
  ///
  /// 返回 `null` 表示输入不合法，调用方据此提示，而不是把 `192.168.1.5:`
  /// 这样的东西直接丢给 adb。
  static String? normalizeAddress(String raw, {int? defaultPort = 5555}) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    // 去掉可能被一起粘进来的 `adb connect ` 前缀。
    var address = value;
    const prefix = 'adb connect ';
    if (address.toLowerCase().startsWith(prefix)) {
      address = address.substring(prefix.length).trim();
    }

    final colon = address.lastIndexOf(':');
    if (colon < 0) {
      final host = address;
      if (!_isValidHost(host)) return null;
      if (defaultPort == null) return null;
      return '$host:$defaultPort';
    }

    final host = address.substring(0, colon);
    final portText = address.substring(colon + 1);
    if (!_isValidHost(host)) return null;
    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) return null;
    return '$host:$port';
  }

  static bool _isValidHost(String host) {
    if (host.isEmpty || host.contains(' ')) return false;
    // IPv4 或主机名（Android 无线调试也允许 `.local`）。不做严格校验：
    // 真正的判定交给 adb，这里只挡明显的手误。
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host);
  }

  static Future<List<AdbDevice>> listDevices({Duration? timeout}) async {
    final result = await _run(
      ['devices', '-l'],
      timeout: timeout ?? defaultTimeout,
    );
    if (!result.ok) return const [];
    return parseDevices(result.output);
  }

  /// 读一台设备的品牌 / 型号 / 系统版本。
  ///
  /// 一次 `adb shell` 拿三项：`echo B:$(...)` 这种带前缀的写法能容忍某个
  /// 属性为空（部分 ROM 删掉了 `ro.product.brand`）—— 直接按行号取会在
  /// 空值被折叠后错位。
  static Future<AdbDeviceInfo?> deviceInfo(
    String deviceId, {
    Duration? timeout,
  }) async {
    final result = await _run(
      [
        '-s',
        deviceId,
        'shell',
        // 原始字符串：`$(...)` 必须原样交给设备的 shell，不能被 Dart 插值。
        r'echo B:$(getprop ro.product.brand); '
            r'echo N:$(getprop ro.product.manufacturer); '
            r'echo M:$(getprop ro.product.model); '
            r'echo S:$(getprop ro.build.version.release)',
      ],
      timeout: timeout ?? const Duration(seconds: 15),
    );
    if (!result.ok) return null;
    return parseDeviceInfo(result.output);
  }

  /// 解析 [deviceInfo] 的输出。
  static AdbDeviceInfo? parseDeviceInfo(String output) {
    String? brand;
    String? manufacturer;
    String? model;
    String? system;
    for (final line in const LineSplitter().convert(output)) {
      final trimmed = line.trim();
      if (trimmed.length < 2 || trimmed[1] != ':') continue;
      final value = trimmed.substring(2).trim();
      if (value.isEmpty) continue;
      switch (trimmed[0]) {
        case 'B':
          brand = value;
        case 'N':
          manufacturer = value;
        case 'M':
          model = value;
        case 'S':
          system = value;
      }
    }
    // `ro.product.brand` 缺失时用厂商名兜底 —— 对用户来说两者都是「牌子」。
    final resolvedBrand = brand ?? manufacturer;
    if (resolvedBrand == null && model == null && system == null) return null;
    return AdbDeviceInfo(
      brand: resolvedBrand,
      model: model,
      systemVersion: system,
    );
  }

  static Future<AdbCommandResult> pair({
    required String address,
    required String code,
    Duration? timeout,
  }) async {
    return _run(
      ['pair', address, code],
      timeout: timeout ?? const Duration(seconds: 60),
      parse: parsePairResult,
    );
  }

  /// 连接一台无线设备。
  ///
  /// ## 为什么失败后要自己判一次
  ///
  /// **adb 后台进程（server）状态坏掉时，`adb connect` 会报
  /// `No route to host`** —— 和「端口不对 / 不在同一网络」是同一句话，
  /// 但两者要做的事完全相反。实测：`nc -vz 192.168.1.35 43931` 明明能连上，
  /// `adb connect` 却报 no route，`adb kill-server` 之后立刻成功。
  ///
  /// 所以失败时**用一次 TCP 探测把两者分开**：
  /// - 端口连不上 → 原文就是对的（端口/网络问题），不改；
  /// - 端口能连上 → 是 adb 后台的问题，**重启 server 重试一次**。
  ///
  /// 重启是无损的（只影响 adb 自己的后台进程，1–2 秒），所以值得自动做。
  static Future<AdbCommandResult> connect(
    String address, {
    Duration? timeout,
  }) async {
    final first = await _run(
      ['connect', address],
      timeout: timeout ?? defaultTimeout,
      parse: parseConnectResult,
    );
    if (first.ok) return first;

    final parts = _splitHostPort(address);
    if (parts == null) return first;
    if (!await probeTcp(parts.$1, parts.$2)) return first;

    // 端口可达，但 adb 说连不上 —— 重启后台进程再试一次。
    log.warning('AdbService: $address 端口可达但 adb 报错，重启 server 重试');
    await _run(['kill-server'], timeout: const Duration(seconds: 10));
    await _run(['start-server'], timeout: const Duration(seconds: 20));
    final retry = await _run(
      ['connect', address],
      timeout: timeout ?? defaultTimeout,
      parse: parseConnectResult,
    );
    return AdbCommandResult(
      ok: retry.ok,
      output: retry.output,
      serverRestarted: true,
    );
  }

  /// 探测目标 TCP 端口能不能连上。
  ///
  /// 只用来**区分原因**，不参与结论：连得上不代表能装（还要配对、要授权），
  /// 但连不上就一定不是 adb 的问题。
  static Future<bool> probeTcp(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } catch (e) {
      log.info('AdbService: 探测 $host:$port 失败: $e');
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// 把 `host:port` 拆开；格式不对返回 `null`。
  static (String, int)? _splitHostPort(String address) {
    final colon = address.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(address.substring(colon + 1));
    if (port == null) return null;
    return (address.substring(0, colon), port);
  }

  static Future<AdbCommandResult> disconnect(String address,
      {Duration? timeout}) {
    return _run(
      ['disconnect', address],
      timeout: timeout ?? const Duration(seconds: 10),
      parse: parseDisconnectResult,
    );
  }

  /// 卸载指定包。
  ///
  /// 用于「安装前先卸载」：签名不一致时 `adb install -r` 必然失败，而重打包
  /// 的包几乎一定签名不同。**失败不抛异常** —— 包里本来就没有这个包时
  /// `uninstall` 会返回 `Failure [not installed]`，那不是错误，接着装就行。
  static Future<AdbCommandResult> uninstall(
    String deviceId,
    String packageName, {
    Duration? timeout,
  }) {
    return _run(
      ['-s', deviceId, 'uninstall', packageName],
      timeout: timeout ?? const Duration(seconds: 60),
    );
  }

  /// 执行一条 adb 命令并交给 [parse] 解释。
  ///
  /// 参数以数组传入，**不经过任何 shell** —— 设备 id 里可能带 `:`，
  /// 用户输入的地址里也可能带空格，拼字符串迟早出事。
  static Future<AdbCommandResult> _run(
    List<String> args, {
    required Duration timeout,
    AdbCommandResult Function(int exitCode, String output)? parse,
  }) async {
    final executable = CommandTools.findAdbPath();
    if (executable == null) {
      log.warning('AdbService: 找不到 adb');
      return AdbCommandResult.adbMissing;
    }

    try {
      final result = await Process.run(executable, args).timeout(timeout);
      // adb 把结果写在 stdout，把 `daemon started successfully` 之类的
      // 噪音写在 stderr；两者都要看，否则「Successfully paired」在
      // 某些版本里会落在 stderr 上。
      final output = '${result.stdout}\n${result.stderr}'.trim();
      if (parse != null) return parse(result.exitCode, output);
      return AdbCommandResult(ok: result.exitCode == 0, output: output);
    } on TimeoutException {
      log.warning('AdbService: adb ${args.first} 超时（${timeout.inSeconds}s）');
      return AdbCommandResult(
        ok: false,
        output: 'adb ${args.first} timed out after ${timeout.inSeconds}s',
      );
    } on ProcessException catch (e) {
      log.warning('AdbService: adb 无法执行: $e');
      return AdbCommandResult(ok: false, output: e.message);
    } catch (e) {
      log.warning('AdbService: adb ${args.first} 失败: $e');
      return AdbCommandResult(ok: false, output: '$e');
    }
  }
}
