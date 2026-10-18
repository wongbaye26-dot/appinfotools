// `res/xml/network_security_config.xml` 的展开。
//
// ## 为什么这件事不能省
//
// AOSP `ApplicationInfo`：**API 24 起，只要声明了 `android:networkSecurityConfig`，
// `android:usesCleartextTraffic` 就不再生效**，明文策略完全由那份 XML 决定。
//
// 于是只剩两条路，两条都是错的：
// - 照抄清单属性 → **证据指向一个平台根本不看的地方**；
// - 因为「属性无效」就不判定 → 把真发现吞掉（假阴性）。
//
// 唯一正确的做法是**打开那份 XML**。这条测试就是钉住它真的被打开了。
//
// ## 期望值从哪来
//
// `test/fixtures/apk/nsc-fixture.apk` 由 `aapt2` 真实编译链接产出（源文件见
// 同目录的 `nsc-fixture.AndroidManifest.xml` 与
// `nsc-fixture.network_security_config.xml`）。期望值全部来自独立工具：
//
// ```
// aapt2 dump xmltree test/fixtures/apk/nsc-fixture.apk \
//   --file res/xml/network_security_config.xml
// ```
//
// 输出里能看到 `base-config cleartextTrafficPermitted=false`、
// `domain-config cleartextTrafficPermitted=true`，以及两个 `<domain>` 的
// **文本节点**（`T: 'api.example.com'`）—— 域名在文本里而不是属性里，
// 所以 AXML 解析必须保留 `RES_XML_CDATA_TYPE`，否则只能数出「有 2 条规则」
// 却说不出是哪些域名。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/apk/nsc-fixture.apk';

Future<ApkMeta> _parseFixture() async {
  final reader = ApkReader();
  addTearDown(reader.close);
  final opened = await reader.open(_fixture);
  expect(opened.isOk, isTrue, reason: '夹具打不开：$opened');
  final meta = await reader.parse();
  expect(meta, isNotNull);
  return meta!;
}

