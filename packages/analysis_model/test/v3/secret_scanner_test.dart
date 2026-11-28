import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('SecretScanner', () {
    test('识别 AWS Access Key，脱敏且不返回明文', () {
      final outcome = SecretScanner.scanText(
        'const key = "AKIAIOSFODNN7EXAMPLE";',
        location: 'classes.dex',
      );
      expect(outcome.matches, hasLength(1));
      final match = outcome.matches.single;
      expect(match.kind, SecretKind.awsAccessKey);
      expect(match.redactedValue, 'AKIA…MPLE');
      expect(match.redactedValue, isNot(contains('IOSFODNN7')));
      expect(match.contextRedacted, contains('AKIA…MPLE'));
      expect(match.contextRedacted, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
      expect(match.valueSha256, hasLength(16));
      expect(match.id, startsWith('v1:'));
    });

    test('识别 Google API Key / GitHub token / 私钥头', () {
      final google = SecretScanner.scanText(
        'https://maps.example/?key=AIza${'a' * 35}',
        location: 'assets/config.json',
      );
      expect(google.matches.single.kind, SecretKind.googleApiKey);

      final github = SecretScanner.scanText(
        'token: ghp_${'a' * 36}',
        location: 'META-INF/x.properties',
      );
      expect(github.matches.single.kind, SecretKind.githubToken);

      final pem = SecretScanner.scanText(
        '-----BEGIN RSA PRIVATE KEY-----\nMIIE...',
        location: 'assets/key.pem',
      );
      expect(pem.matches.single.kind, SecretKind.privateKey);
    });

    test('credential assignment 取捕获组，不把整行当值', () {
      final outcome = SecretScanner.scanText(
        "api_key = 'abcdefghijklmnop1234'",
        location: 'res/raw/config.txt',
      );
      final match = outcome.matches
          .firstWhere((m) => m.kind == SecretKind.genericCredential);
      expect(match.redactedValue, 'abcd…1234');
      expect(match.contextRedacted, isNot(contains('abcdefghijklmnop1234')));
    });

    test('同一值只报一次（去重键含规则 id）', () {
      final text = 'AKIAIOSFODNN7EXAMPLE AKIAIOSFODNN7EXAMPLE';
      final outcome = SecretScanner.scanText(text, location: 'classes.dex');
      expect(outcome.matches, hasLength(1));
    });

    test('普通文本不产生误报', () {
      final outcome = SecretScanner.scanText(
        'build falvor "release" and api_key_setting_enabled = true',
        location: 'classes.dex',
      );
      expect(outcome.matches, isEmpty);
    });

    test('超出字节上限时截断并记录 code', () {
      final big = 'x' * 200 + ' AKIAIOSFODNN7EXAMPLE';
      final outcome = SecretScanner.scanText(
        big,
        location: 'classes.dex',
        limits: const SecretScanLimits(maxBytes: 50),
      );
      expect(outcome.truncated, isTrue);
      expect(outcome.skippedCodes, contains('secret.byteLimit'));
      expect(outcome.scannedBytes, 50);
    });

    test('命中上限生效且标记 truncated', () {
      // 必须用不同值：同值会被去重成一条，测不出上限。
      final text = List.generate(
        30,
        (i) => 'AKIA${i.toString().padLeft(16, '0')}',
      ).join(' ');
      final outcome = SecretScanner.scanText(
        text,
        location: 'classes.dex',
        limits: const SecretScanLimits(maxMatches: 3),
      );
      expect(outcome.matches.length, lessThanOrEqualTo(3));
      expect(outcome.truncated, isTrue);
      expect(outcome.skippedCodes, contains('secret.matchLimit'));
    });

    test('toJson / fromJson 往返保留字段与 id', () {
      final match = SecretScanner.scanText(
        'AKIAIOSFODNN7EXAMPLE',
        location: 'classes.dex',
      ).matches.single;
      final restored = SecretMatch.fromJson(match.toJson());
      expect(restored.toJson(), match.toJson());
      expect(restored.id, match.id);
    });

    test('脱敏函数规则：短值全掩、长度 8–15 留两头', () {
      expect(SecretRedactor.redact('short'), '***');
      expect(SecretRedactor.redact('abcdefgh'), 'ab…gh');
      expect(SecretRedactor.redact('a' * 20), 'aaaa…aaaa');
      expect(SecretRedactor.redact('   '), '***');
    });
  });
}
