import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/utils/diff_labels.dart';
import 'package:path/path.dart' as path;

/// 把两份包的差异渲染成一份**独立**报告。
///
/// ## 为什么是独立文档而不是「现有报告加一节」（§17.4-4 / D4）
///
/// 现有报告的输入是**一个**文件：`inputArtifact`、`reportId`、`suggestedFileName`
/// 这些字段都建立在「一个输入」之上。把差异塞进去会让它们全部语义变形
/// （`inputArtifact` 到底指哪一份？）。因此差异报告**自己一份 schema 与版本号**，
/// `AnalysisReport.reportSchemaVersion` **不动**。
///
/// ## 三端同源
///
/// UI（`diff_page.dart`）、Markdown、JSON 都调 [diffOf] 拿同一份 [PackageDiff]，
/// 再共用 [DiffLabels] 把机器 id 变成文案。三处各自实现一遍必然漂移 ——
/// 用户会看到界面说「变更」、报告说「新增」。
///
/// ## 两个必须保留的区别
///
/// 1. **「无法比较」不是「没有差异」**：任一侧「我们没读到」时，条目进
///    「无法比较」区并带状态与原因，绝不与「新增 / 删除 / 变更」混排；
/// 2. **JSON 保留机器 id**（`android.minSdkVersion` 这类），Markdown 显示
///    本地化名字 —— 与覆盖维度同一套口径。
class DiffReport {
  DiffReport._();

  /// 差异报告的 schema 版本。
  ///
  /// **与 `AnalysisReport.reportSchemaVersion` 各管各的**：两者结构不同、
  /// 消费者不同（差异报告的输入是**两个**文件）。刻意用一个不同的字段名，
  /// 这样「把差异报告喂给只认单文件报告的脚本」会直接找不到版本号而失败，
  /// 而不是拿着 v4 的假设去解析一份完全不同的结构。
  ///
  /// v1：初版。`fields[]`（id / kind / left / right）+ `sets[]`
  ///     （id / comparable / added / removed / common）+ `summary`。
  static const int schemaVersion = 1;

  /// 渲染 Markdown 报告。
  ///
  /// [generatedAt] 由调用方给出，不读系统时钟 —— 测试才能固定输出。
  static String render(
    PackageAnalysisResult left,
    PackageAnalysisResult right,
    Translations t, {
    required DateTime generatedAt,
  }) {
    final diff = diffOf(left, right);
    final sb = StringBuffer();

    _header(sb, left, right, t, generatedAt);
    _summary(sb, diff, t);

    final fieldChanges = diff.fields
        .where((f) =>
            f.kind == DiffKind.added ||
            f.kind == DiffKind.removed ||
            f.kind == DiffKind.changed)
        .toList();
    final fieldUnknown =
        diff.fields.where((f) => f.kind == DiffKind.unknown).toList();
    final setChanges =
        diff.sets.where((s) => s.comparable && !s.isSame).toList();
    final setUnknown = diff.sets.where((s) => !s.comparable).toList();

    if (fieldChanges.isNotEmpty) {
      sb
        ..writeln('## ${t.diff.section_fields}')
        ..writeln()
        ..writeln('| ${t.report.column_field} | ${t.diff.report_left} | '
            '${t.diff.report_right} | ${t.diff.column_kind} |')
        ..writeln('| --- | --- | --- | --- |');
      for (final f in fieldChanges) {
        _fieldRow(sb, f, t);
      }
      sb.writeln();
    }

    if (setChanges.isNotEmpty) {
      sb.writeln('## ${t.diff.section_sets}');
      sb.writeln();
      for (final s in setChanges) {
        _setSection(sb, s, t);
      }
    }

    if (fieldUnknown.isNotEmpty || setUnknown.isNotEmpty) {
      sb
        ..writeln('## ${t.diff.section_unknown}')
        ..writeln()
        // 先给口径再给数据：读者看到一片「无法比较」时要知道那不是「没差异」。
        ..writeln('> ${t.diff.unknown_field_hint}')
        ..writeln();
      if (fieldUnknown.isNotEmpty) {
        sb
          ..writeln('| ${t.report.column_field} | ${t.diff.report_left} | '
              '${t.diff.report_right} | ${t.diff.column_kind} |')
          ..writeln('| --- | --- | --- | --- |');
        for (final f in fieldUnknown) {
          _fieldRow(sb, f, t);
        }
        sb.writeln();
      }
      for (final s in setUnknown) {
        sb
          ..writeln('### ${_escape(DiffLabels.set(s.id, t))}')
          ..writeln()
          ..writeln(t.diff.unknown_set_hint)
          ..writeln();
      }
    }

    // 范围说明放最后：它解释的是「这份报告为什么没有发现项那一节」，
    // 读者读完全文再看到它才明白少了什么。
    sb
      ..writeln('## ${t.diff.section_scope}')
      ..writeln()
      ..writeln(t.diff.report_scope_note);

    return '${sb.toString().trimRight()}\n';
  }

