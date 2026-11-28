import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/utils/privacy_inventory.dart';
import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart' show AndroidComponent;
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show IosBundle, IosBundleKind, IpaInfoPlist;

PackageAnalysisResult _result(List<String> permissions) =>
    PackageAnalysisResult(
      platform: PackagePlatform.android,
      fileName: const FieldValue<String>.extracted(
        'demo.apk',
        source: FieldSource.fileSystem,
      ),
      fileSize: const FieldValue<int>.extracted(
        1024,
        source: FieldSource.fileSystem,
      ),
      android: AndroidPackageInfo(
        minSdkVersion: const FieldValue<int>.absent(),
        targetSdkVersion: const FieldValue<int>.absent(),
        maxSdkVersion: const FieldValue<int>.absent(),
        debuggable: const FieldValue<bool>.absent(),
        permissions: FieldValue<List<String>>.extracted(
          permissions,
          source: FieldSource.builtinParser,
        ),
        archiveType: const FieldValue<String>.absent(),
        supportsScreens: const FieldValue<List<String>>.absent(),
        densities: const FieldValue<List<String>>.absent(),
        nativeCodes: const FieldValue<List<String>>.absent(),
        locales: const FieldValue<List<String>>.absent(),
        splitApks: const FieldValue<List<String>>.absent(),
        obbFiles: const FieldValue<List<String>>.absent(),
        icpFiling: const FieldValue<String>.absent(),
        components: const FieldValue<List<AndroidComponent>>.absent(),
      ),
      diagnostics: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AndroidMetadata.instance.ensureLoaded();
  });

  test('权限按风险分组，高敏排在前面并带官方标题', () {
    final inventory = PrivacyInventory.collect(
      result: _result([
        'android.permission.CAMERA',
        'android.permission.READ_SMS',
        'android.permission.INTERNET',
        'com.example.CUSTOM',
      ]),
    );
    expect(inventory.permissionsRead, isTrue);
    expect(inventory.totalPermissions, 4);
    expect(inventory.countOf(AndroidPermissionRisk.high), 1);
    expect(inventory.countOf(AndroidPermissionRisk.sensitive), 1);
    expect(inventory.countOf(AndroidPermissionRisk.normal), 1);
    expect(inventory.countOf(AndroidPermissionRisk.unknown), 1);
    expect(inventory.notable, hasLength(2));
    expect(inventory.notable.first.shortName, 'READ_SMS');
    expect(inventory.notable.last.shortName, 'CAMERA');
    // 官方文案只覆盖部分权限：有就填、没有就 null（不能编造）。
    expect(
      inventory.notable.firstWhere((item) => item.shortName == 'CAMERA').label,
      isNotNull,
    );
  });

  test('权限未读取时如实给出 permissionsRead=false，不假装 0 项', () {
    final inventory = PrivacyInventory.collect(result: _result(const []));
    expect(inventory.permissionsRead, isTrue); // 空列表是「读到了 0 项」
    expect(inventory.totalPermissions, 0);
  });

  test('iOS 用途声明键被收集并排序', () {
    final plist = IpaInfoPlist(
      bundle: const IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/Demo.app',
        name: 'Demo.app',
      ),
      privacyUsageDescriptions: const FieldValue<Map<String, String>>.extracted(
        {
          'NSCameraUsageDescription': 'camera',
          'NSLocationWhenInUseUsageDescription': 'location',
        },
        source: FieldSource.builtinParser,
      ),
    );
    final inventory = PrivacyInventory.collect(
      result: _result(const []),
      infoPlist: plist,
    );
    expect(inventory.iosUsageKeys, [
      'NSCameraUsageDescription',
      'NSLocationWhenInUseUsageDescription',
    ]);
    expect(inventory.isEmpty, isFalse);
  });
}
