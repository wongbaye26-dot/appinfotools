// iOS 签名材料的静态提取测试（规范 5.5）。
//
// 正常样本是一个**真实的 CMS/PKCS#7 SignedData**（`test/fixtures/ipa/
// embedded.mobileprovision`，由 macOS `security cms` 生成，见同目录 README），
// 期望值取自 `security cms -D` —— 独立于本项目的参照物。用真实产物而不是
// 手工拼的字节，是因为手工拼的 CMS 会带着与提取器相同的错误假设。
//
// 畸形样本只能手工构造，而它们断言的是「必须拒绝并且不死循环」，
// 构造器与被测逻辑不共享假设。
//
// 本文件**不**测试签名验证 —— 本项目不做签名验证（规范 5.5）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

/// 真实的描述文件样本。
///
/// 生成命令见 `test/fixtures/ipa/README.md`；解码结果用
/// `security cms -D -i embedded.mobileprovision` 交叉核对过。
Uint8List _provisionFixture() {
  final file = File('test/fixtures/ipa/embedded.mobileprovision');
  expect(file.existsSync(), isTrue,
      reason: '缺少测试样本 —— 见 test/fixtures/ipa/README.md');
  return file.readAsBytesSync();
}

/// 一个覆盖全部待提取字段的描述文件 plist（XML）。
///
/// 与真实样本字段一致，便于断言；真实样本另行验证 CMS 外壳。
const String _provisionPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppIDName</key>
	<string>Probe App</string>
	<key>ApplicationIdentifierPrefix</key>
	<array>
		<string>ABCDE12345</string>
	</array>
	<key>CreationDate</key>
	<date>2024-01-01T00:00:00Z</date>
	<key>ExpirationDate</key>
	<date>2025-01-01T00:00:00Z</date>
	<key>Name</key>
	<string>Probe Distribution</string>
	<key>TeamIdentifier</key>
	<array>
		<string>ABCDE12345</string>
	</array>
	<key>UUID</key>
	<string>11111111-2222-3333-4444-555555555555</string>
	<key>Entitlements</key>
	<dict>
		<key>application-identifier</key>
		<string>ABCDE12345.com.example.app</string>
		<key>com.apple.developer.team-identifier</key>
		<string>ABCDE12345</string>
		<key>get-task-allow</key>
		<false/>
		<key>aps-environment</key>
		<string>production</string>
	</dict>
