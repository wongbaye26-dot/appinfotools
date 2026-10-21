// 「连过的设备」的持久化。
//
// 这个列表唯一的价值是**无线设备免于重新输入 IP**，所以：
// - 同一台设备重复出现只能有一条（按 id 合并）；
// - 这次读不到型号时保留上次的，别把已知信息抹掉；
// - 有上限，否则「已保存」区块会比设备列表还长。

import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/utils/adb_service.dart';
import 'package:apk_info_tool/utils/known_devices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() async {
    await Config.knownDevices.updateValue('[]');
  });

  test('remember 后能读出来，且保留型号与系统版本', () async {
    await KnownDeviceStore.remember(
      id: '192.168.1.5:5555',
      wireless: true,
      info: const AdbDeviceInfo(
        brand: 'samsung',
        model: 'SM_G9910',
        systemVersion: '14',
      ),
    );

    final devices = KnownDeviceStore.load();
    expect(devices, hasLength(1));
    expect(devices.single.id, '192.168.1.5:5555');
    expect(devices.single.wireless, isTrue);
    expect(devices.single.info.model, 'SM_G9910');
    expect(devices.single.info.systemVersion, '14');
  });

  test('同一台设备重复 remember 只留一条，并更新信息', () async {
    await KnownDeviceStore.remember(
      id: 'R58M12ABCDE',
      wireless: false,
      info: const AdbDeviceInfo(model: 'OldModel'),
    );
    await KnownDeviceStore.remember(
      id: 'R58M12ABCDE',
      wireless: false,
      info: const AdbDeviceInfo(model: 'NewModel'),
    );

    final devices = KnownDeviceStore.load();
    expect(devices, hasLength(1));
    expect(devices.single.info.model, 'NewModel');
  });

  test('这次读不到信息时保留上次的，不清空', () async {
    await KnownDeviceStore.remember(
      id: 'R58M12ABCDE',
      wireless: false,
      info: const AdbDeviceInfo(brand: 'google', model: 'Pixel 7'),
    );
    // 第二次探测失败（info 为空）—— 不该把已知信息抹掉。
    await KnownDeviceStore.remember(id: 'R58M12ABCDE', wireless: false);

    expect(KnownDeviceStore.load().single.info.model, 'Pixel 7');
  });

  test('超过上限时丢掉最旧的', () async {
    for (var i = 0; i < KnownDeviceStore.maxEntries + 2; i++) {
      await KnownDeviceStore.remember(
        id: '10.0.0.$i:5555',
        wireless: true,
        info: AdbDeviceInfo(model: 'M$i'),
      );
    }

    final devices = KnownDeviceStore.load();
    expect(devices, hasLength(KnownDeviceStore.maxEntries));
    // 最早的两条应当已经被挤出去。
    expect(devices.any((d) => d.id == '10.0.0.0:5555'), isFalse);
    expect(devices.any((d) => d.id == '10.0.0.1:5555'), isFalse);
  });

  test('forget 之后不再出现', () async {
    await KnownDeviceStore.remember(id: '10.0.0.9:5555', wireless: true);
    await KnownDeviceStore.forget('10.0.0.9:5555');

    expect(KnownDeviceStore.load(), isEmpty);
  });

  test('配置被写坏时当成没有历史，不抛异常', () async {
    await Config.knownDevices.updateValue('{not json');
    expect(KnownDeviceStore.load(), isEmpty);
  });
}
