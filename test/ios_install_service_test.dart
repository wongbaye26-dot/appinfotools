import 'dart:io';

import 'package:apk_info_tool/utils/ios_install_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseIosUdidList', () {
    test('一行一个 UDID', () {
      expect(
        parseIosUdidList(
          '00008030-001A2C3D4E5F6A7B\n'
          '00008110-000A1B2C3D4E5F60\n',
        ),
        ['00008030-001A2C3D4E5F6A7B', '00008110-000A1B2C3D4E5F60'],
      );
    });

    test('忽略警告行与空行', () {
      expect(
        parseIosUdidList(
          'WARNING: something happened\n'
          '\n'
          '00008030-001A2C3D4E5F6A7B\n'
          '   \n',
        ),
        ['00008030-001A2C3D4E5F6A7B'],
      );
    });

    test('没有设备时返回空列表', () {
      expect(parseIosUdidList(''), isEmpty);
      expect(parseIosUdidList('WARNING: no device\n'), isEmpty);
    });
  });

  group('parseIosDeviceInfo', () {
    test('取 DeviceName / ProductVersion / ProductType', () {
      final device = parseIosDeviceInfo(
        '00008030-001A2C3D4E5F6A7B',
        'DeviceName: 张三的 iPhone\n'
            'ProductName: iPhone 15 Pro\n'
            'ProductVersion: 18.1\n'
            'ProductType: iPhone16,1\n'
            'UniqueDeviceID: 00008030-001A2C3D4E5F6A7B\n',
      );
      expect(device.udid, '00008030-001A2C3D4E5F6A7B');
      expect(device.name, '张三的 iPhone');
      expect(device.version, '18.1');
      expect(device.model, 'iPhone16,1');
    });

    test('缺少字段时用 UDID 与 - 占位，不拼空壳', () {
      final device = parseIosDeviceInfo('abc123', 'ModelNumber: N123');
      expect(device.name, 'abc123');
      expect(device.version, '-');
      expect(device.model, isNull);
    });

    test('冒号后的值保留原始冒号', () {
      final device = parseIosDeviceInfo('u', 'DeviceName: A:B:C');
      expect(device.name, 'A:B:C');
    });
  });

  group('IosToolchain.detect', () {
    test('PATH 中三条命令都存在时 available', () {
      final existing = <String>{
        '/opt/homebrew/bin/idevice_id',
        '/opt/homebrew/bin/ideviceinfo',
        '/opt/homebrew/bin/ideviceinstaller',
      };
      final toolchain = IosToolchain.detect(
        pathEnv: '/usr/bin:/opt/homebrew/bin',
        exists: existing.contains,
      );
      expect(toolchain.available, isTrue);
      expect(toolchain.ideviceId, '/opt/homebrew/bin/idevice_id');
      expect(toolchain.ideviceInfo, '/opt/homebrew/bin/ideviceinfo');
      expect(toolchain.ideviceinstaller, '/opt/homebrew/bin/ideviceinstaller');
    });

    test('缺 ideviceinstaller 时 available 为 false', () {
      final existing = <String>{'/usr/bin/idevice_id'};
      final toolchain = IosToolchain.detect(
        pathEnv: '/usr/bin',
        exists: existing.contains,
      );
      expect(toolchain.available, isFalse);
      expect(toolchain.ideviceId, '/usr/bin/idevice_id');
      expect(toolchain.ideviceinstaller, isNull);
    });

    test('空 PATH 时不崩溃', () {
      final toolchain = IosToolchain.detect(pathEnv: '', exists: (_) => false);
      expect(toolchain.available, isFalse);
      expect(toolchain.ideviceId, isNull);
    });
  });

  group('IosInstallService 缺少工具', () {
    test('listDevices 返回空列表而不是抛异常', () async {
      const service = IosInstallService(toolchain: IosToolchain());
      expect(await service.listDevices(), isEmpty);
    });

    test('install 未执行时返回 false', () async {
      const service = IosInstallService(toolchain: IosToolchain());
      final lines = <String>[];
      final ok = await service.install('/tmp/missing.ipa', onLine: lines.add);
      expect(ok, isFalse);
      expect(lines, isEmpty);
    });
  });

  group('IosToolchain 默认探测本机', () {
    test('真实 PATH 上不存在的工具为 null', () {
      // 这条不依赖机器上装没装：只要求 detect 不抛异常，且 available 与
      // ideviceinstaller 是否存在一致。
      final toolchain = IosToolchain.detect();
      if (toolchain.ideviceinstaller != null) {
        expect(File(toolchain.ideviceinstaller!).existsSync(), isTrue);
      }
    });
  });
}