</dict>
</plist>
''';

// ---------------------------------------------------------------------------
// BER 构造工具（仅测试用）
// ---------------------------------------------------------------------------

/// 定长 TLV。
List<int> _tlv(int tag, List<int> content) {
  final length = content.length;
  final header = <int>[tag];
  if (length < 0x80) {
    header.add(length);
  } else if (length <= 0xFF) {
    header.addAll([0x81, length]);
  } else {
    header.addAll([0x82, (length >> 8) & 0xFF, length & 0xFF]);
  }
  return [...header, ...content];
}

/// 不定长 TLV（BER），自动补结束标记。
List<int> _indefinite(int tag, List<int> content) =>
    [tag, 0x80, ...content, 0x00, 0x00];

const List<int> _signedDataOid = [
  0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02, //
];

const List<int> _dataOid = [
  0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01, //
];

/// 构造一个 CMS `SignedData`，[payload] 作为 `eContent`。
///
/// [indefiniteLengths] 为 true 时全部使用 BER 不定长，模拟 `security cms`
/// 的产物；为 false 时全部定长。
///
/// [eContentOverride] 直接作为 `eContent` 包装器的内容，用于构造分段
/// OCTET STRING 这类 [payload] 表达不了的结构。
///
/// `eContent` 之后**故意**再放一个元素（模拟真实的证书/签名者信息）——
/// 提前认定容器结束的实现在这里就会失败。
Uint8List _buildCms(
  List<int> payload, {
  bool indefiniteLengths = true,
  List<int> contentType = _dataOid,
  List<int>? outerContentType,
  List<int>? eContentOverride,
}) {
  final eContent = _tlv(0x04, payload);
  final encapContentInfo = _tlv(0x30, [
    ..._tlv(0x06, contentType),
    ..._tlv(0xA0, eContentOverride ?? eContent),
  ]);

  final signedData = _tlv(0x30, [
    ..._tlv(0x02, [0x01]),
    ..._tlv(0x31, const []),
    ...encapContentInfo,
    // eContent 之后的元素：证书 / 签名者信息。真实文件一定有。
    ..._tlv(0xA0, _tlv(0x30, List.filled(8, 0xAB))),
  ]);

  final outer = _tlv(0x30, [
    ..._tlv(0x06, outerContentType ?? _signedDataOid),
    ..._tlv(0xA0, signedData),
  ]);

  if (!indefiniteLengths) return Uint8List.fromList(outer);

  // 用不定长重新拼一遍：只有容器改成不定长，叶子仍定长。
  final indefiniteSignedData = _indefinite(0x30, [
    ..._tlv(0x02, [0x01]),
    ..._tlv(0x31, const []),
    ..._indefinite(0x30, [
      ..._tlv(0x06, contentType),
      ..._indefinite(0xA0, eContentOverride ?? _indefinite(0x24, eContent)),
    ]),
    ..._tlv(0xA0, _tlv(0x30, List.filled(8, 0xAB))),
  ]);

  return Uint8List.fromList(
    _indefinite(0x30, [
      ..._tlv(0x06, outerContentType ?? _signedDataOid),
      ..._indefinite(0xA0, indefiniteSignedData),
    ]),
  );
}

// ---------------------------------------------------------------------------
// 归档构造工具
// ---------------------------------------------------------------------------

ArchiveFile _file(String name, List<int> content) =>
    ArchiveFile(name, content.length, Uint8List.fromList(content));

ArchiveFile _dir(String name) => ArchiveFile(name, 0, <int>[])..isFile = false;

/// 一个带签名材料的主应用。
Archive _ipa({
  List<int>? provision,
  bool codeSignature = true,
  List<String> codeSignatureEntries = const ['CodeResources'],
  List<int>? infoPlist,
}) {
  final archive = Archive()
    ..addFile(_dir('Payload/'))
    ..addFile(_dir('Payload/MyApp.app/'))
    ..addFile(_file('Payload/MyApp.app/Info.plist',
        utf8.encode(infoPlist == null ? _provisionPlist : _infoPlistXml)))
    ..addFile(_file('Payload/MyApp.app/MyApp', List.filled(64, 0xCF)));

  if (codeSignature) {
    for (final entry in codeSignatureEntries) {
      archive.addFile(
          _file('Payload/MyApp.app/_CodeSignature/$entry', List.filled(32, 7)));
    }
  }
  if (provision != null) {
    archive
        .addFile(_file('Payload/MyApp.app/embedded.mobileprovision', provision));
  }
  return archive;
}

const String _infoPlistXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.example.app</string>
</dict>
</plist>
''';

IosBundle _mainApp(Archive archive) =>
    IpaContainerReader.read(archive).mainApp!;

