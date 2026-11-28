import 'dart:io';
import 'dart:typed_data';

import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

const String _fixtures = '../../test/fixtures';

Uint8List _bytes(String relative) =>
    File('$_fixtures/$relative').readAsBytesSync();

void main() {
  // 期望值全部取自独立工具 `openssl x509 -text` / `-fingerprint`
  //（夹具生成命令见 test/fixtures/ipa/README.md），不从本解析器取。
  group('X.509 — 证书公开字段', () {
    late X509CertificateInfo cert;

    setUpAll(() {
      final info = CmsContentExtractor.extractCertificates(
        _bytes('ipa/embedded.mobileprovision'),
      );
      cert = info.certificates.single;
    });

    test('主体与签发者 DN 按 RFC 4514 输出', () {
      expect(cert.subject, 'CN=Probe');
      expect(cert.issuer, 'CN=Probe');
    });

    test('序列号与 openssl 一致（大写、无分隔）', () {
      expect(cert.serialNumberHex, '9D872EE17763407E');
    });

    test('签名算法 OID 被翻译成名称', () {
      expect(cert.signatureAlgorithm, 'SHA256withRSA');
    });

    test('公钥算法与长度', () {
      expect(cert.publicKeyAlgorithm, 'RSA');
      expect(cert.publicKeyBits, 2048);
      expect(cert.publicKeyCurve, isNull);
    });

    test('三种指纹与 openssl 一致', () {
      expect(
        X509Parser.formatFingerprint(cert.sha256Fingerprint!),
        'C6:57:A1:AD:D1:3E:54:1A:B8:7C:E7:6A:01:7D:75:ED:'
        '32:9C:7C:5F:16:42:35:E7:79:46:85:90:13:79:C1:0E',
      );
      expect(
        X509Parser.formatFingerprint(cert.sha1Fingerprint!),
        '0E:F1:6D:B8:18:5F:8C:16:E5:60:D6:F0:A5:1A:19:A2:64:8C:8E:E9',
      );
      expect(
        X509Parser.formatFingerprint(cert.md5Fingerprint!),
        '3E:A4:F0:E1:F0:94:8F:DC:24:D9:94:10:53:28:81:5A',
      );
    });

    test('有效期与 openssl 一致（精确到秒）', () {
      expect(cert.notBefore, DateTime.utc(2026, 10, 13, 15, 34, 7));
      expect(cert.notAfter, DateTime.utc(2026, 10, 15, 15, 34, 7));
    });
  });

  group('X.509 — 界限', () {
    test('畸形输入返回 null，不抛异常', () {
      expect(
        () => X509Parser.parse(
          Uint8List.fromList(List.generate(64, (i) => (i * 7) % 251)),
        ),
        returnsNormally,
      );
      expect(
        X509Parser.parse(
          Uint8List.fromList(List.generate(64, (i) => (i * 7) % 251)),
        ),
        isNull,
      );
      expect(X509Parser.parse(Uint8List(0)), isNull);
    });

    test('formatFingerprint 对空串与奇数长度不越界', () {
      expect(X509Parser.formatFingerprint(''), '');
      expect(X509Parser.formatFingerprint('ab'), 'AB');
      expect(X509Parser.formatFingerprint('abcd'), 'AB:CD');
    });
  });
}
