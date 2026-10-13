// 文件导入要支持 IPA。
//
// 三件事曾经各说各话：扩展名白名单里有 `ipa`，但对话框标题、按钮提示、
// 拖放拒绝时的提示**只写了 APK 系**。用户看到「请选择 APK/XAPK/APKM/APKS 文件」，
// 自然以为这个工具打不开 IPA —— 功能有、入口也认，只是没说。
//
// 因此这里两头都钉：文案里必须提到 IPA，判定函数必须接受 `.ipa`。

import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/package_file_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  group('导入提示文案', () {
    test('六种语言的按钮提示、对话框标题、类型错误提示都提到 IPA', () async {
      for (final locale in AppLocale.values) {
        final tr = await locale.build();
        final texts = {
          'open_apk': tr.open.open_apk,
          'select_apk_file': tr.open.select_apk_file,
          'invalid_file_type': tr.open.invalid_file_type,
        };
        for (final entry in texts.entries) {
          expect(entry.value, contains('IPA'),
              reason: '${locale.name} 的 ${entry.key} 没有提到 IPA：'
                  '「${entry.value}」');
        }
      }
    });
  });

  group('文件类型判定', () {
    test('文件选择器接受 IPA', () {
      // 系统文件对话框只认扩展名，必须逐个列出。
      expect(kPickableExtensions, contains('ipa'));
    });

    test('拖放接受 IPA 与其余已知格式', () {
      for (final path in [
        '/tmp/App.ipa',
        '/tmp/App.apk',
        '/tmp/App.xapk',
        '/tmp/App.apkm',
        '/tmp/App.apks',
        '/tmp/App.zip',
        '/tmp/App.apk.1',
        '/tmp/App.apk.1.1',
      ]) {
        expect(isSupportedPackagePath(path), isTrue, reason: '应当接受 $path');
      }
    });

    test('大小写不敏感', () {
      expect(isSupportedPackagePath('/tmp/APP.IPA'), isTrue);
      expect(isSupportedPackagePath('/tmp/App.APK'), isTrue);
    });

    test('拒绝无关类型，而不是丢给解析器', () {
      for (final path in [
        '/tmp/notes.txt',
        '/tmp/archive.tar.gz',
        '/tmp/App.apk.bak',
        '/tmp/ipa',
        '/tmp/App.ipa.txt',
      ]) {
        expect(isSupportedPackagePath(path), isFalse, reason: '不该接受 $path');
      }
    });

    test('重名后缀只认数字，不认别的', () {
      // `.apk.1` 是下载渠道给重名文件加的后缀；`.apk.bak` 不是。
      expect(isSupportedPackagePath('/tmp/App.apk.2'), isTrue);
      expect(isSupportedPackagePath('/tmp/App.apk.bak'), isFalse);
    });
  });
}
