import 'package:analysis_model/analysis_model.dart';
import 'package:test/test.dart';

void main() {
  group('FindingFingerprint', () {
    test('同一输入得到同一指纹，格式为 v1:<32 hex>', () {
      final a = FindingFingerprint.of(
        ruleId: 'ANDROID-PERMISSION-INTERNET',
        platform: 'android',
        artifactPath: 'AndroidManifest.xml',
        location: 'uses-permission',
        value: 'INTERNET',
      );
      final b = FindingFingerprint.of(
        ruleId: 'ANDROID-PERMISSION-INTERNET',
        platform: 'android',
        artifactPath: 'AndroidManifest.xml',
        location: 'uses-permission',
        value: 'INTERNET',
      );
      expect(a, b);
      expect(a, matches(RegExp(r'^v1:[0-9a-f]{32}$')));
    });

    test('路径大小写、前导斜杠与反斜杠不影响指纹', () {
      String fp(String path) => FindingFingerprint.of(
            ruleId: 'R',
            platform: 'android',
            artifactPath: path,
          );
      expect(fp('/lib/ARM64-V8A/libfoo.so'), fp('lib/arm64-v8a/libfoo.so'));
      expect(fp('lib\\x86\\libfoo.so'), fp('lib/x86/libfoo.so'));
      expect(fp('./lib/foo.so'), fp('lib/foo.so'));
    });

    test('位置里的偏移与行号被去掉', () {
      String fp(String location) => FindingFingerprint.of(
            ruleId: 'R',
            platform: 'android',
            location: location,
          );
      expect(fp('classes.dex+0x1a2b'), fp('classes.dex'));
      expect(fp('home_page.dart:120:7'), fp('home_page.dart'));
      expect(fp('  Foo   Bar  '), fp('foo bar'));
    });

    test('值的大小写与空白不影响指纹，且指纹不含明文', () {
      final a = FindingFingerprint.of(
        ruleId: 'SECRET-AWS',
        platform: 'ios',
        value: 'AKIAIOSFODNN7EXAMPLE',
      );
      final b = FindingFingerprint.of(
        ruleId: 'SECRET-AWS',
        platform: 'ios',
        value: '  akiaiosfodnn7example ',
      );
      expect(a, b);
      expect(a, isNot(contains('AKIA')));
    });

    test('规则或平台变化必变', () {
      final base = FindingFingerprint.of(
        ruleId: 'R1',
        platform: 'android',
        artifactPath: 'classes.dex',
        location: 'com/foo/Bar;',
      );
      expect(
        base,
        isNot(FindingFingerprint.of(
          ruleId: 'R2',
          platform: 'android',
          artifactPath: 'classes.dex',
          location: 'com/foo/Bar;',
        )),
      );
      expect(
        base,
        isNot(FindingFingerprint.of(
          ruleId: 'R1',
          platform: 'ios',
          artifactPath: 'classes.dex',
          location: 'com/foo/Bar;',
        )),
      );
    });

    test('缺省字段与空串等价', () {
      final a = FindingFingerprint.of(ruleId: 'R', platform: 'android');
      final b = FindingFingerprint.of(
        ruleId: 'R',
        platform: 'android',
        artifactPath: '   ',
        location: '\n',
        value: '',
      );
      expect(a, b);
    });

    test('规范化函数公开，便于报告 UI 复用', () {
      expect(FindingFingerprint.normalizeArtifactPath('/a/B/c'), 'a/b/c');
      expect(FindingFingerprint.normalizeArtifactPath('   '), isNull);
      expect(FindingFingerprint.normalizeLocation('a.dex+0x10'), 'a.dex');
      expect(FindingFingerprint.normalizeLocation(''), isNull);
    });
  });
}
