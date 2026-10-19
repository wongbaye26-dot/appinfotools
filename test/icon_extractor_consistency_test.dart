// 「原生扩展拿到的图标」与「主应用拿到的图标」是不是同一张。
//
// 规格 5.2 要求：*必须用同一组安装包测试原生提取结果与 AppInfoTool 主应用
// 提取结果的一致性*。这条不是形式主义 —— 两套代码路径独立演进时，
// 最容易出现「界面显示 A、文件管理器显示 B」，而用户完全无从判断哪个是对的。
//
// 这里比的是**图标选择规则**，不是渲染结果：
// - 提取器（`app_icon_extractor`）：纯 Dart，按 density 降序取位图；
// - 主应用（`apk_info.dart` → `ApkInfo.icons`）：同一份 `resources.arsc`，
//   按 density 降序填 map，取第一个当 `mainIconPath`。
//
// 两者若选出不同的条目，说明至少有一方的排序或过滤写错了。

import 'dart:io';

import 'package:apk_info_tool/utils/zip_helper.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:app_icon_extractor/app_icon_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 夹具路径（`flutter test` 的 cwd 是仓库根）。
const _pngFixture = 'test/fixtures/apk/icon-png.apk';
const _adaptiveFixture = 'test/fixtures/apk/icon-adaptive.apk';

/// 第二个**有图标且内容不同**的包（96×96，`icon-png.apk` 是 72×72）。
///
/// 存在的唯一理由是规格 2.4 的第一条验收项：「两个内容不同的 APK 显示
/// 不同的真实应用图标」。这条在 Windows 侧由 `thumbnail_selftest` 比像素
/// 哈希；这里用同一对夹具在**本地**先验一遍，不必等 CI。
const _altPngFixture = 'test/fixtures/apk/icon-png-alt.apk';

void main() {
  group('提取器与主应用的图标选择一致', () {
    test('同一个 APK：两边取到的是**同一份字节**', () async {
      final extracted = await extractAppIcon(_pngFixture);
      expect(extracted.status, AppIconStatus.success,
          reason: '前提不成立：夹具本身取不到图标（${extracted.reasonCode}）');

      // ---- 主应用侧的等价路径 ----
      //
      // `parseApkInfoFromOutput` / `_applyMetaToApkInfo` 的做法是：
      // `ApkReader.parse()` 填 `meta.iconPaths`，再按 density 降序取第一个。
      final reader = ApkReader();
      addTearDown(reader.close);
      expect((await reader.open(_pngFixture)).isOk, isTrue);
      final meta = await reader.parse();
      expect(meta, isNotNull);

      final sorted = meta!.iconPaths.entries.toList()
        ..sort((a, b) => b.key.compareTo(a.key));
      expect(sorted, isNotEmpty, reason: '夹具应当声明了 android:icon');

      // 主应用会取 density 最大的那个；提取器取第一个**可识别的图片**。
      // 在这个夹具里两者是同一个条目（只有一个 density 变体）。
      final primaryPath = sorted.first.value;
      final primaryBytes = reader.readFile(primaryPath);
      expect(primaryBytes, isNotNull);

      expect(
        extracted.png,
        equals(primaryBytes),
        reason: '提取器与主应用选到了不同的条目：'
            '提取器=${extracted.source.id} ${extracted.pixelWidth}x'
            '${extracted.pixelHeight}，主应用=$primaryPath',
      );
    });

    test('自适应图标的包：提取器明确拒绝，而不是取一张背景层', () async {
      // 主应用（`AdaptiveIconRenderer`，依赖 dart:ui）能合成这个图标；
      // 提取器不能。这里钉住的是：**不能**因此退而求其次去拿前景/背景位图 ——
      // 那会在文件管理器里显示一个缺了背景的残缺图标，比没有更糟。
      final extracted = await extractAppIcon(_adaptiveFixture);
      expect(extracted.status, AppIconStatus.unsupported);
      expect(extracted.reasonCode, 'android.adaptive_icon_unsupported');
      expect(extracted.png, isNull);
    });

    test('两个内容不同的包产出**不同**的图标（规格 2.4 第一条）', () async {
      final a = await extractAppIcon(_pngFixture);
      final b = await extractAppIcon(_altPngFixture);

      expect(a.status, AppIconStatus.success, reason: '${a.reasonCode}');
      expect(b.status, AppIconStatus.success, reason: '${b.reasonCode}');

      // 尺寸不同是最粗的证据，但真正要验的是**字节不同** ——
      // 两个包若读到同一个条目，尺寸也会一样。
      expect(a.pixelWidth, 72);
      expect(b.pixelWidth, 96);
      expect(
        a.png,
        isNot(equals(b.png)),
        reason: '两个包的图标字节完全相同 —— 提取器没有按文件内容取值',
      );
    });

    test('同一个包两次提取必须逐字节相同（结果不受顺序/缓存影响）', () async {
      final first = await extractAppIcon(_pngFixture);
      final second = await extractAppIcon(_pngFixture);
      expect(first.png, equals(second.png));
      expect(first.pixelWidth, second.pixelWidth);
    });

    test('提取器的 format 与像素尺寸与 PNG 头自洽', () async {
      final extracted = await extractAppIcon(_pngFixture);
      expect(extracted.hasIcon, isTrue);
      expect(extracted.format, AppIconFormat.png);

      // 用**另一条**读法重新算一次尺寸：从字节头读，而不是信结果里的字段。
      final size = pngPixelSize(extracted.png!);
      expect(size, isNotNull);
      expect(extracted.pixelWidth, size!.$1);
      expect(extracted.pixelHeight, size.$2);
    });
  });

  group('提取器与主应用共用同一套归档安全判定', () {
    test('同一个 APK，两边都能打开或都不能打开', () async {
      // 提取器内部用 `ApkReader.open`，所以这条必然成立 —— 它守的是
      // 「将来有人把提取器改成自己解 ZIP」时的一致性。
      final helper = ZipHelper();
      addTearDown(helper.close);
      final helperResult = await helper.open(_pngFixture);

      final reader = ApkReader();
      addTearDown(reader.close);
      final readerResult = await reader.open(_pngFixture);

      expect(readerResult.isOk, helperResult.isOk);
    });

    test('非 ZIP 输入：提取器报 invalidInput，且不抛异常', () async {
      final tmp = File('${Directory.systemTemp.path}/aie_consistency.apk')
        ..writeAsStringSync('not a zip');
      addTearDown(() => tmp.deleteSync());
      final result = await extractAppIcon(tmp.path);
      expect(result.status, AppIconStatus.invalidInput);
      expect(result.reasonCode, 'archive.not_zip');
    });
  });
}