void main() {
  group('资源 id → 文件路径 → AXML', () {
    test('清单里的引用被解成了真实路径并真的打开了', () async {
      final meta = await _parseFixture();
      expect(meta.networkSecurityConfigResId, isNotNull,
          reason: '没从 @res/0x... 里取出资源 id，后面就查不到路径');
      final nsc = meta.networkSecurityConfigInfo;
      expect(nsc, isNotNull, reason: '声明了 NSC 却没展开');
      expect(nsc!.parsed, isTrue, reason: '展开失败：${nsc.failure}');
      expect(nsc.path, 'res/xml/network_security_config.xml');
    });

    test('base-config 的 cleartextTrafficPermitted 读到了（false）', () async {
      final nsc = (await _parseFixture()).networkSecurityConfigInfo!;
      expect(nsc.baseCleartextPermitted, isFalse,
          reason: 'aapt2 显示 base-config cleartextTrafficPermitted=false');
    });

    test('domain-config 的域名与 includeSubdomains 都读到了', () async {
      final nsc = (await _parseFixture()).networkSecurityConfigInfo!;
      expect(nsc.domains, hasLength(2));
      final byDomain = {for (final d in nsc.domains) d.domain: d};
      expect(
          byDomain.keys, containsAll(['api.example.com', 'legacy.example.org']),
          reason: '域名是**元素文本**，不是属性 —— 不取 CDATA 就一个都拿不到');
      expect(byDomain['api.example.com']!.includeSubdomains, isTrue);
      expect(byDomain['legacy.example.org']!.includeSubdomains, isFalse);
      expect(byDomain['api.example.com']!.cleartextPermitted, isTrue);
    });
  });

  group('判定：base 与 domain 的覆盖关系', () {
    test('base 禁止但某个 domain 允许 → 整体仍允许明文', () async {
      final nsc = (await _parseFixture()).networkSecurityConfigInfo!;
      expect(nsc.resolvedAllowsCleartext(targetSdkVersion: 33), isTrue,
          reason: 'domain-config 覆盖 base-config；漏掉这条就会把'
              '「只对某几个域名放行」说成「完全禁止」');
    });

    test('放行的域名要能点名，而不是只给一个数量', () async {
      final nsc = (await _parseFixture()).networkSecurityConfigInfo!;
      expect(nsc.cleartextDomains,
          containsAll(['api.example.com', 'legacy.example.org']));
    });

    test('base 未声明时按 targetSdk 推平台默认（28 是分界）', () {
      // 这条不依赖夹具：直接构造，因为要覆盖 targetSdk 的两侧。
      const info = NetworkSecurityConfigInfo(
        path: 'res/xml/nsc.xml',
        domains: [
          NscDomainRule(domain: 'a.example', cleartextPermitted: false)
        ],
      );
      expect(info.resolvedAllowsCleartext(targetSdkVersion: 27), isTrue,
          reason: 'targetSdk < 28 时平台默认允许明文');
      expect(info.resolvedAllowsCleartext(targetSdkVersion: 28), isFalse);
      expect(info.resolvedAllowsCleartext(targetSdkVersion: null), isNull,
          reason: 'targetSdk 也读不到时就真的不知道，不能猜');
    });

    test('解析失败 → null，不是 false', () {
      const broken = NetworkSecurityConfigInfo(
        path: 'res/xml/nsc.xml',
        failure: 'not a readable binary XML',
      );
      expect(broken.parsed, isFalse);
      expect(broken.resolvedAllowsCleartext(targetSdkVersion: 33), isNull,
          reason: '「不知道」与「不允许」必须能区分');
      expect(broken.allowsCleartext, isNull);
    });

    test('不是 NSC 的 AXML（根元素不对）→ 记失败原因而不是崩', () {
      final info = parseNetworkSecurityConfig(
        // 一个最小但合法的 AXML：根元素叫别的名字。
        Uint8List.fromList(_minimalAxml()),
        path: 'res/xml/whatever.xml',
      );
      expect(info.parsed, isFalse);
      expect(info.failure, contains('root element'));
    });

    test('字节为 null（条目读不到）→ 记失败原因', () {
      final info = parseNetworkSecurityConfig(null, path: 'res/xml/nsc.xml');
      expect(info.parsed, isFalse);
      expect(info.failure, contains('could not be read'));
    });
  });

  group('规则 D 的证据指向真正生效的那份配置', () {
    test('有 NSC 时证据是 NSC 文件，不是清单属性', () async {
      final meta = await _parseFixture();
      final result =
          AndroidSecurityAudit.audit(meta: meta, dexEntries: const []);
      final ruleD = result.findings
          .where((f) => f.ruleId.startsWith('ANDROID-RULE-D'))
          .toList();
      expect(ruleD, hasLength(1), reason: 'domain-config 允许明文，规则 D 必须报');
      final locations = ruleD.single.evidence.map((e) => e.location).join('\n');
      expect(locations, contains('network security config'));
      expect(locations, contains('domain-config'));
      expect(locations, isNot(contains('AndroidManifest.xml')),
          reason: '有 NSC 时清单属性被平台忽略，拿它当证据等于指向不生效的地方');
    });

    test('有 NSC 且已展开 → 覆盖率是 covered，不再说「未展开」', () async {
      final meta = await _parseFixture();
      final result =
          AndroidSecurityAudit.audit(meta: meta, dexEntries: const []);
      final entry = result.coverage.entry('android.cleartextPolicy');
      expect(entry, isNotNull);
      expect(entry!.status, CoverageStatus.covered);
      expect(entry.noteCode, isNull);
    });

    test('base 禁止且没有放行域名 → 规则 D 不报', () async {
      final meta = await _parseFixture();
      // 直接把展开结果换成「全面禁止」，验证判定确实以 NSC 为准。
      meta.networkSecurityConfigInfo = const NetworkSecurityConfigInfo(
        path: 'res/xml/network_security_config.xml',
        baseCleartextPermitted: false,
      );
      final result =
          AndroidSecurityAudit.audit(meta: meta, dexEntries: const []);
      expect(
        result.findings.where((f) => f.ruleId.startsWith('ANDROID-RULE-D')),
        isEmpty,
        reason: '清单里写着 usesCleartextTraffic=true，但 NSC 才是生效的那份',
      );
    });
  });

  test('夹具存在且不是空壳', () {
    final file = File(_fixture);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1000));
  });
}