  /// 渲染 JSON 报告。
  ///
  /// 结构化输出，便于自动化对照两个版本的包。字段与集合都用**机器 id**，
  /// 程序按 id 取本地化名字（与覆盖维度同一套口径）。
  static String renderJson(
    PackageAnalysisResult left,
    PackageAnalysisResult right, {
    required DateTime generatedAt,
  }) {
    final diff = diffOf(left, right);
    final map = <String, dynamic>{
      'diffReportSchemaVersion': schemaVersion,
      'reportId': _reportId(left, right, generatedAt),
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      // 两侧同平台才有意义；调用方负责拦住跨平台（`samePlatform`）。
      'platform': left.platform.name,
      'left': _side(left),
      'right': _side(right),
      'summary': {
        'hasChanges': diff.hasChanges,
        // `unknown` **不算差异**，但也不代表「没差异」—— 单独给一个计数，
        // 免得消费者只看 `hasChanges: false` 就下结论。
        'differenceCount': diff.fields
                .where((f) =>
                    f.kind != DiffKind.same && f.kind != DiffKind.unknown)
                .length +
            diff.sets.where((s) => s.comparable && !s.isSame).length,
        'unknownFieldCount': diff.unknownFieldCount,
        'notComparableSetCount': diff.sets.where((s) => !s.comparable).length,
      },
      'fields': [
        for (final f in diff.fields)
          {
            'id': f.id,
            'kind': f.kind.name,
            // 两侧的**原始**状态都带上：消费者要能分辨「左边没有」与
            // 「左边没读到」—— 只看 kind 会丢掉这个区别。
            'left': _fieldValue(f.left),
            'right': _fieldValue(f.right),
          },
      ],
      'sets': [
        for (final s in diff.sets)
          {
            'id': s.id,
            'comparable': s.comparable,
            'added': s.added,
            'removed': s.removed,
            'common': s.common,
          },
      ],
    };

    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert(map)}\n';
  }

  /// 建议的文件名。
  ///
  /// 两侧的文件名都带上：只留一侧会让「拿两份差异报告对照」时分不清方向。
  static String suggestedFileName(
    PackageAnalysisResult left,
    PackageAnalysisResult right, {
    required String extension,
    required DateTime generatedAt,
  }) {
    final stamp = generatedAt
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    return '${_stem(left)}_vs_${_stem(right)}_diff_$stamp.$extension';
  }

  // ---------------------------------------------------------------------------
  // 各段
  // ---------------------------------------------------------------------------

  static void _header(
    StringBuffer sb,
    PackageAnalysisResult left,
    PackageAnalysisResult right,
    Translations t,
    DateTime generatedAt,
  ) {
    sb
      ..writeln('# ${t.diff.report_title}')
      ..writeln()
      ..writeln('- ${t.diff.report_left}: ${_inline(left.fileName.value)}')
      ..writeln('- ${t.diff.report_right}: ${_inline(right.fileName.value)}')
      ..writeln('- ${t.report.platform}: ${_platformLabel(left)}')
      ..writeln('- ${t.report.generated_at}: '
          '${generatedAt.toUtc().toIso8601String()}')
      ..writeln();
  }

  static void _summary(
    StringBuffer sb,
    PackageDiff diff,
    Translations t,
  ) {
    final changes = diff.fields
            .where((f) =>
                f.kind == DiffKind.added ||
                f.kind == DiffKind.removed ||
                f.kind == DiffKind.changed)
            .length +
        diff.sets.where((s) => s.comparable && !s.isSame).length;
    sb
      ..writeln('## ${t.diff.section_summary}')
      ..writeln()
      ..writeln(
          '- ${diff.hasChanges ? t.diff.summary_changes(count: changes) : t.diff.summary_same}');
    if (diff.unknownFieldCount > 0) {
      sb.writeln('- ${t.diff.summary_unknown(count: diff.unknownFieldCount)}');
    }
    sb
      ..writeln()
      // 口径写在摘要下面：报告会被单独转发出去，读者未必看过界面。
      ..writeln('> ${t.diff.report_note}')
      ..writeln();
  }

  static void _fieldRow(StringBuffer sb, FieldDiff f, Translations t) {
    sb.writeln('| ${_escape(DiffLabels.field(f.id, t))} '
        '| ${_escape(_valueText(f.id, f.left, t))} '
        '| ${_escape(_valueText(f.id, f.right, t))} '
        '| ${_escape(DiffLabels.kind(f.kind, t))} |');
  }

  static void _setSection(StringBuffer sb, SetDiff s, Translations t) {
    sb
      ..writeln('### ${_escape(DiffLabels.set(s.id, t))}')
      ..writeln()
      ..writeln('| ${t.diff.column_change} | ${t.diff.column_members} |')
      ..writeln('| --- | --- |');
    if (s.added.isNotEmpty) {
      sb.writeln('| ${_escape(t.diff.added_count(count: s.added.length))} '
          '| ${_escape(_members(s.added))} |');
    }
    if (s.removed.isNotEmpty) {
      sb.writeln('| ${_escape(t.diff.removed_count(count: s.removed.length))} '
          '| ${_escape(_members(s.removed))} |');
    }
    sb.writeln();
    if (s.common.isNotEmpty) {
      // 未变的成员**只报条数不列出**：差异报告的读者关心的是变化，
      // 把上千条未变域名铺进报告会把它淹掉。
      sb
        ..writeln(t.diff.common_count(count: s.common.length))
        ..writeln();
    }
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  /// 一个字段值在报告里的文本（与界面共用 [DiffLabels.value]）。
  static String _valueText(
    String id,
    FieldValue<Object?> value,
    Translations t,
  ) =>
      DiffLabels.value(id, value, t);

  /// 集合成员单元格：Markdown 表格里不能有裸换行，用 `<br>` 分隔。
  static String _members(List<String> members) =>
      members.map((m) => '`$m`').join('<br>');

  /// 转义竖线，避免把表格结构撑破。
  static String _escape(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', ' ');

  /// 行内代码块里的值不做转义，但要防住反引号。
  static String _inline(String? value) {
    if (value == null) return '-';
    return '`${value.replaceAll('`', "'")}`';
  }

  static String _platformLabel(PackageAnalysisResult result) =>
      switch (result.platform) {
        // 「Android」是平台名，不是界面文案，因此不进 i18n（与单文件报告一致）。
        PackagePlatform.android => 'Android',
        PackagePlatform.ios => 'iOS (.ipa)',
        PackagePlatform.unknown => '-',
      };

  static String _stem(PackageAnalysisResult result) {
    final base = result.fileName.value ?? 'package';
    return path.basenameWithoutExtension(base);
  }

  static Map<String, dynamic> _side(PackageAnalysisResult result) => {
        'fileName': result.fileName.value,
        'sizeBytes': result.fileSize.value,
        'sha256': result.sha256.value,
        'packageId': result.packageId.value,
        'version': result.version.value,
        'buildNumber': result.buildNumber.value,
      };

  static Map<String, dynamic> _fieldValue(FieldValue<Object?> value) => {
        'status': value.status.name,
        'value': _jsonValue(value.value),
        'source': value.source.name,
        'diagnostic': value.diagnostic,
      };

  /// 把字段值转成 JSON 能编码的东西。
  ///
  /// 枚举直接扔给 `JsonEncoder` 会抛异常（`SignatureVerdict` 就是枚举），
  /// 因此显式降级成 `name` —— 那是稳定标识，与「JSON 保留机器 id」一致。
  static Object? _jsonValue(Object? value) {
    if (value == null) return null;
    if (value is String || value is num || value is bool) return value;
    if (value is Enum) return value.name;
    if (value is List) return [for (final e in value) _jsonValue(e)];
    return '$value';
  }

  static String _reportId(
    PackageAnalysisResult left,
    PackageAnalysisResult right,
    DateTime at,
  ) =>
      '${_sideId(left)}-${_sideId(right)}-${at.toUtc().millisecondsSinceEpoch}';

  /// 一侧的短标识：优先 SHA-256 前 8 位，**没算哈希时退回文件名**。
  ///
  /// 只取哈希会得到 `--1792152000000` 这种没法看的标识 —— 而「设置里关掉了
  /// 哈希计算」是常见情形，不是边角情况。文件名做标识弱一些（不同目录下
  /// 可以有同名文件），但**可读**，且同一份报告里两侧各一个、不会混。
  static String _sideId(PackageAnalysisResult result) {
    final sha = result.sha256.value;
    if (sha != null && sha.isNotEmpty) {
      return sha.length >= 8 ? sha.substring(0, 8) : sha;
    }
    return _stem(result);
  }
}
