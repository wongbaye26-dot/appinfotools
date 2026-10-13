import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/diagnostic.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ApkParseStage, ArchiveOpenResult, ComponentType;

/// 详情页的纯文本渲染。
///
/// 这些逻辑原先散在 `_APKInfoPageState` 的私有方法里，只能靠 widget 测试
/// 间接覆盖。抽成顶层函数后可以直接单测 —— 它们本来就是纯字符串拼装，
/// 不需要 widget 树，也不该需要。
///
/// 所有方法都显式接收 [Translations]，不读全局 `t`，这样测试可以固定语言。
class DetailRenderer {
  DetailRenderer._();

  /// 容器打开失败原因的本地化文案。
  ///
  /// 四种原因对用户的含义完全不同，不能统一退化成「解析失败」；
  /// 其中 [ArchiveOpenResult.resourceBudgetExceeded] 是**安全拒绝**，
  /// 必须让用户看到真实原因。
  static String openFailure(ArchiveOpenResult result, Translations t) {
    return switch (result) {
      ArchiveOpenResult.notArchive => t.parse.open_failure_not_archive,
      ArchiveOpenResult.corrupt => t.parse.open_failure_corrupt,
      ArchiveOpenResult.resourceBudgetExceeded => t.parse.open_failure_budget,
      ArchiveOpenResult.ioError => t.parse.open_failure_io,
      ArchiveOpenResult.ok => t.parse.parse_apk_info_fail,
    };
  }

  /// 解析阶段的本地化文案。
  ///
  /// [ApkParseStage.done] 复用通用的「解析中…」：它只会出现一瞬，
  /// 紧接着解析就结束了。
  static String parseStageLabel(ApkParseStage stage, Translations t) {
    return switch (stage) {
      ApkParseStage.openContainer => t.parse.stage_open_container,
      ApkParseStage.manifest => t.parse.stage_manifest,
      ApkParseStage.resources => t.parse.stage_resources,
      ApkParseStage.nativeLibraries => t.parse.stage_native_libraries,
      ApkParseStage.done => t.parse.parsing,
    };
  }

  /// 签名状态的本地化标签。
  ///
  /// 关键在于**不能把「工具不可用」说成「验证失败」**—— 那会把没装
  /// Android SDK 的机器误报成恶意应用；同样也不能把「结果未知」说成「通过」，
  /// 那会让用户以为已经验证过了。
  static String signatureStatusLabel(SignatureStatus status, Translations t) {
    return switch (status) {
      SignatureStatus.verified => t.signature.status_verified,
      SignatureStatus.verificationFailed => t.signature.status_failed,
      SignatureStatus.toolUnavailable => t.signature.status_tool_unavailable,
      SignatureStatus.unknown => t.signature.status_unknown,
    };
  }

  /// 把签名分析结果渲染为多行文本。
  static String signature(SignatureAnalysis? analysis, Translations t) {
    if (analysis == null) return '';

    final sb = StringBuffer()
      ..writeln(signatureStatusLabel(analysis.status, t));

    if (analysis.status == SignatureStatus.toolUnavailable) {
      sb.writeln(t.signature.tool_hint);
    }

    if (analysis.verifiedSchemes.isNotEmpty) {
      final schemes = analysis.verifiedSchemes.toList()..sort();
      sb.writeln('${t.signature.schemes}: ${schemes.join(', ')}');
    }

    for (final signer in analysis.signers) {
      if (signer.isEmpty) continue;
      sb.writeln('');
      sb.writeln(t.signature.signer(index: signer.index));
      if (signer.subjectDn != null) {
        sb.writeln('  ${t.signature.subject}: ${signer.subjectDn}');
      }
      if (signer.sha256Digest != null) {
        sb.writeln('  ${t.signature.sha256}: ${signer.sha256Digest}');
      }
      if (signer.sha1Digest != null) {
        sb.writeln('  ${t.signature.sha1}: ${signer.sha1Digest}');
      }
      if (signer.keyAlgorithm != null) {
        final bits = signer.keySizeBits;
        final suffix =
            bits == null ? '' : ' (${t.signature.key_size_bits(bits: bits)})';
        sb.writeln(
            '  ${t.signature.key_algorithm}: ${signer.keyAlgorithm}$suffix');
      }
      if (signer.validity != null) {
        sb.writeln('  ${t.signature.validity}: ${signer.validity}');
      }
    }

    // 没有结论时把工具的原始输出一并给出 —— 否则用户无从判断为什么没有结论。
    if (!analysis.status.hasConclusiveResult) {
      final raw = analysis.rawOutput;
      if (raw.isNotEmpty) {
        sb.writeln('');
        sb.writeln('${t.signature.diagnostics}:');
        sb.writeln(raw);
      }
    }

    return sb.toString().trimRight();
  }

