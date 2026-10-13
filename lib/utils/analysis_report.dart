import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:path/path.dart' as path;

/// 把统一分析结果渲染成一份可读、可归档的报告。
///
/// 用 Markdown 而不是纯文本：它仍是纯文本（可以直接进邮件、工单、diff），
/// 又能在支持的地方正常显示表格。
///
/// 报告的重点**不是复述界面**，而是把界面上一闪而过、或者用户没注意到的
/// 东西固定下来：
///
/// - 每个字段都带上**状态与来源**。只列值会把「文件里没有」「我们没读出来」
///   「这个来源不报」压成同一个空白，而那正是排查时最需要区分的；
/// - 每个「没做」的检查都单独列出来。报告里出现空白时，读者必须能分辨
///   那是「查了没有」还是「根本没查」；
/// - 工具的原始输出原样附上。结论是「无法确认」时，原因只在那里。
///
/// 渲染是纯函数（[Translations] 与时间都从外面传），因此可以直接单测。
class AnalysisReport {
  AnalysisReport._();

  /// 渲染报告正文。
  ///
  /// [generatedAt] 由调用方给出，不读系统时钟 —— 测试才能固定输出。
  static String render(
    PackageAnalysisResult result,
    Translations t, {
    required DateTime generatedAt,
  }) {
    final sb = StringBuffer();

    _header(sb, result, t, generatedAt);
    _basicInfo(sb, result, t);
    _conclusion(sb, result, t);
    switch (result.platform) {
      case PackagePlatform.android:
        _androidSection(sb, result, t);
      case PackagePlatform.ios:
        _iosSection(sb, result, t);
      case PackagePlatform.unknown:
        break;
    }
    _limitations(sb, result, t);
    _diagnostics(sb, result, t);

    return '${sb.toString().trimRight()}\n';
  }

  /// 建议的文件名。
  ///
  /// 带上平台与时间戳：用户常常要为同一个包的不同版本各存一份报告，
  /// 同名文件会互相覆盖。
  static String suggestedFileName(
    PackageAnalysisResult result,
    DateTime generatedAt,
  ) {
    final base = result.fileName.value ?? 'package';
    final stem = path.basenameWithoutExtension(base);
    final stamp = generatedAt
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    return '${stem}_${result.platform.name}_$stamp.md';
  }

  // ---------------------------------------------------------------------------
  // 各段
  // ---------------------------------------------------------------------------

  static void _header(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
    DateTime generatedAt,
  ) {
    sb
      ..writeln('# ${t.report.title}')
      ..writeln()
      ..writeln('- ${t.report.file}: ${_inline(result.fileName.value)}')
      ..writeln('- ${t.report.platform}: ${_platformLabel(result, t)}')
      ..writeln('- ${t.report.size}: ${result.fileSize.value ?? '-'} '
          '${t.report.bytes}')
      ..writeln('- ${t.report.generated_at}: '
          '${generatedAt.toUtc().toIso8601String()}')
      ..writeln();
  }

  static void _basicInfo(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    sb
      ..writeln('## ${t.report.basic_info}')
      ..writeln()
      ..writeln('| ${t.report.column_field} | ${t.report.column_value} | '
          '${t.report.column_status} | ${t.report.column_source} | '
          '${t.report.column_note} |')
      ..writeln('| --- | --- | --- | --- | --- |');

    _row(sb, t.apk_info.app_name, result.appName);
    _row(sb, t.report.package_id, result.packageId);
    _row(sb, t.apk_info.version_name, result.version);
    _row(sb, t.apk_info.version_code, result.buildNumber);
    _row(sb, 'SHA-256', result.sha256);

    sb.writeln();
  }

  static void _conclusion(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    sb
      ..writeln('## ${t.report.conclusion}')
      ..writeln()
      ..writeln('- ${t.apk_info.signature_info}: '
          '${DetailRenderer.signatureVerdictLabel(result.signatureVerdict, t)}');

    final android = result.android;
    if (android != null && android.mayBeHardened) {
      sb.writeln('- ${t.apk_info.hardening_summary}:');
      for (final hint in android.hardeningHints) {
        final label = hint.confidence == HintConfidence.strong
            ? t.apk_info.confidence_strong
            : t.apk_info.confidence_weak;
        sb.writeln('  - ${hint.signal.name} [$label] ${hint.evidence}');
      }
    }

    sb.writeln();
  }

