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
      'android.arsc' => d.android_arsc,
      'ios.infoPlist' => d.ios_infoPlist,
      'ios.usageDescriptions' => d.ios_usageDescriptions,
      'ios.privacyManifest' => d.ios_privacyManifest,
      'ios.executables' => d.ios_executables,
      'ios.macho.strings' => d.ios_macho_strings,
      'ios.nativeSymbols' => d.ios_nativeSymbols,
      'ios.signature' => d.ios_signature,
      _ => id,
    };
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
      'ios.info_plist.unparsed' => n.ios_info_plist_unparsed,
      'ios.usage_descriptions.not_read' => n.ios_usage_descriptions_not_read,
      'ios.privacy_manifest.absent' => n.ios_privacy_manifest_absent,
      'ios.executables.unscanned' =>
        count == null ? null : n.ios_executables_unscanned(count: count),
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
        'hasGaps': security?.hasCoverageGaps ?? true,
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