  /// 解析诊断区的完整内容：加固线索 + 诊断记录。
  ///
  /// 两者合成一个区块，因为它们回答的是同一个问题 ——「这次解析有没有
  /// 值得注意的地方」。没有内容时返回空串，调用方据此隐藏整张卡片。
  static String analysisNotes(PackageAnalysisResult? analysis, Translations t) {
    if (analysis == null) return '';

    final sections = <String>[
      hardening(analysis.android?.hardeningHints ?? const [], t),
      diagnostics(analysis.diagnostics, t),
    ].where((s) => s.isNotEmpty).toList();

    return sections.join('\n\n');
  }

  /// 渲染加固线索。
  ///
  /// 线索名直接用枚举名（`dexHeaderNotStandard` 等）：它们是技术标识符，
  /// 强行翻成自然语言反而更难与代码、日志对照。置信度与证据都保留 ——
  /// 「可能被加固」这句话必须能解释清楚是**因为看到了什么**。
  static String hardening(List<HardeningHint> hints, Translations t) {
    if (hints.isEmpty) return '';

    final sb = StringBuffer()..writeln(t.apk_info.hardening_summary);
    for (final hint in hints) {
      final label = hint.confidence == HintConfidence.strong
          ? t.apk_info.confidence_strong
          : t.apk_info.confidence_weak;
      sb.writeln('  ${hint.signal.name} [$label]  ${hint.evidence}');
    }
    return sb.toString().trimRight();
  }

  /// 渲染诊断记录。
  ///
  /// 保留 `code`：它是稳定的机器可读标识，便于把用户反馈直接对上代码位置。
  static String diagnostics(
      List<AnalysisDiagnostic> diagnostics, Translations t) {
    if (diagnostics.isEmpty) return '';
    return diagnostics
        .map((d) => '[${d.severity.name}] ${d.code}: ${d.message}')
        .join('\n');
  }

  /// 把组件列表按类型分组渲染为多行文本。
  ///
  /// 分组标题直接用 manifest 的元素名（activity / service / receiver /
  /// provider）：这些是 Android 平台术语，各语言的技术文档普遍也不翻译，
  /// 强行本地化反而更难与 manifest 对照。
  static String components(ApkInfo? apkInfo, Translations t) {
    if (apkInfo == null) return '';

    final sb = StringBuffer();

    // 只在确实声明了 debuggable=true 时提示 —— 这是值得注意的状态，
    // false / 未声明都是常态，逐条展示只会变成噪声。
    if (apkInfo.applicationDebuggable == true) {
      sb.writeln('[${t.apk_info.debuggable}]');
    }

    final byType = <ComponentType, List<AndroidComponent>>{};
    for (final component in apkInfo.components) {
      byType.putIfAbsent(component.type, () => []).add(component);
    }

    for (final type in ComponentType.values) {
      final list = byType[type];
      if (list == null || list.isEmpty) continue;
      sb.writeln('${type.elementName} (${list.length})');
      for (final component in list) {
        sb.writeln('  ${componentLine(component, t)}');
      }
    }

    return sb.toString().trimRight();
  }

  /// 单行组件描述：`类名  [导出状态, 权限]`。
  ///
  /// 导出状态区分「显式声明」与「按平台默认规则推导」—— 这两者在分析
  /// 组件暴露面时含义不同，不能混为一谈。
  static String componentLine(AndroidComponent component, Translations t) {
    final flags = <String>[];

    if (component.exported != null) {
      flags.add(
          component.exported! ? t.apk_info.exported : t.apk_info.not_exported);
    } else if (component.effectivelyExported) {
      flags.add(t.apk_info.exported_by_default);
    }
    if (component.permission != null) {
      flags.add('${t.apk_info.component_permission}=${component.permission}');
    }
    if (component.authorities != null) {
      flags.add('authorities=${component.authorities}');
    }

    final name = component.name ?? t.apk_info.component_unnamed;
    return flags.isEmpty ? name : '$name  [${flags.join(', ')}]';
  }
}
