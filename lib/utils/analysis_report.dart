import 'dart:convert';

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
  ///
  /// [securityOnly] 为 `true` 时只输出安全章节（供导出对话框的
  /// 「仅安全检测」范围使用）。文件与平台信息仍会保留 —— 没有它们，
  /// 这份安全报告对不上是哪份文件。
  static String render(
    PackageAnalysisResult result,
    Translations t, {
    required DateTime generatedAt,
    bool securityOnly = false,
  }) {
    final sb = StringBuffer();

    _header(sb, result, t, generatedAt);
    if (!securityOnly) {
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
    }
    _securitySection(sb, result, t);
    // 「网络」是报告八部分里独立的一部分：从发现项的证据里也能看到域名，
    // 但那是「顺带看到」，不是「有一节专门回答包里写了哪些域名」。
    _networkSection(sb, result, t);
    // 覆盖放在「未覆盖范围」之前：先逐维度说清覆盖到哪，再说报告级的未执行项。
    _coverage(sb, result, t);
    _limitations(sb, result, t);
    if (!securityOnly) _diagnostics(sb, result, t);

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

  /// 安全检测章节。
  static void _securitySection(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    final security = result.security;
    if (security == null) return;

    sb
      ..writeln('## ${t.security.title}')
      ..writeln();

    if (security.findings.isEmpty) {
      sb.writeln(t.security.no_findings);
      sb.writeln();
    }

    for (final finding in security.findings) {
      sb.writeln('### ${finding.ruleId} [${finding.severity.name}]');
      sb.writeln();
      sb.writeln('- **${t.security.findings}:** ${finding.finding}');
      sb.writeln('- **Confidence:** ${finding.confidence.name}');
      if (finding.evidence.isNotEmpty) {
        sb.writeln('- **Evidence:**');
        for (final ev in finding.evidence) {
          sb.writeln('  - ${ev.source.name} (${ev.location}): ${ev.detail}');
        }
      }
      if (finding.recommendation.isNotEmpty) {
        sb.writeln('- **Recommendation:** ${finding.recommendation}');
      }
      if (finding.limitation != null && finding.limitation!.isNotEmpty) {
        sb.writeln('- **Limitation:** ${finding.limitation}');
      }
      sb.writeln();
    }

    if (security.hasCoverageGaps) {
      sb.writeln('### ${t.security.limitations}');
      sb.writeln();
      for (final limit in security.limitations) {
        sb.writeln('- $limit');
      }
      sb.writeln();
    }
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
    final items = reportLimitations(result, t);
    if (items.isEmpty) return;

    sb
      ..writeln('## ${t.report.limitations}')
      ..writeln();
    for (final item in items) {
      sb.writeln('- $item');
    }
    sb.writeln();
  }

  /// 报告级的「未执行 / 无法确认」清单。
  ///
  /// 从 Markdown 章节里抽出来，供 Markdown 与 JSON **共用** —— 两边各写
  /// 一套判定迟早会漂移成两种说法，而这一节的价值恰恰是「同一份分析结果
  /// 在哪儿看都一样」。
  ///
  /// 注意它与 `SecurityAnalysisResult.limitations` 不是一回事：
  /// 这里说的是「哈希没算」「签名没验」「iOS 分析没跑」这类**整块缺失**，
  /// 安全引擎的 limitations 说的是引擎内部的覆盖不足。
  static List<String> reportLimitations(
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

    if (result.security == null) {
      items.add(t.report.limitation_security);
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

    return items;
  }

  /// 静态提取到的网络端点。
  ///
  /// 没有端点时**整节不出现**（而不是留一节空白）：空一节会被读成
  /// 「这一节没内容」，而真实含义是「本次没有提取到」—— 后者由覆盖一节
  /// 与未覆盖范围说明负责。
  static void _networkSection(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    final network = result.security?.network;
    if (network == null || network.isEmpty) return;

    sb
      ..writeln('## ${t.report.network_section}')
      ..writeln();
    if (network.domains.isNotEmpty) {
      sb
        ..writeln('### ${t.report.network_domains} '
            '(${network.domains.length})')
        ..writeln();
      for (final domain in network.domains) {
        sb.writeln('- ${_escape(domain)}');
      }
      sb.writeln();
    }
    if (network.ips.isNotEmpty) {
      sb
        ..writeln('### ${t.report.network_ips} (${network.ips.length})')
        ..writeln();
      for (final ip in network.ips) {
        sb.writeln('- ${_escape(ip)}');
      }
      sb.writeln();
    }
    sb
      ..writeln(t.report.network_hint)
      ..writeln();
  }

  /// **逐维度**的分析覆盖。
  ///
  /// 与 [_limitations] 分开：那是「报告级的未执行说明」（一句一句的话），
  /// 这里是结构化数据。两者一起看才知道「哪个维度没覆盖」以及「为什么」。
  static void _coverage(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    final coverage = result.security?.coverage;
    if (coverage == null || coverage.isEmpty) return;

    sb
      ..writeln('## ${t.coverage.title}')
      ..writeln()
      ..writeln(coverageSummary(coverage, t))
      ..writeln();

    sb
      ..writeln(
          '| ${t.coverage.column_dimension} | ${t.coverage.column_status} '
          '| ${t.coverage.column_amount} | ${t.coverage.column_note} |')
      ..writeln('| --- | --- | --- | --- |');
    for (final entry in coverage.entries) {
      sb.writeln('| ${_escape(entry.id)} '
          '| ${coverageStatusText(entry.status, t)} '
          '| ${entry.ratioText ?? '—'} '
          '| ${_escape(entry.note ?? '')} |');
    }
    sb
      ..writeln()
      ..writeln(t.coverage.hint)
      ..writeln();
  }

  /// 覆盖情况的汇总句。UI 与 Markdown 共用 —— 两处各写一遍必然漂移。
  static String coverageSummary(AnalysisCoverage coverage, Translations t) {
    final applicable = coverage.applicable;
    final covered = [
      for (final e in applicable)
        if (e.status == CoverageStatus.covered) e,
    ].length;
    if (applicable.isEmpty) return t.coverage.no_gaps;
    if (covered == applicable.length) {
      return '${t.coverage.summary(covered: covered, applicable: applicable.length)}'
          '（${t.coverage.all_covered}）';
    }
    return '${t.coverage.summary(covered: covered, applicable: applicable.length)}；'
        '${t.coverage.gap_count(count: coverage.gaps.length)}';
  }

  /// 覆盖状态的本地化文本。UI 与 Markdown 共用。
  static String coverageStatusText(CoverageStatus status, Translations t) =>
      switch (status) {
        CoverageStatus.covered => t.coverage.covered,
        CoverageStatus.partial => t.coverage.partial,
        CoverageStatus.notCovered => t.coverage.not_covered,
        CoverageStatus.notApplicable => t.coverage.not_applicable,
      };

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

  /// 渲染 JSON 格式的安全报告。
  ///
  /// 结构化输出，便于后续自动化处理或归档。
  /// 报告 schema 版本。
  ///
  /// 只要**字段结构**有增删改就 +1 —— 脚本靠它判断能否解析这份报告。
  /// 与 `engineVersion` / `rulesVersion` 是三件不同的事：
  /// - 本字段变 → 报告结构变了，解析脚本要跟着改；
  /// - 引擎 / 规则版本变 → 结论可能变，但结构没变。
  /// 报告 schema 版本。
  ///
  /// **只在结构变化时递增**，与 `engineVersion` / `rulesVersion` 是三件事：
  /// 引擎换了但结构没变，消费者不需要改代码。
  ///
  /// v2：`coverage` 从「只有 hasGaps + limitations」扩成含结构化 `entries`。
  /// v3：补 `application.permissions`、`signatureSummary` 的平台详情、
  ///     以及一级字段 `network`。
  static const int reportSchemaVersion = 3;

  static String renderJson(
    PackageAnalysisResult result, {
    required DateTime generatedAt,
    required Translations t,
    bool securityOnly = false,
  }) {
    final security = result.security;
    final findings = <Map<String, dynamic>>[
      if (security != null)
        for (final f in security.findings)
          {
            'ruleId': f.ruleId,
            'platform': f.platform.name,
            'category': f.category.name,
            'severity': f.severity.name,
            'confidence': f.confidence.name,
            'finding': f.finding,
            'evidence': [
              for (final e in f.evidence)
                {
                  'source': e.source.name,
                  'location': e.location,
                  'detail': e.detail
                },
            ],
            'dataSource': f.dataSource,
            'dataSink': f.dataSink,
            'relationship': f.relationship,
            'limitation': f.limitation,
            'recommendation': f.recommendation,
          },
    ];

    final counts = <String, int>{};
    if (security != null) {
      for (final entry in security.countBySeverity().entries) {
        counts[entry.key.name] = entry.value;
      }
    }
    final worst = security?.highestRiskFinding;

    final map = <String, dynamic>{
      'reportSchemaVersion': reportSchemaVersion,
      // 报告标识：便于跨版本比对时把「同一份文件、同一次分析」的两份报告
      // 对齐。用文件 SHA-256 前 16 位 + 生成时间戳。
      'reportId': _reportId(result, generatedAt),
      'generatedAt': generatedAt.toUtc().toIso8601String(),

      // 输入文件身份。SHA-256 缺失时是 null 而不是空串 —— 空串会被读成
      // 「哈希就是空的」。
      'inputArtifact': {
        'fileName': result.fileName.value,
        'sizeBytes': result.fileSize.value,
        'sha256': result.sha256.value,
      },

      // 「仅安全检测」范围下，这些与安全无关的块整体不输出 ——
      // 保留了就不是「仅安全」了。
      if (!securityOnly) ...{
        'application': {
          'platform': result.platform.name,
          'appName': result.appName.value,
          'packageId': result.packageId.value,
          'version': result.version.value,
          'buildNumber': result.buildNumber.value,
          // 权限是「应用声明了什么能力」的一等事实，单列成数组。
          // 此前它只散落在逐权限的发现项里，消费者要拿这份清单
          // 得先解析 findings —— 那是把结构化数据当文本用。
          'permissions': result.android?.permissions ?? const <String>[],
        },

        // 签名只给**结论**：平台特有的细节（方案、指纹、退出码）留在各自的
        // 平台信息里。`conclusive` 单列，免得消费者把 inconclusive 读成通过。
        'signatureSummary': {
          'verdict': result.signatureVerdict.name,
          'conclusive': result.signatureVerdict.isConclusive,
          // 平台特有的**详情**（方案、签名者、工具结论）此前只在 Markdown 的
          // 平台小节里，JSON 消费者看不到。这里补上，但**不**放指纹之外的
          // 原始输出 —— 那是「技术摘要」的事。
          if (result.android?.signature case final s?) ...{
            'schemes': s.verifiedSchemes.toList()..sort(),
            'signers': [
              for (final signer in s.signers)
                {
                  'index': signer.index,
                  'subjectDn': signer.subjectDn,
                  'sha256': signer.sha256Digest,
                  'sha1': signer.sha1Digest,
                  'keyAlgorithm': signer.keyAlgorithm,
                  'keySizeBits': signer.keySizeBits,
                },
            ],
            'toolExecuted': s.toolExecuted,
            'exitCode': s.exitCode,
          },
          if (result.ios?.codeSign case final c?) ...{
            'codesignStatus': c.status.name,
            'toolExecuted': c.toolExecuted,
            'exitCode': c.exitCode,
          },
        },
      },

      'securitySummary': security == null
          ? null
          : {
              'engineVersion': security.engineVersion,
              'rulesVersion': security.rulesVersion,
              'hasCoverageGaps': security.hasCoverageGaps,
              'includesRuntimeEvidence': security.includesRuntimeEvidence,
              'counts': counts,
              'highestRiskRuleId': worst?.ruleId,
              'highestRiskSeverity': worst?.severity.name,
            },

      // 网络端点：静态提取到的主机名与 IP。空表示本次没提取到（或没做），
      // 不表示「没有网络行为」。
      'network': {
        'domains': security?.network.domains ?? const <String>[],
        'ips': security?.network.ips ?? const <String>[],
      },

      'findings': findings,

      // 安全引擎视角的覆盖情况。
      //
      // `entries` 是**结构化**的逐维度状态（稳定 id + 可判定状态）；
      // `limitations` 是给人读的句子。两者都在：程序用前者，
      // 人读后者，且不必从文本里反推状态。
      'coverage': {
        'hasGaps': security?.hasCoverageGaps ?? true,
        'entries': [
          for (final entry
              in security?.coverage.entries ?? const <CoverageEntry>[])
            {
              'id': entry.id,
              'status': entry.status.name,
              'covered': entry.covered,
              'limit': entry.limit,
              'note': entry.note,
            },
        ],
        'limitations': security?.limitations ?? const <String>[],
      },

      if (!securityOnly)
        'diagnostics': [
          for (final d in result.diagnostics)
            {
              'severity': d.severity.name,
              'code': d.code,
              'message': d.message,
              'source': d.source?.name,
            },
        ],

      // 引擎与规则版本单列成一级字段，方便脚本在不解析 findings 的情况下
      // 判断「这份报告是用哪套规则跑出来的」。
      'engineVersions': {
        if (security != null) 'security': security.engineVersion,
      },
      'rulesVersions': {
        if (security != null) 'security': security.rulesVersion,
      },

      // 报告级的「未执行 / 无法确认」，与上面的 coverage 不是一回事。
      if (!securityOnly) 'limitations': reportLimitations(result, t),
    };

    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert(map)}\n';
  }

  static String _reportId(PackageAnalysisResult result, DateTime at) {
    final sha = result.sha256.value ?? '';
    final short = sha.length >= 16 ? sha.substring(0, 16) : sha;
    return '$short-${at.toUtc().millisecondsSinceEpoch}';
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
