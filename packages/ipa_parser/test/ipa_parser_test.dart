// ipa_parser 的包级测试。
//
// 覆盖四个纯逻辑子系统：plist（XML / 二进制）、Mach-O（thin / fat / 符号表）、
// CgBI PNG、CMS 载荷提取。全部复用仓库根目录 `test/fixtures/` 里由公开工具
// 生成的夹具（生成命令见各自 README），不另造样本。
//
// 本包**不做签名验证**（规范 5.5 禁止自实现签名算法并宣称权威结论），
// 因此这里断言的是「材料长什么样」与「提取是否如实」，而不是「签名是否有效」。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

const String _fixtures = '../../test/fixtures';

Uint8List _bytes(String relative) =>
    File('$_fixtures/$relative').readAsBytesSync();

void main() {
  group('PlistParser — 格式判定与解析', () {
    test('XML plist 能被识别并解析', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.app</string>
  <key>CFBundleVersion</key>
  <string>42</string>
</dict>
</plist>
''';
      final bytes = Uint8List.fromList(xml.codeUnits);
      expect(PlistParser.detectFormat(bytes), PlistFormat.xml);

      final value = PlistParser.parse(bytes);
      expect(value, isA<PlistDict>());
      final dict = value as PlistDict;
      expect(dict.value['CFBundleIdentifier'], isA<PlistString>());
    });

    test('既不是 XML 也不是 bplist 时格式判定为 null', () {
      expect(
        PlistParser.detectFormat(
          Uint8List.fromList(List.generate(64, (i) => (i * 3) % 251)),
        ),
        isNull,
      );
    });

    test('二进制 plist 的魔数能被认出（bplist00）', () {
      final magic = Uint8List.fromList('bplist00'.codeUnits);
      expect(PlistParser.detectFormat(magic), PlistFormat.binary);
    });

    test('二进制解析器对截断输入抛异常，而不是返回半成品', () {
      final truncated = Uint8List.fromList([
        ...'bplist00'.codeUnits,
        ...List.filled(8, 0),
      ]);
      expect(() => BinaryPlistParser.parse(truncated), throwsA(anything));
    });
  });

  group('Mach-O — thin / fat 与符号表', () {
    test('thin 文件解析出一个镜像，且架构名可读', () {
      final file = MachOParser.parse(_bytes('macho/thin-arm64.dylib'));

      expect(file.images, hasLength(1));
      expect(file.images.first.is64Bit, isTrue);
      // 架构名带位宽后缀（`arm64 (64-bit)`），不假设它恰好等于 `arm64`。
      expect(file.architectureNames.any((n) => n.contains('arm64')), isTrue);
    });

    test('fat 文件解析出两个切片，且各自独立解析', () {
      final file = MachOParser.parse(_bytes('macho/fat-x86_64-arm64.dylib'));

      expect(file.images.length, 2);
      expect(file.architectureNames.toSet(), hasLength(2));
      for (final image in file.images) {
        expect(image.offset, greaterThanOrEqualTo(0));
      }
    });

    test('链接库列表跨切片汇总并去重', () {
      final file = MachOParser.parse(_bytes('macho/fat-x86_64-arm64.dylib'));
      final libraries = file.allLinkedLibraries;
      expect(libraries, isNotEmpty);
      expect(libraries.toSet(), hasLength(libraries.length));
    });

    test('符号表：导入符号是 N_UNDF|N_EXT，导出符号是 N_SECT|N_EXT', () {
      // 用带真实符号表的夹具：`thin-arm64.dylib` 只有头部与加载命令。
      final file =
          MachOParser.parse(_bytes('macho/libnative-fixture-arm64.dylib'));
      final image = file.images.first;

      expect(image.symbolsRead, isTrue, reason: '夹具的符号表可读');
      final imported = image.importedSymbols;
      final exported = image.exportedSymbols;

      expect(imported, isNotEmpty, reason: '夹具导入了系统库符号');
      expect(exported, isNotEmpty, reason: '动态库要对外暴露符号');
      for (final symbol in imported) {
        expect(symbol.isUndefined, isTrue);
      }
      for (final symbol in exported) {
        expect(symbol.isDefinedExternal, isTrue);
      }
    });

    test('strip 过的库仍保留导入符号（链接期需要）', () {
      final file =
          MachOParser.parse(_bytes('macho/libnative-fixture-stripped.dylib'));
      expect(file.images.first.importedSymbols, isNotEmpty);
    });

    test('魔数不认识时记诊断、不抛，也不假装解析成功', () {
      final file = MachOParser.parse(
        Uint8List.fromList(List.generate(256, (i) => (i * 5) % 251)),
      );
      expect(file.images, isEmpty);
      expect(file.diagnostics, isNotEmpty);
    });

    test('太短的文件同样不抛', () {
      expect(() => MachOParser.parse(Uint8List(4)), returnsNormally);
    });
  });

  group('CgBI PNG — Apple 的 "PNG crush" 变体', () {
    test('真实 CgBI 夹具被认出，且尺寸能从块链里读出来', () {
      final bytes = _bytes('cgbi/rgba-alpha-16x16.cgbi.png');

      expect(isCgbiPng(bytes), isTrue);
      // IHDR 前面还有一个 CgBI 块 —— 写死偏移 12 会读成 null。
      expect(readPngSize(bytes), (16, 16));
    });

    test('规范化后不再含 CgBI 块，且能给出像素数据', () {
      final result = normalizeCgbiPng(_bytes('cgbi/rgba-alpha-16x16.cgbi.png'));

      expect(result.ok, isTrue, reason: result.failure ?? '');
      expect(isCgbiPng(result.png!), isFalse);
    });

    test('不是 CgBI 时明确拒绝，而不是照常转换', () {
      // 标准 PNG 的签名 + IHDR，但没有 CgBI 块。
      final standard = Uint8List.fromList([
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        ...'IHDR'.codeUnits,
      ]);
      expect(isCgbiPng(standard), isFalse);
      expect(normalizeCgbiPng(standard).ok, isFalse);
    });

    test('随机字节不抛异常', () {
      final junk = Uint8List.fromList(List.generate(64, (i) => (i * 9) % 251));
      expect(() => isCgbiPng(junk), returnsNormally);
      expect(() => normalizeCgbiPng(junk), returnsNormally);
    });
  });

  group('CMS — 从签名材料里取载荷', () {
    test('真实描述文件里的 CMS 能取出 plist 载荷', () {
      final der = _bytes('ipa/embedded.mobileprovision');
      final result = CmsContentExtractor.extract(der);

      expect(result.content, isNotNull, reason: result.failure ?? '');
      // 取出来的应当是 plist（XML 或二进制），不是任意字节。
      expect(PlistParser.detectFormat(result.content!), isNotNull);
    });

    test('载荷能被 plist 解析器解成字典，且带 TeamIdentifier', () {
      final der = _bytes('ipa/embedded.mobileprovision');
      final content = CmsContentExtractor.extract(der).content!;
      final value = PlistParser.parse(content);

      expect(value, isA<PlistDict>());
      expect((value as PlistDict).value['TeamIdentifier'], isNotNull);
    });

    test('非 CMS 输入如实报告失败，而不是返回空载荷冒充成功', () {
      final junk =
          Uint8List.fromList(List.generate(128, (i) => (i * 11) % 251));
      final result = CmsContentExtractor.extract(junk);

      expect(result.content, isNull);
      expect(result.failure, isNotNull);
    });

    test('空输入不抛异常', () {
      expect(() => CmsContentExtractor.extract(Uint8List(0)), returnsNormally);
    });
  });

  // iOS-B（第一批）：CMS 证书链的**公开信息**提取。
  //
  // 期望值全部取自**独立工具** `openssl pkcs7 -print_certs`（见
  // fixtures/ipa/README.md 的生成命令），不从本项目解析器取 ——
  // 否则就是自证。
  group('X.509 / CMS 证书链 — 只取公开信息', () {
    /// 夹具里的 CMS。
    Uint8List provision() => _bytes('ipa/embedded.mobileprovision');

    test('从真实描述文件里解出证书链（openssl 说只有 1 张）', () {
      final info = CmsContentExtractor.extractCertificates(provision());

      expect(info.failure, isNull, reason: info.failure ?? '');
      expect(info.entryCount, 1);
      expect(info.certificates, hasLength(1));
      expect(info.isEmpty, isFalse);
    });

    test('主体与签发者 CN 与 openssl 一致（CN=Probe）', () {
      final cert = CmsContentExtractor.extractCertificates(provision())
          .certificates
          .single;

      expect(cert.subjectCommonName, 'Probe');
      expect(cert.issuerCommonName, 'Probe');
    });

    test('有效期与 openssl 一致（精确到秒）', () {
      final cert = CmsContentExtractor.extractCertificates(provision())
          .certificates
          .single;

      expect(cert.notBefore, DateTime.utc(2026, 10, 13, 15, 34, 7));
      expect(cert.notAfter, DateTime.utc(2026, 10, 15, 15, 34, 7));
    });

    test('序列号与 openssl 一致（9D872EE17763407E）', () {
      final cert = CmsContentExtractor.extractCertificates(provision())
          .certificates
          .single;

      expect(cert.serialNumberHex, '9D872EE17763407E');
    });

    test('自签证书的签发者 CN 里没有 Apple —— 启发式如实反映', () {
      final cert = CmsContentExtractor.extractCertificates(provision())
          .certificates
          .single;

      // 夹具是自签的（CN=Probe），因此这个启发式必须为 false。
      // 它回答的是「自称是谁签的」，**不是**「证书可信」。
      expect(cert.issuerLooksLikeApple, isFalse);
    });

    test('畸形输入返回失败原因，不抛异常', () {
      final junk =
          Uint8List.fromList(List.generate(256, (i) => (i * 13) % 251));

      late CmsCertificateInfo info;
      expect(
        () => info = CmsContentExtractor.extractCertificates(junk),
        returnsNormally,
      );
      expect(info.failure, isNotNull);
      expect(info.certificates, isEmpty);

      expect(
        () => CmsContentExtractor.extractCertificates(Uint8List(0)),
        returnsNormally,
      );
    });

    test('超限输入被拒绝，不分配内存', () {
      final huge = Uint8List(
        CmsContentExtractor.maxInputBytes + 1,
      );
      final info = CmsContentExtractor.extractCertificates(huge);
      expect(info.failure, contains('above the'));
    });
  });

  group('DER 读取器 — 越界一律返回 null，不抛', () {
    test('截断的长度字段不崩', () {
      // SEQUENCE 声称长度 200，但只有 4 字节内容。
      final bytes = Uint8List.fromList([0x30, 0x81, 0xC8, 1, 2, 3, 4]);
      expect(DerReader(bytes).at(0), isNull);
    });

    test('不定长（BER 0x80）被拒绝 —— 证书里不该出现', () {
      final bytes = Uint8List.fromList([0x30, 0x80, 1, 2, 0x00, 0x00]);
      expect(DerReader(bytes).at(0), isNull);
    });

    test('OID 解出点分形式', () {
      // 2.5.4.3 的 DER 编码：06 03 55 04 03
      final bytes = Uint8List.fromList([0x06, 0x03, 0x55, 0x04, 0x03]);
      final reader = DerReader(bytes);
      final element = reader.at(0)!;
      expect(reader.oid(element), '2.5.4.3');
    });

    test('随机字节不抛异常', () {
      final random =
          Uint8List.fromList(List.generate(128, (i) => (i * 37) % 251));
      expect(() => DerReader(random).at(0), returnsNormally);
      final element = DerReader(random).at(0);
      if (element != null) {
        expect(() => DerReader(random).children(element), returnsNormally);
      }
    });
  });

  // iOS-B：`_CodeSignature/CodeResources` 的**结构**概况。
  //
  // 只回答「密封清单里列了多少个文件与规则」，**不回答密封是否有效**。
  group('CodeResources — 只数条目，不重算哈希', () {
    const bundlePath = 'Payload/Example.app';

    /// 把一段 CodeResources 字节放进一个最小归档里。
    IosSignatureMaterials readWith(Uint8List? codeResources) {
      final archive = Archive();
      if (codeResources != null) {
        archive.addFile(ArchiveFile(
          '$bundlePath/_CodeSignature/CodeResources',
          codeResources.length,
          codeResources,
        ));
      }
      return IpaSignatureMaterialReader.read(
        archive,
        const IosBundle(
          kind: IosBundleKind.mainApp,
          path: bundlePath,
          name: 'Example.app',
        ),
      );
    }

    test('数出 files / files2 / rules / rules2 的条目数', () {
      final materials = readWith(_bytes('ipa/CodeResources'));
      final cr = materials.codeResources;

      expect(cr, isNotNull, reason: '夹具里确实有 CodeResources');
      // 夹具刻意用了四个互不相等的数：读错键会立刻暴露。
      expect(cr!.fileCount, 2);
      expect(cr.file2Count, 3);
      expect(cr.ruleCount, 4, reason: 'rules(2) + rules2(2)');
      expect(cr.sealedFileCount, 5, reason: 'files + files2');
      expect(cr.isV2, isTrue);
      expect(cr.isParsed, isTrue);
    });

    test('没有 CodeResources 时是 null，不是空概况', () {
      final materials = readWith(null);
      expect(materials.codeResources, isNull, reason: '「没有这个文件」与「有但 0 条」必须分开');
    });

    test('畸形字节不抛异常，记诊断并给出 parseFailure', () {
      final junk =
          Uint8List.fromList(List.generate(128, (i) => (i * 17) % 251));

      late IosSignatureMaterials materials;
      expect(() => materials = readWith(junk), returnsNormally);

      final cr = materials.codeResources;
      expect(cr, isNotNull);
      expect(cr!.isParsed, isFalse);
      expect(cr.parseFailure, isNotNull);
      expect(cr.sealedFileCount, 0);
      expect(
        materials.diagnostics
            .any((d) => d.code.startsWith('ios.coderesources')),
        isTrue,
        reason: '畸形密封清单要留下诊断，而不是静默',
      );
    });
  });
}
