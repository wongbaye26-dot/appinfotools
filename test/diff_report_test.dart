// 差异报告（阶段 5.3）的验收测试。
//
// 验收条件（`docs/plans/V2.4.0_PROGRESS.md` §17.3）：
// - Markdown 与 JSON 都有差异章节，且**三端同源**（UI / MD / JSON 读同一份
//   `PackageDiff`）—— 这条靠「都走 `diffOf`」保证，测试拿 `diffOf` 的结果
//   去核对两份输出的条目；
// - JSON 有自己的 schema 版本号，并**不**冒充单文件报告的版本号；
// - 文案走 i18n。

import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/diff_report.dart';
import 'package:flutter_test/flutter_test.dart';

final _at = DateTime.utc(2026, 10, 16, 12, 0, 0);

PackageAnalysisResult _android({
  String fileName = 'demo-1.0.0.apk',
  int fileSize = 1024,
  int? minSdk,
  int? targetSdk,
  int? maxSdk,
  List<String> permissions = const [],
  FieldSource source = FieldSource.builtinParser,
}) =>
    AnalysisBuilder.buildAndroid(
      filePath: '/tmp/$fileName',
      fileSize: fileSize,
      manifestSource: source,
      appName: 'Demo',
      packageId: 'com.example.demo',
      version: '1.0.0',
      minSdkVersion: minSdk,
      targetSdkVersion: targetSdk,
      maxSdkVersion: maxSdk,
      permissions: permissions,
    );