/// 一个最小的合法 AXML：`<foo a="b"/>`，根元素不叫 `network-security-config`。
///
/// 手工构造在这里是**对的**：它要验证的正是「根元素不对时如实报错」，
/// 而真实产物不可能产出这种文件。
List<int> _minimalAxml() {
  // 复用解析器自己的编码能力太绕，这里直接拼一份最小结构。
  const strings = <String>['foo', 'a', 'b'];
  final stringData = <int>[];
  final offsets = <int>[];
  for (final s in strings) {
    offsets.add(stringData.length);
    stringData
      ..add(s.length)
      ..add(0);
    for (final c in s.codeUnits) {
      stringData
        ..add(c & 0xff)
        ..add(0);
    }
    stringData.add(0);
    stringData.add(0);
  }
  final stringPoolSize = 28 + offsets.length * 4 + stringData.length;

  final body = <int>[];

  // START_ELEMENT: <foo a="b">
  final elem = <int>[];
  void eu16(int v) => elem
    ..add(v & 0xff)
    ..add((v >> 8) & 0xff);
  void eu32(int v) => elem
    ..add(v & 0xff)
    ..add((v >> 8) & 0xff)
    ..add((v >> 16) & 0xff)
    ..add((v >> 24) & 0xff);
  eu16(0x0102); // type
  eu16(16); // headerSize
  eu32(16 + 20 + 20); // size
  eu32(0); // lineNumber
  eu32(0xffffffff); // comment
  eu32(0xffffffff); // ns
  eu32(0); // name -> "foo"
  eu16(20); // attributeStart
  eu16(20); // attributeSize
  eu16(1); // attributeCount
  eu16(0);
  eu16(0);
  eu16(0);
  eu32(0xffffffff); // attr ns
  eu32(1); // attr name -> "a"
  eu32(2); // rawValue -> "b"
  eu16(8);
  elem.add(0);
  elem.add(0x03); // TYPE_STRING
  eu32(2);
  body.addAll(elem);

  // END_ELEMENT
  final end = <int>[];
  void nu16(int v) => end
    ..add(v & 0xff)
    ..add((v >> 8) & 0xff);
  void nu32(int v) => end
    ..add(v & 0xff)
    ..add((v >> 8) & 0xff)
    ..add((v >> 16) & 0xff)
    ..add((v >> 24) & 0xff);
  nu16(0x0103);
  nu16(16);
  nu32(24);
  nu32(0);
  nu32(0xffffffff);
  nu32(0xffffffff);
  nu32(0);
  body.addAll(end);

  final pool = <int>[];
  void pu16(int v) => pool
    ..add(v & 0xff)
    ..add((v >> 8) & 0xff);
  void pu32(int v) => pool
    ..add(v & 0xff)
    ..add((v >> 8) & 0xff)
    ..add((v >> 16) & 0xff)
    ..add((v >> 24) & 0xff);
  pu16(0x0001);
  pu16(28);
  pu32(stringPoolSize);
  pu32(strings.length);
  pu32(0); // styleCount
  pu32(0x100); // UTF-8
  pu32(28 + offsets.length * 4); // stringsStart
  pu32(0); // stylesStart
  for (final o in offsets) {
    pu32(o);
  }
  pool.addAll(stringData);

  final out = <int>[];
  void ou16(int v) => out
    ..add(v & 0xff)
    ..add((v >> 8) & 0xff);
  void ou32(int v) => out
    ..add(v & 0xff)
    ..add((v >> 8) & 0xff)
    ..add((v >> 16) & 0xff)
    ..add((v >> 24) & 0xff);
  ou16(0x0003); // RES_XML_TYPE
  ou16(8);
  ou32(8 + pool.length + body.length);
  out.addAll(pool);
  out.addAll(body);
  return out;
}
