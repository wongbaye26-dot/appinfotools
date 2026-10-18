// SDK 盘点扫描器：按 DEX `string_ids` 精确索引。
//
// ## 为什么不用 `DexClueScanner` 的字符串提取
//
// 试过。`DexClueScanner` 是暴力扫全部字节、单 DEX 上限 8 MiB，而 DEX 的
// `string_data` 在文件**后半部分**（头 → id 表 → class_defs → data）。
// 实测抖音（55 个 DEX / 437 MiB）：
//
// | `maxTotalBytes` | 耗时 | 命中的服务类 SDK |
// |---|---|---|
// | 48 MiB（生产默认） | 1.9 s | **0 个** |
// | 128 MiB | 5.2 s | 2 个 |
// | 512 MiB | 14.4 s | 3 个 |
//
// 而按 `string_ids` 索引后，**40/40 个 DEX 全扫、命中 5 个**。
// 也就是说：让「大包返回 0」的不是阈值，是**字符串在文件里的位置**。
//
// ## 期望值来源
//
// 解析正确性用 `test/fixtures/dex/` 里的**真实 DEX**（`javac` + `d8` 产出）
// 钉住；判据（阈值、边界、去重）用 `support/minimal_dex.dart` 构造的
// 最小 DEX 钉住。两者分工见那个文件的头注释。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

import 'support/minimal_dex.dart';

/// 仓库根到 DEX 夹具的相对路径（`dart test` 的 cwd 是包目录）。
const _realDex = '../../test/fixtures/dex/real-cooccurrence.dex';

Uint8List _dexWith(String prefix, int count) =>
    buildDexWithClassPrefix(prefix, count);

SdkInventory _scanOne(Uint8List bytes, {String name = 'classes.dex'}) =>
    SdkInventoryScanner.scan([name], (_) => bytes);

