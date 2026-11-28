// v10 报告契约：把界面上已有的「权限分级」与「库识别」写进导出结果。
//
// 这两块的意义不是「多两个字段」，而是让归档的报告能复现当时的结论：
// 同一个权限名在不同 Android 版本里的保护级别会变，同一份 APK 半年后
// 也未必还能重新跑到同样的规则版本。

import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/android_metadata.dart';
import 'package:apk_info_tool/utils/report_extras.dart';
import 'package:apk_parser/apk_parser.dart'
    show
        LibCheckerRule,
        LibCheckerRuleType,
        LibraryGroup,
        LibraryHit,
        LibraryHitKind,
        LibraryMatchSource,
        LibraryReport,
        NativeLibraryEntry;
import 'package:flutter_test/flutter_test.dart';

final DateTime _at = DateTime.utc(2026, 11, 28, 12, 0, 0);

const _permissions = ['android.permission.READ_SMS', 'custom.permission.THING'];

PackageAnalysisResult _result() => PackageAnalysisResult(
      platform: PackagePlatform.android,
      fileName: const FieldValue<String>.extracted(
        'example.apk',
        source: FieldSource.fileSystem,
      ),
      fileSize: const FieldValue<int>.extracted(
        2048,
        source: FieldSource.fileSystem,
      ),
      sha256: const FieldValue<String>.extracted(
        'abc123',
        source: FieldSource.fileSystem,
      ),
      appName: const FieldValue<String>.extracted(
        'Example',
        source: FieldSource.builtinParser,
      ),
      packageId: const FieldValue<String>.extracted(
        'com.example.app',
        source: FieldSource.builtinParser,
      ),
      version: const FieldValue<String>.extracted(
        '1.2.3',
        source: FieldSource.builtinParser,
      ),
      buildNumber: const FieldValue<String>.extracted(
        '4',
        source: FieldSource.builtinParser,
      ),
      signatureVerdict: PackageAnalysisResult.verdictFrom(null),
      android: const AndroidPackageInfo(
        permissions: FieldValue<List<String>>.extracted(
          _permissions,
          source: FieldSource.builtinParser,
        ),
      ),
    );

List<PermissionFact> _facts() => const [
      PermissionFact(
        name: 'android.permission.READ_SMS',
        shortName: 'READ_SMS',
        label: 'read your text messages',
        description: 'Allows the app to read SMS messages.',
        risk: AndroidPermissionRisk.high,
        base: AndroidProtectionBase.dangerous,
        raw: 1,
        flags: [],
      ),
      PermissionFact(
        name: 'custom.permission.THING',
        risk: AndroidPermissionRisk.unknown,
        flags: <String>[],
      ),
    ];

LibraryReport _libraries() {
  final group = LibraryGroup(
    label: 'Flutter',
    iconId: 'ic_lib_flutter',
    simpleColorIcon: true,
    rule: const LibCheckerRule(
      id: 1,
      name: 'libflutter.so',
      label: 'Flutter',
      type: LibCheckerRuleType.native,
      iconId: 'ic_lib_flutter',
      simpleColorIcon: true,
      isRegex: false,
      detailIndex: 0,
      priority: 1,
    ),
  )..hits.add(
      const LibraryHit(
        kind: LibraryHitKind.nativeLibrary,
        name: 'libflutter.so',
        source: LibraryMatchSource.exact,
        abis: ['arm64-v8a'],
        size: 1024,
      ),
    );
  return LibraryReport(
    dataVersion: 50,
    nativeGroups: [group],
    componentGroups: const [],
    dexGroups: const [],
    unmatchedNative: const [
      NativeLibraryEntry(
        name: 'libprivate.so',
        path: 'lib/arm64-v8a/libprivate.so',
        abi: 'arm64-v8a',
        size: 4096,
      ),
    ],
    dexPackages: const ['com.example'],
    dexClasses: 12,
    dexTruncated: false,
    kotlin: true,
    compose: false,
  );
}

Map<String, dynamic> _json(Translations t, {ReportExtras? extras}) =>
    jsonDecode(
      AnalysisReport.renderJson(
        _result(),
        generatedAt: _at,
        t: t,
        extras: extras,
      ),
    ) as Map<String, dynamic>;

void main() {
  final t = AppLocale.en.buildSync();

  test('带 extras 时 JSON 增加权限分级与库识别', () {
    final map = _json(
      t,
      extras: ReportExtras(permissions: _facts(), libraries: _libraries()),
    );

    final details = ((map['application']
            as Map<String, dynamic>)['permissionDetails'] as List)
        .cast<Map<String, dynamic>>();
    expect(details, hasLength(2));
    expect(details.first['name'], 'android.permission.READ_SMS');
    expect(details.first['risk'], 'high');
    expect(details.first['protection'], 'dangerous');
    expect(details.first['protectionLevel'], 1);
    // 非框架权限：既没有保护级别，也不猜成 normal。
    expect(details.last['risk'], 'unknown');
    expect(details.last['protection'], isNull);

    final libraries = map['libraries'] as Map<String, dynamic>;
    expect(libraries['dataVersion'], 50);
    expect(libraries['identifiedSdkCount'], 1);
    expect(libraries['kotlin'], isTrue);
    final native = (libraries['native'] as List).cast<Map<String, dynamic>>();
    expect(native.single['label'], 'Flutter');
    expect((native.single['hits'] as List).single['abis'], ['arm64-v8a']);
    expect(libraries['unmatchedNative'], hasLength(1));
  });

  test('不带 extras 时不出现这两个键（缺失 ≠ 空数组）', () {
    final map = _json(t);
    final application = map['application'] as Map<String, dynamic>;
    expect(application.containsKey('permissionDetails'), isFalse);
    expect(map.containsKey('libraries'), isFalse);
  });

  test('Markdown 渲染权限表与库识别小节', () {
    final markdown = AnalysisReport.render(
      _result(),
      t,
      generatedAt: _at,
      extras: ReportExtras(permissions: _facts(), libraries: _libraries()),
    );

    expect(markdown, contains('### Permissions (2)'));
    expect(
      markdown,
      contains('| Permission | Risk | Protection | Description |'),
    );
    expect(markdown, contains('High risk'));
    expect(markdown, contains('Dangerous · 0x1'));
    expect(markdown, contains('## Libraries'));
    expect(markdown, contains('Identified 1 SDKs'));
    expect(markdown, contains('### Native libraries'));
    expect(markdown, contains('libflutter.so (arm64-v8a, 1 KB)'));
    expect(markdown, contains('### Unidentified native libraries'));
    expect(markdown, contains('Tech markers: Kotlin'));
  });

  test('securityOnly 不输出库识别（与「仅安全」范围的承诺一致）', () {
    final json = AnalysisReport.renderJson(
      _result(),
      generatedAt: _at,
      t: t,
      securityOnly: true,
      extras: ReportExtras(permissions: _facts(), libraries: _libraries()),
    );
    expect(json, isNot(contains('"libraries"')));
  });
}
