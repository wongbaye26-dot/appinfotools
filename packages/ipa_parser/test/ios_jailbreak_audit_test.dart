// 越狱 / 内核漏洞利用组件识别。
//
// 判据只有一条：**组件名**。这条路误报率极低（`multicast_bytecopy`、
// `badRecovery` 这种词不会自然出现），代价是改名的私有分支看不到 —— 所以
// 边界要钉住：像的不能漏，不像的不能中。

import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<String> strings) {
  final out = <int>[];
  for (final s in strings) {
    out.addAll(const Utf8Encoder().convert(s));
    out.add(0);
  }
  return Uint8List.fromList(out);
}

SecurityFinding? _finding({
  List<String> paths = const [],
  List<String> strings = const [],
}) {
  final findings = IosJailbreakAudit.audit(
    executablePaths: paths,
    executableBytes: strings.isEmpty ? null : _bytes(strings),
  );
  return findings.isEmpty ? null : findings.single;
}

void main() {
  test('内核漏洞框架 → P1，组件名进正文', () {
    final finding = _finding(paths: [
      'Payload/OPEN.app/OPEN',
      'Payload/OPEN.app/Frameworks/kfd.framework/kfd',
      'Payload/OPEN.app/Frameworks/multicast_bytecopy.framework/multicast_bytecopy',
    ]);
    expect(finding, isNotNull);
    expect(finding!.ruleId, 'IOS-JAILBREAK-TOOLKIT');
    expect(finding.severity, SecuritySeverity.p1);
    expect(finding.messageArgs['kernelExploit'], isTrue);
    expect(
      finding.messageArgs['components'],
      containsAll(<String>['kfd', 'multicast_bytecopy']),
    );
    // 证据要指到具体路径。
    expect(
      finding.evidence.any((e) => e.location.contains('kfd.framework')),
      isTrue,
    );
  });

  test('只有越狱基础设施 → P2', () {
    final finding = _finding(paths: [
      'Payload/App.app/App',
      'Payload/App.app/Frameworks/libjailbreak.dylib',
    ]);
    expect(finding, isNotNull);
    expect(finding!.severity, SecuritySeverity.p2);
    expect(finding.messageArgs['kernelExploit'], isNull);
  });

  test('主二进制里引用的注入 dylib 也算（不在包里的情况）', () {
    final finding = _finding(
      paths: ['Payload/App.app/App'],
      strings: ['@rpath/libchoma.dylib'],
    );
    expect(finding, isNotNull);
    expect(finding!.severity, SecuritySeverity.p1);
    expect(finding.messageArgs['components'], contains('libchoma'));
  });

  test('普通应用不命中', () {
    expect(
      _finding(paths: [
        'Payload/App.app/App',
        'Payload/App.app/Frameworks/Flutter.framework/Flutter',
        'Payload/App.app/Frameworks/Runner.appex/Runner',
      ]),
      isNull,
    );
  });

  test('名字只是「像」的不命中（段级比较，不做子串）', () {
    // `kfd` 是段级比较：`kfdhelper` 这种更长的名字不该命中。
    expect(
      _finding(
          paths: ['Payload/App.app/Frameworks/kfdhelper.framework/kfdhelper']),
      isNull,
    );
  });

  test('没有任何可执行文件时不报', () {
    expect(_finding(), isNull);
  });
}
