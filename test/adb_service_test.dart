// adb 输出解析 —— 全部是**纯函数**，不插手机也能测。
//
// 判据必须钉住的地方：
// 1. `adb devices -l` 的噪音行（`List of devices attached`、daemon 启动提示）
//    不能变成设备；
// 2. `unauthorized` 与 `offline` 是两种状态，用户动作完全不同，不能混；
// 3. `adb connect` **对失败也可能返回 0**，所以判据看文本不看退出码；
// 4. 地址补全：`connect` 省略端口补 5555，**配对端口不能补** ——
//    它是设备随机生成的，补一个默认值只会连到不存在的端口。

import 'dart:io';

import 'package:apk_info_tool/utils/adb_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseDevices', () {
    test('USB + 无线 + 未授权混在一起的真实输出', () {
      const output = '''
List of devices attached
R58M12ABCDE            device product:beyond1q model:SM_G9730 device:beyond1q transport_id:1
192.168.1.5:5555       device product:beyond1q model:SM_G9730 device:beyond1q transport_id:2
R58M99ZZZZZ            unauthorized usb:1-1 transport_id:3
R58M11YYYYY            offline transport_id:4

''';
      final devices = AdbService.parseDevices(output);

      expect(devices, hasLength(4));
      expect(devices[0].id, 'R58M12ABCDE');
      expect(devices[0].model, 'SM_G9730');
      expect(devices[0].isUsable, isTrue);
      expect(devices[0].isWireless, isFalse);

      expect(devices[1].isWireless, isTrue);
      expect(devices[1].id, '192.168.1.5:5555');

      // 两种「不能用」必须分得开。
      expect(devices[2].isUnauthorized, isTrue);
      expect(devices[2].isUsable, isFalse);
      expect(devices[3].isOffline, isTrue);
      expect(devices[3].isUnauthorized, isFalse);
    });

    test('daemon 启动提示与空行不算设备', () {
      const output = '''
* daemon not running; starting now at tcp:5037
* daemon started successfully
List of devices attached

''';
      expect(AdbService.parseDevices(output), isEmpty);
    });

    test('没有 model 时退回 id 当显示名', () {
      final devices =
          AdbService.parseDevices('List of devices attached\nABC123\tdevice\n');
      expect(devices.single.displayName, 'ABC123');
    });

    test('未知状态词不当成设备', () {
      // `List of devices attached` 的第二列是 `of`；若不按状态白名单过滤，
      // 这里会凭空多出一台叫 `List` 的设备。
      final devices = AdbService.parseDevices('List of devices attached\n');
      expect(devices, isEmpty);
    });
  });

  group('parsePairResult', () {
    test('成功', () {
      final result = AdbService.parsePairResult(
        0,
        'Successfully paired to 192.168.1.5:37123 [guid=adb-R58M12ABCDE-xyz]',
      );
      expect(result.ok, isTrue);
    });

    test('配对码错误 -> 失败，原文保留给用户看', () {
      final result = AdbService.parsePairResult(
        1,
        'Failed: Invalid code. Try again.',
      );
      expect(result.ok, isFalse);
      expect(result.output, contains('Invalid code'));
    });

    test('真实失败形状：拿连接端口去 pair -> protocol fault', () {
      // 实测输出（macOS，adb 37.0.0）：
      //   error: protocol fault (couldn't read status message): Undefined error: 0
      final result = AdbService.parsePairResult(
        1,
        'error: protocol fault (couldn\'t read status message): '
        'Undefined error: 0',
      );
      expect(result.ok, isFalse);
      expect(result.output, contains('protocol fault'));
    });

    test('成功时退出码非零也认（文本优先）', () {
      final result = AdbService.parsePairResult(
        1,
        'Successfully paired to 192.168.1.35:37123 [guid=adb-xyz]',
      );
      expect(result.ok, isTrue);
    });

    test('退出码 0 但文本不是成功 -> 仍判失败', () {
      // 少数版本对失败也返回 0，只把原因写进输出。
      final result = AdbService.parsePairResult(
          0, 'Failed: unable to connect to 10.0.0.2');
      expect(result.ok, isFalse);
    });
  });

  group('parseConnectResult', () {
    test('connected to', () {
      expect(
        AdbService.parseConnectResult(0, 'connected to 192.168.1.5:5555').ok,
        isTrue,
      );
    });

    test('already connected 也算成功', () {
      expect(
        AdbService.parseConnectResult(
                0, 'already connected to 192.168.1.5:5555')
            .ok,
        isTrue,
      );
    });

    test('failed to connect -> 失败（哪怕退出码是 0）', () {
      final result = AdbService.parseConnectResult(
          0, 'failed to connect to 10.0.0.2:5555');
      expect(result.ok, isFalse);
      expect(result.output, contains('failed to connect'));
    });

    test('输出为空时给出退出码，不返回空字符串', () {
      final result = AdbService.parseConnectResult(7, '   ');
      expect(result.ok, isFalse);
      expect(result.output, contains('7'));
    });
  });

  group('normalizeAddress', () {
    test('connect：省略端口补 5555', () {
      expect(AdbService.normalizeAddress('192.168.1.5'), '192.168.1.5:5555');
    });

    test('connect：给了端口就原样用', () {
      expect(
        AdbService.normalizeAddress('192.168.1.5:4321'),
        '192.168.1.5:4321',
      );
    });

    test('pair：省略端口必须判为非法（配对端口是随机的）', () {
      expect(
        AdbService.normalizeAddress('192.168.1.5', defaultPort: null),
        isNull,
      );
    });

    test('pair：显式端口通过', () {
      expect(
        AdbService.normalizeAddress('192.168.1.5:37123', defaultPort: null),
        '192.168.1.5:37123',
      );
    });

    test('顺手粘进来的 `adb connect ` 前缀会被去掉', () {
      expect(
        AdbService.normalizeAddress('adb connect 192.168.1.5:5555'),
        '192.168.1.5:5555',
      );
    });

    test('空白、非法端口、带空格的主机名一律拒绝', () {
      expect(AdbService.normalizeAddress(''), isNull);
      expect(AdbService.normalizeAddress('   '), isNull);
      expect(AdbService.normalizeAddress('192.168.1.5:'), isNull);
      expect(AdbService.normalizeAddress('192.168.1.5:0'), isNull);
      expect(AdbService.normalizeAddress('192.168.1.5:70000'), isNull);
      expect(AdbService.normalizeAddress('192.168.1.5:abc'), isNull);
      expect(AdbService.normalizeAddress('host name'), isNull);
    });

    test('主机名与 .local 也可以', () {
      expect(AdbService.normalizeAddress('pixel.local'), 'pixel.local:5555');
    });
  });

  // `connect` 失败时会用 TCP 探测把「端口不通」和「adb 后台进程坏了」分开 ——
  // 后者也报 `No route to host`，但要做的事完全相反。实测：`nc` 能连上
  // 192.168.1.35:43931，`adb connect` 却报 no route，kill-server 后立刻成功。
  group('probeTcp', () {
    test('有人在监听 → true', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      expect(await AdbService.probeTcp('127.0.0.1', server.port), isTrue);
    });

    test('端口没人监听 → false（而不是抛异常）', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      expect(
        await AdbService.probeTcp(
          '127.0.0.1',
          port,
          timeout: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('主机不可解析 → false', () async {
      expect(
        await AdbService.probeTcp(
          'this-host-does-not-exist.invalid',
          5555,
          timeout: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });
  });
}