void main() {
  group('CmsContentExtractor — 真实描述文件', () {
    late CmsContentResult result;

    setUpAll(() {
      result = CmsContentExtractor.extract(_provisionFixture());
    });

    test('从真实的 CMS 外壳里取出 plist 字节', () {
      expect(result.ok, isTrue, reason: result.failure);
      // 长度与 `openssl asn1parse` 报告的 `l= 952` 一致。
      expect(result.content!.length, 952);
    });

    test('取出的字节确实是一段 plist', () {
      final text = utf8.decode(result.content!.sublist(0, 40));
      expect(text, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
    });

    test('解析出的字段与 `security cms -D` 一致', () {
      final parsed = PlistParser.parse(result.content!) as PlistDict;
      final map = parsed.value;

      expect((map['Name'] as PlistString).value, 'Probe Distribution');
      expect((map['AppIDName'] as PlistString).value, 'Probe App');
      expect((map['UUID'] as PlistString).value,
          '11111111-2222-3333-4444-555555555555');
      expect((map['TeamIdentifier'] as PlistArray).value.single.asString,
          'ABCDE12345');
      expect(
          (map['CreationDate'] as PlistDate).value,
          DateTime.utc(2024, 1, 1));
      expect(
          (map['ExpirationDate'] as PlistDate).value, DateTime.utc(2025, 1, 1));

      final entitlements = (map['Entitlements'] as PlistDict).value;
      expect((entitlements['application-identifier'] as PlistString).value,
          'ABCDE12345.com.example.app');
      expect((entitlements['get-task-allow'] as PlistBoolean).value, isFalse);
      expect((entitlements['aps-environment'] as PlistString).value,
          'production');
    });

    test('eContent 之后还有证书与签名者信息时不会提前收尾', () {
      // 真实样本正是这种形态：payload 在文件中间，后面还有 1176 字节。
      // 如果实现把「eContent 的结束标记」当成父容器的结束标记，
      // 上面几个断言就会因为解析出截断的 plist 而失败。
      expect(_provisionFixture().length, greaterThan(result.content!.length));
      expect(result.content!.length, lessThan(1100));
    });
  });

  group('CmsContentExtractor — 定长与不定长编码', () {
    test('定长（DER）外壳同样能取出载荷', () {
      final cms = _buildCms(utf8.encode(_provisionPlist),
          indefiniteLengths: false);
      final result = CmsContentExtractor.extract(cms);

      expect(result.ok, isTrue, reason: result.failure);
      expect(utf8.decode(result.content!), _provisionPlist);
    });

    test('不定长（BER）外壳把多段 OCTET STRING 拼起来', () {
      // `security cms` 会把长内容切成构造形式的 OCTET STRING；
      // 这里手工造两段，验证拼接而不是「只取第一段」。
      final whole = utf8.encode(_provisionPlist);
      final first = whole.sublist(0, whole.length ~/ 2);
      final second = whole.sublist(whole.length ~/ 2);

      final cms = _buildCms(
        const [],
        indefiniteLengths: true,
        // `[0] { OCTET STRING(构造) { OCTET STRING(第一段), OCTET STRING(第二段) } }`
        eContentOverride: _indefinite(0x24, [
          ..._tlv(0x04, first),
          ..._tlv(0x04, second),
        ]),
      );
      final result = CmsContentExtractor.extract(cms);

      expect(result.ok, isTrue, reason: result.failure);
      expect(utf8.decode(result.content!), _provisionPlist);
    });
  });

  group('CmsContentExtractor — 畸形输入必须被拒绝', () {
    test('空输入', () {
      final result = CmsContentExtractor.extract(Uint8List(0));
      expect(result.ok, isFalse);
      expect(result.failure, contains('empty'));
    });

    test('根元素不是 SEQUENCE', () {
      final result = CmsContentExtractor.extract(
        Uint8List.fromList(_tlv(0x02, [0x01])),
      );
      expect(result.ok, isFalse);
      expect(result.failure, contains('SEQUENCE'));
    });

    test('内容类型不是 pkcs7-signedData', () {
      final cms = _buildCms(utf8.encode(_provisionPlist),
          outerContentType: _dataOid);
      final result = CmsContentExtractor.extract(cms);

      expect(result.ok, isFalse);
      expect(result.failure, contains('pkcs7-signedData'));
    });

    test('encapContentInfo 的内容类型不是 pkcs7-data', () {
      final cms = _buildCms(utf8.encode(_provisionPlist),
          contentType: _signedDataOid);
      final result = CmsContentExtractor.extract(cms);

      expect(result.ok, isFalse);
      expect(result.failure, contains('pkcs7-data'));
    });

    test('声明长度超出缓冲区时不越界读', () {
      // `30 84 FF FF FF FF`：SEQUENCE 声称有 4 GiB 内容。
      final result = CmsContentExtractor.extract(
        Uint8List.fromList([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]),
      );
      expect(result.ok, isFalse);
    });

    test('长度字段被截断', () {
      final result = CmsContentExtractor.extract(
        Uint8List.fromList([0x30, 0x82, 0x01]),
      );
      expect(result.ok, isFalse);
    });

    test('不定长容器缺少结束标记', () {
      final result = CmsContentExtractor.extract(
        Uint8List.fromList([0x30, 0x80, 0x02, 0x01, 0x01]),
      );
      expect(result.ok, isFalse);
    });

    test('只有结束标记', () {
      final result = CmsContentExtractor.extract(
        Uint8List.fromList([0x00, 0x00]),
      );
      expect(result.ok, isFalse);
    });

    test('长度字节声称是 0xFF 段（非法长形式）', () {
      final result = CmsContentExtractor.extract(
        Uint8List.fromList([0x30, 0xFF, 0x00, 0x00]),
      );
      expect(result.ok, isFalse);
    });

    test('深嵌套不会打穿栈', () {
      // 200 层 `30 80` —— 超过深度上限，必须被拒绝而不是栈溢出。
      final bytes = <int>[];
      for (var i = 0; i < 200; i++) {
        bytes.addAll([0x30, 0x80]);
      }
      for (var i = 0; i < 200; i++) {
        bytes.addAll([0x00, 0x00]);
      }

      final result = CmsContentExtractor.extract(Uint8List.fromList(bytes));
      expect(result.ok, isFalse);
    });

    test('随机字节不会抛异常', () {
      // 固定种子的伪随机，保证可复现。
      var state = 0x12345678;
      int next() {
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
        return state & 0xFF;
      }

      for (var round = 0; round < 200; round++) {
        final bytes = Uint8List.fromList(
          List.generate(round * 3 + 2, (_) => next()),
        );
        // 只要求「不抛异常」：结论是 ok 还是 failure 都合法。
        expect(() => CmsContentExtractor.extract(bytes), returnsNormally);
      }
    });

    test('超过输入上限时拒绝，且不尝试分配', () {
      // 只声明长度、不给内容 —— 上限检查发生在读取之前。
      final huge = Uint8List(CmsContentExtractor.maxInputBytes + 1);
      huge[0] = 0x30;
      huge[1] = 0x80;

      final result = CmsContentExtractor.extract(huge);
      expect(result.ok, isFalse);
      expect(result.failure, contains('limit'));
    });
  });

  group('IpaSignatureMaterialReader — 材料清单', () {
    test('列出 _CodeSignature 条目并排序，不依赖顺序', () {
      final archive = _ipa(
        provision: _provisionFixture(),
        codeSignatureEntries: const ['CodeResources', 'CodeDirectory'],
      );
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.hasCodeSignatureDirectory, isTrue);
      expect(materials.codeSignatureEntries,
          ['CodeDirectory', 'CodeResources']);
      expect(materials.hasEmbeddedProvision, isTrue);
      expect(materials.embeddedProvisionSize, _provisionFixture().length);
      expect(materials.hasAnyMaterial, isTrue);
    });

    test('没有签名材料时状态是「未知」，不是「无效」', () {
      final archive = _ipa(codeSignature: false);
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.hasAnyMaterial, isFalse);
      expect(materials.verificationStatus, SignatureStatus.unknown);
      expect(materials.verificationStatus.hasConclusiveResult, isFalse);
      expect(
        materials.diagnostics.map((d) => d.code),
        contains('ios.signature.no_code_signature_dir'),
      );
    });

    test('有材料但没有工具验证时状态是「工具不可用」，不是「已通过」', () {
      final archive = _ipa(provision: _provisionFixture());
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.verificationStatus, SignatureStatus.toolUnavailable);
      expect(materials.verificationStatus.hasConclusiveResult, isFalse);
      expect(materials.isVerified, isFalse);
      expect(materials.verificationDetail, isNotNull);
      expect(materials.verificationDetail, contains('no signature verification'));
    });

    test('bundle 之外的签名材料不算在它头上', () {
      final archive = _ipa(provision: _provisionFixture())
        ..addFile(_file('Payload/Other.app/_CodeSignature/CodeResources',
            List.filled(8, 1)));

      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.codeSignatureEntries, ['CodeResources']);
    });
  });

  group('IpaSignatureMaterialReader — 描述文件字段', () {
    late IosProvisioningProfile profile;

    setUpAll(() {
      final archive = _ipa(provision: _provisionFixture());
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));
      expect(materials.profile.hasValue, isTrue,
          reason: materials.profile.diagnostic);
      profile = materials.profile.value!;
    });

    test('字段与 `security cms -D` 一致', () {
      expect(profile.name.value, 'Probe Distribution');
      expect(profile.appIdName.value, 'Probe App');
      expect(profile.uuid.value, '11111111-2222-3333-4444-555555555555');
      expect(profile.teamIdentifiers.value, ['ABCDE12345']);
      expect(profile.applicationIdentifierPrefixes.value, ['ABCDE12345']);
      expect(profile.applicationIdentifier.value, 'ABCDE12345.com.example.app');
      expect(profile.creationDate.value, DateTime.utc(2024, 1, 1));
      expect(profile.expirationDate.value, DateTime.utc(2025, 1, 1));
    });

    test('每个字段都标注来源为签名材料', () {
      expect(profile.name.source, FieldSource.signatureMaterials);
      expect(profile.expirationDate.source, FieldSource.signatureMaterials);
    });

    test('授权项保留原始 plist 类型', () {
      final byKey = {for (final e in profile.entitlements) e.key: e};

      expect(byKey['get-task-allow']!.value, isA<PlistBoolean>());
      expect(byKey['get-task-allow']!.valueText, 'false');
      expect(byKey['aps-environment']!.value, isA<PlistString>());
      expect(byKey['aps-environment']!.valueText, 'production');
      expect(profile.entitlements, hasLength(4));
      expect(profile.entitlementsRaw, isNotNull);
    });

    test('有效期判断接收显式时间，不读系统时钟', () {
      expect(profile.isExpiredAt(DateTime.utc(2024, 6, 1)), isFalse);
      expect(profile.isExpiredAt(DateTime.utc(2025, 1, 2)), isTrue);
      // 恰好到期的那一刻不算过期。
      expect(profile.isExpiredAt(DateTime.utc(2025, 1, 1)), isFalse);
    });

    test('有效期缺失时返回 null，而不是猜「有效」', () {
      const profile = IosProvisioningProfile();
      expect(profile.isExpiredAt(DateTime.utc(2030, 1, 1)), isNull);
    });
  });

  group('IpaSignatureMaterialReader — 异常描述文件', () {
    test('内容不是 CMS 时记为解析失败，而不是「缺失」', () {
      final archive = _ipa(provision: List.filled(512, 0x41));
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.profile.hasValue, isFalse);
      expect(materials.profile.status, FieldStatus.failed);
      expect(
        materials.diagnostics.map((d) => d.code),
        contains('ios.provision.cms_unreadable'),
      );
    });

    test('CMS 里裹的不是 plist 时记为解析失败', () {
      final archive = _ipa(provision: _buildCms(utf8.encode('not a plist')));
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.profile.status, FieldStatus.failed);
      expect(
        materials.diagnostics.map((d) => d.code),
        contains('ios.provision.unparsable'),
      );
    });

    test('CMS 里裹的是数组而不是字典时记为解析失败', () {
      const arrayPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><array><string>x</string></array></plist>
''';
      final archive = _ipa(provision: _buildCms(utf8.encode(arrayPlist)));
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.profile.status, FieldStatus.failed);
      expect(
        materials.diagnostics.map((d) => d.code),
        contains('ios.provision.not_a_dict'),
      );
    });

    test('声明尺寸超过上限时拒绝读取', () {
      final archive = _ipa();
      // 直接构造一个声称很大的条目。
      archive.addFile(ArchiveFile(
        'Payload/MyApp.app/embedded.mobileprovision',
        IpaSignatureMaterialReader.maxProvisionBytes + 1,
        Uint8List.fromList(_provisionFixture()),
      ));

      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));
      expect(materials.profile.status, FieldStatus.failed);
      expect(
        materials.diagnostics.map((d) => d.code),
        contains('ios.provision.too_large'),
      );
    });

    test('Entitlements 类型不符时记诊断，且不伪造 application-identifier', () {
      const badPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Name</key>
	<string>Bad</string>
	<key>Entitlements</key>
	<string>not a dict</string>
</dict>
</plist>
''';
      final archive = _ipa(provision: _buildCms(utf8.encode(badPlist)));
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      final profile = materials.profile.value!;
      expect(profile.name.value, 'Bad');
      expect(profile.entitlements, isEmpty);
      expect(profile.applicationIdentifier.hasValue, isFalse);
      expect(profile.applicationIdentifier.status, FieldStatus.absent);
      expect(
        materials.diagnostics.map((d) => d.code),
        contains('ios.plist.wrong_type'),
      );
    });

    test('日期被写成字符串时记类型错误，而不是猜一个时间', () {
      const badPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>ExpirationDate</key>
	<string>2025-01-01T00:00:00Z</string>
</dict>
</plist>
''';
      final archive = _ipa(provision: _buildCms(utf8.encode(badPlist)));
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      final profile = materials.profile.value!;
      expect(profile.expirationDate.hasValue, isFalse);
      expect(profile.expirationDate.status, FieldStatus.wrongType);
      expect(profile.expirationDate.diagnostic, contains('expected a date'));
      expect(profile.isExpiredAt(DateTime.utc(2030, 1, 1)), isNull);
    });

    test('TeamIdentifier 被写成字符串时记类型错误', () {
      const badPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>TeamIdentifier</key>
	<string>ABCDE12345</string>
</dict>
</plist>
''';
      final archive = _ipa(provision: _buildCms(utf8.encode(badPlist)));
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.profile.value!.teamIdentifiers.status,
          FieldStatus.wrongType);
    });

    test('描述文件缺失时状态是「不存在」，不是「失败」', () {
      final archive = _ipa(codeSignature: true);
      final materials =
          IpaSignatureMaterialReader.read(archive, _mainApp(archive));

      expect(materials.profile.status, FieldStatus.absent);
      expect(materials.profile.hasValue, isFalse);
      // 但材料存在，所以结论仍是「工具不可用」而不是「未知」。
      expect(materials.verificationStatus, SignatureStatus.toolUnavailable);
    });
  });

  group('compareIosAuthorization', () {
    IosProvisioningProfile profileWith(String? applicationIdentifier) {
      if (applicationIdentifier == null) return const IosProvisioningProfile();
      return IosProvisioningProfile(
        applicationIdentifier: FieldValue<String>.extracted(
          applicationIdentifier,
          source: FieldSource.signatureMaterials,
        ),
      );
    }

    FieldValue<String> appId(String? value) => value == null
        ? const FieldValue<String>.absent(source: FieldSource.infoPlist)
        : FieldValue<String>.extracted(value, source: FieldSource.infoPlist);

    test('标准写法：授权标识是「前缀 + bundle id」时一致', () {
      final result = compareIosAuthorization(
        bundleIdentifier: appId('com.example.app'),
        profile: profileWith('ABCDE12345.com.example.app'),
      );

      // 描述文件里是 `<App ID 前缀>.<bundle id>`，应用侧只有 `<bundle id>`。
      // 直接比字符串会让每个正常应用都被判成「授权的是别的应用」。
      expect(result.verdict, IosAuthorizationVerdict.matches);
      expect(result.isConsistent, isTrue);
      expect(result.isConclusive, isTrue);
    });

    test('授权标识不带前缀时也一致', () {
      final result = compareIosAuthorization(
        bundleIdentifier: appId('com.example.app'),
        profile: profileWith('com.example.app'),
      );

      expect(result.verdict, IosAuthorizationVerdict.matches);
    });

    test('后缀相同但 bundle id 不同时是不一致', () {
      final result = compareIosAuthorization(
        bundleIdentifier: appId('com.example.app'),
        profile: profileWith('ABCDE12345.com.example.app.extra'),
      );

      expect(result.verdict, IosAuthorizationVerdict.mismatch);
    });

    test('通配符授权覆盖该前缀下的应用，但不点名具体标识', () {
      final result = compareIosAuthorization(
        bundleIdentifier: appId('com.example.app'),
        profile: profileWith('ABCDE12345.*'),
      );

      expect(result.verdict, IosAuthorizationVerdict.wildcardMatch);
      expect(result.isConsistent, isTrue);
      expect(result.isConclusive, isTrue);
      expect(result.note, contains('wildcard'));
      expect(result.note, contains('does not pin'));
    });

    test('授权的是别的应用时不一致', () {
      final result = compareIosAuthorization(
        bundleIdentifier: appId('com.example.app'),
        profile: profileWith('ABCDE12345.com.other.app'),
      );

      expect(result.verdict, IosAuthorizationVerdict.mismatch);
      expect(result.isConsistent, isFalse);
      expect(result.appIdentifier, 'com.example.app');
      expect(result.authorizedIdentifier, 'ABCDE12345.com.other.app');
    });

    test('应用没有标识时无法比较，而不是判为不一致', () {
      final result = compareIosAuthorization(
        bundleIdentifier: appId(null),
        profile: profileWith('ABCDE12345.com.example.app'),
      );

      expect(result.verdict, IosAuthorizationVerdict.incomparable);
      expect(result.isConclusive, isFalse);
      expect(result.note, contains('CFBundleIdentifier'));
    });

    test('描述文件没有授权标识时无法比较', () {
      final result = compareIosAuthorization(
        bundleIdentifier: appId('ABCDE12345.com.example.app'),
        profile: profileWith(null),
      );

      expect(result.verdict, IosAuthorizationVerdict.incomparable);
      expect(result.isConclusive, isFalse);
      expect(result.note, contains('application-identifier'));
    });
  });
}
