// `resources.arsc` 的 `uiMode`（夜间模式）解析。
//
// 夹具是 `aapt2` **真实产出**的两个最小 APK，区别只有一个：一个多
// `res/values-night/`。期望值用 `aapt2 dump configurations` 独立核对过
// （见 `test/fixtures/apk/README.md`），不是从本项目解析器拿的 —— 那样等于自证。
//
// 为什么值得单独钉住：`ResTable_config` 是一段**按偏移访问的二进制结构**，
// 偏移写错不会报错，只会读出一个看起来合理的错值。用真实产物做样本，
// 偏移错了就会被 aapt2 的结论打脸。
//
// 第二组是手工构造的 config blob —— 这一组才是「没有工具能生成」的形态：
// `size < 30` 的截短配置。它断言的是**不去读不存在的字段**。

import 'dart:typed_data';

import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

const String _fixtureDir = 'test/fixtures/apk';

Future<ApkMeta?> _parseFixture(String name) async {
  final reader = ApkReader();
  try {
    final result = await reader.open(path.join(_fixtureDir, name));
    expect(result.isOk, isTrue, reason: '$name 应当能打开：${result.description}');
    return await reader.parse();
  } finally {
    reader.close();
  }
}

/// 按 AOSP `ResTable_config` 布局拼一个 config blob。
///
/// 只填本组测试关心的字段：`size`（偏移 0）、`density`（偏移 14）、
/// `uiMode`（偏移 29）。其余留 0 —— 它们与这两条断言无关。
Uint8List _config(int size, {int? uiMode}) {
  final bytes = Uint8List(size);
  final view = ByteData.view(bytes.buffer);
  view.setUint32(0, size, Endian.little);
  if (size >= 16) view.setUint16(14, 240, Endian.little);
  if (uiMode != null && size >= 30) bytes[29] = uiMode;
  return bytes;
}

void main() {
  group('夜间模式：真实 aapt2 产物端到端', () {
    test('带 values-night 的 APK 报告有夜间资源', () async {
      final meta = await _parseFixture('night-mode-resources.apk');

      expect(meta, isNotNull);
      expect(
        meta!.hasNightMode,
        isTrue,
        reason: 'aapt2 dump configurations 对这个包输出 "night"',
      );
    });

    test('没有 values-night 的 APK 报告没有夜间资源', () async {
      final meta = await _parseFixture('no-night-mode-resources.apk');

      expect(meta, isNotNull);
      expect(
        meta!.hasNightMode,
        isFalse,
        reason: '只留带夜间资源的样本时，直接 return true 也能过 —— 负例必须一起留',
      );
    });

    test('两个夹具的既有 arsc 事实没被改坏', () async {
      for (final name in const [
        'night-mode-resources.apk',
        'no-night-mode-resources.apk',
      ]) {
        final meta = await _parseFixture(name);
        expect(meta!.packageName, 'com.example.fixture', reason: name);
        expect(meta.minSdkVersion, 21, reason: name);
        expect(meta.targetSdkVersion, 34, reason: name);
        // 标签要从 arsc 的全局字符串池里解出来 —— 这条能兜住「改动把字符串池
        // 或 config 解析弄坏了」。密度不在这里断言：1x1 PNG 放在无密度限定的
        // `res/drawable/` 下，config.density 本来就是 0（会被 getDensities 过滤），
        // 断言它非空是错的。
        expect(meta.label, 'Fixture', reason: name);
        expect(
          meta.hasNightMode,
          isNotNull,
          reason: '$name 的资源表读到了，hasNightMode 不该是 null',
        );
      }
    });
  });

  group('ResourceConfig 的字段边界', () {
    test('size < 30 时不读 uiMode（不越界、也不误读别的字节）', () {
      // 28 字节的 config 到 screenLayout 为止，uiMode 根本不存在。
      final cfg =
          ResourceConfig.read(ByteDataReader.wrapUint8List(_config(28)));

      expect(cfg.size, 28);
      expect(cfg.uiMode, 0);
      expect(cfg.isNightMode, isFalse);
    });

    test('size >= 30 时按偏移 29 读 uiMode', () {
      // 0x21 = 夜间(0x20) | 设备类型 normal(1)
      final cfg = ResourceConfig.read(
        ByteDataReader.wrapUint8List(_config(32, uiMode: 0x21)),
      );

      expect(cfg.uiMode, 0x21);
      expect(cfg.isNightMode, isTrue);
      expect(ResourceConfig.uiModeTypeName(cfg.uiModeType), 'normal');
    });

    test('夜间位是 0x10（显式非夜间）不算夜间资源', () {
      // 0x11 = 0x10（显式「非夜间」）| 设备类型 normal(1)
      final cfg = ResourceConfig.read(
        ByteDataReader.wrapUint8List(_config(32, uiMode: 0x11)),
      );

      expect(
        cfg.isNightMode,
        isFalse,
        reason: '0x10 是「显式声明非夜间」，与 0x20「夜间」是两回事',
      );
    });

    test('夜间位是 0x00（未指定）不算夜间资源', () {
      final cfg = ResourceConfig.read(
        ByteDataReader.wrapUint8List(_config(32, uiMode: 0x01)),
      );

      expect(cfg.isNightMode, isFalse);
    });

    test('density 仍按偏移 14 读（回归：新增字段没有挪动既有偏移）', () {
      final cfg = ResourceConfig.read(
        ByteDataReader.wrapUint8List(_config(32, uiMode: 0x21)),
      );

      expect(cfg.density, 240);
    });

    test('未知设备类型如实给出 type<N>，不丢也不猜', () {
      expect(ResourceConfig.uiModeTypeName(3), 'car');
      expect(ResourceConfig.uiModeTypeName(4), 'television');
      expect(ResourceConfig.uiModeTypeName(6), 'watch');
      expect(ResourceConfig.uiModeTypeName(15), 'type15');
    });
  });
}
