// 清单属性**真的**从字节里读出来了 —— 端到端，不用手搓 `ApkMeta`。
//
// ## 为什么需要这个文件
//
// `android_manifest_hygiene_test.dart` 里的用例全部手工构造 `ApkMeta`，
// 于是「属性名解析」这一段完全没被覆盖。结果是：`_kFrameworkAttrNames`
// 里 51 条 ID 对应错了名字，`android:exported` / `debuggable` / `allowBackup` /
// `usesCleartextTraffic` 在**所有真实包**上都读不到，而单测一直是绿的 ——
// 它测的是「拿到一个 bool 之后规则怎么判」，不是「这个 bool 能不能拿到」。
//
// ## 夹具与期望值的来源
//
// `test/fixtures/apk/attr-fixture.apk` 由 aapt2 2.19（build-tools 34.0.0）
// 从 `attr-fixture.AndroidManifest.xml` 真实编译链接而来，**不是手拼字节**。
// 期望值全部来自独立工具的核对：
//
// ```
// aapt2 dump xmltree test/fixtures/apk/attr-fixture.apk --file AndroidManifest.xml
// ```
//
// 该输出里每条属性都带着自己的资源 ID，例如
// `A: http://...android:exported(0x01010010)=true` —— 这正是判定
// 「解析器有没有读对属性」的第三方依据，**不能从本项目解析器取**。

import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixturePath = 'test/fixtures/apk/attr-fixture.apk';

Future<ApkMeta> _parseFixture() async {
  final reader = ApkReader();
  addTearDown(reader.close);
  final opened = await reader.open(_fixturePath);
  expect(opened.isOk, isTrue, reason: '夹具打不开：$opened');
  final meta = await reader.parse();
  expect(meta, isNotNull, reason: '夹具解析失败');
  return meta!;
}

void main() {
  group('框架属性 ID → 名字：真实 AXML 端到端', () {
    test('<application> 上的四个安全属性都读到了', () async {
      final meta = await _parseFixture();

      // 期望值来自 aapt2 dump xmltree 的独立输出。
      expect(meta.applicationDebuggable, isTrue,
          reason: 'android:debuggable(0x0101000f) 没读到 —— '
              'ANDROID-DEBUGGABLE 会永远不触发');
      expect(meta.applicationAllowBackup, isFalse,
          reason: 'android:allowBackup(0x01010280) 没读到');
      expect(meta.applicationUsesCleartextTraffic, isTrue,
          reason: 'android:usesCleartextTraffic(0x010104ec) 没读到 —— '
              'RULE-D（明文流量）会静默失效');
      expect(meta.networkSecurityConfig, isNotNull,
          reason: 'android:networkSecurityConfig(0x01010527) 没读到');
    });

    test('清单级属性（versionCode / versionName / package）', () async {
      final meta = await _parseFixture();
      expect(meta.packageName, 'com.example.attrfixture');
      expect(meta.versionCode, 7);
      expect(meta.versionName, '1.2.3');
      expect(meta.compileSdkVersion, 34);
    });

    test('uses-sdk 的 min / target 读到了', () async {
      final meta = await _parseFixture();
      expect(meta.minSdkVersion, 21);
      expect(meta.targetSdkVersion, 33);
    });

    test('uses-permission 的 maxSdkVersion 与名字一起读到了', () async {
      final meta = await _parseFixture();
      final internet = meta.permissionRequests
          .where((p) => p.name == 'android.permission.INTERNET')
          .toList();
      expect(internet, hasLength(1));
      expect(internet.single.maxSdkVersion, 28);
    });
  });

  group('组件上的 exported / enabled / authorities', () {
    test('activity：exported=true 与 enabled=false 都读到了', () async {
      final meta = await _parseFixture();
      final activity = meta.components
          .where((c) => c.type == ComponentType.activity)
          .toList();
      expect(activity, hasLength(1));
      expect(activity.single.name, '.MainActivity');
      expect(activity.single.exported, isTrue,
          reason: 'android:exported(0x01010010) 没读到 —— '
              '曾经被错读成 resource，AndroidComponent.exported 恒为 null');
      expect(activity.single.enabled, isFalse,
          reason: 'android:enabled(0x0101000e) 没读到');
    });

    test('provider：authorities 与 exported 都读到了', () async {
      final meta = await _parseFixture();
      final provider = meta.components
          .where((c) => c.type == ComponentType.provider)
          .toList();
      expect(provider, hasLength(1));
      expect(provider.single.name, '.LeakyProvider');
      expect(provider.single.exported, isTrue);
      expect(provider.single.authorities, 'com.example.attrfixture.provider',
          reason: 'android:authorities(0x01010018) 没读到 —— '
              '曾与 debuggable 的 ID 互换');
    });

    test('service：exported=false 是「读到了 false」，不是「没读到」', () async {
      final meta = await _parseFixture();
      final service = meta.components
          .where((c) => c.type == ComponentType.service)
          .toList();
      expect(service, hasLength(1));
      expect(service.single.exported, isFalse,
          reason: 'false 与 null 必须能区分：前者是显式声明，后者是没声明');
    });

    test('启动页被识别出来（MAIN / LAUNCHER）', () async {
      final meta = await _parseFixture();
      expect(meta.launchableActivities.map((a) => a.name),
          contains('.MainActivity'));
    });
  });

  group('属性读对了，规则才会真的开火', () {
    test('ANDROID-DEBUGGABLE 在真实字节上触发', () async {
      final meta = await _parseFixture();
      final result = AndroidSecurityAudit.audit(
        meta: meta,
        dexEntries: const [],
      );
      final finding = result.findings
          .where((f) => f.ruleId == 'ANDROID-DEBUGGABLE')
          .toList();
      expect(finding, hasLength(1), reason: '清单里明写 debuggable=true，规则必须报');
      expect(finding.single.severity, SecuritySeverity.p1);
    });

    test('导出组件只报 LeakyProvider（走 provider 专项），不报启动页', () async {
      final meta = await _parseFixture();
      final result = AndroidSecurityAudit.audit(
        meta: meta,
        dexEntries: const [],
      );
      // provider 现在由 `ANDROID-PROVIDER-EXPOSED` 负责。
      final provider = result.findings
          .where((f) => f.ruleId == 'ANDROID-PROVIDER-EXPOSED')
          .toList();
      expect(provider, hasLength(1));
      expect(provider.single.severity, SecuritySeverity.p2);
      final detail = provider.single.evidence.map((e) => e.detail).join('\n');
      expect(detail, contains('LeakyProvider'));
      expect(detail, isNot(contains('MainActivity')),
          reason: '启动页必须导出，报它等于每个应用都报一条');
      // 「导出组件」汇总里不该再有 provider。
      expect(
        result.findings.where((f) => f.ruleId == 'ANDROID-EXPORTED-COMPONENT'),
        isEmpty,
      );
    });

    test('allowBackup=false → ANDROID-ALLOW-BACKUP 不触发（能区分 true/false）',
        () async {
      final meta = await _parseFixture();
      final result = AndroidSecurityAudit.audit(
        meta: meta,
        dexEntries: const [],
      );
      expect(
        result.findings.where((f) => f.ruleId == 'ANDROID-ALLOW-BACKUP'),
        isEmpty,
        reason: '夹具里显式写了 allowBackup=false；若这里报了，'
            '说明把「读不到」当成了「true」',
      );
    });
  });

  test('夹具本身存在且不是空壳', () {
    final file = File(_fixturePath);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1000));
  });
}
