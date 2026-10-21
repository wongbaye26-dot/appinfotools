import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';

/// iOS 侧的**越狱 / 内核漏洞利用组件**识别。
///
/// ## 为什么需要它
///
/// 真实样本（一个侧载工具箱）里有 14 个嵌套可执行文件：
/// `kfd`、`badRecovery`、`multicast_bytecopy`、`weightBufs`、`dmaFail`、
/// `libchoma`、`libjailbreak`、`libxpf`、`libgrabkernel2`…… 这些是**公开的
/// 内核漏洞利用**与签名绕过库。正常应用不会包含它们；包含它们意味着这个包
/// 能在设备上取得远超沙箱的能力。
///
/// 之前审计只按「隐私 API / 权限 / 符号」看，对这类组件完全无感 —— 一个
/// 捆绑了内核 exploit 的包会被报成「没什么问题」。
///
/// ## 判据：组件名
///
/// 只看**路径段**与**二进制里的 dylib 路径**，不做内容分析：
/// - 路径段：`Payload/OPEN.app/Frameworks/kfd.framework/kfd` → `kfd`；
/// - 字符串：主二进制里 `@rpath/libjailbreak.dylib` 这类加载路径。
///
/// 组件名是唯一的（`multicast_bytecopy`、`badRecovery` 这种词不会自然出现），
/// 所以这条路**误报率极低**；代价是改名的私有分支看不到 —— 写进局限。
///
/// ## 分级
///
/// - 出现**内核漏洞利用**（`kfd` / `weightBufs` / `multicast_bytecopy` /
///   `dmaFail` / `badRecovery` / `libgrabkernel` / `choma`…）→ **P1**；
/// - 只有越狱基础设施（`libjailbreak` / `Substrate` / `TrollStore` /
///   `RootHide` / `ElleKit`…）→ **P2**。
///
/// P1 的依据：内核读写等于拿到设备完全控制权，这不是「配置问题」的量级。
class IosJailbreakAudit {
  IosJailbreakAudit._();

  /// 内核漏洞利用 / 签名绕过组件（P1）。
  static const Set<String> exploitComponents = {
    'kfd',
    'badrecovery',
    'multicast_bytecopy',
    'weightbufs',
    'dmafail',
    'libgrabkernel',
    'libgrabkernel2',
    'physpuppet',
    'landa',
    'macdirtycow',
    'coretrust',
    'choma',
    'libchoma',
  };

  /// 越狱基础设施（P2）：注入、hook、包管理器、隐藏。
  static const Set<String> jailbreakComponents = {
    'libjailbreak',
    'xpf',
    'libxpf',
    'roothide',
    'trollstore',
    'substitute',
    'ellekit',
    'mobilesubstrate',
    'cydia',
    'sileo',
    'zebra',
    'dopamine',
    'palera1n',
    'checkra1n',
    'unc0ver',
    'taurine',
    'libhooker',
    'bootstrap',
  };

  /// 只在**主二进制字符串**里找的长字面量（短名子在字符串里太容易误伤）。
  static const List<String> stringMarkers = [
    'libjailbreak',
    'libchoma',
    'mobilesubstrate',
    'multicast_bytecopy',
    'trollstore',
    'roothide',
    'ellekit',
  ];

  /// 从路径里取出「组件名」：去掉 `.framework` / `.dylib` / `.appex` 后缀。
  ///
  /// `Payload/X.app/Frameworks/kfd.framework/kfd` → `['payload', 'x',
  /// 'frameworks', 'kfd', 'kfd']`，调用方再逐段比对。
  static List<String> segmentsOf(String path) => [
        for (final raw in path.split('/'))
          if (raw.isNotEmpty)
            raw
                .toLowerCase()
                .replaceFirst(RegExp(r'\.(framework|dylib|appex|app)$'), ''),
      ];

  /// 返回命中的组件名（去重、稳定排序）。
  static List<String> matchComponents({
    required List<String> executablePaths,
    Uint8List? executableBytes,
  }) {
    final hits = <String>{};
    for (final path in executablePaths) {
      for (final segment in segmentsOf(path)) {
        if (exploitComponents.contains(segment) ||
            jailbreakComponents.contains(segment)) {
          hits.add(segment);
        }
      }
    }
    // 注入的 dylib 可能不在包里（`@rpath/...` 只是字符串），所以主二进制也扫。
    if (executableBytes != null) {
      for (final text in AsciiStrings.extract(executableBytes)) {
        final lower = text.toLowerCase();
        for (final marker in stringMarkers) {
          if (lower.contains(marker)) hits.add(marker);
        }
      }
    }
    return hits.toList()..sort();
  }

  /// 产出发现项。没有命中时返回空列表。
  static List<SecurityFinding> audit({
    required List<String> executablePaths,
    Uint8List? executableBytes,
  }) {
    final components = matchComponents(
      executablePaths: executablePaths,
      executableBytes: executableBytes,
    );
    if (components.isEmpty) return const [];

    final hasExploit = components.any(exploitComponents.contains);
    return [
      SecurityFinding(
        ruleId: 'IOS-JAILBREAK-TOOLKIT',
        platform: SecurityPlatform.ios,
        category: SecurityCategory.other,
        severity: hasExploit ? SecuritySeverity.p1 : SecuritySeverity.p2,
        // 组件名是**确定的**：包里确实有这个文件。它是否被调用、被谁调用，
        // 静态分析看不到 —— 但「存在内核 exploit」这件事本身不需要推断。
        confidence: SecurityConfidence.confirmed,
        finding: 'This bundle ships known jailbreak / kernel-exploit '
            'components: ${components.join(', ')}. '
            '${hasExploit ? 'Kernel exploits give the code read/write access '
                'to the kernel — full control of the device. ' : ''}'
            'No App Store app bundles these.',
        messageCode: 'ios.jailbreak_toolkit',
        messageArgs: {
          'components': components,
          if (hasExploit) 'kernelExploit': true,
        },
        evidence: [
          for (final path in executablePaths)
            if (segmentsOf(path).any(components.contains))
              SecurityEvidence(
                source: SecurityEvidenceSource.zipEntry,
                location: path,
                detail: 'component: '
                    '${segmentsOf(path).where(components.contains).join(', ')}',
              ),
          for (final component in components)
            if (!executablePaths.any((p) => segmentsOf(p).contains(component)))
              SecurityEvidence(
                source: SecurityEvidenceSource.machoSymbol,
                location: 'main executable',
                detail: '$component referenced from the main binary',
              ),
        ],
        limitation: 'Detected by **component name** only (framework directory '
            'names and dylib paths). A privately rebuilt exploit with a '
            'different name, or one linked statically into the main binary '
            'with no residual strings, is not visible here. Absence of this '
            'finding does not prove the app is clean.',
        limitationCode: 'ios.jailbreak_toolkit.limitation',
        recommendation: 'Decide whether this is a tool you intentionally '
            'analysed. If it is an app from an unknown source, a bundled '
            'kernel exploit means it can take full control of the device — '
            'do not install it on a personal device.',
        recommendationCode: 'ios.jailbreak_toolkit.review',
      ),
    ];
  }
}
