// 分包安装包的元数据不再依赖 aapt2。
//
// 背景：XAPK / APKM / APKS 的标签、图标、组件、ABI 此前全部来自
// `aapt2 dump badging`。没装 Android SDK 的机器上，分包包只剩
// `manifest.json` 里那几个字段，图标缺失、组件为空 —— 而内置解析器本来
// 就能读 APK。现在内置解析器优先，aapt2 退居兜底。
//
// 用真实夹具：`test/fixtures/xapk/xapk-fixture.xapk` 的内层 base.apk 是
// aapt2 真实产出（见 xapk_real_fixture_test.dart 的说明）。

import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/xapk/xapk-fixture.xapk';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('没有 aapt2 也能从 base APK 取到标签、包名、版本与组件', () async {
    expect(File(_fixture).existsSync(), isTrue, reason: '缺少 XAPK 夹具');

    final info = await getApkInfo(_fixture);
    expect(info, isNotNull);
    addTearDown(() => info!.dispose());

    expect(info!.isXapk, isTrue);
    expect(info.archiveType, 'XAPK');
    expect(info.packageName, isNotEmpty, reason: '包名来自 base APK 清单');
    expect(info.versionName, isNotEmpty);
    expect(info.label, isNotEmpty, reason: '标签来自 base APK 的资源表');
    expect(info.sdkVersion, isNotNull);
    // 真实夹具的 base APK 声明了启动 Activity；内置解析器能读出来。
    expect(info.components, isNotEmpty);
    expect(info.launchableActivity, isNotEmpty);
  });

  test('图标从 base APK 渲染，不需要 aapt2 dump resources', () async {
    // 真实 XAPK 夹具的 base.apk 是 aapt2 link 的最小产物（没有 res/），
    // 拿它测图标等于测「没有图标」。这里用带 PNG 图标的 APK 现场组一个
    // 容器：容器格式不影响被测路径，图标只能来自 base.apk。
    final dir = await Directory.systemTemp.createTemp('xapk_icon');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final baseBytes =
        await File('test/fixtures/apk/icon-png.apk').readAsBytes();
    final archive = Archive()
      ..addFile(ArchiveFile('base.apk', baseBytes.length, baseBytes))
      ..addFile(ArchiveFile.string(
        'manifest.json',
        jsonEncode({'package_name': 'com.example.iconfixture'}),
      ));
    final xapkPath = '${dir.path}/icon-fixture.xapk';
    await File(xapkPath).writeAsBytes(ZipEncoder().encode(archive));

    final info = await getApkInfo(xapkPath);
    expect(info, isNotNull);
    final parsed = info!;
    addTearDown(parsed.dispose);

    expect(
      parsed.mainIconImage,
      isNotNull,
      reason: '内置 arsc 资源表必须能支撑图标渲染',
    );
    expect(parsed.icons, isNotEmpty);
  });
}
