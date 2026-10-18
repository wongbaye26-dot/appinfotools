// `res/xml/network_security_config.xml` 的解析。
//
// ## 为什么需要它
//
// AOSP `ApplicationInfo` 写得很清楚：**API 24 起，只要声明了
// `android:networkSecurityConfig`，`android:usesCleartextTraffic` 就不再生效**，
// 明文策略完全由这份配置决定。
//
// 所以只读 `usesCleartextTraffic` 回答不了「是否允许明文」。实测 5 个真实包里
// 4 个 `usesCleartextTraffic=true`，其中 3 个同时有 NSC —— 对这 3 个，
// 清单属性**不能作为证据**（平台根本不看它）。
//
// 但「属性被忽略」不等于「策略不成立」：展开那 3 份 NSC 后发现
// `base-config cleartextTrafficPermitted="true"`，它们确实允许明文。
// 所以正确做法既不是照抄清单属性（证据指向了不生效的地方），
// 也不是因为「属性无效」就不判定（那会把真发现吞掉）—— 而是**打开 NSC 看**。
//
// ## 判定规则（对齐平台实现）
//
// - `<base-config cleartextTrafficPermitted>`：全局默认。
//   未声明时，targetSdk >= 28 默认 **false**，否则默认 **true**。
// - `<domain-config cleartextTrafficPermitted>`：对其中 `<domain>` 列的域名覆盖。
//   未声明时沿用 base。
//
// 本工具只回答「**这个应用是否允许任何明文流量**」，因此：
// `allowsCleartext = base 允许 || 存在任意一个允许的 domain-config`。
//
// ## 边界（必须如实说明，不能假装知道）
//
// - 不判定 `<trust-anchors>`、`<pin-set>`、`<certificates>` —— 证书校验策略
//   与明文流量是两个维度。
// - `domain` 的文本能取到（`XmlElement.text`），但**不展开通配符匹配**，
//   只原样列出。
// - `debug-overrides` 不影响明文判定，忽略。

import 'dart:typed_data';

import '../binary_xml.dart';

/// 一条 `<domain-config>` 的明文策略。
class NscDomainRule {
  /// `<domain>` 里写的域名（原样，含可能的通配符）；取不到文本时为 `null`。
  final String? domain;

  /// `cleartextTrafficPermitted`；未声明时沿用 base，这里为 `null`。
  final bool? cleartextPermitted;

  /// `<domain includeSubdomains="true">`
  final bool includeSubdomains;

  const NscDomainRule({
    this.domain,
    this.cleartextPermitted,
    this.includeSubdomains = false,
  });

  @override
  String toString() => 'NscDomainRule($domain, permitted: $cleartextPermitted, '
      'subdomains: $includeSubdomains)';
}

/// `res/xml/network_security_config.xml` 的解析结果。
class NetworkSecurityConfigInfo {
  /// 资源在 APK 里的路径，例如 `res/xml/network_security_config.xml`。
  final String path;

  /// `<base-config cleartextTrafficPermitted>`；**未声明**为 `null`。
  ///
  /// 注意区分：`null` = 配置里没写（走平台默认），`false` = 显式禁止。
  final bool? baseCleartextPermitted;

  final List<NscDomainRule> domains;

  /// 解析失败的原因；`null` 表示解析成功。
  ///
  /// **失败不等于「没有明文流量」** —— 调用方必须把它当成「不知道」。
  final String? failure;

  const NetworkSecurityConfigInfo({
    required this.path,
    this.baseCleartextPermitted,
    this.domains = const [],
    this.failure,
  });

  bool get parsed => failure == null;

  /// 该配置是否允许**任何**明文流量。
  ///
  /// 解析失败时返回 `null` —— 「不知道」和「不允许」是两件事。
  bool? get allowsCleartext {
    if (!parsed) return null;
    if (baseCleartextPermitted == true) return true;
    for (final d in domains) {
      if (d.cleartextPermitted == true) return true;
    }
    // base 未声明时平台默认值取决于 targetSdk，这里无法单独判定，
    // 交给调用方结合 targetSdk 决定（见 [resolvedAllowsCleartext]）。
    if (baseCleartextPermitted == null && domains.isEmpty) return null;
    return false;
  }

