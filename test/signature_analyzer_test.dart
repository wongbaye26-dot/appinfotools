import 'dart:io';

import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

/// apksigner 成功输出的样本（v1 + v2 通过，单个签名者）。
///
/// 结构取自 `apksigner verify --print-certs --verbose` 的真实输出形态。
const _successOutput = '''
Verifies
Verified using v1 scheme (JAR signing): true
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): false
Verified using v4 scheme (APK Signature Scheme v4): false
Number of signers: 1
Signer #1 certificate DN: CN=Android Debug, O=Android, C=US
Signer #1 certificate SHA-256 digest: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
Signer #1 certificate SHA-1 digest: 0123456789abcdef0123456789abcdef01234567
Signer #1 key algorithm: RSA
Signer #1 key size (bits): 2048
Signer #1 certificate validity: 2024-01-01T00:00:00Z -- 2054-01-01T00:00:00Z
''';

/// apksigner 验证失败的输出样本。
const _failureOutput = '''
DOES NOT VERIFY
ERROR: APK Signature Scheme v2 signer #1: APK integrity check failed
''';

void main() {
  group('SignatureAnalyzer.parseResult', () {
    test('验证通过：状态、方案与签名者字段都被解析出来', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 0,
        stdout: _successOutput,
      );

      expect(a.status, SignatureStatus.verified);
      expect(a.status.hasConclusiveResult, isTrue);
      expect(a.verifiedSchemes, {'v1', 'v2'});
      expect(a.signers, hasLength(1));

      final signer = a.signers.single;
      expect(signer.index, 1);
      expect(signer.subjectDn, 'CN=Android Debug, O=Android, C=US');
      expect(signer.sha256Digest, startsWith('0123456789abcdef'));
      expect(signer.sha1Digest, startsWith('0123456789abcdef'));
      expect(signer.keyAlgorithm, 'RSA');
      expect(signer.keySizeBits, 2048);
      expect(signer.validity, '2024-01-01T00:00:00Z -- 2054-01-01T00:00:00Z');
      expect(signer.isEmpty, isFalse);
    });

    test('验证失败：退出码 1 -> verificationFailed，且保留原始原因', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 1,
        stdout: _failureOutput,
        stderr: 'ERROR: APK integrity check failed\n',
      );

      expect(a.status, SignatureStatus.verificationFailed);
      expect(a.exitCode, 1);
      expect(a.rawOutput, contains('DOES NOT VERIFY'));
      expect(a.rawOutput, contains('APK integrity check failed'));
    });

    test('非预期退出码 -> unknown，不能报成「签名无效」', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 2,
        stdout: 'usage: apksigner verify ...',
      );

      expect(a.status, SignatureStatus.unknown);
      expect(a.status.hasConclusiveResult, isFalse);
    });

    test('输出含 DOES NOT VERIFY 时，即使退出码异常也判为失败', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 3,
        stdout: _failureOutput,
      );
      expect(a.status, SignatureStatus.verificationFailed);
    });

    test('缺少可选字段时保持 null，不做推测填充', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 0,
        stdout: 'Verifies\n'
            'Verified using v2 scheme (APK Signature Scheme v2): true\n'
            'Signer #1 certificate DN: CN=Only DN\n',
      );

      final signer = a.signers.single;
      expect(signer.subjectDn, 'CN=Only DN');
      expect(signer.sha256Digest, isNull);
      expect(signer.sha1Digest, isNull);
      expect(signer.keyAlgorithm, isNull);
      expect(signer.keySizeBits, isNull);
      expect(signer.validity, isNull);
    });

    test('多个签名者按序号排序', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 0,
        stdout: 'Verifies\n'
            'Signer #2 certificate DN: CN=Second\n'
            'Signer #1 certificate DN: CN=First\n',
      );

      expect(a.signers.map((s) => s.index).toList(), [1, 2]);
      expect(a.signers.first.subjectDn, 'CN=First');
    });

    test('没有签名者时不报错', () {
      final a =
          SignatureAnalyzer.parseResult(exitCode: 0, stdout: 'Verifies\n');
      expect(a.signers, isEmpty);
      expect(a.verifiedSchemes, isEmpty);
    });
  });

  group('运行时缺失不能被说成「签名被篡改」', () {
    // apksigner 在 macOS / Linux 上只是一段 `exec java -jar apksigner.jar`
    // 的 shell 脚本。Java 缺失时它起不来 —— 而 macOS 的 /usr/bin/java 是个
    // 桩：没装 JDK 时它存在、能执行、以 **1** 退出。1 正是 apksigner 的
    // 「验证未通过」退出码。不先拦下来，缺 JDK 的机器上每个包都会被判成
    // 「签名被篡改」。
    test('macOS java 桩（退出码 1 + Unable to locate a Java Runtime）', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 1,
        stdout: '',
        stderr: 'The operation couldn\'t be completed. '
            'Unable to locate a Java Runtime.\n'
            'Please visit http://www.java.com for information on installing '
            'Java.\n',
      );

      expect(a.status, SignatureStatus.toolUnavailable);
      expect(a.status, isNot(SignatureStatus.verificationFailed));
      expect(a.toolExecuted, isFalse);
      expect(a.error, contains('Unable to locate a Java Runtime'));
    });

    test('bash 找不到 java（退出码 127）', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 127,
        stdout: '',
        stderr: '/path/apksigner: line 97: java: command not found\n',
      );

      expect(a.status, SignatureStatus.toolUnavailable);
      expect(a.toolExecuted, isFalse);
    });

    test('dash 的 `java: not found`', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 127,
        stdout: '',
        stderr: '/path/apksigner: 97: java: not found\n',
      );

      expect(a.status, SignatureStatus.toolUnavailable);
    });

    test('cmd.exe 的 is not recognized', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 9009,
        stdout: '',
        stderr:
            "'java' is not recognized as an internal or external command,\n",
      );

      expect(a.status, SignatureStatus.toolUnavailable);
    });

    test('普通的验证失败仍判为 verificationFailed（没被新规则吃掉）', () {
      final a = SignatureAnalyzer.parseResult(
        exitCode: 1,
        stdout: _failureOutput,
        stderr: 'ERROR: APK integrity check failed\n',
      );

      expect(a.status, SignatureStatus.verificationFailed);
      expect(a.toolExecuted, isTrue);
      expect(a.error, isNull);
    });
  });

  group('SignatureStatus / SignatureAnalysis 语义', () {
    test('工具不可用不是「签名无效」，且标记为未执行工具', () {
      final a = SignatureAnalysis.toolUnavailable('apksigner not found');

      expect(a.status, SignatureStatus.toolUnavailable);
      expect(a.status.hasConclusiveResult, isFalse);
      expect(a.toolExecuted, isFalse);
      expect(a.error, 'apksigner not found');
    });

    test('只有 verified / verificationFailed 是有结论的', () {
      expect(SignatureStatus.verified.hasConclusiveResult, isTrue);
      expect(SignatureStatus.verificationFailed.hasConclusiveResult, isTrue);
      expect(SignatureStatus.toolUnavailable.hasConclusiveResult, isFalse);
      expect(SignatureStatus.unknown.hasConclusiveResult, isFalse);
    });
  });

  group('SignatureAnalyzer.analyze 的进程层行为', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('signature_analyzer_test');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('二进制不存在 -> toolUnavailable（而不是 verificationFailed）', () async {
      final a = await SignatureAnalyzer.analyze(
        '${tmp.path}/whatever.apk',
        apksignerPath: '${tmp.path}/definitely-not-here',
      );

      expect(a.status, SignatureStatus.toolUnavailable);
      expect(a.toolExecuted, isFalse);
    });

    test('超时 -> unknown，且不等待子进程自然结束', () async {
      final script = File('${tmp.path}/slow_apksigner.sh');
      await script.writeAsString('#!/bin/sh\nsleep 5\n');
      await Process.run('chmod', ['+x', script.path]);

      final sw = Stopwatch()..start();
      final a = await SignatureAnalyzer.analyze(
        '${tmp.path}/whatever.apk',
        apksignerPath: script.path,
        timeout: const Duration(milliseconds: 400),
      );
      sw.stop();

      expect(a.status, SignatureStatus.unknown);
      expect(a.status.hasConclusiveResult, isFalse);
      expect(a.error, contains('timed out'));
      expect(a.toolExecuted, isTrue);
      // 若 kill 之后还去等 stdout/stderr 关闭，这里会一直等到脚本自己结束
      // （5s）—— 因为 `sleep` 继承了同一批管道。
      expect(
        sw.elapsedMilliseconds,
        lessThan(2000),
        reason: '超时后应立即返回，不等待子进程/孙进程结束',
      );
    });
  });
}
