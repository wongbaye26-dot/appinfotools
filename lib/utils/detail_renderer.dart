import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_diagnostic_text.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/format.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show
        AndroidComponent,
        ApkParseStage,
        ArchiveOpenResult,
        ComponentType,
        ContainerStructure;
import 'package:ipa_parser/ipa_parser.dart'
    show
        IosAuthorizationVerdict,
        IosBundleKind,
        IosIconCandidate,
        IosIconResolution,
        IosIconSource,
        IpaContainer,
        MachOFile;

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
  ///
  /// [detail] 是命中的**具体条目与字节数**（英文，来自
  /// `ZipBudgetViolation.describe()`）。有它就追加一行「详情」——
  /// 「归档超出安全解压上限」本身回答不了「是哪个条目、超了多少」，
  /// 而那正是用户唯一能用来判断「这是不是我这个包的问题」的信息。
  static String openFailure(
    ArchiveOpenResult result,
    Translations t, {
    String? detail,
  }) {
    final summary = switch (result) {
      ArchiveOpenResult.notArchive => t.parse.open_failure_not_archive,
      ArchiveOpenResult.corrupt => t.parse.open_failure_corrupt,
      ArchiveOpenResult.resourceBudgetExceeded => t.parse.open_failure_budget,
      ArchiveOpenResult.ioError => t.parse.open_failure_io,
      ArchiveOpenResult.ok => t.parse.parse_apk_info_fail,
    };
    if (detail == null || detail.isEmpty) return summary;
    return '$summary\n${t.parse.open_failure_detail(detail: detail)}';
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

  /// 平台中立的签名结论文案。
  ///
  /// 与 [signatureStatusLabel] 的区别：[SignatureVerdict] 只有四态且不含
  /// 平台细节，供 Android / iOS 共用；四态到文案的映射**必须一致** ——
  /// 用户在两个平台上看到的「无法确认」必须是同一句话。
  static String signatureVerdictLabel(
      SignatureVerdict verdict, Translations t) {
    return switch (verdict) {
      SignatureVerdict.verified => t.signature.status_verified,
      SignatureVerdict.rejected => t.signature.status_failed,
      SignatureVerdict.inconclusive => t.signature.status_unknown,
      // `notChecked` 在实践里**只出现在 Android**：iOS 侧 `verdictFromIos`
      // 对「没跑 codesign」返回 `inconclusive`，不会返回 `notChecked`。
      // 此前这里复用 `t.ios_info.codesign_not_run`（「非 macOS、设置中已关闭，
      // 或解包失败」），于是 Android 包的结论行会写着「非 macOS」——
      // 一句话里三个原因，两个与 Android 无关。
      SignatureVerdict.notChecked => t.signature.status_not_checked,
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

  /// 渲染容器结构概览（DEX 数量、原生库、ABI、顶层目录）。
  ///
  /// 顶层目录只列体积最大的前几个：目录可能有几十个，全列出来在详情页里
  /// 只会变成噪声。
  static String structure(ContainerStructure? structure, Translations t) {
    if (structure == null || structure.fileEntryCount == 0) return '';

    final sb = StringBuffer()
      ..writeln('${t.apk_info.structure_entries}: '
          '${structure.fileEntryCount} '
          '(${formatFileSize(structure.totalUncompressedBytes)})');

    if (structure.dexFileCount > 0) {
      sb.writeln('${t.apk_info.structure_dex}: ${structure.dexFileCount}');
    }
    if (structure.abis.isNotEmpty) {
      sb.writeln('${t.apk_info.abi}: ${structure.abis.join(', ')}');
    }
    if (structure.nativeLibraryCount > 0) {
      sb.writeln(
          '${t.apk_info.structure_native_libs}: ${structure.nativeLibraryCount}');
    }

    if (structure.topLevelDirectories.isNotEmpty) {
      sb.writeln(t.apk_info.structure_directories);
      for (final entry in structure.topDirectoriesBySize()) {
        sb.writeln('  ${entry.key}/  '
            '${formatFileSize(entry.value.uncompressedBytes)}  '
            '(${t.apk_info.structure_file_count(count: entry.value.fileCount)})');
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
    // 走共用的呈现层：认得出 code 就本地化（模板 + messageArgs），
    // 否则退回 message 的英文原文。此前这里直接输出 `d.message`。
    return diagnostics.map((d) => AnalysisDiagnosticText.line(d, t)).join('\n');
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

  // ---------------------------------------------------------------------------
  // iOS
  // ---------------------------------------------------------------------------

  /// IPA 解析阶段的本地化文案。
  static String ipaParseStageLabel(IpaParseStage stage, Translations t) {
    return switch (stage) {
      IpaParseStage.openContainer => t.parse.stage_open_container,
      IpaParseStage.container => t.ios_info.container_section,
      IpaParseStage.infoPlist => t.parse.stage_manifest,
      IpaParseStage.icon => t.ios_info.icon_section,
      IpaParseStage.macho => t.ios_info.binary_section,
      IpaParseStage.signature => t.ios_info.signature_section,
      IpaParseStage.done => t.parse.parsing,
    };
  }

  /// 设备类型（`UIDeviceFamily`）。
  ///
  /// 未知取值**原样给出数字**，不映射到最近的一档 —— `UIDeviceFamily` 的含义
  /// 由 Apple 定义，猜错会让用户以为这个包支持某类设备。
  static String deviceFamily(List<int>? families, Translations t) {
    if (families == null || families.isEmpty) return '';
    return families
        .map((code) => switch (code) {
              1 => t.ios_info.device_iphone,
              2 => t.ios_info.device_ipad,
              3 => t.ios_info.device_tv,
              4 => t.ios_info.device_watch,
              _ => t.ios_info.device_unknown(code: code),
            })
        .join(', ');
  }

  /// 可执行文件的架构与格式。
  static String iosExecutable(MachOFile? macho, Translations t) {
    if (macho == null) return '';
    if (!macho.isMachO) return '${t.ios_info.macho_format}: -';

    final sb = StringBuffer();
    sb.writeln('${t.ios_info.macho_format}: ${macho.isFat ? 'fat' : 'thin'}');
    sb.writeln(
        '${t.ios_info.architectures}: ${macho.architectureNames.join(', ')}');

    final primary = macho.primary!;
    sb.writeln('${t.ios_info.macho_format}: ${primary.fileType.name}');
    if (primary.platformName != null) {
      sb.writeln('${t.ios_info.target_platform}: ${primary.platformName}');
    }
    if (primary.minimumOsVersionText != null) {
      sb.writeln('${t.ios_info.macho_min_os}: ${primary.minimumOsVersionText}');
    }
    if (primary.uuid != null) {
      sb.writeln('${t.ios_info.uuid}: ${primary.uuid}');
    }
    if (macho.allLinkedLibraries.isNotEmpty) {
      sb.writeln('${t.ios_info.linked_libraries} '
          '(${macho.allLinkedLibraries.length}):');
      for (final lib in macho.allLinkedLibraries) {
        sb.writeln('  $lib');
      }
    }
    if (primary.rpaths.isNotEmpty) {
      sb.writeln('${t.ios_info.rpaths}:');
      for (final rpath in primary.rpaths) {
        sb.writeln('  $rpath');
      }
    }
    return sb.toString().trimRight();
  }

  /// 嵌套 bundle 的二进制清单。
  static String iosNestedBinaries(
      List<IosNestedBinary> binaries, Translations t) {
    if (binaries.isEmpty) return '';

    final sb = StringBuffer();
    for (final binary in binaries) {
      final kind = bundleKindLabel(binary.kind, t);
      final arch =
          binary.architectures.isEmpty ? '?' : binary.architectures.join(', ');
      sb.writeln('${binary.bundlePath}  [$kind]  $arch');
      // 解析失败时给出原因，而不是显示成「没有架构」。
      final failure = binary.failureReason;
      if (failure != null) {
        sb.writeln('  ! $failure');
      }
    }
    return sb.toString().trimRight();
  }

  /// bundle 种类的本地化名。
  static String bundleKindLabel(IosBundleKind kind, Translations t) =>
      switch (kind) {
        IosBundleKind.mainApp => t.ios_info.bundle_kind_main_app,
        IosBundleKind.appExtension => t.ios_info.bundle_kind_app_extension,
        IosBundleKind.watchApp => t.ios_info.bundle_kind_watch_app,
        IosBundleKind.nestedApp => t.ios_info.bundle_kind_nested_app,
        IosBundleKind.framework => t.ios_info.bundle_kind_framework,
      };

  /// 容器结构概览。
  static String iosContainer(IpaContainer container, Translations t) {
    if (container.bundles.isEmpty) return '';

    final sb = StringBuffer()
      ..writeln('${t.ios_info.bundles}: ${container.bundles.length}')
      // `structure_file_count` 是带 `{count}` 的**方法**，不是 getter。漏传参数
      // 不会编译报错（函数对象本身就是个合法值），但会把函数本身插进字符串，
      // 界面上就出现 `Closure: (required Ordered object) => ...` —— 这一条
      // 曾经真的出现在 iOS 的「容器」卡片里。
      ..writeln('${t.apk_info.structure_entries}: '
          '${container.fileEntryCount}');

    for (final bundle in container.bundles) {
      sb.writeln('  ${bundle.path}  [${bundleKindLabel(bundle.kind, t)}]  '
          '${t.apk_info.structure_file_count(count: bundle.fileCount)}');
    }
    return sb.toString().trimRight();
  }

  /// 签名与授权。
  ///
  /// 这里最重要的约束是**不能把「有材料」说成「验证通过」**：
  /// 材料那一节只陈述观察到的事实，结论只来自 [codeSign]。
  static String iosSignature(IosPackageInfo ios, Translations t) {
    final sb = StringBuffer();

    // 1. 材料（事实）
    final materials = ios.signatureMaterials;
    if (materials != null) {
      sb.writeln('${t.ios_info.materials}:');

      final presence = materials.hasCodeSignatureDirectory
          ? t.ios_info.presence_yes
          : t.ios_info.presence_no;
      // 条目名一并列出：只有目录、没有 CodeResources 是值得注意的情况。
      final entries = materials.codeSignatureEntries.isEmpty
          ? ''
          : ' (${materials.codeSignatureEntries.join(', ')})';
      sb.writeln('  ${t.ios_info.code_signature_dir}: $presence$entries');

      final provision = materials.hasEmbeddedProvision
          ? t.ios_info.presence_yes
          : t.ios_info.presence_no;
      sb.writeln('  ${t.ios_info.embedded_provision}: $provision');
    }

    // 密封清单：**只数条目**。重算哈希并与签名比对属于验证，本工具不做。
    final codeResources = materials?.codeResources;
    if (codeResources != null) {
      if (!codeResources.isParsed) {
        sb.writeln('  ${t.ios_info.code_resources}: '
            '${t.ios_info.code_resources_failed(reason: codeResources.parseFailure ?? '')}');
      } else {
        final parts = <String>[
          t.ios_info
              .code_resources_sealed(count: codeResources.sealedFileCount),
          t.ios_info.code_resources_rules(count: codeResources.ruleCount),
          if (codeResources.isV2) t.ios_info.code_resources_v2,
        ];
        sb.writeln('  ${t.ios_info.code_resources}: ${parts.join(' · ')}');
      }
    }

    // 证书链：**静态材料**。这里说的「签发者」是证书自称的，不是验证结论。
    final chain = materials?.certificateChain;
    if (chain != null && chain.certificates.isNotEmpty) {
      sb.writeln('  ${t.ios_info.certificate_chain}: '
          '${t.ios_info.certificate_count(count: chain.certificates.length)}');
      for (final certificate in chain.certificates) {
        sb.writeln('    ${t.ios_info.certificate_entry(
          subject: certificate.subjectCommonName ?? '-',
          issuer: certificate.issuerCommonName ?? '-',
        )}');
        final notAfter = certificate.notAfter;
        if (notAfter != null) {
          sb.writeln('      ${t.ios_info.certificate_valid_until(
            date: notAfter.toIso8601String().split('T').first,
          )}');
        }
      }
      sb.writeln('    ${t.ios_info.certificate_material_note}');
    }

    // 2. 描述文件字段
    final profile = materials?.profile;
    if (profile != null && profile.hasValue) {
      final value = profile.value!;
      sb.writeln('');
      sb.writeln('${t.ios_info.embedded_provision}:');
      if (value.name.value != null) {
        sb.writeln('  ${t.ios_info.profile_name}: ${value.name.value}');
      }
      if (value.teamIdentifiers.value != null) {
        sb.writeln('  ${t.ios_info.profile_team}: '
            '${value.teamIdentifiers.value!.join(', ')}');
      }
      if (value.applicationIdentifier.value != null) {
        sb.writeln('  application-identifier: '
            '${value.applicationIdentifier.value}');
      }
      final expiry = value.expirationDate.value;
      if (expiry != null) {
        // 用**当前时间**判断是否过期：这是用户唯一关心的相对结论。
        final expired = value.isExpiredAt(DateTime.now()) ?? false;
        sb.writeln('  ${t.ios_info.profile_expiry}: '
            '${expiry.toIso8601String()} '
            '(${expired ? t.ios_info.profile_expired : t.ios_info.profile_valid})');
      } else {
        sb.writeln(
            '  ${t.ios_info.profile_expiry}: ${t.ios_info.profile_expiry_unknown}');
      }
    } else if (profile != null) {
      // 读不出来时说明原因，而不是显示成「没有描述文件」。
      sb.writeln('${t.ios_info.embedded_provision}: '
          '${profile.status.name}${profile.diagnostic == null ? '' : ' — ${profile.diagnostic}'}');
    }

    // 3. 授权项
    final codeSign = ios.codeSign;
    if (codeSign?.info != null) {
      final info = codeSign!.info!;
      sb.writeln('');
      sb.writeln('${t.ios_info.entitlements}:');
      if (!info.entitlementsRead) {
        sb.writeln('  ${t.ios_info.entitlements_unreadable}');
      } else if (info.entitlements.isEmpty) {
        sb.writeln('  ${t.ios_info.entitlements_empty}');
      } else {
        for (final entitlement in info.entitlements) {
          sb.writeln('  ${entitlement.key} = ${entitlement.valueText}');
        }
      }
    } else if (profile != null && profile.value != null) {
      // codesign 没跑时退回静态提取到的授权项 —— 但要标明来源不同。
      final entitlements = profile.value!.entitlements;
      sb.writeln('');
      sb.writeln('${t.ios_info.entitlements} '
          '(${t.ios_info.embedded_provision}):');
      if (entitlements.isEmpty) {
        sb.writeln('  ${t.ios_info.entitlements_empty}');
      } else {
        for (final entitlement in entitlements) {
          sb.writeln('  ${entitlement.key} = ${entitlement.valueText}');
        }
      }
    }

    // 4. 授权比对
    final authorization = ios.authorization;
    if (authorization != null) {
      sb.writeln('');
      sb.writeln('${t.ios_info.authorization}: '
          '${authorizationVerdictLabel(authorization.verdict, t)}');
      if (authorization.note != null) {
        sb.writeln('  ${authorization.note}');
      }
    }

    return sb.toString().trimRight();
  }

  /// 图标候选与「为什么取不到」的清单。
  ///
  /// 与 Android 侧的区别：Android 的图标候选放在右键菜单里，iOS 没有对应入口，
  /// 因此这里把同样的信息直接渲染成文本卡片。**信息量必须一致** ——
  /// 「图标是哪个文件、多大、来自哪条声明、哪些取不到、为什么」缺一不可。
  static String iosIcon(IosIconResolution? resolution, Translations t) {
    if (resolution == null) return t.ios_info.icon_unavailable;

    final sb = StringBuffer();
    for (final candidate in resolution.candidates) {
      sb.writeln('${candidate.relativePath}  '
          '${_iconSize(candidate)}  '
          '[${_iconSourceLabel(candidate.source, t)}]');
      // 归档路径要给出：排查时要拿它去比对 ZIP 条目名，而相对路径不够。
      sb.writeln('  ${candidate.archivePath}');
    }

    for (final item in resolution.unresolved) {
      sb.writeln('${t.ios_info.icon_declared_unresolved}: ${item.declared}'
          '  [${_iconSourceLabel(item.source, t)}] — ${item.reason}');
    }

    if (sb.isEmpty) return t.ios_info.icon_unavailable;
    return sb.toString().trimRight();
  }

  /// 「152x152  31686 B」；尺寸读不出来时只给字节数。
  ///
  /// 尺寸读不出来本身是值得注意的（说明 IHDR 没被正确解析），因此不留空，
  /// 而是明确写出 `?`。
  static String _iconSize(IosIconCandidate candidate) {
    final width = candidate.pixelWidth;
    final height = candidate.pixelHeight;
    if (width == null || height == null) return '?x?  ${candidate.size} B';
    return '${width}x$height  ${candidate.size} B';
  }

  static String _iconSourceLabel(IosIconSource source, Translations t) =>
      switch (source) {
        IosIconSource.primaryIconFiles => t.ios_info.icon_source_primary,
        IosIconSource.alternateIconFiles => t.ios_info.icon_source_alternate,
        IosIconSource.primaryIconFilesIpad => t.ios_info.icon_source_ipad,
        IosIconSource.legacyIconFiles ||
        IosIconSource.legacyIconFile =>
          t.ios_info.icon_source_legacy,
        IosIconSource.assetCatalogName => t.ios_info.icon_source_asset_catalog,
      };

  /// 授权比对结论的本地化标签。
  static String authorizationVerdictLabel(
          IosAuthorizationVerdict verdict, Translations t) =>
      switch (verdict) {
        IosAuthorizationVerdict.matches => t.ios_info.authorization_matches,
        IosAuthorizationVerdict.wildcardMatch =>
          t.ios_info.authorization_wildcard,
        IosAuthorizationVerdict.mismatch => t.ios_info.authorization_mismatch,
        IosAuthorizationVerdict.incomparable =>
          t.ios_info.authorization_incomparable,
      };

  /// `codesign` 的验证结论与描述性信息。
  ///
  /// [codeSign] 为 `null` 表示**没做**这项检查 —— 必须如实说「未执行」，
  /// 而不是显示成「无法确认」或干脆留空（留空会被读成「没问题」）。
  ///
  /// 输出自带表头，适合独立成段使用。详情页把表头放进了卡片标题，用的是
  /// [iosCodeSignBody]。
  static String iosCodeSign(IosCodeSignResult? codeSign, Translations t) =>
      _iosCodeSign(codeSign, t, header: t.ios_info.codesign_section);

  /// 同 [iosCodeSign]，但**不带**表头。
  ///
  /// 详情页把「codesign 验证」渲染成卡片标题，正文再重复一遍表头就会出现
  /// 「codesign 验证   codesign 验证: 验证通过」这种叠字。
  static String iosCodeSignBody(IosCodeSignResult? codeSign, Translations t) =>
      _iosCodeSign(codeSign, t, header: null);

  /// 两个入口的共用实现。
  ///
  /// [header] 为 `null` 表示调用方已经自己给出了表头。
  static String _iosCodeSign(
    IosCodeSignResult? codeSign,
    Translations t, {
    required String? header,
  }) {
    if (codeSign == null) {
      final reason = t.ios_info.codesign_not_run;
      return header == null ? reason : '$header: $reason';
    }

    final sb = StringBuffer();
    final status = signatureStatusLabel(codeSign.status, t);
    sb.writeln(header == null ? status : '$header: $status');

    if (codeSign.status == SignatureStatus.toolUnavailable) {
      sb.writeln(t.signature.tool_hint);
    }

    final info = codeSign.info;
    if (info != null) {
      if (info.identifier != null) {
        sb.writeln('  ${t.ios_info.codesign_identifier}: ${info.identifier}');
      }
      if (info.teamIdentifier != null) {
        sb.writeln('  ${t.ios_info.codesign_team}: ${info.teamIdentifier}');
      }
      if (info.signatureKind != null) {
        sb.writeln('  ${t.ios_info.codesign_signature_kind}: '
            '${info.signatureKind}');
      }
      if (info.cdHash != null) {
        sb.writeln('  ${t.ios_info.codesign_cdhash}: ${info.cdHash}');
      }
      if (info.sealedResources != null) {
        sb.writeln('  ${t.ios_info.codesign_sealed_resources}: '
            '${info.sealedResources}');
      }
      if (info.authorities.isNotEmpty) {
        sb.writeln('  ${t.ios_info.codesign_authorities}:');
        for (final authority in info.authorities) {
          sb.writeln('    $authority');
        }
      }
    }

    // 验证失败时先说**这意味着什么**，再给原始输出。
    //
    // 只有原始输出的话，用户看到的是一句英文（`invalid signature (code or
    // signature have been modified)`），既不知道该怀疑什么，也不知道这是不是
    // 工具的误判。两句话按 codesign 的措辞分岔：
    //   - 代码哈希不符 → 二进制被改（砸壳 / 重打包最常见，签名失效是必然）；
    //   - 其它（资源封印不符等）→ 包内文件被增删。
    if (codeSign.status == SignatureStatus.verificationFailed) {
      sb.writeln('');
      sb.writeln(
        codeSign.rawOutput.contains('code or signature have been modified')
            ? t.signature.failed_code_modified_hint
            : t.signature.failed_generic_hint,
      );
    }

    // 没有验证通过时把工具的原始输出一并给出。
    //
    // 判据是「不是 verified」而不是「没有明确结论」：验证**失败**时用户最
    // 需要的恰恰是具体原因，而那几行只出现在 codesign 的输出里。
    if (codeSign.status != SignatureStatus.verified) {
      final raw = codeSign.rawOutput;
      if (raw.isNotEmpty) {
        sb.writeln('');
        sb.writeln('${t.signature.diagnostics}:');
        sb.writeln(raw);
      }
    }

    return sb.toString().trimRight();
  }
}
