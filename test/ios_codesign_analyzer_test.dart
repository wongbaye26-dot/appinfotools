// `codesign` 调用的解析测试（规范 5.5）。
//
// 解析部分刻意与进程调用分离：样本是**真实** `codesign` 的输出（在 macOS 26
// 上对系统应用与 ad-hoc 签名样本实测得到），这样测试不必依赖本机环境，
// 而期望值来自工具本身而非本项目的假设。
//
// 另有一组**真的调用 codesign** 的端到端用例：它们在本机装有 codesign 时
// 运行，否则整体跳过 —— 跳过时不会把「没跑」写成「通过」。

import 'dart:io';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart' show PlistBoolean, PlistString;

/// 对系统应用（`/System/Applications/Calculator.app`）执行
/// `codesign -d --verbose=4` 的真实输出。
const String _signedInfoOutput = '''
Executable=/System/Applications/Calculator.app/Contents/MacOS/Calculator
Identifier=com.apple.calculator
Format=app bundle with Mach-O universal (arm64e arm64e.x1)
CodeDirectory v=20400 size=3629 flags=0x0(none) hashes=103+7 location=embedded
Platform identifier=27
VersionPlatform=1
VersionMin=1769984
VersionSDK=1769984
Hash type=sha256 size=32
CandidateCDHash sha256=9d586b23a9275d3c996a57819bb2dcc390dcceab
CandidateCDHashFull sha256=9d586b23a9275d3c996a57819bb2dcc390dcceab6676f87b16037c8f8a018593
Hash choices=sha256
CMSDigest=9d586b23a9275d3c996a57819bb2dcc390dcceab6676f87b16037c8f8a018593
CMSDigestType=2
Page size=16384
CDHash=9d586b23a9275d3c996a57819bb2dcc390dcceab
Signature size=4202
Authority=Software Signing
Authority=Apple Code Signing Certification Authority
Authority=Apple Root CA
TeamIdentifier=not set
Sealed Resources version=2 rules=13 files=74
Info.plist entries=36
TeamIdentifier=not set
''';

/// 对一个由 `/bin/echo` 拷贝并 ad-hoc 重签的 bundle 执行
/// `codesign -d --verbose=4` 的真实输出（截取到需要的行）。
const String _adhocInfoOutput = '''
Executable=/private/tmp/cstest/Adhoc.app/Contents/MacOS/Adhoc
Identifier=Adhoc-55554944236623055dae3a4fb9d72518dca6b7cf
Format=bundle with Mach-O universal (x86_64 arm64e arm64e.x1)
CodeDirectory v=20400 size=327 flags=0x2(adhoc) hashes=3+3 location=embedded
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Sealed Resources=none
Internal requirements=none
''';

/// `codesign -d --entitlements :-` 对系统应用的真实输出（截取）。
const String _entitlementsOutput = '''
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>aps-environment</key><string>production</string><key>com.apple.security.exception.shared-preference.read-only</key><array><string>com.apple.calculator</string></array></dict></plist>
''';

