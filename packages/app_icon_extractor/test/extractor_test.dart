// 提取器的行为：**每个失败都要有区别于其它失败的原因**。
//
// 这一组测试的断言重点不是「返回了图标」，而是：
// - 成功时格式与像素尺寸都对；
// - 失败时 `status` + `reasonCode` 能区分「包坏了」「我们不支持这种形态」
//   「超出预算」—— 三者的补救方式完全不同；
// - 任何输入都不抛异常（原生扩展拿不到异常，只有返回值）。

import 'dart:io';

import 'package:app_icon_extractor/app_icon_extractor.dart';
import 'package:test/test.dart';

/// 夹具在仓库根 `test/fixtures/apk/`；`dart test` 的 cwd 是包目录。
String _fixture(String name) => '../../test/fixtures/apk/$name';

void main() {
  group('输入校验（不打开归档就能拒绝）', () {
    test('不支持的扩展名', () async {
      final r = await extractAppIcon('foo.xapk');
      expect(r.status, AppIconStatus.unsupported);
      expect(r.reasonCode, 'input.unsupported_extension');
      expect(r.hasIcon, isFalse);
    });

    test('文件不存在', () async {
      final r = await extractAppIcon('/nonexistent/foo.apk');
      expect(r.status, AppIconStatus.invalidInput);
      expect(r.reasonCode, 'input.not_found');
    });

    test('空文件', () async {
      final tmp = File('${Directory.systemTemp.path}/aie_empty.apk')
        ..writeAsBytesSync(const []);
      addTearDown(() => tmp.deleteSync());
      final r = await extractAppIcon(tmp.path);
      expect(r.status, AppIconStatus.invalidInput);
      expect(r.reasonCode, 'input.empty');
    });

    test('后缀是 .apk 但内容不是 ZIP —— 与「ZIP 损坏」分开', () async {
      final tmp = File('${Directory.systemTemp.path}/aie_notzip.apk')
        ..writeAsStringSync('this is definitely not a zip archive at all');
      addTearDown(() => tmp.deleteSync());
      final r = await extractAppIcon(tmp.path);
      expect(r.status, AppIconStatus.invalidInput);
      expect(r.reasonCode, 'archive.not_zip');
    });
  });

  group('APK 提取', () {
    test('带 PNG 图标的包：取到图标，格式与尺寸都对', () async {
      final r = await extractAppIcon(_fixture('icon-png.apk'));
      expect(r.status, AppIconStatus.success, reason: '${r.reasonCode}');
      expect(r.format, AppIconFormat.png);
      expect(r.source, AppIconSource.androidResourcePng);
      expect(r.png, isNotNull);
      expect(r.png!.length, greaterThan(100));
      // 夹具是 72×72（hdpi）。
      expect(r.pixelWidth, 72);
      expect(r.pixelHeight, 72);
      // 拿到的字节本身必须是 PNG，而不是「碰巧读到的条目」。
      expect(isPng(r.png!), isTrue);
    });

    test('自适应图标：明确报不支持，绝不返回一张猜的图', () async {
      final r = await extractAppIcon(_fixture('icon-adaptive.apk'));
      expect(r.status, AppIconStatus.unsupported);
      expect(r.reasonCode, 'android.adaptive_icon_unsupported');
      expect(r.png, isNull, reason: '拿不到完整图标时不能给半成品');
    });

    test('没有声明图标的包：与「不支持这种格式」分开', () async {
      // `signed-v2-v3.apk` 的 manifest 没有 android:icon。
      final r = await extractAppIcon(_fixture('signed-v2-v3.apk'));
      expect(r.status, AppIconStatus.unsupported);
      expect(r.reasonCode, 'android.no_icon_declared');
    });

    test('预算太小 → resourceLimit，而不是 invalidInput', () async {
      // 夹具 9 KB，把上限压到 1 KB。
      final r = await extractAppIcon(
        _fixture('icon-png.apk'),
        limits: const IconLimits(maxFileBytes: 1024),
      );
      expect(r.status, AppIconStatus.resourceLimit);
      expect(r.reasonCode, 'input.file_too_large');
      expect(r.detail, contains('1024'));
    });

    test('像素超限 → resourceLimit（在解码之前拦掉）', () async {
      final r = await extractAppIcon(
        _fixture('icon-png.apk'),
        limits: const IconLimits(maxIconPixels: 32),
      );
      expect(r.status, AppIconStatus.resourceLimit);
      expect(r.reasonCode, 'android.icon_too_large');
    });

    test('图标字节超限 → resourceLimit', () async {
      final r = await extractAppIcon(
        _fixture('icon-png.apk'),
        limits: const IconLimits(maxIconBytes: 64),
      );
      expect(r.status, AppIconStatus.resourceLimit);
      expect(r.reasonCode, 'android.icon_too_large');
    });
  });

  group('IPA 提取', () {
    // 41 MB 真实包，**不在 git 里**（CI 上没有）。存在才跑，否则显式跳过并说明。
    final ipa = File('../../sun_signed.ipa');

    test('真实 IPA：从 Assets.car 取到 1024×1024 图标', () async {
      if (!ipa.existsSync()) {
        markTestSkipped('sun_signed.ipa 不在仓库里（需人工提供）');
        return;
      }
      final r = await extractAppIcon(ipa.path);
      expect(r.status, AppIconStatus.success, reason: '${r.reasonCode}');
      expect(r.source, AppIconSource.iosAssetCatalog);
      expect(r.format, AppIconFormat.png);
      expect(r.pixelWidth, 1024);
      expect(r.pixelHeight, 1024);
      expect(r.png!.length, greaterThan(100000));
    });

    test('把 APK 改名成 .ipa —— 按扩展名走 IPA 路径并给出明确原因', () async {
      final tmp = File('${Directory.systemTemp.path}/aie_apk_as_ipa.ipa');
      tmp.writeAsBytesSync(File(_fixture('icon-png.apk')).readAsBytesSync());
      addTearDown(() => tmp.deleteSync());
      final r = await extractAppIcon(tmp.path);
      // 能打开 ZIP，但没有 Payload/*.app。
      expect(r.status, AppIconStatus.invalidInput);
      expect(r.reasonCode, 'ios.no_main_app');
    });
  });

  group('不变量', () {
    test('任何输入都不抛异常（原生扩展只认返回值）', () async {
      final cases = [
        '',
        '/',
        'foo',
        'x.apk',
        _fixture('icon-png.apk'),
        _fixture('icon-adaptive.apk'),
      ];
      for (final path in cases) {
        final r = await extractAppIcon(path);
        // 只要拿到结果就算通过；具体状态由上面的用例覆盖。
        expect(r.status, isA<AppIconStatus>(), reason: path);
      }
    });

    test('失败结果的 png 必须为空 —— 不给半成品', () async {
      for (final path in ['x.apk', '/nonexistent.apk']) {
        final r = await extractAppIcon(path);
        expect(r.hasIcon, isFalse);
        expect(r.png, isNull, reason: path);
      }
    });
  });
}
