// Android 平台元数据（保护级别 / 风险分级 / 官方文案）。
//
// 风险分级是**工具自己的策略**，不是 Android 的结论 —— 这些断言钉住
// 「策略表 + 位掩码解析」两层的组合结果，避免以后调表时悄悄改变排序。

import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AndroidMetadata meta;

  setUpAll(() async {
    meta = AndroidMetadata.instance;
    await meta.ensureLoaded();
  });

  group('保护级别位掩码', () {
    test('基础级别取低四位', () {
      expect(AndroidProtection.parse(1).base, AndroidProtectionBase.dangerous);
      expect(AndroidProtection.parse(2).base, AndroidProtectionBase.signature);
      expect(
        AndroidProtection.parse(3).base,
        AndroidProtectionBase.signatureOrSystem,
      );
      expect(AndroidProtection.parse(4).base, AndroidProtectionBase.internal);
      expect(AndroidProtection.parse(0).base, AndroidProtectionBase.normal);
    });

    test('标记位不影响基础级别', () {
      // 0x12 = signature | privileged，真实数据里出现 283 次。
      final protection = AndroidProtection.parse(0x12);
      expect(protection.base, AndroidProtectionBase.signature);
      expect(protection.flags, contains('privileged'));
    });

    test('框架权限能查到原始值，自定义权限查不到', () {
      expect(meta.protectionOf('android.permission.CAMERA'), isNotNull);
      expect(meta.protectionOf('com.example.CUSTOM'), isNull);
    });
  });

  group('风险分级', () {
    test('高危清单优先于保护级别', () {
      expect(
        meta.riskOf('android.permission.READ_SMS'),
        AndroidPermissionRisk.high,
      );
      expect(
        meta.riskOf('android.permission.MANAGE_EXTERNAL_STORAGE'),
        AndroidPermissionRisk.high,
      );
    });

    test('危险级落到 sensitive', () {
      expect(
        meta.riskOf('android.permission.CAMERA'),
        AndroidPermissionRisk.sensitive,
      );
    });

    test('普通级落到 normal', () {
      expect(
        meta.riskOf('android.permission.ACCESS_NETWORK_STATE'),
        AndroidPermissionRisk.normal,
      );
    });

    test('签名级落到 system', () {
      expect(
        meta.riskOf('android.permission.WRITE_SECURE_SETTINGS'),
        AndroidPermissionRisk.system,
      );
    });

    test('表外权限一律 unknown，不猜', () {
      expect(
        meta.riskOf('com.example.permission.INTERNAL'),
        AndroidPermissionRisk.unknown,
      );
      expect(
        meta.riskOf('android.permission.NOT_A_REAL_PERMISSION'),
        AndroidPermissionRisk.unknown,
      );
    });
  });

  group('文案与名称', () {
    test('框架权限有官方标题与说明', () {
      expect(meta.permissionLabel('android.permission.CAMERA'), isNotEmpty);
      expect(
          meta.permissionDescription('android.permission.CAMERA'), isNotEmpty);
    });

    test('自定义权限没有平台文案', () {
      expect(meta.permissionLabel('com.example.permission.INTERNAL'), isNull);
    });

    test('特性说明按完整名称查', () {
      expect(meta.featureDescription('android.hardware.camera'), isNotEmpty);
      expect(
          meta.featureDescription('android.hardware.unknown_feature'), isNull);
    });

    test('语言名称与自称都能取到', () {
      final names = meta.localeNames('zh-CN');
      expect(names.language, isNotEmpty);
      expect(names.region, isNotEmpty);
      expect(meta.autonymOf('zh-CN'), isNotEmpty);
    });
  });
}
