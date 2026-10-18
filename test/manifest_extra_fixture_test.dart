// 清单里「数据已经在手但没人读」的四项：`sharedUserId`、`protectionLevel`、
// 两个备份规则属性。
//
// ## 每一项为什么会改变结论
//
// | 项 | 不读它时的错误结论 |
// |---|---|
// | `sharedUserId` | 与同签名应用共享沙箱这件事**完全不可见** |
// | `protectionLevel` | 导出组件只要写了 `android:permission` 就当「受保护」，而 `normal` 级自定义权限**任何应用都能申请** |
// | `dataExtractionRules` / `fullBackupContent` | `allowBackup="true"` 就说「整包数据可被备份」，而 `"false"` 其实把备份彻底关了、指向 XML 时还有例外清单 |
//
// ## 期望值来源
//
// `test/fixtures/apk/manifest-extra-fixture.apk` 由 aapt2 真实产出，
// 逐条用外部工具核对过：
//
// ```
// aapt2 dump xmltree manifest-extra-fixture.apk --file AndroidManifest.xml
//   A: ...sharedUserId(0x0101000b)="com.example.shared"
//   A: ...protectionLevel(0x01010009)=0x00000000   ← normal
//   A: ...protectionLevel(0x01010009)=0x00000002   ← signature
//   A: ...dataExtractionRules(0x0101063e)=@0x7f010000
// ```
//
// **注意 `protectionLevel` 是整数不是字符串** —— 按字符串找 `"signature"`
// 永远找不到，规则会静默不生效。这一条是本文件存在的主要理由。
//
// 夹具的源文件（可复现，不要只留二进制）：
//   test/fixtures/apk/manifest-extra-fixture.AndroidManifest.xml
//   test/fixtures/apk/manifest-extra-fixture.data_extraction_rules.xml

import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/apk/manifest-extra-fixture.apk';

Future<ApkMeta> _parseFixture() async {
  final reader = ApkReader();
  addTearDown(reader.close);
  final opened = await reader.open(_fixture);
  expect(opened.isOk, isTrue, reason: '夹具打不开：$opened');
  final meta = await reader.parse();
  expect(meta, isNotNull);
  return meta!;
}

SecurityAnalysisResult _audit(ApkMeta meta) =>
    AndroidSecurityAudit.audit(meta: meta, dexEntries: const []);

List<SecurityFinding> _byId(SecurityAnalysisResult r, String id) =>
    r.findings.where((f) => f.ruleId == id).toList();

