import 'dart:io';

import 'package:apk_parser/src/binary_xml.dart';
import 'package:test/test.dart';

/// [kFrameworkAttrNames] 的守卫。
///
/// 背景：这张表曾经凭印象写成 63 条，其中 **51 条 ID 对应错了名字**
/// （`0x01010010` 写成 `resource`，实为 `exported`；`0x01010280` 写成
/// `screenSize`，实为 `allowBackup`）。后果不是「少读一个字段」，而是
/// **用错名字覆盖正确的名字**：`AndroidComponent.exported` 恒为 `null`，
/// `debuggable` / `allowBackup` / `usesCleartextTraffic` 同样读不到，
/// 依赖它们的安全规则在真实包上长期静默失效。
///
/// 为什么以前没被发现：单元测试自己拼 AXML、自己写期望值，用的是同一张错表，
/// 自证循环。所以这里的期望值**必须来自外部工具**，即
/// `test/fixtures/android_34_attrs.txt`（`aapt2 dump resources` 的快照）。
///
/// 改表的流程：先跑夹具头注释里的 aapt2 命令重新生成快照 → 再改表 → 再跑本测试。
void main() {
  late Map<int, String> authoritative;

  setUpAll(() {
    final file = File('test/fixtures/android_34_attrs.txt');
    expect(file.existsSync(), isTrue,
        reason: '缺少 aapt2 快照夹具 test/fixtures/android_34_attrs.txt');
    authoritative = <int, String>{};
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+'));
      expect(parts, hasLength(2), reason: '夹具行格式错误：$raw');
      final id = int.parse(parts[0].replaceFirst('0x', ''), radix: 16);
      expect(authoritative.containsKey(id), isFalse,
          reason: '夹具里出现重复 ID：${parts[0]}');
      authoritative[id] = parts[1];
    }
  });

  test('夹具本身是可用的（防止空文件让整组断言空转）', () {
    expect(authoritative.length, greaterThan(1500));
    expect(authoritative[0x01010003], 'name');
  });

  test('表里每一条 ID 都与 aapt2 快照一致', () {
    final mismatched = <String>[];
    for (final entry in kFrameworkAttrNames.entries) {
      final expected = authoritative[entry.key];
      final id = '0x${entry.key.toRadixString(16).padLeft(8, '0')}';
      if (expected == null) {
        mismatched.add('$id -> 表里叫 ${entry.value}，但 aapt2 没有这个属性 ID');
      } else if (expected != entry.value) {
        mismatched.add('$id -> 表里叫 ${entry.value}，aapt2 说是 $expected');
      }
    }
    expect(mismatched, isEmpty,
        reason: '框架属性 ID 与 aapt2 快照不一致：\n${mismatched.join('\n')}');
  });

  test('表里没有两条不同 ID 映射到同一个名字', () {
    final byName = <String, List<int>>{};
    for (final entry in kFrameworkAttrNames.entries) {
      byName.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    final dupes = byName.entries.where((e) => e.value.length > 1).toList();
    expect(dupes, isEmpty,
        reason: '重复的属性名会让「读哪个」变成未定义：'
            '${dupes.map((e) => '${e.key}=${e.value.map((i) => '0x${i.toRadixString(16)}')}').join(', ')}');
  });

  test('安全分析依赖的四个属性 ID 钉死（它们曾全部读错）', () {
    // 这四条不是「重复断言」，而是把最贵的错误写在最显眼的地方：
    // 它们一错，P1 级规则 ANDROID-DEBUGGABLE / ANDROID-EXPORTED-COMPONENT /
    // ANDROID-ALLOW-BACKUP / RULE-D 全部静默失效，而界面上一切正常。
    expect(kFrameworkAttrNames[0x01010010], 'exported');
    expect(kFrameworkAttrNames[0x0101000f], 'debuggable');
    expect(kFrameworkAttrNames[0x01010280], 'allowBackup');
    expect(kFrameworkAttrNames[0x010104ec], 'usesCleartextTraffic');
    // 这几个是 0x0101000e/0x01010018 的邻居，历史上被整体错位过一格。
    expect(kFrameworkAttrNames[0x0101000e], 'enabled');
    expect(kFrameworkAttrNames[0x01010018], 'authorities');
  });

  test('表里不含解析器不消费的属性（避免维护一份没人用的错表）', () {
    // 只收录真正被 `attributes['xxx']` 读到的名字 + 结构性的几个。
    // 多加一条就等于多一条要守的错，且会遮住字符串池回退。
    const consumed = {
      'label',
      'icon',
      'name',
      'permission',
      'protectionLevel',
      'sharedUserId',
      'enabled',
      'debuggable',
      'exported',
      'authorities',
      'scheme',
      'minSdkVersion',
      'versionCode',
      'versionName',
      'targetSdkVersion',
      'maxSdkVersion',
      'allowBackup',
      'required',
      'fullBackupContent',
      'usesCleartextTraffic',
      'dataExtractionRules',
      'networkSecurityConfig',
      'compileSdkVersion',
      'compileSdkVersionCodename',
    };
    expect(kFrameworkAttrNames.values.toSet().difference(consumed), isEmpty);
    expect(kFrameworkAttrNames.length, consumed.length);
  });
}
