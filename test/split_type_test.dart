import 'package:apk_info_tool/models/split_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SplitType.fromId', () {
    test('classifies base splits', () {
      expect(SplitType.fromId('base'), SplitType.base);
      expect(SplitType.fromId('base-master'), SplitType.base);
      expect(SplitType.fromId('base-arm64_v8a'), SplitType.base);
      expect(SplitType.fromId('base_en'), SplitType.base);
    });

    test('regression: split_config.en was previously unreachable', () {
      // The old check required `id.length <= 5` together with
      // `id.contains('config.')`, which can never both hold for
      // "split_config.en" (15 chars), so it fell through to `unknown`.
      expect(SplitType.fromId('split_config.en'), SplitType.language);
      expect(SplitType.fromId('config.en'), SplitType.language);
      expect(SplitType.fromId('split_config.zh-rCN'), SplitType.language);
    });

    test('classifies language splits', () {
      expect(SplitType.fromId('en'), SplitType.language);
      expect(SplitType.fromId('fil'), SplitType.language);
      expect(SplitType.fromId('zh-rCN'), SplitType.language);
      expect(SplitType.fromId('config.zh'), SplitType.language);
    });

    test('classifies abi splits', () {
      expect(SplitType.fromId('config.arm64_v8a'), SplitType.abi);
      expect(SplitType.fromId('config.armeabi_v7a'), SplitType.abi);
      expect(SplitType.fromId('config.x86_64'), SplitType.abi);
      expect(SplitType.fromId('split_config.arm64_v8a'), SplitType.abi);
    });

    test('classifies density splits', () {
      expect(SplitType.fromId('config.hdpi'), SplitType.density);
      expect(SplitType.fromId('config.mdpi'), SplitType.density);
      expect(SplitType.fromId('config.xxhdpi'), SplitType.density);
      expect(SplitType.fromId('config.480dpi'), SplitType.density);
      expect(SplitType.fromId('config.xxhdpi-v4'), SplitType.density);
      expect(SplitType.fromId('split_config.xxhdpi'), SplitType.density);
    });

    test('falls back to unknown for unrecognised names', () {
      expect(SplitType.fromId('drawable'), SplitType.unknown);
      expect(SplitType.fromId('unknown_thing'), SplitType.unknown);
    });
  });
}
