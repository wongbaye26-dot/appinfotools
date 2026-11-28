// 预算守卫：「不回退」不是靠记忆，而是靠断言钉住。
//
// 2.11.1 第四阶段要求「ZIP 安全与 DEX 预算不回退」。这些上限散落在三个包里，
// 只要有人为了让某个样本通过而把它们调大，测试就应该红。这里不重复验证
// 「超限会不会被拦住」（各自的测试已经做了），只钉住**阈值本身**与几条
// 强约束，防止悄悄放宽。
//
// 调大任何一条都必须同时改这份测试，并在 PR 里说明为什么原阈值不成立。

import 'package:apk_parser/apk_parser.dart'
    show
        AndroidLoadGraphScanner,
        ApkSealCheck,
        AndroidArtifactInventoryScanner,
        DexClueScanner,
        DexLibraryScanner,
        SdkInventoryScanner;
import 'package:archive_safety/archive_safety.dart' show ZipBudgetLimits;
import 'package:flutter_test/flutter_test.dart';

const _mib = 1024 * 1024;

void main() {
  group('ZIP 读取预算', () {
    test('单条目压缩上限 512 MiB、总压缩上限 2 GiB、真实产出上限 1 GiB', () {
      expect(ZipBudgetLimits.maxSingleEntryCompressed, 512 * _mib);
      expect(ZipBudgetLimits.maxTotalCompressed, 2048 * _mib);
      expect(ZipBudgetLimits.maxSessionOutputBytes, 1024 * _mib);
    });

    test('真实产出上限必须低于总压缩上限（否则等于没有解压炸弹防线）', () {
      expect(
        ZipBudgetLimits.maxSessionOutputBytes,
        lessThan(ZipBudgetLimits.maxTotalCompressed),
        reason: '2 GiB 压缩数据可以解出远超 1 GiB，产出上限才有意义',
      );
    });
  });

  group('DEX / 清单扫描预算', () {
    test('SDK 清单单 DEX 64 MiB、库识别类数 40 万', () {
      expect(SdkInventoryScanner.maxDexBytes, 64 * _mib);
      expect(DexLibraryScanner.maxClasses, 400000);
    });

    test('安全线索扫描：单 DEX 8 MiB、总量 48 MiB、每条 DEX 最多留 200 条字符串', () {
      expect(DexClueScanner.maxBytesPerDex, 8 * _mib);
      expect(DexClueScanner.maxTotalBytes, 48 * _mib);
      expect(DexClueScanner.maxStringKeep, 200);
    });

    test('加载图：边数 5000、每 DEX 字符串上限 50 万', () {
      expect(AndroidLoadGraphScanner.defaultMaxEdges, 5000);
      expect(AndroidLoadGraphScanner.maxStringsPerDex, 500000);
    });

    test('APK Seal 只读 64 个条目、单条 8 MiB', () {
      expect(ApkSealCheck.maxEntries, 64);
      expect(ApkSealCheck.maxEntryBytes, 8 * _mib);
    });

    test('制品清单最多 2000 条', () {
      expect(AndroidArtifactInventoryScanner.defaultMaxEntries, 2000);
    });

    test('总量预算必须小于文件级预算的常见量级（防「加起来读全包」）', () {
      expect(DexClueScanner.maxTotalBytes, lessThan(64 * _mib));
      expect(
        SdkInventoryScanner.maxDexBytes,
        greaterThan(DexClueScanner.maxBytesPerDex),
        reason: '库识别要看到整张字符串表，允许的窗口应比线索扫描大',
      );
    });
  });
}