  /// 结合 `targetSdkVersion` 给出最终结论。
  ///
  /// `base-config` 未声明时，平台默认：**targetSdk >= 28 → 不允许明文**，
  /// 否则 → 允许（Android 8.1 及以前默认放行）。
  bool? resolvedAllowsCleartext({required int? targetSdkVersion}) {
    if (!parsed) return null;
    for (final d in domains) {
      if (d.cleartextPermitted == true) return true;
    }
    if (baseCleartextPermitted != null) return baseCleartextPermitted;
    if (targetSdkVersion == null) return null;
    return targetSdkVersion < 28;
  }

  /// 放行了明文的具体域名（只含显式允许的 domain-config）。
  List<String> get cleartextDomains => [
        for (final d in domains)
          if (d.cleartextPermitted == true && d.domain != null) d.domain!,
      ];

  @override
  String toString() => 'NetworkSecurityConfigInfo($path, '
      'base: $baseCleartextPermitted, domains: ${domains.length}, '
      'failure: $failure)';
}

/// 解析 `res/xml/network_security_config.xml` 的字节。
///
/// [bytes] 是该条目的**解压后**字节（编译过的 AXML）。
/// 传 `null` 表示条目读不到（被预算拒绝、路径解析失败等），
/// 此时返回带 `failure` 的结果而不是 `null` —— 让「没读到」也能被呈现。
NetworkSecurityConfigInfo parseNetworkSecurityConfig(
  Uint8List? bytes, {
  required String path,
}) {
  if (bytes == null) {
    return NetworkSecurityConfigInfo(
      path: path,
      failure: 'the entry could not be read from the archive',
    );
  }
  XmlDocument doc;
  try {
    doc = BinaryXmlDecompressor().decompressToDocument(bytes);
  } catch (e) {
    return NetworkSecurityConfigInfo(
      path: path,
      failure: 'not a readable binary XML: $e',
    );
  }

  final root = _findElement(doc, 'network-security-config');
  if (root == null) {
    return NetworkSecurityConfigInfo(
      path: path,
      failure: 'the root element is not <network-security-config>',
    );
  }

  bool? basePermitted;
  final domains = <NscDomainRule>[];

  for (final child in root.children) {
    switch (child.name) {
      case 'base-config':
        basePermitted = _bool(child.attributes['cleartextTrafficPermitted']);
      case 'domain-config':
        final permitted = _bool(child.attributes['cleartextTrafficPermitted']);
        final domainElements =
            child.children.where((e) => e.name == 'domain').toList();
        if (domainElements.isEmpty) {
          // 没有 <domain> 的 domain-config 不指向任何域名，按 base 的覆盖
          // 无从谈起 —— 记一条无域名的规则，但不参与 allowsCleartext 判定。
          continue;
        }
        for (final d in domainElements) {
          domains.add(NscDomainRule(
            domain: d.text.isEmpty ? null : d.text,
            cleartextPermitted: permitted,
            includeSubdomains:
                _bool(d.attributes['includeSubdomains']) ?? false,
          ));
        }
      default:
        // trust-anchors / pin-set / debug-overrides 与明文判定无关。
        break;
    }
  }

  return NetworkSecurityConfigInfo(
    path: path,
    baseCleartextPermitted: basePermitted,
    domains: domains,
  );
}

XmlElement? _findElement(XmlElement node, String name) {
  if (node.name == name) return node;
  for (final child in node.children) {
    final found = _findElement(child, name);
    if (found != null) return found;
  }
  return null;
}

bool? _bool(String? raw) {
  if (raw == null) return null;
  switch (raw.trim().toLowerCase()) {
    case 'true':
      return true;
    case 'false':
      return false;
    default:
      return null;
  }
}
