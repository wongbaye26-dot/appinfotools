// 设备品牌 / 型号 / 系统版本的解析。
//
// 输出形状是 `B:brand` / `N:manufacturer` / `M:model` / `S:system` 四行
// （见 `AdbService.deviceInfo`）。用带前缀的行而不是按行号取，是因为
// 部分定制 ROM 删掉了 `ro.product.brand` —— 按行号取会在空值被折叠后错位，
// 把「型号」当成「品牌」显示。

import 'package:apk_info_tool/utils/adb_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('四项齐全', () {
    final info = AdbService.parseDeviceInfo('''
B:samsung
N:samsung
M:SM_G9910
S:14
''');

    expect(info, isNotNull);
    expect(info!.brand, 'samsung');
    expect(info.model, 'SM_G9910');
    expect(info.systemVersion, '14');
  });

  test('ro.product.brand 缺失时用厂商名兜底', () {
    // 真实定制 ROM 的常见情况：只有 manufacturer。
    final info = AdbService.parseDeviceInfo('''
B:
N:Xiaomi
M:2201123C
S:13
''');

    expect(info, isNotNull);
    expect(info!.brand, 'Xiaomi');
    expect(info.model, '2201123C');
  });

  test('某项为空不影响其它项', () {
    final info = AdbService.parseDeviceInfo('B:\nN:\nM:OnlyModel\nS:\n');
    expect(info, isNotNull);
    expect(info!.model, 'OnlyModel');
    expect(info.brand, isNull);
    expect(info.systemVersion, isNull);
  });

  test('全空时返回 null（调用方据此不显示）', () {
    expect(AdbService.parseDeviceInfo('B:\nN:\nM:\nS:\n'), isNull);
    expect(AdbService.parseDeviceInfo(''), isNull);
  });

  test('adb 的噪音行不会污染解析', () {
    final info = AdbService.parseDeviceInfo('''
* daemon not running; starting now at tcp:5037
B:google
M:Pixel 7
S:15
''');

    expect(info, isNotNull);
    expect(info!.brand, 'google');
    expect(info.model, 'Pixel 7');
  });
}
