// 第五阶段核验：用**真实 APK** 走一遍「解析 → 分析模型 → 报告导出」，
// 逐项确认 Evidence / Finding / Coverage / Artifact / Load Graph / Network
// Clues 都真的出现在导出的 JSON 与 Markdown 里，而不是只在 UI 里拼出来的。
//
// 为什么单独放 tool/verify：这是「取证式核验」，需要真实样本，不能进 CI
// 的常规测试集（CI 上没有 ~/Downloads 里的包）。运行方式：
//
//   VERIFY_APK=~/Downloads/xxx.apk flutter test tool/verify/verify_core_capabilities_test.dart
//
// 断言只针对「有/没有」与「key 是否存在」，不钉具体数字 —— 数字随样本变化。

import 'dart:convert';
import 'dart:io';

import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/report_extras.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // LibChecker 规则包走 rootBundle，没有绑定会直接抛。
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['VERIFY_APK'];
  test('真实 APK 的核心分析能力与报告导出', () async {
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      markTestSkipped('未提供 VERIFY_APK；跳过真实样本核验');
      return;
    }

    final info = await getApkInfo(path);
    expect(info, isNotNull);

    final result = AnalysisBuilder.buildAndroid(
      filePath: path,
      fileSize: File(path).lengthSync(),
      manifestSource: info!.manifestSource,
      appName: info.label,
      packageId: info.packageName,
      version: info.versionName,
      buildNumber: info.versionCode?.toString(),
      minSdkVersion: info.sdkVersion,
      targetSdkVersion: info.targetSdkVersion,
      permissions: info.usesPermissions,
      components: info.components,
      structure: info.structure.fileEntryCount == 0 ? null : info.structure,
      security: info.securityResult,
      diagnostics: info.diagnostics,
    );

    final security = result.security;
    final t = AppLocale.en.buildSync();
    final extras =
        await ReportExtras.collect(result: result, archivePath: path);
    final json = jsonDecode(AnalysisReport.renderJson(
      result,
      generatedAt: DateTime.utc(2026, 11, 28),
      t: t,
      extras: extras,
    )) as Map<String, dynamic>;
    final markdown = AnalysisReport.render(
      result,
      t,
      generatedAt: DateTime.utc(2026, 11, 28),
      extras: extras,
    );

    final counts = <String, Object>{
      'findings': security?.findings.length ?? 0,
      'evidence': security?.findings.expand((f) => f.evidence).length ?? 0,
      'artifacts': security?.artifacts?.entries.length ?? 0,
      'loadEdges': security?.loadGraph?.edges.length ?? 0,
      'networkDomains': security?.network.domains.length ?? 0,
      'networkClues': security?.network.clues.length ?? 0,
      'coverageEntries': result.security?.coverage.entries.length ?? 0,
      'coverageGaps': result.security?.coverage.gaps.length ?? 0,
      'permissions': extras.permissions?.length ?? 0,
      'libraries': extras.libraries?.sdkCount ?? 0,
      'dexPackages': extras.libraries?.dexPackages.length ?? 0,
      'dexClasses': extras.libraries?.dexClasses ?? 0,
      'nativeGroups': extras.libraries?.nativeGroups.length ?? 0,
      'componentGroups': extras.libraries?.componentGroups.length ?? 0,
    };
    // ignore: avoid_print
    print('COUNTS ${jsonEncode(counts)}');

    // 1) Finding 与 Evidence：真实包里必须有结论，且每条结论带证据。
    expect(security, isNotNull);
    expect(security!.findings, isNotEmpty);
    expect(security.findings.expand((f) => f.evidence), isNotEmpty);

    // 2) Coverage：维度齐全，且每个维度都有状态（不是空壳）。
    expect(security.coverage.entries, isNotEmpty);
    expect(
      security.coverage.entries.every((e) => e.status.name.isNotEmpty),
      isTrue,
    );

    // 3) JSON 报告：六类结论都要落盘，键名即契约。
    // ignore: avoid_print
    print('TOPKEYS ${json.keys.join(",")} network=${json['network']}');
    final securityJson = json['security'] as Map<String, dynamic>;
    expect(securityJson['evidence'], isA<List<dynamic>>());
    expect(securityJson['artifacts'], isA<Map<String, dynamic>>(),
        reason: 'artifacts 是清单对象（entries/完整性/截断原因），不是裸数组');
    expect((securityJson['artifacts'] as Map<String, dynamic>)['entries'],
        isA<List<dynamic>>());
    expect(securityJson['loadGraph'], isA<Map<String, dynamic>>());
    expect(json['coverage'], isA<Map<String, dynamic>>());
    expect(json['network'], isA<Map<String, dynamic>>());
    expect(json['application'], isA<Map<String, dynamic>>());
    expect(
      (json['application'] as Map<String, dynamic>)['permissionDetails'],
      isA<List<dynamic>>(),
      reason: 'schema v10 起权限分级要进报告',
    );
    if (extras.libraries != null) {
      expect(json['libraries'], isA<Map<String, dynamic>>());
      expect((json['libraries'] as Map<String, dynamic>)['dataVersion'],
          isNotNull);
    } else {
      // 没识别到 SDK 时整块不出现在报告里（不是伪造一个空对象）。
      expect(json.containsKey('libraries'), isFalse);
    }
    expect(json['signatureSummary'], isA<Map<String, dynamic>>());

    // 4) Markdown 报告：权限分级表与库识别小节都要在。
    expect(markdown, contains('## Permissions'));
    if (extras.libraries != null) {
      expect(markdown, contains('## Libraries'));
    }

    final target = Platform.environment['VERIFY_OUT'];
    if (target != null && target.isNotEmpty) {
      File(target)
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