void main() {
  group('差异报告 · Markdown', () {
    test('标题、两侧身份、摘要与三个区都在', () {
      final md = DiffReport.render(
        _android(targetSdk: 33, permissions: ['A', 'B']),
        _android(
            fileName: 'demo-2.0.0.apk', targetSdk: 34, permissions: ['B', 'C']),
        t,
        generatedAt: _at,
      );

      expect(md, startsWith('# ${t.diff.report_title}'));
      // 两侧的文件名都要写出来 —— 只留一侧分不清方向。
      expect(md, contains('demo-1.0.0.apk'));
      expect(md, contains('demo-2.0.0.apk'));
      expect(md, contains('## ${t.diff.section_summary}'));
      expect(md, contains('## ${t.diff.section_fields}'));
      expect(md, contains('## ${t.diff.section_sets}'));
      // 范围说明必须写出来：报告会被单独转发，读者要知道它不覆盖发现项。
      expect(md, contains('## ${t.diff.section_scope}'));
      expect(md, contains(t.diff.report_scope_note));
      // 口径写在摘要下面。
      expect(md, contains(t.diff.report_note));
    });

    test('字段差异用本地化名字，不用机器 id', () {
      final md = DiffReport.render(
        _android(targetSdk: 33),
        _android(targetSdk: 34),
        t,
        generatedAt: _at,
      );
      expect(md, contains(t.diff.fields.android_targetSdkVersion));
      expect(md, isNot(contains('android.targetSdkVersion')));
      expect(md, contains(t.diff.kind_changed));
      expect(md, contains('33'));
      expect(md, contains('34'));
    });

    test('集合差异按「变化 / 成员」成表，未变的只报条数', () {
      final md = DiffReport.render(
        _android(permissions: ['A', 'B']),
        _android(fileName: 'demo-2.0.0.apk', permissions: ['B', 'C']),
        t,
        generatedAt: _at,
      );
      expect(md, contains('### ${t.diff.sets.android_permissions}'));
      expect(md, contains(t.diff.added_count(count: 1)));
      expect(md, contains(t.diff.removed_count(count: 1)));
      expect(md, contains('`C`'));
      expect(md, contains('`A`'));
      // 未变的成员不列出来（差异报告关心的是变化）。
      expect(md, contains(t.diff.common_count(count: 1)));
      expect(md, isNot(contains('`B`')));
    });

    test('「我们没读到」进「无法比较」区，而不是被算成新增', () {
      // 左侧走 aapt2（不报 maxSdkVersion）、右侧走内置解析器。
      // 两侧**同名同大小**，把「文件名 / 大小」这类噪音排除掉，
      // 好让这条测试只盯着「没读到」那一条。
      final md = DiffReport.render(
        _android(source: FieldSource.aapt2, permissions: ['A']),
        _android(permissions: ['A'], maxSdk: 35),
        t,
        generatedAt: _at,
      );

      expect(md, contains('## ${t.diff.section_unknown}'));
      expect(md, contains(t.diff.unknown_field_hint));
      expect(md, contains(t.diff.kind_unknown));
      expect(md, contains('[unsupported]'));
      // 关键：不能出现「新增」这个结论。
      expect(
        md.contains(t.diff.kind_added),
        isFalse,
        reason: '左侧「没读到」被写成了「新增」',
      );
      // 既然没有实质差异，字段差异那一节不该出现。
      expect(md, isNot(contains('## ${t.diff.section_fields}')));
    });

    test('文件名不同就是一条变更（这是事实，不是噪音）', () {
      // 用户下载两个版本时文件名几乎总是不同，因此这一条**必然**出现。
      // 把它钉住是为了说明「差异报告第一行就是文件名」是预期行为，
      // 而不是某次改动引入的意外。
      final md = DiffReport.render(
        _android(),
        _android(fileName: 'demo-2.0.0.apk'),
        t,
        generatedAt: _at,
      );
      expect(md, contains('## ${t.diff.section_fields}'));
      expect(md, contains(t.diff.fields.file_fileName));
      expect(md, contains(t.diff.kind_changed));
    });

    test('值里的竖线不会撑破表格', () {
      final md = DiffReport.render(
        _android(permissions: ['A|B']),
        _android(fileName: 'demo-2.0.0.apk', permissions: ['A|B', 'C']),
        t,
        generatedAt: _at,
      );
      // 转义后的竖线：表格列数不变（每行 3 个未转义的 `|` 分隔符）。
      for (final line in md.split('\n')) {
        if (!line.startsWith('|')) continue;
        final cells = RegExp(r'(?<!\\)\|').allMatches(line).length;
        expect(cells, anyOf(3, 5), reason: '表格行列数被撑破了: $line');
      }
    });
  });

  group('差异报告 · JSON', () {
    test('是合法 JSON，且用自己的 schema 版本号', () {
      final json = DiffReport.renderJson(
        _android(targetSdk: 33),
        _android(fileName: 'demo-2.0.0.apk', targetSdk: 34),
        generatedAt: _at,
      );
      final map = jsonDecode(json) as Map<String, dynamic>;

      expect(map['diffReportSchemaVersion'], DiffReport.schemaVersion);
      expect(map['diffReportSchemaVersion'], 1);
      // 刻意**不**冒充单文件报告的版本号：拿差异报告去喂只认
      // `reportSchemaVersion` 的脚本应该直接找不到版本号而失败，
      // 而不是拿着 v4 的假设去解析一份完全不同的结构。
      expect(map.containsKey('reportSchemaVersion'), isFalse);
      expect(map['platform'], 'android');
      expect(map['generatedAt'], '2026-10-16T12:00:00.000Z');
    });

    test('字段与集合用机器 id，并带上两侧的原始状态', () {
      final json = DiffReport.renderJson(
        _android(source: FieldSource.aapt2, permissions: ['A']),
        _android(fileName: 'demo-2.0.0.apk', permissions: ['A'], maxSdk: 35),
        generatedAt: _at,
      );
      final map = jsonDecode(json) as Map<String, dynamic>;
      final fields = (map['fields'] as List).cast<Map<String, dynamic>>();
      final maxSdk =
          fields.firstWhere((f) => f['id'] == 'android.maxSdkVersion');

      expect(maxSdk['kind'], 'unknown');
      // 两侧的**原始**状态都要在：只看 kind 会丢掉「左边为什么没结论」。
      expect((maxSdk['left'] as Map)['status'], 'unsupported');
      expect((maxSdk['left'] as Map)['diagnostic'], isNotNull);
      expect((maxSdk['right'] as Map)['status'], 'extracted');
      expect((maxSdk['right'] as Map)['value'], 35);

      // 集合的 `comparable` 是判断「这次说不说得清」的唯一依据。
      final sets = (map['sets'] as List).cast<Map<String, dynamic>>();
      expect(sets.every((s) => s.containsKey('comparable')), isTrue);
    });

    test('摘要把「无法比较」单独计数，不并进「没有差异」', () {
      // 两侧同名同大小 → 没有任何实质差异，只剩「说不清」的那些。
      final json = DiffReport.renderJson(
        _android(source: FieldSource.aapt2, permissions: ['A']),
        _android(permissions: ['A'], maxSdk: 35),
        generatedAt: _at,
      );
      final summary =
          (jsonDecode(json) as Map<String, dynamic>)['summary'] as Map;
      expect(summary['hasChanges'], isFalse);
      expect(summary['unknownFieldCount'], greaterThan(0));
      expect(summary['differenceCount'], 0);
    });

    test('枚举值能被编码：签名结论降级成稳定 name', () {
      // `SignatureVerdict` 是枚举，直接交给 `JsonEncoder` 会抛异常。
      final json = DiffReport.renderJson(
        _android(),
        _android(fileName: 'demo-2.0.0.apk'),
        generatedAt: _at,
      );
      final fields =
          ((jsonDecode(json) as Map<String, dynamic>)['fields'] as List)
              .cast<Map<String, dynamic>>();
      final verdict = fields.firstWhere((f) => f['id'] == 'signature.verdict');
      expect((verdict['left'] as Map)['status'], 'notRequested');
      expect((verdict['left'] as Map)['value'], isNull);
    });

    test('三端同源：报告的条目与 diffOf 完全一致', () {
      final left = _android(targetSdk: 33, permissions: ['A', 'B']);
      final right = _android(
        fileName: 'demo-2.0.0.apk',
        targetSdk: 34,
        permissions: ['B', 'C'],
      );
      // 界面用的是同一个函数（`diff_page.dart`）。
      final diff = diffOf(left, right);

      final map = jsonDecode(
        DiffReport.renderJson(left, right, generatedAt: _at),
      ) as Map<String, dynamic>;
      final fields = (map['fields'] as List).cast<Map<String, dynamic>>();
      final sets = (map['sets'] as List).cast<Map<String, dynamic>>();

      expect(
        fields.map((f) => f['id']).toList(),
        diff.fields.map((f) => f.id).toList(),
        reason: 'JSON 的字段顺序与模型必须一致',
      );
      expect(
        fields.map((f) => f['kind']).toList(),
        diff.fields.map((f) => f.kind.name).toList(),
      );
      expect(
        sets.map((s) => s['id']).toList(),
        diff.sets.map((s) => s.id).toList(),
      );
      for (final s in diff.sets) {
        final jsonSet = sets.firstWhere((x) => x['id'] == s.id);
        expect(jsonSet['added'], s.added);
        expect(jsonSet['removed'], s.removed);
        expect(jsonSet['common'], s.common);
      }
    });
  });

  group('差异报告 · 文件名与版本号', () {
    test('建议文件名带上两侧的文件名，免得两份报告分不清方向', () {
      final name = DiffReport.suggestedFileName(
        _android(),
        _android(fileName: 'demo-2.0.0.apk'),
        extension: 'md',
        generatedAt: _at,
      );
      expect(name, startsWith('demo-1.0.0_vs_demo-2.0.0_diff_'));
      expect(name, endsWith('.md'));
      expect(name, isNot(contains(':')));

      expect(
        DiffReport.suggestedFileName(
          _android(),
          _android(fileName: 'demo-2.0.0.apk'),
          extension: 'json',
          generatedAt: _at,
        ),
        endsWith('.json'),
      );
    });

    test('reportId 在没算哈希时退回文件名，不留 `--` 这种没法看的标识', () {
      // 「设置里关掉了哈希计算」是常见情形，不是边角情况。
      final noHash = jsonDecode(
        DiffReport.renderJson(
          _android(),
          _android(fileName: 'demo-2.0.0.apk'),
          generatedAt: _at,
        ),
      ) as Map<String, dynamic>;
      final leftSide = noHash['left'] as Map<String, dynamic>;
      expect(leftSide['sha256'], isNull);
      expect(noHash['reportId'], startsWith('demo-1.0.0-demo-2.0.0-'));
      expect(noHash['reportId'], isNot(contains('--')));
    });

    test('差异报告不碰单文件报告的 schema 版本号', () {
      // §17.4-4 定的是**独立文档**：两份报告各有各的版本号，改一份不动另一份。
      //
      // 单文件报告本轮从 4 升到 5（JSON 新增 `fieldStatus`，见
      // `report_format_consistency_test.dart`）；`DiffReport.schemaVersion`
      // 仍是 1 —— 这条测试要守的正是「升了一个不会连带另一个」。
      expect(AnalysisReport.reportSchemaVersion, 7);
      expect(DiffReport.schemaVersion, 1);
    });
  });
}
