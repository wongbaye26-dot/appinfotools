// 真实 XAPK：分包清单的解析与去重。
//
// ## 为什么需要它
//
// 此前 XAPK 相关的测试样本全部由 `ZipEncoder` 现造 —— 那只能证明「预算传下去了」，
// 证明不了「真实 XAPK 的 `manifest.json` 能读懂」。而 `manifest.json` 是
// **别人定的格式**（APKPure 的 XAPK 规范），字段名和嵌套形状不能靠猜：
// `split_apks` 里每一项可能是字符串，也可能是带 `file` / `path` / `apk` / `name`
// 的对象，还可能是 `apks` / `splits` 这两个别名。
//
// ## 夹具的来历
//
// `test/fixtures/xapk/xapk-fixture.xapk` 里的**两个 APK 都是 `aapt2` 真实产出**：
//
// ```sh
// aapt2 compile --dir res -o compiled.zip
// aapt2 link -o base.apk -I $ANDROID_HOME/platforms/android-34/android.jar \
//   --manifest AndroidManifest.xml --split split-fr.apk:fr compiled.zip
// ```
//
// 容器按 XAPK 规范打包（`manifest.json` + 根目录下的 APK），
// 并**故意把同一个分包在 `split_apks` 里列了两次** —— 真实打包器合并脚本时
// 很常见。不去重的话同一个路径会被传给 `adb install-multiple` 两次，adb 直接
// 报错退出。
//
// 说明：APKPure 的下载端点对非浏览器客户端返回 403，所以这里没有直接下载
// 一个线上 XAPK；容器格式来自公开规范，内层 APK 来自真实构建工具。

import 'dart:io';

import 'package:apk_info_tool/utils/xapk_installer.dart';
import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/xapk/xapk-fixture.xapk';

void main() {
  test('分包清单能读出来，且重复项被去重', () async {
    final installer = XapkInstaller();
    final splits = await installer.getSplitApks(_fixture);

    expect(splits, isNotNull, reason: '真实 XAPK 的分包清单必须能解析');
    expect(splits, hasLength(2),
        reason: 'manifest 里列了 3 项，其中 1 项是重复的 → 应当只剩 2 个');
    expect(splits!.toSet(), hasLength(2), reason: '不能有重复路径');
  });

  test('返回的是**归档条目名**，不是解包后的路径', () async {
    final installer = XapkInstaller();
    final splits = (await installer.getSplitApks(_fixture))!;
    // 这个区分很重要：`getSplitApks` 只读清单，不解包。调用方（安装流程）
    // 才负责解包，且每个条目都要过 `safeExtractJoin`。
    for (final name in splits) {
      expect(name, isNot(contains('/tmp')), reason: '不该返回临时目录路径');
      expect(name.endsWith('.apk'), isTrue);
    }
  });

  test('清单里点名的两个条目在归档里都真实存在，且能解析成包', () async {
    final installer = XapkInstaller();
    final splits = (await installer.getSplitApks(_fixture))!;

    final zip = ZipHelper();
    addTearDown(zip.close);
    expect((await zip.open(_fixture)).isOk, isTrue);

    final parsed = <String, ApkMeta>{};
    for (final name in splits) {
      final bytes = await zip.readFileContent(name);
      expect(bytes, isNotNull, reason: '归档里没有清单点名的条目：$name');
      final reader = ApkReader();
      final opened = reader.openBytes(bytes!);
      expect(opened.isOk, isTrue, reason: '$name 打不开：$opened');
      final meta = await reader.parse();
      reader.close();
      expect(meta, isNotNull, reason: '$name 解析失败');
      parsed[name] = meta!;
    }

    // base：应用级字段齐全。
    final base = parsed[splits.first]!;
    expect(base.packageName, 'com.example.xapkfixture');
    expect(base.versionCode, 12);
    expect(base.versionName, '1.2');
    expect(base.targetSdkVersion, 33);
    expect(base.permissionRequests.map((p) => p.name),
        contains('android.permission.INTERNET'));
    expect(base.launchableActivities, isNotEmpty,
        reason: '启动页能识别出来 → base 的清单是完整的，不是空壳');

    // config split：同包名，但没有应用级版本字段 —— 这正是「base 与 split
    // 必须分开对待」的原因，也是 `install-multiple` 要一次收齐全部的原因。
    final split = parsed[splits.last]!;
    expect(split.packageName, 'com.example.xapkfixture');
    expect(split.launchableActivities, isEmpty);
  });

  test('夹具存在且不是空壳', () {
    final file = File(_fixture);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1000));
  });
}