  static void _androidSection(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    final android = result.android;
    if (android == null) return;

    sb
      ..writeln('## ${t.report.android_section}')
      ..writeln()
      ..writeln('| ${t.report.column_field} | ${t.report.column_value} | '
          '${t.report.column_status} | ${t.report.column_source} | '
          '${t.report.column_note} |')
      ..writeln('| --- | --- | --- | --- | --- |');

    _row(sb, t.apk_info.min_sdk, android.minSdkVersion);
    _row(sb, t.apk_info.target_sdk, android.targetSdkVersion);
    _row(sb, t.apk_info.max_sdk, android.maxSdkVersion);
    _row(sb, t.apk_info.debuggable, android.debuggable);
    // 组件用 DetailRenderer 渲染，而不是把对象丢给 `toString()` ——
    // 报告是给人看的，`AndroidComponent{activity, name: ..., permission: null}`
    // 这种 Dart 对象转储不该出现在里面。
    _row(sb, t.apk_info.components, android.components,
        displayValue: android.components.hasValue
            ? android.components.value!
                .map((c) => DetailRenderer.componentLine(c, t))
                .join('<br>')
            : null);

    if (android.permissions.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.apk_info.permissions} '
            '(${android.permissions.length})')
        ..writeln();
      for (final permission in android.permissions) {
        sb.writeln('- $permission');
      }
    }

    final components = android.components.value;
    if (components != null && components.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.apk_info.components} (${components.length})')
        ..writeln();
      for (final component in components) {
        sb.writeln('- ${DetailRenderer.componentLine(component, t)}');
      }
    }

    final structure = DetailRenderer.structure(android.structure, t);
    if (structure.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.apk_info.structure}')
        ..writeln()
        ..writeln('```')
        ..writeln(structure)
        ..writeln('```');
    }

    final signature = DetailRenderer.signature(android.signature, t);
    if (signature.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.apk_info.signature_info}')
        ..writeln()
        ..writeln('```')
        ..writeln(signature)
        ..writeln('```');
    }

    sb.writeln();
  }

  static void _iosSection(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    final ios = result.ios;
    if (ios == null) return;

    sb
      ..writeln('## ${t.report.ios_section}')
      ..writeln()
      ..writeln('| ${t.report.column_field} | ${t.report.column_value} | '
          '${t.report.column_status} | ${t.report.column_source} | '
          '${t.report.column_note} |')
      ..writeln('| --- | --- | --- | --- | --- |');

    _row(sb, t.ios_info.bundle_id, ios.bundleIdentifier);
    _row(sb, t.ios_info.executable, ios.executableName);
    _row(sb, t.ios_info.minimum_os, ios.minimumOSVersion);
    // 设备类型走 DetailRenderer 的本地化映射，而不是把 `1`、`2` 直接印出来 ——
    // 报告是给人看的，`[1, 2]` 需要读者自己记 Apple 的枚举。
    _row(sb, t.ios_info.device_family, ios.deviceFamily,
        displayValue: ios.deviceFamily.hasValue
            ? DetailRenderer.deviceFamily(ios.deviceFamily.value, t)
            : null);
    _row(sb, t.ios_info.queries_schemes, ios.queriesSchemes);
    _row(sb, t.ios_info.required_capabilities, ios.requiredDeviceCapabilities);

    if (ios.unavailableReason != null) {
      sb
        ..writeln()
        ..writeln('> ${t.ios_info.unavailable}: ${ios.unavailableReason}');
    }

    final binary = DetailRenderer.iosExecutable(ios.executable, t);
    if (binary.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.ios_info.binary_section}')
        ..writeln()
        ..writeln('```')
        ..writeln(binary)
        ..writeln('```');
    }

    final container = DetailRenderer.iosContainer(ios.container, t);
    if (container.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.ios_info.container_section}')
        ..writeln()
        ..writeln('```')
        ..writeln(container)
        ..writeln('```');
    }

    final nested = DetailRenderer.iosNestedBinaries(ios.nestedBinaries, t);
    if (nested.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.ios_info.nested_binaries}')
        ..writeln()
        ..writeln('```')
        ..writeln(nested)
        ..writeln('```');
    }

    final signature = DetailRenderer.iosSignature(ios, t);
    if (signature.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.ios_info.signature_section}')
        ..writeln()
        ..writeln('```')
        ..writeln(signature)
        ..writeln('```');
    }

    // codesign 的结论与原始输出 —— 结论是「无法确认」时，原因只在这里。
    sb
      ..writeln()
      ..writeln('### ${t.ios_info.codesign_section}')
      ..writeln()
      ..writeln('```')
      ..writeln(DetailRenderer.iosCodeSign(ios.codeSign, t))
      ..writeln('```')
      ..writeln();
  }

  /// 明确列出**没做的检查**。
  ///
  /// 这一节存在的唯一理由：报告里出现空白时，读者必须能分辨那是「查了没有」
  /// 还是「根本没查」。规范第五、七步反复强调的正是这一点。
  static void _limitations(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    final items = <String>[];

    if (!result.sha256.hasValue) {
      items.add(t.report.limitation_hash);
    }

    if (result.platform == PackagePlatform.android &&
        result.android?.signature == null) {
      items.add(t.report.limitation_signature);
    }

    if (result.platform == PackagePlatform.ios) {
      final ios = result.ios;
      if (ios == null || ios.unavailableReason != null) {
        items.add(t.report.limitation_ios_analysis);
      } else if (ios.codeSign == null) {
        items.add(t.report.limitation_codesign);
      } else if (!ios.codeSign!.status.hasConclusiveResult) {
        items.add(t.report.limitation_codesign_inconclusive);
      }
    }

    if (items.isEmpty) return;

    sb
      ..writeln('## ${t.report.limitations}')
      ..writeln();
    for (final item in items) {
      sb.writeln('- $item');
    }
    sb.writeln();
  }

  static void _diagnostics(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    sb
      ..writeln('## ${t.apk_info.diagnostics}')
      ..writeln();

    if (result.diagnostics.isEmpty) {
      sb
        ..writeln(t.report.no_diagnostics)
        ..writeln();
      return;
    }

    sb
      ..writeln('| ${t.report.column_severity} | ${t.report.column_code} | '
          '${t.report.column_note} |')
      ..writeln('| --- | --- | --- |');
    for (final diagnostic in result.diagnostics) {
      sb.writeln('| ${diagnostic.severity.name} | ${_escape(diagnostic.code)} '
          '| ${_escape(diagnostic.message)} |');
    }
    sb.writeln();
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  /// 写一行字段。
  ///
  /// [displayValue] 用于覆盖「值」列的呈现（例如把 `UIDeviceFamily` 的
  /// 数字映射成设备名）。**状态与来源不受影响** —— 覆盖的只是可读性，
  /// 不是事实。
  static void _row(
    StringBuffer sb,
    String label,
    FieldValue<Object?> value, {
    String? displayValue,
  }) {
    final cell = displayValue ?? _valueCell(value);
    sb.writeln('| ${_escape(label)} | ${_escape(cell)} '
        '| ${value.status.name} | ${value.source.name} '
        '| ${_escape(value.diagnostic ?? '')} |');
  }

  /// 值单元格的**原始**文本（尚未转义）。
  ///
  /// 没有值时给一个破折号，**不填默认值** —— 状态列会说明为什么没有。
  ///
  /// 刻意不在这里转义：转义只在写行时做一次。两处都转会把 `A | B` 变成
  /// `A \\| B`（多出一个反斜杠），显示出来就是错的。
  static String _valueCell(FieldValue<Object?> value) {
    if (!value.hasValue) return '—';
    final raw = value.value;
    if (raw is List) {
      if (raw.isEmpty) return '—';
      // Markdown 表格里不能有裸换行，用 `<br>` 分隔。
      return raw.map((e) => '$e').join('<br>');
    }
    return '$raw';
  }

  /// 转义竖线，避免把表格结构撑破。
  static String _escape(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', ' ');

  /// 行内代码块里的值不做转义，但要防住反引号。
  static String _inline(String? value) {
    if (value == null) return '-';
    return '`${value.replaceAll('`', "'")}`';
  }

  static String _platformLabel(
    PackageAnalysisResult result,
    Translations t,
  ) =>
      switch (result.platform) {
        // 「Android」是平台名，不是界面文案，因此不进 i18n。
        PackagePlatform.android => 'Android',
        PackagePlatform.ios => t.ios_info.platform_badge,
        PackagePlatform.unknown => '-',
      };
}