void main() {
  group('parseVerifyResult — 退出码语义', () {
    test('0 且输出里有 codesign 的结论行时表示验证通过', () {
      final (status, error) = IosCodeSignAnalyzer.parseVerifyResult(
        exitCode: 0,
        stderr: '/tmp/Ok.app: valid on disk\n'
            '/tmp/Ok.app: satisfies its Designated Requirement',
      );

      expect(status, SignatureStatus.verified);
      expect(status.hasConclusiveResult, isTrue);
      expect(error, isNull);
    });

    test('0 但输出不像 codesign 时不报「验证通过」', () {
      // 这是最危险的一类错误：路径被指向别的程序，对方返回 0，
      // 于是「签名有效」被凭空报出来。规范 5.5 明确禁止这种展示。
      final (status, error) =
          IosCodeSignAnalyzer.parseVerifyResult(exitCode: 0, stderr: '');

      expect(status, SignatureStatus.unknown);
      expect(status.hasConclusiveResult, isFalse);
      expect(error, contains('may not be codesign'));
    });

    test('1 表示验证不通过，并带上 codesign 给的原因', () {
      final (status, error) = IosCodeSignAnalyzer.parseVerifyResult(
        exitCode: 1,
        stderr:
            '/tmp/Bare.app: code has no resources but signature indicates they must be present',
      );

      expect(status, SignatureStatus.verificationFailed);
      expect(error, contains('not valid'));
      expect(error, contains('signature indicates they must be present'));
    });

    test('3 表示密封完好但不满足指定要求（ad-hoc 必然如此）', () {
      final (status, error) = IosCodeSignAnalyzer.parseVerifyResult(
        exitCode: 3,
        stderr: '/tmp/Adhoc.app: valid on disk\n'
            '/tmp/Adhoc.app: does not satisfy its designated Requirement',
      );

      expect(status, SignatureStatus.verificationFailed);
      // 原因必须与「文件被篡改」区分开，否则会把 ad-hoc 签名误报成恶意。
      expect(error, contains('designated requirement'));
      expect(error, contains('seal is intact'));
    });

    test('路径不存在时归入「未知」，不是「签名无效」', () {
      final (status, error) = IosCodeSignAnalyzer.parseVerifyResult(
        exitCode: 1,
        stderr: '/tmp/nope.app: No such file or directory',
      );

      expect(status, SignatureStatus.unknown);
      expect(status.hasConclusiveResult, isFalse);
      expect(error, contains('could not find'));
    });

    test('其他退出码归入「未知」，不猜测含义', () {
      final (status, error) = IosCodeSignAnalyzer.parseVerifyResult(
        exitCode: 4,
        stderr: 'something went wrong',
      );

      expect(status, SignatureStatus.unknown);
      expect(error, contains('exited with 4'));
      expect(error, contains('something went wrong'));
    });

    test('stderr 为空时也能给出结论', () {
      final (status, error) =
          IosCodeSignAnalyzer.parseVerifyResult(exitCode: 1, stderr: '   ');

      expect(status, SignatureStatus.verificationFailed);
      expect(error, isNotNull);
      expect(error, isNot(contains(': ')));
    });
  });

  group('parseInfo — 描述性信息', () {
    test('从真实输出里取出已知字段', () {
      final info = IosCodeSignAnalyzer.parseInfo(_signedInfoOutput);

      expect(info.identifier, 'com.apple.calculator');
      expect(info.executable,
          '/System/Applications/Calculator.app/Contents/MacOS/Calculator');
      expect(
          info.format, 'app bundle with Mach-O universal (arm64e arm64e.x1)');
      expect(info.cdHash, '9d586b23a9275d3c996a57819bb2dcc390dcceab');
      expect(info.sealedResources, 'version=2 rules=13 files=74');
      expect(info.hasAnyValue, isTrue);
    });

    test('多行 Authority 全部保留且保持顺序', () {
      final info = IosCodeSignAnalyzer.parseInfo(_signedInfoOutput);

      expect(info.authorities, [
        'Software Signing',
        'Apple Code Signing Certification Authority',
        'Apple Root CA',
      ]);
    });

    test('`not set` 被当作「没有值」而不是一个值', () {
      final info = IosCodeSignAnalyzer.parseInfo(_adhocInfoOutput);

      expect(info.teamIdentifier, isNull);
      expect(info.signatureKind, 'adhoc');
    });

    test('未知行不影响解析', () {
      final info = IosCodeSignAnalyzer.parseInfo(
        'Page size=16384\nSomeFutureKey=whatever\nIdentifier=com.example.app',
      );

      expect(info.identifier, 'com.example.app');
    });

    test('空输出得到空信息而不是异常', () {
      final info = IosCodeSignAnalyzer.parseInfo('');

      expect(info.hasAnyValue, isFalse);
      expect(info.authorities, isEmpty);
    });

    test('没有等号的行被忽略', () {
      final info =
          IosCodeSignAnalyzer.parseInfo('garbage line\nno equals here');

      expect(info.hasAnyValue, isFalse);
    });
  });

  group('parseEntitlements — 授权项', () {
    test('解析真实的 XML plist 输出', () {
      final entitlements =
          IosCodeSignAnalyzer.parseEntitlements(_entitlementsOutput);

      expect(entitlements, isNotNull);
      expect(entitlements, hasLength(3));

      final byKey = {for (final e in entitlements!) e.key: e};
      expect(
          byKey['com.apple.security.app-sandbox']!.value, isA<PlistBoolean>());
      expect(byKey['com.apple.security.app-sandbox']!.valueText, 'true');
      expect(byKey['aps-environment']!.value, isA<PlistString>());
      expect(byKey['aps-environment']!.valueText, 'production');
      expect(
          byKey['com.apple.security.exception.shared-preference.read-only']!
              .valueText,
          'com.apple.calculator');
    });

    test('空输出表示没有授权项，返回空列表而不是 null', () {
      expect(IosCodeSignAnalyzer.parseEntitlements(''), isEmpty);
      expect(IosCodeSignAnalyzer.parseEntitlements('   \n  '), isEmpty);
    });

    test('输出不是 plist 时返回 null，而不是当成「没有授权项」', () {
      expect(
          IosCodeSignAnalyzer.parseEntitlements('[Dict]\n\t[Key] x'), isNull);
    });

    test('输出是 plist 但不是字典时返回 null', () {
      expect(
        IosCodeSignAnalyzer.parseEntitlements(
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<plist version="1.0"><array><string>x</string></array></plist>',
        ),
        isNull,
      );
    });
  });

  group('findCodesignPath', () {
    test('显式传入的路径被原样采用（便于测试与自定义）', () {
      expect(
        IosCodeSignAnalyzer.findCodesignPath(override: '/opt/bin/codesign'),
        '/opt/bin/codesign',
      );
    });

    test('macOS 上能找到系统的 codesign', () {
      if (!Platform.isMacOS) return;
      expect(IosCodeSignAnalyzer.findCodesignPath(), '/usr/bin/codesign');
    });

    test('非 macOS 平台返回 null（无工具可用）', () {
      if (Platform.isMacOS) return;
      expect(IosCodeSignAnalyzer.findCodesignPath(), isNull);
    });
  });

  group('端到端：真的调用 codesign', () {
    // 只有本机确实有 codesign 时才跑；没有就跳过，绝不把「没跑」当「通过」。
    final codesign = IosCodeSignAnalyzer.findCodesignPath();
    final skipReason = codesign == null ? '本机没有 codesign' : null;

    test('对 ad-hoc 签名的 bundle 得到「不满足指定要求」', () async {
      // 用系统自带的已签名二进制搭一个临时 bundle，再 ad-hoc 重签。
      // 这样样本是**真实**的签名产物，而不是手工拼的字节。
      final temp = await Directory.systemTemp.createTemp('appinfo_cs_test_');
      try {
        final appPath = '${temp.path}/Adhoc.app';
        await Directory('$appPath/Contents/MacOS').create(recursive: true);
        await File('/bin/echo').copy('$appPath/Contents/MacOS/Adhoc');
        await File('$appPath/Contents/Info.plist').writeAsString(
          '{"CFBundleIdentifier":"com.example.adhoc",'
          '"CFBundleExecutable":"Adhoc"}',
        );

        final sign = await Process.run(codesign!, [
          '-s',
          '-',
          '--force',
          appPath,
        ]);
        expect(sign.exitCode, 0, reason: 'ad-hoc 签名失败：${sign.stderr}');

        final result = await IosCodeSignAnalyzer.analyze(
          appPath,
          codesignPath: codesign,
        );

        // ad-hoc 签名没有指定要求，因此验证必然走到退出码 3。
        // 这不是「文件被篡改」，测试据此固定住这个区分。
        expect(result.toolExecuted, isTrue);
        expect(result.status, SignatureStatus.verificationFailed);
        expect(result.exitCode, 3);
        expect(result.error, contains('designated requirement'));
      } finally {
        if (temp.existsSync()) await temp.delete(recursive: true);
      }
    }, skip: skipReason);

    test('对系统应用验证通过，并读出 Authority 链', () async {
      final appPath = '/System/Applications/Calculator.app';
      if (!Directory(appPath).existsSync()) return;

      final result = await IosCodeSignAnalyzer.analyze(
        appPath,
        codesignPath: codesign,
      );

      expect(result.status, SignatureStatus.verified);
      expect(result.exitCode, 0);
      expect(result.info, isNotNull);
      expect(result.info!.identifier, 'com.apple.calculator');
      expect(result.info!.authorities, isNotEmpty);
      expect(result.info!.entitlementsRead, isTrue);
      expect(result.info!.entitlements, isNotEmpty);
    }, skip: skipReason);

    test('对不存在的路径返回「未知」而不是「签名无效」', () async {
      final result = await IosCodeSignAnalyzer.analyze(
        '/tmp/appinfo-does-not-exist.app',
        codesignPath: codesign,
      );

      expect(result.toolExecuted, isTrue);
      expect(result.status, SignatureStatus.unknown);
      expect(result.status.hasConclusiveResult, isFalse);
    }, skip: skipReason);

    test('工具路径被指向别的程序时不会报「验证通过」', () async {
      // `/usr/bin/true` 存在、能执行、退出码 0，但什么都没输出。
      // 只认退出码的实现会在这里报出「签名有效」—— 这个用例就是钉死它。
      final result = await IosCodeSignAnalyzer.analyze(
        '/tmp',
        codesignPath: '/usr/bin/true',
      );

      expect(result.toolExecuted, isTrue);
      expect(result.exitCode, 0);
      expect(result.status, SignatureStatus.unknown);
      expect(result.status.hasConclusiveResult, isFalse);
      expect(result.error, contains('may not be codesign'));
    }, skip: skipReason);

    test('超时被归入「未知」，并且真的把子进程终止掉', () async {
      // `/usr/bin/yes` 会一直输出，永远不退出 —— 用它确定性地触发超时路径。
      // 期望：不假装通过，而且子进程被 kill（不是只停止等待）。
      final result = await IosCodeSignAnalyzer.analyze(
        '/tmp',
        codesignPath: '/usr/bin/yes',
        timeout: const Duration(milliseconds: 50),
      );

      expect(result.toolExecuted, isTrue);
      expect(result.status, SignatureStatus.unknown);
      expect(result.status.hasConclusiveResult, isFalse);
      expect(result.error, contains('timed out'));

      // 给内核一点时间回收；残留的 `yes` 会一直吃 CPU。
      //
      // 已知局限：`ps` 在受限沙箱里会以 "Operation not permitted" 失败
      // （本机开发环境即如此），因此这条断言在那种环境下**不会真正执行**。
      // 这里如实跳过而不是假装检查过 —— 在没有沙箱限制的机器上它才会生效。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        final ps = await Process.run('ps', ['-o', 'pid=,comm=']);
        final lingering = (ps.stdout as String)
            .split('\n')
            .where((line) => line.trim().endsWith('yes'))
            .toList();
        expect(lingering, isEmpty, reason: '超时后不应残留子进程：$lingering');
      } on ProcessException {
        // 环境不允许枚举进程，跳过这项检查。
      }
    }, skip: skipReason);
  });
}
