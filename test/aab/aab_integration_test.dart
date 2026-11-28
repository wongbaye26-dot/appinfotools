// .aab 的端到端接线测试：白名单放行 + getApkInfo 分支 + 模型字段。
//
// 这里不复用 page 层，只验证「文件进来之后模型里有什么」—— UI 的卡片
// 条件由 widget 测试覆盖，不属于本文件的职责。
import 'dart:io';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_parser/apk_parser.dart' show ComponentType;
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:apk_info_tool/utils/package_identity.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../packages/apk_parser/test/aab/support/aab_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('aab_integration_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<String> write(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  test('getApkInfo 识别 .aab 并填充清单、资源与结构字段', () async {
    final path = await write('app.aab', buildStandardAab());
    final info = await getApkInfo(path);

    expect(info, isNotNull);
    info!;
    expect(info.archiveType, 'AAB');
    // AAB 不是可安装归档：不能被当成 XAPK / APK 集合。
    expect(info.isXapk, isFalse);

    expect(info.packageName, 'com.example.aab');
    expect(info.versionCode, 42);
    expect(info.versionName, '1.2.3');
    expect(info.sdkVersion, 21);
    expect(info.targetSdkVersion, 33);

    expect(info.label, 'Demo App');
    expect(info.labels, {'zh-CN': '演示应用', 'en': 'Demo EN'});
    expect(info.icons, isNotEmpty);
    expect(
      info.mainIconPath,
      'base/res/mipmap-xxxhdpi-v4/ic_launcher.png',
    );

    expect(info.nativeCodes, ['arm64-v8a']);
    expect(info.locales, containsAll(['en', 'zh-CN']));
    expect(info.densities, containsAll(['160', '640']));
    expect(info.structure.dexFileCount, 2);
    expect(info.structure.nativeLibraryCount, 1);

    expect(info.parseFailureReason, isNull);
    expect(info.aabResourceFailure, isNull);
  });

  test('AAB 清单：权限、组件、特性、debuggable、compileSdk 进入模型', () async {
    final path = await write(
      'decls.aab',
      buildStandardAab(
        manifest: standardManifest(
          compileSdk: 35,
          debuggable: true,
          usesCleartextTraffic: false,
          permissions: const [
            'android.permission.INTERNET',
            'android.permission.CAMERA',
          ],
          requiredFeatures: const ['android.hardware.camera'],
          optionalFeatures: const ['android.hardware.touchscreen'],
          componentElements: [
            xmlChild(xmlElement('activity', attributes: [
              xmlAttribute('name', rawValue: '.MainActivity'),
              xmlAttribute('exported', rawValue: 'true'),
              xmlAttribute('enabled', rawValue: 'false'),
            ], children: [
              xmlChild(xmlElement('intent-filter', children: [
                xmlChild(xmlElement('action', attributes: [
                  xmlAttribute('name', rawValue: 'android.intent.action.VIEW'),
                ])),
                xmlChild(xmlElement('data', attributes: [
                  xmlAttribute('scheme', rawValue: 'https'),
                ])),
              ])),
            ])),
            xmlChild(xmlElement('service', attributes: [
              xmlAttribute('name', rawValue: '.SyncService'),
              xmlAttribute('exported', rawValue: 'false'),
            ])),
          ],
        ),
      ),
    );
    final info = await getApkInfo(path);

    expect(info, isNotNull);
    info!;
    expect(info.usesPermissions, [
      'android.permission.INTERNET',
      'android.permission.CAMERA',
    ]);
    expect(info.userFeatures, ['android.hardware.camera']);
    expect(info.userFeaturesNotRequired, ['android.hardware.touchscreen']);
    expect(info.applicationDebuggable, isTrue);
    expect(info.compileSdkVersion, 35);

    expect(info.components.length, 2);
    final activity =
        info.components.firstWhere((c) => c.type == ComponentType.activity);
    expect(activity.name, '.MainActivity');
    expect(activity.exported, isTrue);
    expect(activity.enabled, isFalse);
    expect(activity.intentFilters.single.schemes, ['https']);
    final service =
        info.components.firstWhere((c) => c.type == ComponentType.service);
    expect(service.exported, isFalse);
  });

  test('损坏的 .aab 返回带失败原因的 ApkInfo，而不是 null', () async {
    final path = await write('broken.aab', 'not a zip'.codeUnits);
    final info = await getApkInfo(path);

    expect(info, isNotNull);
    expect(info!.archiveType, 'AAB');
    expect(info.parseFailureReason, isNotNull);
    expect(info.parseFailureReason, contains('ZIP'));
    // 容器都打不开时不能伪造结构统计。
    expect(info.structure.fileEntryCount, 0);
  });

  test('resources.pb 缺失：清单元数据保留，资源层失败单独进诊断', () async {
    final path = await write(
      'no-res.aab',
      buildStandardAab(includeResources: false),
    );
    final info = await getApkInfo(path);

    expect(info, isNotNull);
    expect(info!.packageName, 'com.example.aab');
    // 清单读出来了，就不可能同时报「清单读不出来」。
    expect(info.parseFailureReason, isNull);
    expect(info.label, isNull);
    expect(info.aabResourceFailure, contains('base/resources.pb is missing'));
    expect(
      info.diagnostics.any(
        (diagnostic) => diagnostic.code == 'android.aab_resources_unresolved',
      ),
      isTrue,
      reason: '资源层失败必须能被界面说清楚，而不是只留在内存里',
    );
  });

  test('重名后缀 app.aab.1 仍然按 AAB 解析，而不是掉进 APK 流程', () async {
    final path = await write('app.aab.1', buildStandardAab());
    final info = await getApkInfo(path);

    expect(info, isNotNull);
    expect(info!.archiveType, 'AAB');
    expect(info.packageName, 'com.example.aab');
    expect(info.parseFailureReason, isNull);
  });

  test('批量重命名也能读到 AAB 的应用名与版本', () async {
    final path = await write('rename.aab', buildStandardAab());
    final identity = await readPackageIdentityInIsolate(path);

    expect(identity.platform, PackageIdentityPlatform.android);
    expect(identity.appName, 'Demo App');
    expect(identity.version, '1.2.3');
    expect(identity.failure, isNull);
  });

  test('文件选择器与拖放白名单放行 .aab', () {
    expect(kPickableExtensions, contains('aab'));
    expect(isSupportedPackagePath('/tmp/app.aab'), isTrue);
    // 下载渠道加的重名后缀同样要认。
    expect(isSupportedPackagePath('/tmp/app.aab.1'), isTrue);
    expect(isSupportedPackagePath('/tmp/app.AAB'), isTrue);
  });
}
