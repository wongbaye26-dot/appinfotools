import 'dart:io';
import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

import 'support/aab_builder.dart';

/// 真实 AAB 样本不在仓库里（体积大、含第三方代码），因此这个用例只在
/// 环境里存在样本时才跑：设置 `AAB_SAMPLE=/path/to/app.aab`，或放到
/// `/tmp/app.aab`。
final String? _sampleAab = _findSampleAab();

String? _findSampleAab() {
  final fromEnv = Platform.environment['AAB_SAMPLE'];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return fromEnv;
  }
  for (final candidate in const ['/tmp/app.aab', '/tmp/sample.aab']) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('aab_reader_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<String> write(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  group('AabReader 正常路径', () {
    test('解析清单、资源、dex 与原生库', () async {
      final path = await write('app.aab', buildStandardAab());
      final reader = AabReader();
      final info = await reader.read(path);

      expect(reader.lastFailure, isNull);
      expect(info, isNotNull);
      info!;

      expect(info.packageName, 'com.example.aab');
      expect(info.versionCode, 42);
      expect(info.versionName, '1.2.3');
      expect(info.minSdkVersion, 21);
      expect(info.targetSdkVersion, 33);

      expect(info.label, 'Demo App');
      expect(info.labels, {'zh-CN': '演示应用', 'en': 'Demo EN'});

      // 资源里的 file 路径是模块内相对路径，必须拼上 base/ 才能命中 ZIP 条目。
      expect(info.iconPaths.keys.toSet(), {'mdpi', 'xxxhdpi', 'anydpi'});
      expect(
        info.iconPaths.values.every((value) => value.startsWith('base/')),
        isTrue,
      );
      expect(
        info.mainIconPath,
        'base/res/mipmap-xxxhdpi-v4/ic_launcher.png',
      );

      expect(info.dexEntries, [
        'base/dex/classes.dex',
        'base/dex/classes2.dex',
      ]);
      expect(info.nativeLibraries, hasLength(1));
      expect(info.nativeLibraries.single.abi, 'arm64-v8a');
      expect(info.nativeLibraries.single.name, 'libfoo.so');
      expect(info.nativeLibraries.single.size, 128);

      expect(info.fileCount, 6);
      expect(info.totalUncompressedBytes, greaterThan(0));
      expect(info.structure.fileEntryCount, 6);
      expect(info.structure.dexFileCount, 2);
      expect(info.structure.nativeLibraryCount, 1);
      expect(info.structure.abis, ['arm64-v8a']);
      expect(info.structure.topLevelDirectories['base']!.fileCount, 5);
      expect(info.structure.topLevelDirectories['(root)']!.fileCount, 1);

      // 一切读全时不应有任何失败说明。
      expect(info.failureReason, isNull);
      expect(info.resourceFailure, isNull);
    });

    test('清单里的 label 是原文时直接展示，不伪装成引用', () async {
      final path = await write(
        'inline.aab',
        buildStandardAab(
          manifest: standardManifest(labelRef: null, inlineLabel: 'Inline App'),
          includeResources: false,
        ),
      );

      final info = await AabReader().read(path);
      expect(info!.label, 'Inline App');
      expect(info.labels, isEmpty);
    });

    test('内联 icon 原文同样被当作条目路径', () async {
      final path = await write(
        'inline-icon.aab',
        buildStandardAab(
          manifest: standardManifest(
            iconRef: null,
            inlineIcon: 'res/drawable/ic_launcher.png',
          ),
          includeResources: false,
        ),
      );

      final info = await AabReader().read(path);
      expect(
        info!.iconPaths['default'],
        'base/res/drawable/ic_launcher.png',
      );
      expect(info.mainIconPath, 'base/res/drawable/ic_launcher.png');
    });

    test('resources.pb 缺失是部分失败：清单字段仍在，原因可读', () async {
      final path = await write(
        'no-res.aab',
        buildStandardAab(includeResources: false),
      );

      final info = await AabReader().read(path);
      expect(info!.packageName, 'com.example.aab');
      expect(info.versionCode, 42);
      // 引用解不出来时 label 保持 null，而不是塞一个空字符串。
      expect(info.label, isNull);
      expect(info.iconPaths, isEmpty);
      expect(info.failureReason, isNull);
      expect(info.resourceFailure, contains('base/resources.pb is missing'));
    });

    test('resources.pb 截断是部分失败，不拖垮清单', () async {
      final tableBytes = standardResourceTable().toBytes();
      final brokenTable =
          Uint8List.sublistView(tableBytes, 0, tableBytes.length - 3);
      final fixture = AabFixture()
        ..add('base/manifest/AndroidManifest.xml', standardManifest())
        ..add('base/resources.pb', brokenTable)
        ..addDex('base', 'classes.dex');
      final path = await write('truncated-res.aab', fixture.build());

      final info = await AabReader().read(path);
      expect(info!.packageName, 'com.example.aab');
      expect(info.label, isNull);
      expect(info.failureReason, isNull);
      expect(
        info.resourceFailure,
        contains('could not be parsed as a protobuf resource table'),
      );
    });
  });

  group('AabReader 失败路径', () {
    test('空文件：容器层打不开，返回 null 并留下原因', () async {
      final path = await write('empty.aab', const <int>[]);
      final reader = AabReader();
      final info = await reader.read(path);

      expect(info, isNull);
      expect(reader.lastFailure, contains('not a ZIP archive'));
    });

    test('非 ZIP 文件返回 null', () async {
      final path = await write('text.aab', 'not a zip'.codeUnits);
      final reader = AabReader();
      expect(await reader.read(path), isNull);
      expect(reader.lastFailure, isNotNull);
    });

    test('缺少 base 清单：返回带原因的 AabInfo，dex 统计仍然保留', () async {
      final fixture = AabFixture()
        ..addBundleConfig()
        ..add('base/resources.pb', standardResourceTable().toBytes())
        ..addDex('base', 'classes.dex');
      final path = await write('no-manifest.aab', fixture.build());

      final info = await AabReader().read(path);
      expect(info, isNotNull);
      expect(
          info!.failureReason, contains('base/manifest/AndroidManifest.xml'));
      expect(info.packageName, isNull);
      expect(info.dexEntries, ['base/dex/classes.dex']);
      expect(info.fileCount, 3);
    });

    test('根级 AndroidManifest.xml：明确说这不是 AAB', () async {
      final fixture = AabFixture()
        ..add('AndroidManifest.xml', standardManifest())
        ..addDex('base', 'classes.dex');
      final path = await write('apk-like.aab', fixture.build());

      final info = await AabReader().read(path);
      expect(info!.failureReason, contains('not an Android App Bundle'));
    });

    test('只有 feature 模块清单：列出找到的清单', () async {
      final fixture = AabFixture()
        ..add('feature1/manifest/AndroidManifest.xml', standardManifest())
        ..addDex('feature1', 'classes.dex');
      final path = await write('feature-only.aab', fixture.build());

      final info = await AabReader().read(path);
      expect(
          info!.failureReason, contains('is missing; module manifests found'));
      expect(
        info.failureReason,
        contains('feature1/manifest/AndroidManifest.xml'),
      );
    });

    test('清单被截断：报 protobuf XML 解码失败', () async {
      final manifest = standardManifest();
      final truncated = Uint8List.sublistView(
        manifest,
        0,
        manifest.length - 4,
      );
      final path = await write(
        'bad-manifest.aab',
        buildStandardAab(manifest: truncated, includeResources: false),
      );

      final info = await AabReader().read(path);
      expect(info, isNotNull);
      expect(
        info!.failureReason,
        contains('could not be decoded as protobuf XML'),
      );
    });

    test('根元素不是 manifest：报元素名', () async {
      final path = await write(
        'wrong-root.aab',
        buildStandardAab(
          manifest: standardManifest(rootName: 'bundle'),
          includeResources: false,
        ),
      );

      final info = await AabReader().read(path);
      expect(info!.failureReason, contains('root element is <bundle>'));
      expect(info.failureReason, contains('not <manifest>'));
    });

    test('minSdkVersion 写成代号时读不出数字，不猜', () async {
      final path = await write(
        'codename-sdk.aab',
        buildStandardAab(
          manifest: standardManifest(minSdk: null, minSdkCodename: 'Q'),
          includeResources: false,
        ),
      );

      final info = await AabReader().read(path);
      expect(info!.minSdkVersion, isNull);
      // 其它字段不受影响。
      expect(info.targetSdkVersion, 33);
    });
  });

  group('清单：权限 / 特性 / 组件 / 开关', () {
    Uint8List manifestWithComponents() => standardManifest(
          compileSdk: 35,
          debuggable: true,
          usesCleartextTraffic: false,
          permissions: const [
            'android.permission.INTERNET',
            'android.permission.CAMERA',
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
                xmlChild(xmlElement('category', attributes: [
                  xmlAttribute(
                    'name',
                    rawValue: 'android.intent.category.DEFAULT',
                  ),
                ])),
                xmlChild(xmlElement('data', attributes: [
                  xmlAttribute('scheme', rawValue: 'https'),
                ])),
              ])),
            ])),
            xmlChild(xmlElement('service', attributes: [
              xmlAttribute('name', rawValue: '.SyncService'),
              xmlAttribute('exported', rawValue: 'false'),
              xmlAttribute(
                'permission',
                rawValue: 'com.example.aab.permission.SYNC',
              ),
            ])),
            xmlChild(xmlElement('provider', attributes: [
              xmlAttribute('name', rawValue: '.Files'),
              xmlAttribute('authorities', rawValue: 'com.example.aab.files'),
              xmlAttribute('readPermission', rawValue: 'READ'),
              xmlAttribute('writePermission', rawValue: 'WRITE'),
              xmlAttribute('grantUriPermissions', rawValue: 'true'),
            ])),
            xmlChild(xmlElement('activity-alias', attributes: [
              xmlAttribute('name', rawValue: '.Alias'),
              xmlAttribute('targetActivity', rawValue: '.MainActivity'),
            ])),
          ],
        );

    test('权限去重且保序；特性区分必需/可选', () async {
      final path = await write(
        'manifest-decls.aab',
        buildStandardAab(manifest: manifestWithComponents()),
      );

      final info = await AabReader().read(path);
      expect(info!.usesPermissions, [
        'android.permission.INTERNET',
        'android.permission.CAMERA',
      ]);
      expect(info.features.map((f) => f.name), [
        'android.hardware.camera',
        'android.hardware.touchscreen',
      ]);
      expect(info.features.map((f) => f.required), [true, false]);
    });

    test('组件：类型、导出三态、权限、intent-filter 明细', () async {
      final path = await write(
        'manifest-components.aab',
        buildStandardAab(manifest: manifestWithComponents()),
      );

      final info = await AabReader().read(path);
      final components = info!.components;
      expect(components.length, 4);

      final activity =
          components.firstWhere((c) => c.type == ComponentType.activity);
      expect(activity.name, '.MainActivity');
      expect(activity.exported, isTrue);
      expect(activity.enabled, isFalse);
      expect(activity.hasIntentFilter, isTrue);
      expect(activity.intentFilters.single.actions,
          ['android.intent.action.VIEW']);
      expect(activity.intentFilters.single.categories,
          ['android.intent.category.DEFAULT']);
      expect(activity.intentFilters.single.schemes, ['https']);

      final service =
          components.firstWhere((c) => c.type == ComponentType.service);
      expect(service.exported, isFalse);
      expect(service.permission, 'com.example.aab.permission.SYNC');
      expect(service.hasIntentFilter, isFalse);

      final provider =
          components.firstWhere((c) => c.type == ComponentType.provider);
      expect(provider.authorities, 'com.example.aab.files');
      expect(provider.readPermission, 'READ');
      expect(provider.writePermission, 'WRITE');
      expect(provider.grantUriPermissions, isTrue);

      final alias =
          components.firstWhere((c) => c.type == ComponentType.activityAlias);
      expect(alias.name, '.Alias');
      expect(alias.exported, isNull);
    });

    test('compileSdk / debuggable / cleartext 三态', () async {
      final path = await write(
        'manifest-switches.aab',
        buildStandardAab(manifest: manifestWithComponents()),
      );

      final info = await AabReader().read(path);
      expect(info!.compileSdkVersion, 35);
      expect(info.applicationDebuggable, isTrue);
      expect(info.applicationUsesCleartextTraffic, isFalse);
    });

    test('未声明的开关保持 null，不猜平台默认值', () async {
      final path = await write('manifest-plain.aab', buildStandardAab());

      final info = await AabReader().read(path);
      expect(info!.compileSdkVersion, isNull);
      expect(info.applicationDebuggable, isNull);
      expect(info.applicationUsesCleartextTraffic, isNull);
      expect(info.usesPermissions, isEmpty);
      expect(info.components, isEmpty);
    });
  });

  test(
    '解析真实 .aab 样本',
    () async {
      final info = await AabReader().read(_sampleAab!);
      expect(info, isNotNull);
      expect(info!.failureReason, isNull);
      expect(info.packageName, isNotNull);
      expect(info.fileCount, greaterThan(0));
    },
    skip: _sampleAab == null
        ? '未找到真实 .aab 样本（设置 AAB_SAMPLE 或放到 /tmp/app.aab）'
        : false,
  );
}
