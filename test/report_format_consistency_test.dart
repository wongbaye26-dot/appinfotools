// B-3：同一份数据、两种导出格式（Markdown / JSON），**三态必须都还在**。
//
// ## 为什么单独一个文件
//
// `analysis_report_test.dart` 已经逐段覆盖了 Markdown 的渲染（`absent` → `—`、
// 状态列、`wrongType` 出现在报告里）。本文件只问一个横切问题：
//
// > 把同一份 `PackageAnalysisResult` 分别渲染成 Markdown 与 JSON，
// > 「这个字段是**没有**（absent）」「**读失败**（failed / wrongType）」
// > 「**有值**（extracted）」这三种状态，两种格式里都还分得出来吗？
//
// 这条不是吹毛求疵：JSON 是给机器读的。如果 `absent` 与 `failed` 在 JSON 里
// 都只是一个 `null`，下游就无法区分「这个应用确实没声明」与「我们没读到」——
// 而那正是本项目反复强调、并且在界面上已经分开的两件事。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ContainerStructure;
import 'package:flutter_test/flutter_test.dart';

final DateTime _at = DateTime.utc(2026, 10, 18, 12, 0, 0);

/// 三个字段正好覆盖三种状态：有值 / 没有 / 读失败（类型不对）。
PackageAnalysisResult _result() => PackageAnalysisResult(
      platform: PackagePlatform.android,
      fileName: const FieldValue<String>.extracted(
        'example.apk',
        source: FieldSource.fileSystem,
      ),
      fileSize: const FieldValue<int>.extracted(
        123456,
        source: FieldSource.fileSystem,
      ),
      sha256: const FieldValue<String>.extracted(
        'abc123',
        source: FieldSource.fileSystem,
      ),
      appName: const FieldValue<String>.extracted(
        '示例应用',
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
      // absent：应用真的没声明构建号（不是我们没读到）。
      buildNumber: const FieldValue<String>.absent(
        source: FieldSource.builtinParser,
      ),
      signatureVerdict: PackageAnalysisResult.verdictFrom(null),
      diagnostics: const [],
      android: const AndroidPackageInfo(
        minSdkVersion: FieldValue<int>.extracted(
          21,
          source: FieldSource.builtinParser,
        ),
        // wrongType：清单里写了，但类型不对 —— 与 absent 含义完全不同。
        maxSdkVersion: FieldValue<int>.wrongType(
          diagnostic: 'android:maxSdkVersion is a string, expected an int',
          source: FieldSource.builtinParser,
        ),
        debuggable: FieldValue<bool>.absent(source: FieldSource.builtinParser),
        // wrongType：清单里写了权限，但结构不对 —— 与 absent 含义完全不同。
        permissions: FieldValue<List<String>>.wrongType(
          diagnostic: 'uses-permission is malformed',
          source: FieldSource.builtinParser,
        ),
        components: FieldValue<List<AndroidComponent>>.extracted(
          [],
          source: FieldSource.builtinParser,
        ),
        hardeningHints: [],
        structure: ContainerStructure(fileEntryCount: 12),
      ),
    );

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  late String markdown;
  late String json;

  setUp(() {
    final result = _result();
    markdown = AnalysisReport.render(result, t, generatedAt: _at);
    json = AnalysisReport.renderJson(result, generatedAt: _at, t: t);
  });

  group('三种状态在两种格式里都分得开', () {
    test('Markdown：absent 的值是破折号，wrongType 带状态名与原因', () {
      // 构建号那一行：值列是破折号，状态列是 absent。
      final absentRow = markdown
          .split('\n')
          .firstWhere((line) => line.contains('| absent |'), orElse: () => '');
      expect(absentRow, isNotEmpty, reason: '报告里应有 status=absent 的行');
      expect(absentRow, contains('—'), reason: '没有值时值列必须是破折号，不能留空');

      // 权限：wrongType + 原因。
      expect(markdown, contains('wrongType'));
      expect(
        markdown,
        contains('uses-permission is malformed'),
        reason: '读失败必须带上原因，否则读者不知道该怎么修',
      );
    });

    test('JSON：每个字段都带 status，absent 与 wrongType 不撞成同一个 null', () {
      // 期望 JSON 里有一份逐字段的状态表。
      expect(json, contains('"fieldStatus"'),
          reason: 'JSON 只有 null 的话，下游分不清「没有」和「没读到」');
      expect(json, contains('"status": "absent"'));
      expect(json, contains('"status": "wrongType"'));
      expect(json, contains('"status": "extracted"'));
      expect(
        json,
        contains('uses-permission is malformed'),
        reason: 'JSON 里也要能拿到读失败的原因',
      );
    });

    test('JSON 的 status 取值集合与 Markdown 出现过的状态名一致', () {
      for (final status in ['absent', 'wrongType', 'extracted']) {
        expect(markdown, contains(status), reason: 'Markdown 少了 $status');
        expect(json, contains('"status": "$status"'),
            reason: 'JSON 少了 $status');
      }
    });

    test('值本身仍然原样：中文不会被转义、null 不会变成空串', () {
      expect(markdown, contains('示例应用'));
      expect(json, contains('示例应用'), reason: 'JSON 用 UTF-8 原文，不转成 \\uXXXX');
      expect(json, contains('"buildNumber": null'),
          reason: '没有就是 null，不能是空串（空串会被读成「值就是空的」）');
      expect(json, isNot(contains('"buildNumber": ""')));
    });
  });
}