void main() {
  group('解析：真实 AXML 上读到了', () {
    test('sharedUserId', () async {
      expect((await _parseFixture()).sharedUserId, 'com.example.shared');
    });

    test('protectionLevel 是整数标志位，不是字符串', () async {
      final meta = await _parseFixture();
      final byName = {for (final p in meta.declaredPermissions) p.name: p};
      expect(
          byName.keys,
          containsAll([
            'com.example.permission.WEAK',
            'com.example.permission.STRONG',
          ]));

      final weak = byName['com.example.permission.WEAK']!;
      final strong = byName['com.example.permission.STRONG']!;
      // aapt2 写的是 0x0 / 0x2。
      expect(weak.protectionLevelValue, 0);
      expect(strong.protectionLevelValue, 2);
      expect(weak.signatureProtected, isFalse,
          reason: 'normal 级任何应用都能申请，等于没保护');
      expect(strong.signatureProtected, isTrue);
      // 证据里要能看懂，不能是裸的 0x2。
      expect(strong.protectionLevelText, 'signature');
      expect(weak.protectionLevelText, 'normal');
    });

    test('dataExtractionRules 读到了（引用形态）', () async {
      final meta = await _parseFixture();
      expect(meta.applicationDataExtractionRules, isNotNull);
      expect(meta.applicationDataExtractionRules, startsWith('@res/0x'));
      expect(meta.applicationFullBackupContent, isNull);
    });
  });

  group('规则：sharedUserId', () {
    test('声明了就报一条 P2，并点名值', () async {
      final result = _audit(await _parseFixture());
      final finding = _byId(result, 'ANDROID-SHARED-USER-ID');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p2);
      expect(finding.single.messageArgs['id'], 'com.example.shared');
      expect(finding.single.evidence.single.location, contains('sharedUserId'));
    });

    test('没声明就不报', () {
      final result = _audit(ApkMeta()..packageName = 'com.example.plain');
      expect(_byId(result, 'ANDROID-SHARED-USER-ID'), isEmpty);
    });
  });

  group('规则：导出组件的权限是否名存实亡', () {
    test('normal 级自定义权限 → **仍然报**，且措辞换成「effective」', () async {
      final result = _audit(await _parseFixture());
      final finding = _byId(result, 'ANDROID-EXPORTED-COMPONENT');
      expect(finding, hasLength(1), reason: 'WeakProvider 的权限任何应用都能申请，等于没保护');
      expect(finding.single.messageCode, 'android.exported_component_weak');
      expect(finding.single.finding, contains('effective'));

      final details = finding.single.evidence.map((e) => e.detail).join('\n');
      expect(details, contains('com.example.permission.WEAK'));
      expect(details, contains('protectionLevel="normal"'),
          reason: '证据要能看懂级别，不能是裸的 0x0');
    });

    test('signature 级自定义权限 → 受保护，不报', () async {
      final result = _audit(await _parseFixture());
      final locations = _byId(result, 'ANDROID-EXPORTED-COMPONENT')
          .single
          .evidence
          .map((e) => e.location)
          .join('\n');
      expect(locations, isNot(contains('StrongService')),
          reason: 'signature 级权限只有同签名应用能拿到，是真的保护');
    });

    test('框架权限 → 看不到级别，保守当成受保护，不报', () async {
      final result = _audit(await _parseFixture());
      final locations = _byId(result, 'ANDROID-EXPORTED-COMPONENT')
          .single
          .evidence
          .map((e) => e.location)
          .join('\n');
      expect(locations, isNot(contains('JobReceiver')),
          reason: '猜错的方向必须偏向「不误报」：别包声明的权限不判');
    });

    test('启动页依然被排除', () async {
      final result = _audit(await _parseFixture());
      final locations = _byId(result, 'ANDROID-EXPORTED-COMPONENT')
          .single
          .evidence
          .map((e) => e.location)
          .join('\n');
      expect(locations, isNot(contains('MainActivity')));
    });
  });

  group('规则：备份规则与 allowBackup 的配合', () {
    test('allowBackup=true 且指向规则文件 → 报，但证据里带出规则', () async {
      final result = _audit(await _parseFixture());
      final finding = _byId(result, 'ANDROID-ALLOW-BACKUP');
      expect(finding, hasLength(1));
      final details = finding.single.evidence.map((e) => e.detail).join('\n');
      expect(details, contains('dataExtractionRules'),
          reason: '有例外清单时必须点出来，否则读者以为整包数据都会被备份');
    });

    test('dataExtractionRules="false" → 备份被彻底关掉，**不报**', () {
      final meta = ApkMeta()
        ..packageName = 'com.example.nobackup'
        ..targetSdkVersion = 34
        ..applicationAllowBackup = true
        ..applicationDataExtractionRules = 'false';
      expect(_byId(_audit(meta), 'ANDROID-ALLOW-BACKUP'), isEmpty,
          reason: 'allowBackup=true 与「数据真的会被备份」不是一回事');
    });

    test('fullBackupContent="false" 同样关掉备份', () {
      final meta = ApkMeta()
        ..packageName = 'com.example.nobackup2'
        ..targetSdkVersion = 30
        ..applicationAllowBackup = true
        ..applicationFullBackupContent = 'false';
      expect(_byId(_audit(meta), 'ANDROID-ALLOW-BACKUP'), isEmpty);
    });

    test('allowBackup 未声明时不报（不替平台猜默认值）', () {
      final meta = ApkMeta()..packageName = 'com.example.undeclared';
      expect(_byId(_audit(meta), 'ANDROID-ALLOW-BACKUP'), isEmpty);
    });
  });

  test('夹具存在且不是空壳', () {
    final file = File(_fixture);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1000));
  });
}
