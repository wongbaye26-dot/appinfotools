import 'package:analysis_model/analysis_model.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

const _src = FieldSource.signatureMaterials;
FieldValue<T> v<T>(T value) => FieldValue<T>.extracted(value, source: _src);

void main() {
  test('ProvisionsAllDevices=true → enterprise', () {
    final p = IosProvisioningProfile(
        provisionsAllDevices: v(true), provisionedDeviceCount: v(0));
    expect(p.distribution, IosDistributionType.enterprise);
  });

  test('设备白名单 + get-task-allow=true → development', () {
    final p = IosProvisioningProfile(
      provisionsAllDevices: v(false),
      provisionedDeviceCount: v(12),
      getTaskAllow: v(true),
    );
    expect(p.distribution, IosDistributionType.development);
  });

  test('设备白名单 + get-task-allow=false → adHoc', () {
    final p = IosProvisioningProfile(
      provisionsAllDevices: v(false),
      provisionedDeviceCount: v(12),
      getTaskAllow: v(false),
    );
    expect(p.distribution, IosDistributionType.adHoc);
  });

  test('无白名单、非开发 → appStore', () {
    final p = IosProvisioningProfile(
      provisionsAllDevices: v(false),
      provisionedDeviceCount: v(0),
      getTaskAllow: v(false),
    );
    expect(p.distribution, IosDistributionType.appStore);
  });

  test('字段缺失 → unknown，不猜 App Store', () {
    const p = IosProvisioningProfile();
    expect(p.distribution, IosDistributionType.unknown);
  });
}
