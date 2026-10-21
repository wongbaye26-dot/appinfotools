import 'dart:convert';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_diagnostic_text.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/field_value_text.dart';
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
      // 分包一致性单列一节。放在平台段之后、安全段之前：它是**结构事实**，
      // 不是风险结论 —— 混进安全段会被读成「发现了风险」。
      _splitConsistency(sb, result, t);
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

    // 权限现在是 `FieldValue`：只有**确实读到**才列清单。
    // 「这个来源不报权限」不能渲染成「没有声明权限」。
    final permissions = android.permissions.value ?? const <String>[];
    if (permissions.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('### ${t.apk_info.permissions} (${permissions.length})')
        ..writeln();
      for (final permission in permissions) {
        sb.writeln('- $permission');
      }
    } else if (!android.permissions.hasValue) {
      // **没读到就必须说出来。** 此前这里直接留白，读者只会得到
      // 「这个应用没有声明任何权限」这一个印象 —— 而「读失败」与
      // 「确实没声明」的结论正好相反。
      _row(sb, t.apk_info.permissions, android.permissions);
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
      sb.writeln('- **${t.security.findings}:** ${findingText(finding, t)}');
      sb.writeln(
          '- **${t.report.label_confidence}:** ${finding.confidence.name}');
      // 数据流三段：只写有值的那几段。
      //
      // 界面（`SecurityFindingCard`）早就显示来源与去向，报告里却一直没有 ——
      // 同一份发现，导出成文件就少了两条最关键的信息。中间处理这一段是
      // B-5 新加的（`ANDROID-RULE-C` 的「同一方法体」分支会填）。
      final flow = <String>[
        if (finding.dataSource != null)
          '${t.security.data_flow_source}: ${finding.dataSource}',
        if (finding.dataTransform != null)
          '${t.security.data_flow_transform}: ${finding.dataTransform}',
        if (finding.dataSink != null)
          '${t.security.data_flow_sink}: ${finding.dataSink}',
      ];
      if (flow.isNotEmpty) {
        sb.writeln('- **${t.security.data_flow}:** ${flow.join(' → ')}');
      }
      if (finding.evidence.isNotEmpty) {
        sb.writeln('- **${t.report.label_evidence}:**');
        for (final ev in finding.evidence) {
          sb.writeln('  - ${ev.source.name} (${locationText(ev, t)}): '
              '${detailText(ev, t)}');
        }
      }
      final recommendation = recommendationText(finding, t);
      if (recommendation.isNotEmpty) {
        sb.writeln('- **${t.report.label_recommendation}:** $recommendation');
      }
      final limitation = limitationText(finding, t);
      if (limitation != null && limitation.isNotEmpty) {
        sb.writeln('- **${t.report.label_limitation}:** $limitation');
      }
      sb.writeln();
    }

    // 方法论层面的局限**照实列出**，但不再拿它当「有缺口」的门闩：
    // 两个引擎都无条件追加至少两条，用 `hasCoverageGaps` 当条件会让这一节
    // 永远出现，读者很快学会跳过它。真正的缺口由上面的覆盖表回答。
    if (security.hasDeclaredLimitations) {
      sb.writeln('### ${t.security.limitations}');
      sb.writeln();
      for (final limit in security.limitations) {
        sb.writeln('- ${limitationNoteText(limit, t)}');
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
      sb.writeln('| ${_escape(coverageDimensionLabel(entry.id, t))} '
          '| ${coverageStatusText(entry.status, t)} '
          '| ${entry.ratioText ?? '—'} '
          '| ${_escape(coverageNote(entry, t) ?? '')} |');
    }
    sb
      ..writeln()
      ..writeln(t.coverage.hint)
      ..writeln();
  }

  /// 分包（XAPK / APKM / APKS）一致性。
  ///
  /// **只有查过分包才出现** —— `splitConsistency` 为 `null` 表示「没查」
  ///（单 APK，或本次未做这项检查），此时不渲染空章节：一个空的「分包一致性」
  /// 小节会被读成「查了没问题」。
  ///
  /// 与「解析诊断」分开：那里是给人读的句子，这里是结构化结论
  ///（比对了几个、有几个不一致、有没有没查到的）。
  static void _splitConsistency(
    StringBuffer sb,
    PackageAnalysisResult result,
    Translations t,
  ) {
    final split = result.splitConsistency;
    if (split == null) return;

    sb
      ..writeln('## ${t.report.split_section}')
      ..writeln()
      ..writeln(t.report
          .split_checked(checked: split.checkedCount, total: split.totalCount))
      ..writeln();

    if (split.isFullyChecked) {
      sb.writeln('- ${t.report.split_all_checked}');
    } else {
      sb.writeln('- ${t.report.split_unchecked(count: split.uncheckedCount)}');
    }

    if (split.hasIssues) {
      sb.writeln('- ${t.report.split_issue_count(count: split.issues.length)}');
      sb.writeln();
      for (final issue in split.issues) {
        sb.writeln('- ${_escape(issue)}');
      }
    } else {
      sb.writeln('- ${t.report.split_no_issues}');
    }

    sb
      ..writeln()
      ..writeln(t.report.split_note)
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
    final head =
        t.coverage.summary(covered: covered, applicable: applicable.length);
    if (covered == applicable.length) {
      // 分隔符与括号都走 i18n。此前这里是写死的中文全角「；」与「（）」，
      // 英文报告里会长成 `fully covered；2 dimensions have gaps`。
      return '$head${t.coverage.summary_join}${t.coverage.all_covered}';
    }
    return '$head${t.coverage.summary_join}'
        '${t.coverage.gap_count(count: coverage.gaps.length)}';
  }

  /// 覆盖维度的**本地化名字**。
  ///
  /// [CoverageEntry.id] 是给程序用的稳定标识（`android.dex.strings`），
  /// 不该直接给用户看。UI 与 Markdown 都走这一个函数 —— 两处各写一份映射，
  /// 迟早会出现「界面是中文、报告是英文」这种互相矛盾的呈现。
  ///
  /// 认不出的 id **原样返回**：宁可显示一个机器标识，也不要显示空白或
  /// 「未知维度」—— 后者会让「新增了维度但忘了补文案」变得不可见。
  static String coverageDimensionLabel(String id, Translations t) {
    final d = t.coverage.dimensions;
    return switch (id) {
      'android.manifest' => d.android_manifest,
      'android.permissions' => d.android_permissions,
      'android.dex.structure' => d.android_dex_structure,
      'android.dex.strings' => d.android_dex_strings,
      'android.dex.methodReferences' => d.android_dex_methodReferences,
      'android.dex.callSites' => d.android_dex_callSites,
      'android.nativeSymbols' => d.android_nativeSymbols,
      'android.nativeHardening' => d.android_nativeHardening,
      'android.sdkInventory' => d.android_sdkInventory,
      'android.arsc' => d.android_arsc,
      'android.cleartextPolicy' => d.android_cleartextPolicy,
      'android.signature' => d.android_signature,
      'ios.infoPlist' => d.ios_infoPlist,
      'ios.usageDescriptions' => d.ios_usageDescriptions,
      'ios.privacyManifest' => d.ios_privacyManifest,
      'ios.executables' => d.ios_executables,
      'ios.macho.strings' => d.ios_macho_strings,
      'ios.nativeSymbols' => d.ios_nativeSymbols,
      'ios.entitlements' => d.ios_entitlements,
      'ios.signature' => d.ios_signature,
      _ => id,
    };
  }

  /// 发现项的**本地化正文**。
  ///
  /// 引擎产出的是 [SecurityFinding.messageCode]（稳定 id）+ `finding`（英文回退）
  /// —— 引擎层不依赖 slang。这里按 code 取本地化文案，**认不出来就回退原文**。
  ///
  /// **迁移是增量的**：没填 `messageCode` 的发现项直接返回原文（目前可能是中文），
  /// 因此任何时刻都不会出现「英文界面下一半中文一半英文」的中间态。
  static String findingText(SecurityFinding finding, Translations t) {
    final code = finding.messageCode;
    if (code == null) return finding.finding;

    final f = t.security.finding_texts;
    final key = finding.messageArgs['key'];
    final bundle = finding.messageArgs['bundle'];
    final count = finding.messageArgs['count'];
    final schemes = finding.messageArgs['schemes'];
    // 主动请求权限的 API 名单（`PHPhotoLibrary` 这类专有名词，不翻译）。
    final apis = _joinNames(finding.messageArgs['apis'], t);
    final capability = finding.messageArgs['capability'];
    // 恶意代码指标的信号 id 列表。
    final signals = finding.messageArgs['signals'];
    // 加密资产规则里写死的链上地址条数。
    final addressCount = finding.messageArgs['addressCount'];
    // 「静态分析没看全」的地方（预算截断 / 原生库疑似加壳）。
    final blindSpots = finding.messageArgs['blindSpots'];
    // ATS 例外里「真正放宽了」的域名数。
    final weakened = finding.messageArgs['weakened'];
    // 证书固定涉及的域名（`<pin-set>` 所在域）。
    final domains = finding.messageArgs['domains'];
    // 引用表的两个计数。
    final classes = finding.messageArgs['classes'];
    final selectors = finding.messageArgs['selectors'];
    final total = finding.messageArgs['total'];
    final scanned = finding.messageArgs['scanned'];
    final bytes = finding.messageArgs['bytes'];
    final uncovered = finding.messageArgs['uncovered'];
    final modes = finding.messageArgs['modes'];
    final name = finding.messageArgs['name'];
    final sources = _sourcesText(finding.messageArgs['sources'], t);
    final names = _joinNames(finding.messageArgs['names'], t);
    final symbols = _nativeSymbolsText(finding.messageArgs['symbols'], t);
    final parts = _evidencePartsText(finding.messageArgs['parts'], t);
    final inputClues = _joinNames(finding.messageArgs['inputClues'], t);
    final ocrClues = _joinNames(finding.messageArgs['ocrClues'], t);
    final note = _verdictNoteText(
      finding.messageArgs['noteCode'],
      finding.messageArgs['noteArgs'],
      t,
    );
    final rule = name is String ? _permissionRuleText(name, t) : null;
    final scope = finding.messageArgs['scope'];
    final api = finding.messageArgs['api'];
    // 被截断的点名数量（导出组件可达上百个，正文只列前若干个）。
    final more = finding.messageArgs['more'];
    // sharedUserId 的值（一条发现里只有一个 id）。
    final id = finding.messageArgs['id'];

    final String? localized = switch (code) {
      'ios.usage_description' =>
        key == null ? null : f.ios_usage_description(key: key),
      'ios.nested_usage_description' => (key == null || bundle == null)
          ? null
          : f.ios_nested_usage_description(bundle: bundle, key: key),
      'ios.photo_picker' => f.ios_photo_picker,
      'android.webview_bridge_unsafe' => f.android_webview_bridge_unsafe,
      'android.malware_indicators' => signals == null
          ? null
          : f.android_malware_indicators(
              signals: _joinNames(finding.messageArgs['signals'], t) ?? '—',
              reflection: finding.messageArgs['reflection'] == true
                  ? f.android_malware_reflection_suffix
                  : '',
            ),
      'ios.jailbreak_toolkit' => (() {
          final components = _joinNames(finding.messageArgs['components'], t);
          if (components == null) return null;
          return f.ios_jailbreak_toolkit(
            components: components,
            kernel: finding.messageArgs['kernelExploit'] == true
                ? f.ios_jailbreak_kernel_suffix
                : '',
          );
        })(),
      'crypto.theft_risk' => signals == null
          ? null
          : '${f.crypto_theft_risk(
              signals: _joinNames(signals, t) ?? '—',
              // 没有地址时整句不出现 —— 印出「0 个地址」比不印更让人困惑。
              addresses: addressCount is int && addressCount > 0
                  ? f.crypto_theft_risk_addresses(count: addressCount)
                  : '',
            )}'
              // 「没看全」必须单独说一句：否则「没报出来」会被读成「没有」。
              '${blindSpots is List && blindSpots.isNotEmpty ? '\n\n${f.crypto_theft_risk_blind_spots}' : ''}',
      'android.packer' => names == null ? null : f.android_packer(names: names),
      'android.deeplink' => (count == null || schemes == null)
          ? null
          : f.android_deeplink(
              count: count,
              schemes: _joinNames(finding.messageArgs['schemes'], t) ?? '—',
              components: finding.messageArgs['components'] ?? '—',
            ),
      'android.cert_pinning' => (count == null || domains == null)
          ? null
          : f.android_cert_pinning(
              count: count,
              domains: _joinNames(finding.messageArgs['domains'], t) ?? '—',
            ),
      'android.provider_exposed' => (count == null || names == null)
          ? null
          : f.android_provider_exposed(count: count, names: names),
      'android.permission_not_grantable' =>
        name == null ? null : f.android_permission_not_grantable(name: name),
      'ios.entitlement_capability' => (name == null || capability == null)
          ? null
          : f.ios_entitlement_capability(name: name, capability: capability),
      'ios.ats_exception' => (count == null || weakened == null)
          ? null
          : f.ios_ats_exception(
              count: count,
              weakened: weakened,
              domains: _joinNames(finding.messageArgs['domains'], t) ?? '—',
            ),
      'ios.reference_tables' => (classes == null || selectors == null)
          ? null
          : f.ios_reference_tables(
              classes: classes,
              selectors: selectors,
            ),
      'ios.permission_request' => (count == null || apis == null)
          ? null
          : f.ios_permission_request(count: count, apis: apis),
      'ios.rule_a' => f.ios_rule_a,
      'ios.ocr_capability' => f.ios_ocr_capability,
      'ios.rule_c' => f.ios_rule_c,
      'ios.rule_f' => f.ios_rule_f,
      'ios.url_schemes' => (count == null || schemes == null)
          ? null
          : f.ios_url_schemes(count: count, schemes: schemes),
      'ios.scan_coverage' => (total == null || scanned == null || bytes == null)
          ? null
          : f.ios_scan_coverage(total: total, scanned: scanned, bytes: bytes),
      'ios.scan_coverage_gap' =>
        (total == null || scanned == null || bytes == null || uncovered == null)
            ? null
            : f.ios_scan_coverage_gap(
                total: total,
                scanned: scanned,
                bytes: bytes,
                uncovered: uncovered,
              ),
      'ios.capability_no_usage' => (key == null || api == null)
          ? null
          : f.ios_capability_no_usage(key: key, api: api),
      'ios.usage_without_api' => (key == null || scope == null)
          ? null
          : f.ios_usage_without_api(key: key, scope: scope),
      'ios.photo_library' => f.ios_photo_library,
      'ios.photo_library_no_usage' => f.ios_photo_library_no_usage,
      'ios.camera' => f.ios_camera,
      'ios.camera_no_usage' => f.ios_camera_no_usage,
      'ios.rule_b' => sources == null ? null : f.ios_rule_b(sources: sources),
      'ios.rule_e' => (modes == null || sources == null)
          ? null
          : f.ios_rule_e(modes: modes, sources: sources),
      'ios.rule_d' => f.ios_rule_d,
      'ios.rule_d_escalated' => f.ios_rule_d_escalated,
      'ios.privacy_info' => f.ios_privacy_info,
      'ios.privacy_tracking' => f.ios_privacy_tracking,
      'android.permission_uncategorized' => (count == null || names == null)
          ? null
          : f.android_permission_uncategorized(count: count, names: names),
      'android.permission_sdk23_conditional' => name == null
          ? null
          : f.android_permission_sdk23_conditional(name: name),
      'android.rule_a' => names == null ? null : f.android_rule_a(names: names),
      'android.rule_d' => f.android_rule_d,
      'android.rule_d_escalated' => f.android_rule_d_escalated,
      'android.rule_e' => f.android_rule_e,
      'android.rule_f' => f.android_rule_f,
      'ios.native_symbols' => (count == null || symbols == null)
          ? null
          : f.ios_native_symbols(count: count, symbols: symbols),
      'android.native_symbols' => (count == null || symbols == null)
          ? null
          : f.android_native_symbols(count: count, symbols: symbols),
      'android.ocr_capability' =>
        parts == null ? null : f.android_ocr_capability(parts: parts),
      'android.upload_api' =>
        parts == null ? null : f.android_upload_api(parts: parts),
      'android.network_endpoints' =>
        parts == null ? null : f.android_network_endpoints(parts: parts),
      'android.network_client' =>
        parts == null ? null : f.android_network_client(parts: parts),
      'android.rule_b' => (inputClues == null || ocrClues == null)
          ? null
          : f.android_rule_b(inputClues: inputClues, ocrClues: ocrClues),
      'android.rule_c' => f.android_rule_c,
      'android.debuggable' => f.android_debuggable,
      'android.exported_component' => (count == null || names == null)
          ? null
          : f.android_exported_component(count: count, names: names),
      // 组件数超过点名上限时的措辞（真实包上可达 159 个，全列出来没人看）。
      'android.exported_component_many' =>
        (count == null || names == null || more == null)
            ? null
            : f.android_exported_component_many(
                count: count, names: names, more: more),
      'android.allow_backup' => f.android_allow_backup,
      'android.shared_user_id' =>
        id == null ? null : f.android_shared_user_id(id: id),
      'android.exported_component_weak' => (count == null || names == null)
          ? null
          : f.android_exported_component_weak(count: count, names: names),
      'android.exported_component_weak_many' =>
        (count == null || names == null || more == null)
            ? null
            : f.android_exported_component_weak_many(
                count: count, names: names, more: more),
      'android.third_party_sdk' => (count == null || names == null)
          ? null
          : f.android_third_party_sdk(count: count, names: names),
      'android.native_exec_stack' => (count == null || names == null)
          ? null
          : f.android_native_exec_stack(count: count, names: names),
      'android.native_exec_stack_many' =>
        (count == null || names == null || more == null)
            ? null
            : f.android_native_exec_stack_many(
                count: count, names: names, more: more),
      'android.v1_only_signing' => f.android_v1_only_signing,
      'android.unsigned' => f.android_unsigned,
      'android.webview_bridge' => f.android_webview_bridge,
      'android.permission_without_api' =>
        names == null ? null : f.android_permission_without_api(names: names),
      'ios.rule_g' => sources == null ? null : f.ios_rule_g(sources: sources),
      'ios.rule_g_common' =>
        sources == null ? null : f.ios_rule_g_common(sources: sources),
      'ios.get_task_allow' => f.ios_get_task_allow,
      'ios.push_sandbox' => f.ios_push_sandbox,
      'android.rule_g' =>
        sources == null ? null : f.android_rule_g(sources: sources),
      'android.special_access' =>
        sources == null ? null : f.android_special_access(sources: sources),
      'android.screen_capture' =>
        parts == null ? null : f.android_screen_capture(parts: parts),
      'android.permission_expired' => (name == null || note == null)
          ? null
          : f.android_permission_expired(name: name, note: note),
      'android.permission_inert' => (name == null || note == null)
          ? null
          : f.android_permission_inert(name: name, note: note),
      'android.permission_rule' => rule == null
          ? null
          : f.android_permission_rule(description: rule.description),
      'android.permission_rule_with_note' => (rule == null || note == null)
          ? null
          : f.android_permission_rule_with_note(
              description: rule.description,
              note: note,
            ),
      _ => null,
    };
    var text = localized ?? finding.finding;
    // WebView 的「同时观察到」与 provider 的几种补充说明都是**条件句**，
    // 塞进模板会变成一堆条件占位符；改成拼在正文后面，每种情况一句、各自本地化。
    if (code == 'android.webview_bridge' ||
        code == 'android.webview_bridge_unsafe') {
      text = _appendWebViewExtras(text, finding.messageArgs['extras'], t);
    } else if (code == 'android.provider_exposed') {
      text = _appendProviderSuffixes(text, finding, t);
    }
    return text;
  }

  /// WebView 开关的「同时观察到」句子。
  static String _appendWebViewExtras(
    String base,
    Object? extrasArg,
    Translations t,
  ) {
    if (extrasArg is! List || extrasArg.isEmpty) return base;
    final f = t.security.finding_texts;
    final labels = <String>[
      for (final id in extrasArg)
        switch ('$id') {
          'js-enabled' => f.android_webview_extra_js_enabled,
          'universal-file-access' =>
            f.android_webview_extra_universal_file_access,
          'file-url-access' => f.android_webview_extra_file_url_access,
          _ => '$id',
        },
    ];
    return '$base ${f.android_webview_extras(extras: labels.join(t.security.list_join))}';
  }

  /// provider 发现的补充句（省略数量 / URI 授权 / 单向保护 / 弱权限）。
  static String _appendProviderSuffixes(
    String base,
    SecurityFinding finding,
    Translations t,
  ) {
    final f = t.security.finding_texts;
    final more = finding.messageArgs['more'];
    final parts = <String>[
      base,
      if (more != null) f.android_provider_exposed_more(more: more),
      if (finding.messageArgs['grantUri'] == true)
        f.android_provider_exposed_grant_uri,
      if (finding.messageArgs['partial'] == true)
        f.android_provider_exposed_partial,
      if (finding.messageArgs['weak'] == true) f.android_provider_exposed_weak,
    ];
    return parts.join(' ');
  }

  /// 发现项**建议**的本地化正文，语义同 [findingText]。
  static String recommendationText(SecurityFinding finding, Translations t) {
    final code = finding.recommendationCode;
    if (code == null) return finding.recommendation;

    final f = t.security.finding_texts;
    final ruleName = finding.messageArgs['name'];
    final rule = ruleName is String ? _permissionRuleText(ruleName, t) : null;
    final String? localized = switch (code) {
      'ios.usage_description.cross_check' =>
        f.ios_usage_description_cross_check,
      'ios.photo_picker.confirm_input_path' =>
        f.ios_photo_picker_confirm_input_path,
      'ios.permission_request.review' => f.ios_permission_request_review,
      'ios.ats_exception.review' => f.ios_ats_exception_review,
      'ios.reference_tables.no_action' => f.ios_reference_tables_no_action,
      'android.permission_not_grantable.review' =>
        f.android_permission_not_grantable_review,
      'android.provider_exposed.review' => f.android_provider_exposed_review,
      'android.deeplink.review' => f.android_deeplink_review,
      'android.cert_pinning.review' => f.android_cert_pinning_review,
      'android.packer.review' => f.android_packer_review,
      'android.malware_indicators.review' =>
        f.android_malware_indicators_review,
      'crypto.theft_risk.review' => f.crypto_theft_risk_review,
      'ios.entitlement_capability.review' =>
        f.ios_entitlement_capability_review,
      'ios.capability_no_usage.add_usage' =>
        f.ios_capability_no_usage_add_usage,
      'ios.usage_without_api.review' => f.ios_usage_without_api_review,
      'ios.jailbreak_toolkit.review' => f.ios_jailbreak_toolkit_review,
      'ios.rule_a.manual_review' => f.ios_rule_a_manual_review,
      'ios.ocr_capability.confirm_input_and_sink' =>
        f.ios_ocr_capability_confirm_input_and_sink,
      'ios.rule_c.manual_review' => f.ios_rule_c_manual_review,
      'ios.rule_f.runtime_traffic' => f.ios_rule_f_runtime_traffic,
      'ios.url_schemes.manual_review' => f.ios_url_schemes_manual_review,
      'ios.scan_coverage.manual_review' => f.ios_scan_coverage_manual_review,
      'ios.photo_library.review' => f.ios_photo_library_review,
      'ios.photo_library_no_usage.add_usage' =>
        f.ios_photo_library_no_usage_add_usage,
      'ios.camera.check_purpose' => f.ios_camera_check_purpose,
      'ios.camera_no_usage.add_usage' => f.ios_camera_no_usage_add_usage,
      'ios.rule_b.confirm_pipeline' => f.ios_rule_b_confirm_pipeline,
      'ios.rule_e.manual_review' => f.ios_rule_e_manual_review,
      'ios.rule_d.manual_review' => f.ios_rule_d_manual_review,
      'ios.privacy_info.cross_check' => f.ios_privacy_info_cross_check,
      'ios.privacy_tracking.confirm_att' => f.ios_privacy_tracking_confirm_att,
      'android.permission_uncategorized.manual_review' =>
        f.android_permission_uncategorized_manual_review,
      'android.permission_sdk23_conditional.verify' =>
        f.android_permission_sdk23_conditional_verify,
      'android.debuggable.remove' => f.android_debuggable_remove,
      'android.exported_component.review' =>
        f.android_exported_component_review,
      'android.shared_user_id.review' => f.android_shared_user_id_review,
      'android.third_party_sdk.review' => f.android_third_party_sdk_review,
      'android.native_exec_stack.review' => f.android_native_exec_stack_review,
      'android.v1_only_signing.review' => f.android_v1_only_signing_review,
      'android.unsigned.review' => f.android_unsigned_review,
      'android.webview_bridge.review' => f.android_webview_bridge_review,
      'android.permission_without_api.review' =>
        f.android_permission_without_api_review,
      'ios.rule_g.manual_review' => f.ios_rule_g_manual_review,
      'ios.get_task_allow.review' => f.ios_get_task_allow_review,
      'ios.push_sandbox.review' => f.ios_push_sandbox_review,
      'android.allow_backup.review' => f.android_allow_backup_review,
      'android.rule_g.manual_review' => f.android_rule_g_manual_review,
      'android.special_access.review' => f.android_special_access_review,
      'android.screen_capture.review' => f.android_screen_capture_review,
      'android.rule_a.manual_review' => f.android_rule_a_manual_review,
      'android.rule_d.manual_review' => f.android_rule_d_manual_review,
      'android.rule_e.manual_review' => f.android_rule_e_manual_review,
      'android.rule_f.runtime_traffic' => f.android_rule_f_runtime_traffic,
      'android.ocr_capability.check_pipeline' =>
        f.android_ocr_capability_check_pipeline,
      'android.upload_api.manual_review' => f.android_upload_api_manual_review,
      'android.network_endpoints.verify' => f.android_network_endpoints_verify,
      'android.network_client.manual_review' =>
        f.android_network_client_manual_review,
      'android.rule_b.confirm_pipeline' => f.android_rule_b_confirm_pipeline,
      'android.rule_c.manual_review' => f.android_rule_c_manual_review,
      'android.permission_expired.keep_observing' =>
        f.android_permission_expired_keep_observing,
      'android.permission_inert.check_legacy' =>
        f.android_permission_inert_check_legacy,
      'android.permission_rule.risk_note' => rule == null
          ? null
          : f.android_permission_rule_risk_note(riskNote: rule.riskNote),
      // 原生符号的「建议」与「关联说明」「局限」是一组。此前三条都产出了 code
      // 却没有分支 —— 编译通过、中文界面静默显示英文（审计 P2-7）。
      'ios.native_symbols.manual_review' => f.ios_native_symbols_manual_review,
      'android.native_symbols.manual_review' =>
        f.android_native_symbols_manual_review,
      _ => null,
    };
    return localized ?? finding.recommendation;
  }

  /// 发现项**关联说明**的本地化正文，语义同 [findingText]。
  ///
  /// 返回 `null` 表示这条发现项没有关联说明（或没填 code 时原文为空）。
  static String? relationshipText(SecurityFinding finding, Translations t) {
    final raw = finding.relationship;
    final code = finding.relationshipCode;
    if (code == null) return raw;

    final f = t.security.finding_texts;
    // 规则 C 的关联说明要嵌「出现在哪个方法体里」—— 这是目前唯一带参数的
    // 关联说明，因此 relationshipArgs 是**有真实消费者才加**的。
    final caller = finding.relationshipArgs['caller'];
    final path = finding.relationshipArgs['path'];
    final hops = finding.relationshipArgs['hops'];
    final String? localized = switch (code) {
      'ios.usage_without_api.relationship' =>
        f.ios_usage_without_api_relationship,
      'ios.rule_a.relationship' => f.ios_rule_a_relationship,
      'ios.rule_b.relationship' => f.ios_rule_b_relationship,
      'ios.rule_c.relationship' => f.ios_rule_c_relationship,
      'ios.rule_e.relationship' => f.ios_rule_e_relationship,
      'android.rule_g.relationship' => f.android_rule_g_relationship,
      'android.rule_e.relationship' => f.android_rule_e_relationship,
      'android.ocr_capability.relationship_code_refs' =>
        f.android_ocr_capability_relationship_code_refs,
      'android.ocr_capability.relationship_strings_only' =>
        f.android_ocr_capability_relationship_strings_only,
      'android.upload_api.relationship_code_refs' =>
        f.android_upload_api_relationship_code_refs,
      'android.upload_api.relationship_strings_only' =>
        f.android_upload_api_relationship_strings_only,
      'android.network_client.relationship_code_refs' =>
        f.android_network_client_relationship_code_refs,
      'android.network_client.relationship_strings_only' =>
        f.android_network_client_relationship_strings_only,
      'android.rule_b.relationship' => f.android_rule_b_relationship,
      'android.rule_c.relationship_package' =>
        f.android_rule_c_relationship_package,
      'android.rule_c.relationship_method' => caller == null
          ? null
          : f.android_rule_c_relationship_method(caller: caller),
      'android.rule_c.relationship_chain' => (path == null || hops == null)
          ? null
          : f.android_rule_c_relationship_chain(path: path, hops: hops),
      'ios.native_symbols.relationship' => f.ios_native_symbols_relationship,
      'android.native_symbols.relationship' =>
        f.android_native_symbols_relationship,
      _ => null,
    };
    return localized ?? raw;
  }

  /// 发现项**检测局限**的本地化正文，语义同 [findingText]。
  static String? limitationText(SecurityFinding finding, Translations t) {
    final raw = finding.limitation;
    final code = finding.limitationCode;
    // 调用链局限里的跳数（由引擎写在 `limitationArgs` 里）。
    final hops = finding.limitationArgs['hops'];
    if (code == null) return raw;

    final f = t.security.finding_texts;
    final targetSdk = finding.limitationArgs['targetSdk'];
    final String? localized = switch (code) {
      'ios.url_schemes.limitation' => f.ios_url_schemes_limitation,
      'ios.scan_coverage.limitation' => f.ios_scan_coverage_limitation,
      'ios.capability_no_usage.limitation' =>
        f.ios_capability_no_usage_limitation,
      'ios.usage_without_api.limitation' => f.ios_usage_without_api_limitation,
      'ios.photo_library.limitation' => f.ios_photo_library_limitation,
      'ios.rule_a.limitation' => f.ios_rule_a_limitation,
      'ios.rule_b.limitation' => f.ios_rule_b_limitation,
      'ios.rule_c.limitation' => f.ios_rule_c_limitation,
      'ios.rule_d.limitation' => f.ios_rule_d_limitation,
      'ios.rule_e.limitation' => f.ios_rule_e_limitation,
      'ios.privacy_info.limitation' => f.ios_privacy_info_limitation,
      'ios.rule_f.limitation' => f.ios_rule_f_limitation,
      'android.permission_sdk23_conditional.limitation' =>
        f.android_permission_sdk23_conditional_limitation,
      'android.debuggable.limitation' => f.android_debuggable_limitation,
      'android.shared_user_id.limitation' =>
        f.android_shared_user_id_limitation,
      'android.third_party_sdk.limitation' =>
        f.android_third_party_sdk_limitation,
      'android.native_exec_stack.limitation' =>
        f.android_native_exec_stack_limitation,
      'android.v1_only_signing.limitation' =>
        f.android_v1_only_signing_limitation,
      'android.unsigned.limitation' => f.android_unsigned_limitation,
      'android.webview_bridge.limitation' =>
        f.android_webview_bridge_limitation,
      'android.permission_without_api.limitation' =>
        f.android_permission_without_api_limitation,
      'ios.rule_g.limitation' => f.ios_rule_g_limitation,
      'ios.get_task_allow.limitation' => f.ios_get_task_allow_limitation,
      'ios.push_sandbox.limitation' => f.ios_push_sandbox_limitation,
      'android.exported_component.limitation' =>
        f.android_exported_component_limitation,
      'android.allow_backup.limitation' => f.android_allow_backup_limitation,
      'android.rule_g.limitation' => f.android_rule_g_limitation,
      'android.special_access.limitation' =>
        f.android_special_access_limitation,
      'android.rule_a.limitation' => f.android_rule_a_limitation,
      'android.rule_d.limitation' => f.android_rule_d_limitation,
      'android.rule_e.limitation' => f.android_rule_e_limitation,
      'android.rule_f.limitation_no_dex' => f.android_rule_f_limitation_no_dex,
      'android.rule_f.limitation_scope' => f.android_rule_f_limitation_scope,
      'android.ocr_capability.limitation' =>
        f.android_ocr_capability_limitation,
      'android.network_endpoints.limitation' =>
        f.android_network_endpoints_limitation,
      'android.network_client.limitation' =>
        f.android_network_client_limitation,
      'android.rule_b.limitation' => f.android_rule_b_limitation,
      'android.rule_c.limitation' => f.android_rule_c_limitation,
      'android.permission_expired.limitation' => targetSdk == null
          ? null
          : f.android_permission_expired_limitation(targetSdk: targetSdk),
      'android.permission_rule.limitation' =>
        f.android_permission_rule_limitation,
      'ios.native_symbols.limitation' => f.ios_native_symbols_limitation,
      'android.native_symbols.limitation' =>
        f.android_native_symbols_limitation,
      'android.screen_capture.limitation' =>
        f.android_screen_capture_limitation,
      'android.provider_exposed.limitation' =>
        f.android_provider_exposed_limitation,
      // 找到调用链之后的局限说明：不能再写「不是调用图分析」。
      'android.rule_c.limitation_graph' =>
        hops == null ? null : f.android_rule_c_limitation_graph(hops: hops),
      'android.rule_c.limitation_graph_truncated' => hops == null
          ? null
          : f.android_rule_c_limitation_graph_truncated(hops: hops),
      'android.deeplink.limitation' => f.android_deeplink_limitation,
      'ios.reference_tables.limitation' => f.ios_reference_tables_limitation,
      'ios.jailbreak_toolkit.limitation' => f.ios_jailbreak_toolkit_limitation,
      'android.malware_indicators.limitation' =>
        f.android_malware_indicators_limitation,
      'crypto.theft_risk.limitation' => f.crypto_theft_risk_limitation,
      _ => null,
    };
    return localized ?? raw;
  }

  /// 一个原生符号的**本地化说明**，形如 `执行 shell 命令（system）`。
  ///
  /// 表（`nativeSymbolMarkers`）里存的是「类别 id + 英文回退」，符号名单独拼 ——
  /// 26 条记录只对应 14 类说明，逐个写会把同一句话抄十几遍，改一处措辞就会
  /// 漏掉另外几处。
  ///
  /// 认不出的符号名原样返回：**宁可显示裸符号，也不要显示空白**。
  static String nativeSymbolText(String symbol, Translations t) {
    final marker = nativeSymbolMarkerIndex[symbol];
    if (marker == null) return symbol;

    final n = t.security.native_symbols;
    final String? label = switch (marker.descriptionCode) {
      'shell' => n.shell,
      'shell_popen' => n.shell_popen,
      'exec_image' => n.exec_image,
      'fork' => n.fork,
      'dlopen' => n.dlopen,
      'dlsym' => n.dlsym,
      'dladdr' => n.dladdr,
      'ptrace' => n.ptrace,
      'socket' => n.socket,
      'connect' => n.connect,
      'send' => n.send,
      'recv' => n.recv,
      'resolve' => n.resolve,
      'system_property' => n.system_property,
      _ => null,
    };
    if (label == null) return marker.description;
    return n.line(text: label, symbol: symbol);
  }

  /// 把一串原生符号名组装成**本地化**的一句话片段。
  static String? _nativeSymbolsText(Object? arg, Translations t) {
    if (arg is! List) return null;
    final symbols = arg.whereType<String>().toList();
    if (symbols.isEmpty) return null;
    return symbols
        .map((symbol) => nativeSymbolText(symbol, t))
        .join(t.security.list_join);
  }

  /// DEX 类型描述符 → 人类可读形式（阶段 4.3）。
  ///
  /// - `Lcom/foo/Bar;` → `com.foo.Bar`
  /// - `[Ljava/lang/String;` → `java.lang.String[]`
  /// - `+0x10` → `+16`（偏移是**字节**，十六进制只是 DEX 里的写法）
  ///
  /// **只改呈现**：引擎数据与 JSON 保留原始描述符 —— 那是能逐字对上
  /// `dexdump -d` 输出的形式，改了就再也无法和工具输出核对。
  /// 与「JSON 保留机器 id、UI 显示本地化名字」是同一条原则。
  static final RegExp _typeDescriptor = RegExp(r'(\[*)L([A-Za-z0-9_/$]+);');
  static final RegExp _hexOffset = RegExp(r'\+0x([0-9a-fA-F]+)');

  static String readableEvidenceText(String text) {
    final withoutDescriptors = text.replaceAllMapped(_typeDescriptor, (m) {
      final arraySuffix = '[]' * m.group(1)!.length;
      return '${m.group(2)!.replaceAll('/', '.')}$arraySuffix';
    });
    return withoutDescriptors.replaceAllMapped(
      _hexOffset,
      (m) => '+${int.parse(m.group(1)!, radix: 16)}',
    );
  }

  /// 证据详情的**本地化正文**，语义同 [findingText]。
  ///
  /// 详情里的标签（「引用」「调用点」「导入」）也是给人读的，此前由引擎直接
  /// 写成中文括号 —— 英文界面里就出现 `（引用）`。没填 `detailCode` 的条目
  /// 继续按原文渲染。
  static String detailText(SecurityEvidence evidence, Translations t) {
    final code = evidence.detailCode;
    if (code == null) return evidence.detail;

    final e = t.security.evidence_texts;
    final marker = evidence.detailArgs['marker'];
    final samples = evidence.detailArgs['samples'];
    final symbol = evidence.detailArgs['symbol'];
    final rawNames = evidence.detailArgs['rawNames'];
    final dex = evidence.detailArgs['dex'];
    final callSites = evidence.detailArgs['callSites'];

    final String? localized = switch (code) {
      'code.reference' => (marker == null || samples == null)
          ? null
          : e.code_reference(marker: marker, samples: samples),
      'rule_f.scope' => (dex == null || callSites == null)
          ? null
          : e.android_rule_f_scope(dex: dex, callSites: callSites),
      'code.call_site' => (marker == null || samples == null)
          ? null
          : e.code_call_site(marker: marker, samples: samples),
      'native_symbol.imported' => symbol == null
          ? null
          : e.native_symbol_imported(
              symbol: symbol,
              description: nativeSymbolText('$symbol', t),
            ),
      'native_symbol.imported_raw' => (symbol == null || rawNames == null)
          ? null
          : e.native_symbol_imported_raw(
              symbol: symbol,
              description: nativeSymbolText('$symbol', t),
              rawNames: rawNames,
            ),
      _ => null,
    };
    return readableEvidenceText(localized ?? evidence.detail);
  }

  /// 证据**位置**的本地化正文。
  ///
  /// 绝大多数位置是机器可读的事实（清单路径、`Info.plist` 键），不需要本地化；
  /// 少数是给人读的描述（「N 个 DEX 的字符串」）—— 那些带 `locationCode`。
  static String locationText(SecurityEvidence evidence, Translations t) {
    final code = evidence.locationCode;
    if (code == null) return evidence.location;

    final count = evidence.locationArgs['count'];
    final String? localized = switch (code) {
      'dex.strings' => count == null
          ? null
          : t.security.evidence_texts.dex_strings_location(count: count),
      _ => null,
    };
    return readableEvidenceText(localized ?? evidence.location);
  }

  /// 组装「代码引用 / 字符串提及 / 域名 / IP」这类**证据来源分项**。
  ///
  /// 引擎此前把标签和名字一起拼成一句中文（`'代码引用 A、B'`），再把分项用
  /// 中文分号连起来 —— 英文界面里就出现中文标签和中文标点。现在只传**名字列表**
  /// （它们本来就是终值：权限短名、标记说明都是英文），标签与两个分隔符都取自
  /// 语言包。
  static String? _evidencePartsText(Object? arg, Translations t) {
    if (arg is! Map) return null;
    final p = t.security.parts;
    final parts = <String>[];

    final codeRefs = _joinNames(arg['codeRefs'], t);
    if (codeRefs != null) parts.add(p.code_refs(names: codeRefs));

    final stringClues = _joinNames(arg['stringClues'], t);
    if (stringClues != null) parts.add(p.string_clues(names: stringClues));

    final domains = _joinNames(arg['domains'], t);
    if (domains != null) {
      parts.add(p.domains(count: arg['domainCount'] ?? 0, names: domains));
    }

    final ips = _joinNames(arg['ips'], t);
    if (ips != null) {
      parts.add(p.ips(count: arg['ipCount'] ?? 0, names: ips));
    }

    if (parts.isEmpty) return null;
    return parts.join(p.join);
  }

  /// 版本条件说明（`_Verdict.note`）的本地化文本。
  ///
  /// 它是**嵌在发现项正文里的一句话**（`"{name}: {note}"`），因此不能只做一层
  /// 查表：`messageArgs` 里带的是 `noteCode` + `noteArgs`，先在这里解析成一句
  /// 本地化的话，再作为参数交给外层文案。
  ///
  /// 认不出来就返回 `null`，外层据此整条回退到英文原文 ——
  /// 绝不渲染出 `{note}` 或半句话。
  static String? _verdictNoteText(
    Object? code,
    Object? args,
    Translations t,
  ) {
    if (code is! String) return null;
    final a = args is Map ? args : const {};
    final v = t.security.verdicts;
    final max = a['max'];
    final targetSdk = a['targetSdk'];
    final next = a['next'];
    final minApi = a['minApi'];
    final maxApi = a['maxApi'];

    return switch (code) {
      'max_sdk' => (max == null || targetSdk == null || next == null)
          ? null
          : v.max_sdk(max: max, targetSdk: targetSdk, next: next),
      'min_api' => (minApi == null || targetSdk == null)
          ? null
          : v.min_api(minApi: minApi, targetSdk: targetSdk),
      'max_api_effective_above' => (targetSdk == null || maxApi == null)
          ? null
          : v.max_api_effective_above(targetSdk: targetSdk, maxApi: maxApi),
      _ => null,
    };
  }

  /// 权限目录里一条规则的**本地化文本**（说明 + 风险说明）。
  ///
  /// 表里（`PermissionCatalog.rules`）存的是**英文回退**，本地化文案按
  /// 权限短名取 —— **短名本身就是这张表的稳定 id**，因此不需要额外的 code 字段。
  ///
  /// 24 个分支看着笨，但比「把两张表按索引对齐」安全：加权限时编译器会提醒
  /// 这个 switch 少了分支（Dart 的穷尽性检查管不到字符串，但
  /// `test/security_integration_test.dart` 里有一条「每个目录条目都有文案」
  /// 的测试兜着）。
  ///
  /// 认不出返回 `null`，调用方据此回退到英文原文。
  static ({String description, String riskNote})? _permissionRuleText(
    String name,
    Translations t,
  ) {
    final p = t.security.permission_rules;
    return switch (name) {
      'READ_MEDIA_IMAGES' => (
          description: p.read_media_images_description,
          riskNote: p.read_media_images_risk_note,
        ),
      'READ_MEDIA_VIDEO' => (
          description: p.read_media_video_description,
          riskNote: p.read_media_video_risk_note,
        ),
      'READ_MEDIA_AUDIO' => (
          description: p.read_media_audio_description,
          riskNote: p.read_media_audio_risk_note,
        ),
      'READ_MEDIA_VISUAL_USER_SELECTED' => (
          description: p.read_media_visual_user_selected_description,
          riskNote: p.read_media_visual_user_selected_risk_note,
        ),
      'READ_EXTERNAL_STORAGE' => (
          description: p.read_external_storage_description,
          riskNote: p.read_external_storage_risk_note,
        ),
      'WRITE_EXTERNAL_STORAGE' => (
          description: p.write_external_storage_description,
          riskNote: p.write_external_storage_risk_note,
        ),
      'MANAGE_EXTERNAL_STORAGE' => (
          description: p.manage_external_storage_description,
          riskNote: p.manage_external_storage_risk_note,
        ),
      'CAMERA' => (
          description: p.camera_description,
          riskNote: p.camera_risk_note,
        ),
      'INTERNET' => (
          description: p.internet_description,
          riskNote: p.internet_risk_note,
        ),
      'ACCESS_NETWORK_STATE' => (
          description: p.access_network_state_description,
          riskNote: p.access_network_state_risk_note,
        ),
      'ACCESS_WIFI_STATE' => (
          description: p.access_wifi_state_description,
          riskNote: p.access_wifi_state_risk_note,
        ),
      'CHANGE_WIFI_STATE' => (
          description: p.change_wifi_state_description,
          riskNote: p.change_wifi_state_risk_note,
        ),
      'FOREGROUND_SERVICE' => (
          description: p.foreground_service_description,
          riskNote: p.foreground_service_risk_note,
        ),
      'FOREGROUND_SERVICE_DATA_SYNC' => (
          description: p.foreground_service_data_sync_description,
          riskNote: p.foreground_service_data_sync_risk_note,
        ),
      'RECEIVE_BOOT_COMPLETED' => (
          description: p.receive_boot_completed_description,
          riskNote: p.receive_boot_completed_risk_note,
        ),
      'WAKE_LOCK' => (
          description: p.wake_lock_description,
          riskNote: p.wake_lock_risk_note,
        ),
      'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS' => (
          description: p.request_ignore_battery_optimizations_description,
          riskNote: p.request_ignore_battery_optimizations_risk_note,
        ),
      'SCHEDULE_EXACT_ALARM' => (
          description: p.schedule_exact_alarm_description,
          riskNote: p.schedule_exact_alarm_risk_note,
        ),
      'QUERY_ALL_PACKAGES' => (
          description: p.query_all_packages_description,
          riskNote: p.query_all_packages_risk_note,
        ),
      'READ_PHONE_STATE' => (
          description: p.read_phone_state_description,
          riskNote: p.read_phone_state_risk_note,
        ),
      'ACCESS_FINE_LOCATION' => (
          description: p.access_fine_location_description,
          riskNote: p.access_fine_location_risk_note,
        ),
      'ACCESS_COARSE_LOCATION' => (
          description: p.access_coarse_location_description,
          riskNote: p.access_coarse_location_risk_note,
        ),
      'READ_CONTACTS' => (
          description: p.read_contacts_description,
          riskNote: p.read_contacts_risk_note,
        ),
      'READ_CLIPBOARD' => (
          description: p.read_clipboard_description,
          riskNote: p.read_clipboard_risk_note,
        ),
      'SYSTEM_ALERT_WINDOW' => (
          description: p.system_alert_window_description,
          riskNote: p.system_alert_window_risk_note,
        ),
      'REQUEST_INSTALL_PACKAGES' => (
          description: p.request_install_packages_description,
          riskNote: p.request_install_packages_risk_note,
        ),
      'ACCESS_BACKGROUND_LOCATION' => (
          description: p.access_background_location_description,
          riskNote: p.access_background_location_risk_note,
        ),
      'RECORD_AUDIO' => (
          description: p.record_audio_description,
          riskNote: p.record_audio_risk_note,
        ),
      _ => null,
    };
  }

  /// **结果级局限**的本地化文本。
  ///
  /// 与 [coverageNote] 同构：引擎产出 `AnalysisNote`（稳定 code + 英文回退 +
  /// 参数），这里按 code 取本地化文案，**认不出来就回退英文** ——
  /// 宁可显示英文，也不要显示空白或未替换的 `{count}`。
  ///
  /// 与 [limitationText] 的分工：那个是**单条发现项**的局限（挂在
  /// `SecurityFinding` 上），这个是**整个结果**的覆盖不足说明（挂在
  /// `SecurityAnalysisResult` 上）。
  static String limitationNoteText(AnalysisNote note, Translations t) {
    final n = t.security.limitation_notes;
    final a = note.args;
    final reason = a['reason'];
    final count = a['count'];
    // 总数（原生库加固那条说明要用「N 个里 M 个」的措辞）。
    final total = a['total'];
    // SDK 盘点：截断 / 读不出的 DEX 数。
    final truncated = a['truncated'];
    final failed = a['failed'];
    final path = a['path'];
    final bytes = a['bytes'];
    final limit = a['limit'];
    final names = _joinNames(a['names'], t);
    final name = a['name'];
    final dexCount = a['dexCount'];
    final codeValue = a['code'];
    final message = a['message'];
    final limitMiB = a['limitMiB'];
    final anomaly = a['anomaly'];
    // DEX 扫描预算的三个数（V2.4.9）：只给 `{name}` 时界面只能写「该文件只
    // 扫描了部分内容」，说不出「扫了多少 / 一共多大 / 覆盖几成」。
    final scannedBytes = a['scannedBytes'];
    final totalBytes = a['totalBytes'];
    final percent = a['percent'];
    // 加固/清单结构异常的参数（V2.4.11：这些说明改成 code + 参数，
    // 否则中文界面上是「容器/解析异常可能影响覆盖完整性：21 elements
    // declare a non-standard attributeStart…」这种半中半英）。
    final samples = a['samples'];
    final largest = a['largest'];
    final element = a['element'];
    final standard = a['standard'];
    final chunks = a['chunks'];
    final header = a['header'];
    final size = a['size'];

    final String? localized = switch (note.code) {
      'ios.url_schemes.unreadable' =>
        reason == null ? null : n.ios_url_schemes_unreadable(reason: reason),
      'ios.nested_plist.missing' =>
        count == null ? null : n.ios_nested_plist_missing(count: count),
      'ios.executable.over_budget' =>
        (path == null || bytes == null || limit == null)
            ? null
            : n.ios_executable_over_budget(
                path: path, bytes: bytes, limit: limit),
      'ios.executable.none_readable' => n.ios_executable_none_readable,
      'ios.executable.unscanned' => (count == null || names == null)
          ? null
          : n.ios_executable_unscanned(count: count, names: names),
      'ios.executables.truncated' => (count == null || total == null)
          ? null
          : n.ios_executables_truncated(count: count, total: total),
      'ios.macho.scan_summary' =>
        bytes == null ? null : n.ios_macho_scan_summary(bytes: bytes),
      'ios.privacy_info.unparsable' =>
        reason == null ? null : n.ios_privacy_info_unparsable(reason: reason),
      'ios.privacy_info.absent' => n.ios_privacy_info_absent,
      'ios.offline_static_analysis' => n.ios_offline_static_analysis,
      'ios.scan.truncated' => n.ios_scan_truncated,
      'ios.native_symbols.unreadable' => (count == null || names == null)
          ? null
          : n.ios_native_symbols_unreadable(count: count, names: names),
      'ios.native_symbols.stripped' => n.ios_native_symbols_stripped,
      'ios.native_symbols.semantics' => n.ios_native_symbols_semantics,
      'ios.permission_request.no_methname' =>
        n.ios_permission_request_no_methname,
      'ios.reference_tables.unsupported' => reason == null
          ? null
          : n.ios_reference_tables_unsupported(reason: reason),
      'android.split_apk.base_only' => n.android_split_apk_base_only,
      'android.sdk_inventory.no_dex' => n.android_sdk_inventory_no_dex,
      'android.sdk_inventory.incomplete' =>
        (truncated == null || failed == null)
            ? null
            : n.android_sdk_inventory_incomplete(
                truncated: truncated, failed: failed),
      'android.native_hardening.not_provided' =>
        n.android_native_hardening_not_provided,
      'android.provider_exposed' => n.android_provider_exposed,
      'android.signing_block.unreadable' => reason == null
          ? null
          : n.android_signing_block_unreadable(reason: reason),
      'android.native_hardening.some_without_relro' =>
        (count == null || total == null)
            ? null
            : n.android_native_hardening_some_without_relro(
                count: count, total: total),
      'ios.entitlements.no_profile' => n.ios_entitlements_no_profile,
      'ios.entitlements.empty' => n.ios_entitlements_empty,
      'android.manifest.unparsed' =>
        reason == null ? null : n.android_manifest_unparsed(reason: reason),
      'android.dex.budget' => (name == null ||
              scannedBytes == null ||
              totalBytes == null ||
              percent == null)
          ? null
          : n.android_dex_budget(
              name: name,
              scannedBytes: scannedBytes,
              totalBytes: totalBytes,
              percent: percent,
            ),
      'android.dex.no_content' => n.android_dex_no_content,
      'android.dex.scan_summary' => (dexCount == null || bytes == null)
          ? null
          : n.android_dex_scan_summary(dexCount: dexCount, bytes: bytes),
      'android.dex.structure_anomaly' =>
        (name == null || codeValue == null || message == null)
            ? null
            : n.android_dex_structure_anomaly(
                name: name, code: codeValue, message: message),
      'android.dex.checksum_not_verified' => (name == null || limitMiB == null)
          ? null
          : n.android_dex_checksum_not_verified(name: name, limitMiB: limitMiB),
      'android.dex.structure_untrusted' => (count == null || names == null)
          ? null
          : n.android_dex_structure_untrusted(count: count, names: names),
      'android.dex.method_not_traversable' => (count == null || names == null)
          ? null
          : n.android_dex_method_not_traversable(count: count, names: names),
      'android.dex.method_budget' =>
        names == null ? null : n.android_dex_method_budget(names: names),
      'android.dex.method_entries_unreadable' => count == null
          ? null
          : n.android_dex_method_entries_unreadable(count: count),
      'android.dex.desynced_bodies' => (count == null || names == null)
          ? null
          : n.android_dex_desynced_bodies(count: count, names: names),
      'android.dex.method_semantics' => n.android_dex_method_semantics,
      'android.dex.invoke_custom' =>
        count == null ? null : n.android_dex_invoke_custom(count: count),
      'android.container.anomaly' =>
        anomaly == null ? null : n.android_container_anomaly(anomaly: anomaly),
      // 结构异常（EOCD 条目数与实际不符）与「通用容器异常」同一个模板：
      // 正文就是那句英文/中文的结构说明。
      'android.container.structure_anomaly' =>
        anomaly == null ? null : n.android_container_anomaly(anomaly: anomaly),
      'android.container.decoy_entries' => (count == null || samples == null)
          ? null
          : n.android_container_decoy_entries(count: count, samples: samples),
      'android.manifest.attribute_start_nonstandard' => (count == null ||
              largest == null ||
              element == null ||
              standard == null)
          ? null
          : n.android_manifest_attribute_start_nonstandard(
              count: count,
              largest: largest,
              element: element,
              standard: standard,
            ),
      'android.manifest.attribute_size_nonstandard' =>
        (count == null || largest == null || standard == null)
            ? null
            : n.android_manifest_attribute_size_nonstandard(
                count: count,
                largest: largest,
                standard: standard,
              ),
      'android.manifest.namespace_chunk_nonstandard' =>
        (count == null || largest == null || standard == null)
            ? null
            : n.android_manifest_namespace_chunk_nonstandard(
                count: count,
                largest: largest,
                standard: standard,
              ),
      'android.manifest.unknown_chunk' => (count == null || chunks == null)
          ? null
          : n.android_manifest_unknown_chunk(count: count, chunks: chunks),
      // 其余加固信号（V2.4.11 一次补完，否则面板里仍会剩英文尾巴）。
      'android.container.missing_primary_dex' =>
        n.android_container_missing_primary_dex,
      'android.container.multiple_dex_files' => (count == null || names == null)
          ? null
          : n.android_container_multiple_dex_files(count: count, names: names),
      'android.container.dex_header_unreadable' => name == null
          ? null
          : n.android_container_dex_header_unreadable(name: name),
      'android.container.dex_header_not_standard' =>
        (name == null || header == null)
            ? null
            : n.android_container_dex_header_not_standard(
                name: name, header: header),
      'android.container.dex_in_native_library' => name == null
          ? null
          : n.android_container_dex_in_native_library(name: name),
      'android.container.unusual_native_library' => name == null
          ? null
          : n.android_container_unusual_native_library(name: name),
      'android.container.executable_in_assets' => name == null
          ? null
          : n.android_container_executable_in_assets(name: name),
      'android.container.resource_table_missing' =>
        n.android_container_resource_table_missing,
      'android.container.resource_table_too_small' => size == null
          ? null
          : n.android_container_resource_table_too_small(size: size),
      'android.native_symbols.budget' =>
        name == null ? null : n.android_native_symbols_budget(name: name),
      'android.native_symbols.not_traversable' =>
        (count == null || names == null)
            ? null
            : n.android_native_symbols_not_traversable(
                count: count, names: names),
      'android.native_symbols.skipped' =>
        count == null ? null : n.android_native_symbols_skipped(count: count),
      'android.native_symbols.truncated' => n.android_native_symbols_truncated,
      'android.native_symbols.semantics' => n.android_native_symbols_semantics,
      'android.native_symbols.unstripped' => (count == null || names == null)
          ? null
          : n.android_native_symbols_unstripped(count: count, names: names),
      // 选择阶段就被丢掉的库（连打开都没打开过）—— 与 `...symbols.skipped`
      // 不是一回事：那条是「打开了，但符号表条目读不出来」，这条是「根本没打开」。
      'android.native_symbols.not_scanned' => count == null
          ? null
          : n.android_native_symbols_not_scanned(count: count),
      'android.offline_static_analysis' => n.android_offline_static_analysis,
      'android.analysis.based_on_cooccurrence' =>
        n.android_analysis_based_on_cooccurrence,
      _ => null,
    };
    return localized ?? note.fallback;
  }

  /// 把「来源 id 列表」组装成**本地化**的一句话片段。
  ///
  /// 引擎只能产出 id（`photo_library` / `photo_picker` / `camera` / `clipboard`）
  /// —— 它不依赖 slang，产不出任何语言的成品句子。名字与分隔符都放在语言包里，
  /// 与 `coverageDimensionLabel` 同一思路：**JSON 里保留机器 id，
  /// UI 与 Markdown 显示本地化名字**。
  ///
  /// 参数缺失、不是列表、或列表为空时返回 `null`，调用方据此回退英文原文 ——
  /// 宁可显示英文，也不要显示一个空括号或半截句子。
  static String? _sourcesText(Object? arg, Translations t) {
    if (arg is! List) return null;
    final ids = arg.whereType<String>().toList();
    if (ids.isEmpty) return null;

    final names = t.security.sources;
    return ids
        .map((id) => switch (id) {
              'photo_library' => names.photo_library,
              'photo_picker' => names.photo_picker,
              'camera' => names.camera,
              'clipboard' => names.clipboard,
              'device_id' => names.device_id,
              'contacts' => names.contacts,
              'sms' => names.sms,
              'location' => names.location,
              'recording' => names.recording,
              'accessibility' => names.accessibility,
              'device_admin' => names.device_admin,
              'notification_listener' => names.notification_listener,
              _ => id,
            })
        .join(t.security.list_join);
  }

  /// 用**本地化的分隔符**连接一串已经是终值的名字（权限短名等）。
  ///
  /// 与 [_sourcesText] 的分工：那里的元素是**稳定 id**、要查表换成名字；
  /// 这里的元素本身已经是终值（`READ_MEDIA_IMAGES`），只有**分隔符**随语言变
  /// （en `", "` / 中文 `"、"`）。此前引擎直接 `join('、')`，于是英文界面里
  /// 出现中文顿号。
  ///
  /// 参数缺失或列表为空时返回 `null`，调用方据此回退英文原文。
  static String? _joinNames(Object? arg, Translations t) {
    if (arg is! List) return null;
    final names = arg.whereType<String>().toList();
    if (names.isEmpty) return null;
    return names.join(t.security.list_join);
  }

  /// 覆盖说明的**本地化文本**。
  ///
  /// 引擎产出的是 [CoverageEntry.noteCode]（稳定 id）+ [CoverageEntry.note]
  /// （英文回退）—— 引擎层不依赖 slang，产不出本地化文案。这里按 code 取
  /// 本地化文本，**认不出来就回退到英文 `note`**：
  ///
  /// - 宁可显示英文，也不要显示空白 —— 空白会被读成「没什么可说的」；
  /// - 参数缺失时同样回退，绝不渲染出未替换的 `{count}`。
  ///
  /// 没有 `noteCode` 时（老数据 / 测试手工构造）直接返回 `note`。
  static String? coverageNote(CoverageEntry entry, Translations t) {
    final code = entry.noteCode;
    if (code == null) return entry.note;

    final n = t.coverage.notes;
    final count = entry.noteArgs['count'];
    final reason = entry.noteArgs['reason'];
    // 「N 个里有多少没覆盖」这类说明要用总数。
    final total = entry.noteArgs['total'];

    final String? localized = switch (code) {
      'android.manifest.unparsed' =>
        reason == null ? null : n.android_manifest_unparsed(reason: reason),
      'android.permissions.manifest_unparsed' =>
        n.android_permissions_manifest_unparsed,
      'android.dex.no_content' => n.android_dex_no_content,
      'android.dex.structure_untrusted' =>
        count == null ? null : n.android_dex_structure_untrusted(count: count),
      'android.dex.strings_not_fully_scanned' => count == null
          ? null
          : n.android_dex_strings_not_fully_scanned(count: count),
      'android.dex.no_traversable_dex' => n.android_dex_no_traversable_dex,
      'android.dex.method_entries_unreadable' => count == null
          ? null
          : n.android_dex_method_entries_unreadable(count: count),
      'android.dex.no_traversable_bodies' =>
        n.android_dex_no_traversable_bodies,
      'android.dex.desynced_bodies' =>
        count == null ? null : n.android_dex_desynced_bodies(count: count),
      'android.native_symbols.not_provided' =>
        n.android_native_symbols_not_provided,
      'android.native_symbols.skipped_for_budget' => count == null
          ? null
          : n.android_native_symbols_skipped_for_budget(count: count),
      'android.arsc.missing' => n.android_arsc_missing,
      'android.arsc.empty' => n.android_arsc_empty,
      // 这两条此前在 limitationNoteText 里（那里没有对应 code 的 AnalysisNote），
      // 覆盖说明反而查不到本地化 —— 中文界面上这一格一直是英文。
      'android.cleartext_policy_unknown' => n.android_cleartext_policy_unknown,
      'android.cleartext_policy_target_sdk_unknown' =>
        n.android_cleartext_policy_target_sdk_unknown,
      'android.signature.not_read' => n.android_signature_not_read,
      'android.signature.unreadable' =>
        reason == null ? null : n.android_signature_unreadable(reason: reason),
      'android.signature.v1_undetermined' =>
        n.android_signature_v1_undetermined,
      'ios.info_plist.unparsed' => n.ios_info_plist_unparsed,
      'ios.usage_descriptions.not_read' => n.ios_usage_descriptions_not_read,
      'ios.privacy_manifest.absent' => n.ios_privacy_manifest_absent,
      'ios.executables.unscanned' =>
        count == null ? null : n.ios_executables_unscanned(count: count),
      'ios.executables.truncated' => (count == null || total == null)
          ? null
          : n.ios_executables_truncated(count: count, total: total),
      'ios.macho.no_content' => n.ios_macho_no_content,
      'ios.macho.truncated' => n.ios_macho_truncated,
      'ios.native_symbols.no_symtab' => n.ios_native_symbols_no_symtab,
      'ios.native_symbols.unreadable' =>
        count == null ? null : n.ios_native_symbols_unreadable(count: count),
      'ios.native_symbols.stripped' => n.ios_native_symbols_stripped,
      'ios.signature.separate_step' => n.ios_signature_separate_step,
      _ => null,
    };
    return localized ?? entry.note;
  }

  /// 一条覆盖维度在界面上的单行呈现。
  ///
  /// 由 `AnalysisReport` 提供而不是写在页面里：状态文案、维度名、覆盖量的
  /// 拼法都只有这一份，界面与报告不会各自漂移。
  static String coverageEntryLine(CoverageEntry entry, Translations t) {
    final status = coverageStatusText(entry.status, t);
    final amount = entry.ratioText;
    final note = coverageNote(entry, t);
    return '$status  ${coverageDimensionLabel(entry.id, t)}'
        '${amount == null ? '' : '  $amount'}'
        '${note == null || note.isEmpty ? '' : '  —— $note'}';
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
          '| ${_escape(AnalysisDiagnosticText.text(diagnostic, t))} |');
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
    // 「说明」列走**共用**的呈现层：认得出 `diagnosticCode` 就本地化，
    // 否则退回英文原文。此前这里直接输出 `value.diagnostic`，
    // 中文报告里因此混进英文句子。
    final reason = FieldValueText.diagnostic(value, t) ?? '';
    sb.writeln('| ${_escape(label)} | ${_escape(cell)} '
        '| ${value.status.name} | ${value.source.name} '
        '| ${_escape(reason)} |');
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
  /// v4：B11 给 `findings[]` 补 `messageCode` / `recommendationCode` /
  ///     `relationshipCode` / `limitationCode`，给 `evidence[]` 补
  ///     `detailCode` / `locationCode`。**只增不改**：老消费者忽略新字段即可，
  ///     但「结构变了」这件事必须让脚本能判断出来。
  /// 报告结构版本。
  ///
  /// 5：新增 `fieldStatus` —— 逐字段的 status / source / diagnostic。
  /// 之前 JSON 里只有裸值，`absent` 与 `failed` 都只是 `null`，下游分不开。
  /// 6：`securitySummary.hasCoverageGaps` **改名为** `hasActualGaps`，并新增
  ///    `hasDeclaredLimitations` 与 `coverageGapCount`。旧字段恒为 true，
  ///    留着会让消费者继续误判；这是一次**破坏性**改名，所以必须升版本号。
  /// 7：新增 `platformFacts` —— 平台事实（组件、ABI、语言、密度、分包、ICP、
  ///    entitlements、URL scheme、嵌套 bundle…），每个字段自带 status / source。
  static const int reportSchemaVersion = 7;

  /// 一个字段的状态投影（JSON 用）。
  ///
  /// `status` 取 Dart 枚举名（camelCase），与 findings 里的 severity /
  /// confidence 一致 —— 消费者只需要一套命名。
  static Map<String, dynamic> _fieldStatus(FieldValue<Object?> value) => {
        'status': value.status.name,
        'source': value.source.name,
        if (FieldValueText.rawDiagnostic(value) case final d?) 'diagnostic': d,
        if (value.diagnosticCode != null)
          'diagnosticCode': value.diagnosticCode,
      };

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
                  'detail': e.detail,
                  // 与 findings 的 `*Code` 同构：程序按 code 取本地化文案，
                  // `location` / `detail` 是英文回退。
                  'locationCode': e.locationCode,
                  'detailCode': e.detailCode,
                },
            ],
            'dataSource': f.dataSource,
            'dataTransform': f.dataTransform,
            'dataSink': f.dataSink,
            'relationship': f.relationship,
            'limitation': f.limitation,
            'messageCode': f.messageCode,
            'recommendationCode': f.recommendationCode,
            'relationshipCode': f.relationshipCode,
            'limitationCode': f.limitationCode,
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

      // 逐字段的**状态**。Markdown 的表格里每行都有 status / source，
      // 而 JSON 此前只有裸值 —— 于是「应用确实没声明」（absent）与
      // 「我们没读到 / 读失败」（failed / wrongType / notRequested）
      // 在 JSON 里都只是一个 `null`，下游无从区分。
      //
      // 只覆盖 JSON 里**以裸值出现**的那些字段：值在 `inputArtifact` /
      // `application` 里，状态在这里，按同名 key 对齐。
      'fieldStatus': {
        'fileName': _fieldStatus(result.fileName),
        'sizeBytes': _fieldStatus(result.fileSize),
        'sha256': _fieldStatus(result.sha256),
        if (!securityOnly) ...{
          'appName': _fieldStatus(result.appName),
          'packageId': _fieldStatus(result.packageId),
          'version': _fieldStatus(result.version),
          'buildNumber': _fieldStatus(result.buildNumber),
          if (result.android?.permissions case final p?)
            'permissions': _fieldStatus(p),
        },
      },

      // 「仅安全检测」范围下，这些与安全无关的块整体不输出 ——
      // 保留了就不是「仅安全」了。
      // 平台事实（minSdk / 组件 / ABI / 语言 / 密度 / 分包 / ICP / entitlements
      // / URL scheme / 嵌套 bundle …）。此前 JSON 里**一个都没有** ——
      // 界面看得到、导出看不到。每个字段就地带 status / source。
      if (!securityOnly) 'platformFacts': result.toJson()['platformFacts'],

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
          'permissions': result.android?.permissions.value ?? const <String>[],
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
          // 签名材料的**静态**概况：密封清单条目数与证书链公开字段。
          // 与 codesign 的结论并列而不是合并 —— 材料存在 ≠ 签名有效。
          if (result.ios?.signatureMaterials case final m?) ...{
            'hasCodeSignatureDirectory': m.hasCodeSignatureDirectory,
            'codeSignatureEntries': m.codeSignatureEntries,
            if (m.codeResources case final cr?)
              'codeResources': {
                'sealedFileCount': cr.sealedFileCount,
                'ruleCount': cr.ruleCount,
                'isV2': cr.isV2,
                'parsed': cr.isParsed,
                if (cr.parseFailure != null) 'parseFailure': cr.parseFailure,
              },
            if (m.certificateChain case final chain?)
              'certificates': [
                for (final certificate in chain.certificates)
                  {
                    'subjectCommonName': certificate.subjectCommonName,
                    'issuerCommonName': certificate.issuerCommonName,
                    'notBefore':
                        certificate.notBefore?.toUtc().toIso8601String(),
                    'notAfter': certificate.notAfter?.toUtc().toIso8601String(),
                    'serialNumber': certificate.serialNumberHex,
                    'issuerLooksLikeApple': certificate.issuerLooksLikeApple,
                  },
              ],
          },
        },
      },

      'securitySummary': security == null
          ? null
          : {
              'engineVersion': security.engineVersion,
              'rulesVersion': security.rulesVersion,
              // **两个信号分开给**。此前只有一个 `hasCoverageGaps`，它把
              // 「引擎无条件声明的方法论局限」也算进来，于是恒为 true ——
              // 消费者据此判断「这份结论可不可信」会永远得到「不可信」。
              // `hasActualGaps` 只看结构化覆盖与 UNKNOWN 级发现。
              'hasActualGaps': security.hasActualGaps,
              'hasDeclaredLimitations': security.hasDeclaredLimitations,
              'coverageGapCount': security.coverageGapCount,
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

      // 分包一致性。`null` 表示**没查**（单 APK 或本次未做这项检查）——
      // 与「查了没问题」（对象存在且 issues 为空）必须分得开。
      // 消费方读 `isFullyChecked` 判断结论是否覆盖全部分包。
      if (!securityOnly)
        'splitConsistency': switch (result.splitConsistency) {
          null => null,
          final s => {
              'checkedCount': s.checkedCount,
              'totalCount': s.totalCount,
              'isFullyChecked': s.isFullyChecked,
              'uncheckedCount': s.uncheckedCount,
              'issues': s.issues,
            },
        },

      'findings': findings,

      // 安全引擎视角的覆盖情况。      //
      // `entries` 是**结构化**的逐维度状态（稳定 id + 可判定状态）；
      // `limitations` 是给人读的句子。两者都在：程序用前者，
      // 人读后者，且不必从文本里反推状态。
      'coverage': {
        // 与 `securitySummary.hasActualGaps` 同一个判据（结构化覆盖 + UNKNOWN）。
        // `security == null` 表示**本次没做安全分析**，此时「有没有缺口」未知，
        // 给 `true` 而不是 `false` —— 把「没查」说成「没缺口」是更危险的方向。
        'hasGaps': security?.hasActualGaps ?? true,
        'entries': [
          for (final entry
              in security?.coverage.entries ?? const <CoverageEntry>[])
            {
              'id': entry.id,
              'status': entry.status.name,
              'covered': entry.covered,
              'limit': entry.limit,
              // 程序读 code（稳定），人读 note（英文回退）。两者都在，
              // 消费方不必从本地化文本里反推「这是哪一类缺口」。
              'noteCode': entry.noteCode,
              'noteArgs': entry.noteArgs,
              'note': entry.note,
            },
        ],
        // JSON 里仍是**一串给人读的句子**（英文回退），schema 不变 ——
        // 机器可读的结构化覆盖在 `coverage` 里，那里有稳定 id。
        'limitations': security?.limitations.map((l) => l.fallback).toList() ??
            const <String>[],
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