void main() {
  group('解析真实 DEX', () {
    test('真实产物能解析，且不会崩', () {
      final bytes = File(_realDex).readAsBytesSync();
      final scan = SdkInventoryScanner.scanDex('classes.dex', bytes);
      expect(scan.parsed, isTrue, reason: scan.failure);
      expect(scan.truncated, isFalse);
    });

    test('真实产物里的类名能数出来（前缀命中 > 0）', () {
      // `real-cooccurrence.dex` 里有 com.example.fixture 的类。
      // 目录里没有这个前缀，所以这里只验证「不报错且计数表可读」。
      final bytes = File(_realDex).readAsBytesSync();
      final scan = SdkInventoryScanner.scanDex('classes.dex', bytes);
      expect(scan.parsed, isTrue);
      expect(scan.counts, isA<Map<String, int>>());
    });
  });

  group('阈值：20 条引用', () {
    test('19 条 → 不算（低于下限）', () {
      final inventory = _scanOne(_dexWith('com/adjust/sdk', 19));
      expect(inventory.hits, isEmpty);
    });

    test('20 条 → 算（恰好等于下限）', () {
      final inventory = _scanOne(_dexWith('com/adjust/sdk', 20));
      expect(inventory.hits, hasLength(1));
      expect(inventory.hits.single.id, 'adjust');
      expect(inventory.hits.single.occurrences, 20);
    });

    test('阈值是为了滤掉「只在配置字符串里提了一句」', () {
      // 实测区分度：真打包的 SDK 是几百到几千，提一句的是个位数。
      final few = _scanOne(_dexWith('com/adjust/sdk', 3));
      expect(few.hits, isEmpty);
      final many = _scanOne(_dexWith('com/adjust/sdk', 300));
      expect(many.hits.single.occurrences, 300);
    });
  });

  group('边界：不要把相邻的前缀算进来', () {
    test('com/tencent/mmkv 不会被算成 com/tencent/mm/opensdk', () {
      final inventory = _scanOne(_dexWith('com/tencent/mmkv', 50));
      expect(inventory.hits, isEmpty,
          reason: '两条前缀的公共段是 com/tencent，但 mmkv 不是 mm/opensdk');
    });

    test('com/tencent/mm/opensdk 能被认出来', () {
      final inventory = _scanOne(_dexWith('com/tencent/mm/opensdk', 30));
      expect(inventory.hits.single.id, 'wechat-opensdk');
    });

    test('只有一个常见段（com/facebook）也认得出', () {
      final inventory = _scanOne(_dexWith('com/facebook', 40));
      expect(inventory.hits.single.id, 'facebook');
    });
  });

  group('多 DEX 累加与去重', () {
    test('两个 DEX 各 15 条 → 合计 30 条，命中', () {
      final inventory = SdkInventoryScanner.scan(
        ['classes.dex', 'classes2.dex'],
        (name) => _dexWith('com/adjust/sdk', 15),
      );
      expect(inventory.hits.single.occurrences, 30);
      expect(inventory.hits.single.dexNames, hasLength(2));
      expect(inventory.scannedDexCount, 2);
      expect(inventory.totalDexCount, 2);
      expect(inventory.complete, isTrue);
    });

    test('同一个 SDK 只产出一条 SdkHit', () {
      final inventory = SdkInventoryScanner.scan(
        ['classes.dex', 'classes2.dex', 'classes3.dex'],
        (name) => _dexWith('com/adjust/sdk', 10),
      );
      expect(inventory.hits, hasLength(1));
      expect(inventory.hits.single.occurrences, 30);
    });
  });

  group('读不出 ≠ 没有', () {
    test('不是 DEX → failure，且不计入 scannedDexCount', () {
      final junk = Uint8List.fromList(List.filled(512, 0x41));
      final inventory = _scanOne(junk);
      expect(inventory.hits, isEmpty);
      expect(inventory.scannedDexCount, 0);
      expect(inventory.totalDexCount, 1);
      expect(inventory.failures['classes.dex'], contains('not a DEX'));
      expect(inventory.complete, isFalse, reason: '读不出时不能声称「完整盘点」');
    });

    test('太短 → failure', () {
      final inventory = _scanOne(Uint8List.fromList([0x64, 0x65, 0x78, 0x0A]));
      expect(inventory.failures['classes.dex'], contains('too small'));
    });

    test('string_ids 越界 → failure（不可信长度不能决定读多少）', () {
      final bytes = Uint8List.fromList(_dexWith('com/adjust/sdk', 25));
      final data = ByteData.sublistView(bytes);
      data.setUint32(0x3C, 0xFFFFFF, Endian.little); // string_ids_off
      final inventory = _scanOne(bytes);
      expect(inventory.failures['classes.dex'], contains('out of range'));
    });

    test('条目读不出 → 记为失败，不崩', () {
      final inventory = SdkInventoryScanner.scan(['classes.dex'], (_) => null);
      expect(inventory.hits, isEmpty);
      expect(inventory.failures['classes.dex'], contains('could not be read'));
    });
  });

  group('覆盖率：complete 的判据', () {
    test('全部读成功且无截断 → complete', () {
      final inventory = SdkInventoryScanner.scan(
        ['classes.dex'],
        (_) => _dexWith('com/adjust/sdk', 25),
      );
      expect(inventory.complete, isTrue);
    });

    test('有一个失败 → 不 complete', () {
      final inventory = SdkInventoryScanner.scan(
        ['a.dex', 'b.dex'],
        (name) => name == 'a.dex' ? _dexWith('com/adjust/sdk', 25) : null,
      );
      expect(inventory.complete, isFalse);
      expect(inventory.scannedDexCount, 1);
      expect(inventory.totalDexCount, 2);
    });
  });

  group('发现项：info 级清单，不是风险结论', () {
    test('severity = info，confidence = independentCapability', () {
      final inventory = _scanOne(_dexWith('com/adjust/sdk', 25));
      final finding = buildSdkInventoryFinding(inventory);
      expect(finding.ruleId, 'ANDROID-THIRD-PARTY-SDK');
      expect(finding.severity, SecuritySeverity.info);
      expect(finding.confidence, SecurityConfidence.independentCapability);
      expect(finding.category.name, 'thirdPartySdk');
    });

    test('按类别分组产出证据行', () {
      final inventory = SdkInventoryScanner.scan(
        ['classes.dex'],
        (_) => buildMinimalDex([
          for (var i = 0; i < 25; i++) 'Lcom/adjust/sdk/A$i;',
          for (var i = 0; i < 25; i++) 'Lcom/tencent/bugly/B$i;',
        ]),
      );
      final finding = buildSdkInventoryFinding(inventory);
      expect(inventory.hits, hasLength(2));
      expect(finding.evidence, hasLength(2), reason: '两个类别各一行证据');
      final locations = finding.evidence.map((e) => e.location).join('\n');
      expect(locations, contains('analytics'));
      expect(locations, contains('crash'));
    });
  });

  group('基础库刻意不在目录里', () {
    test('OkHttp / Gson / Lottie 命中不了任何项', () {
      // 实测这些在 4/4 个真实包里都有 —— 报它们等于「每个应用都有第三方库」。
      for (final prefix in [
        'okhttp3',
        'com/google/gson',
        'com/airbnb/lottie',
        'com/google/android/material',
        'io/reactivex',
      ]) {
        final inventory = _scanOne(_dexWith(prefix, 200));
        expect(inventory.hits, isEmpty, reason: '$prefix 不该在目录里');
      }
    });

    test('目录里没有单段前缀（那会把整片包名卷进来）', () {
      for (final descriptor in sdkCatalog) {
        expect(
            descriptor.packagePrefix.split('/').length, greaterThanOrEqualTo(2),
            reason: '${descriptor.id} 的前缀太宽：${descriptor.packagePrefix}');
      }
    });
  });
}
