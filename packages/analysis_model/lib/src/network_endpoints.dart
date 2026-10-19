// 从字符串里提取网络端点（域名 / IP）。
//
// ## 为什么放在 `analysis_model`
//
// Android 与 iOS 的扫描器都在做同一件事：把 ASCII 字符串里像域名的东西挑出来。
// 两边各写一份必然漂移 —— 一边补了 TLD、另一边没补，报告里就会出现「Android
// 认得出 `.top` 而 iOS 认不出」。这与 [AsciiStrings] 放在同一个包是同一个理由。
//
// ## 这是**静态提取**
//
// 域名出现在字符串里可能是配置项、SDK 地址或从未连接的备用端点。
// 措辞上必须守住这条界线：它只说明「包里写了这些」，不说明访问过。

import 'network_facts.dart';

/// 从任意字符串里提取域名与 IPv4 字面量。
class NetworkEndpoints {
  NetworkEndpoints._();

  /// 每个列表最多保留多少条。
  ///
  /// 大包（400 MB 级）里 `http` 开头的字面量能到上万条，全留下会把报告撑爆
  /// 且没有信息增量 —— 用户要的是「写了哪些」，不是完整清单。
  static const int maxEndpoints = 50;

  /// URL 主机名提取：`scheme://host[:port]/…`。
  static final RegExp _urlPattern =
      RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://([a-zA-Z0-9.-]+)');

  /// 裸域名（常见 TLD，避免把普通英文单词误判成域名）。
  ///
  /// 字符类里刻意不放引号：Dart 的原始字符串无法转义与自身相同的引号，
  /// 而这里排除空白与尖括号已经足够截断 URL。
  static final RegExp _bareDomainPattern = RegExp(
    r'\b([a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+'
    r'(com|cn|net|org|io|co|ai|dev|app|info|me|tv|xyz|top|cloud|gov|edu)'
    r'(?::\d{2,5})?(?:/[^\s<>]*)?',
    caseSensitive: true,
  );

  /// IPv4 字面量。
  static final RegExp _ipPattern = RegExp(r'\b(\d{1,3}\.){3}\d{1,3}\b');

  /// 认可的顶级域。
  ///
  /// 与 [_bareDomainPattern] 里那份**必须一致** —— 两处各写一份，加一个 TLD
  /// 只改一处就会出现「裸域名认得出、URL 里的认不出」。
  static const Set<String> tlds = {
    'com', 'cn', 'net', 'org', 'io', 'co', 'ai', 'dev', 'app', //
    'info', 'me', 'tv', 'xyz', 'top', 'cloud', 'gov', 'edu',
  };

  /// 这个「主机名」像不像真的主机名。
  ///
  /// 为什么需要它：Mach-O 里塞着大量 Web 资源（JS / CSS / HTML），
  /// `something://` 后面跟着的往往不是主机名。实测 `sun_signed.ipa` 不校验时
  /// 会产出 `.css`、`In`、`UA-Compatible`、`according` 这类垃圾 —— 一条
  /// 「域名清单」里混进英文单词，比没有清单更糟。
  static bool _plausibleHost(String host) {
    if (host.isEmpty || host.length > 253) return false;
    if (_ipPattern.hasMatch(host)) return true;
    final labels = host.split('.');
    if (labels.length < 2) return false;
    for (final label in labels) {
      if (label.isEmpty || label.length > 63) return false;
      if (label.startsWith('-') || label.endsWith('-')) return false;
    }
    return tlds.contains(labels.last.toLowerCase());
  }

  /// 逐条收集（供扫描器在遍历字符串时复用，避免先攒一个巨大列表）。
  static void collect(
    String value,
    Set<String> domains,
    Set<String> ips,
  ) {
    if (domains.length >= maxEndpoints && ips.length >= maxEndpoints) return;
    for (final match in _urlPattern.allMatches(value)) {
      final host = match.group(1)!;
      // IP 归 `ips`，不混进域名清单 —— 两张表混着放，读者分不清
      // 「写了域名」与「写了地址」，版本对比也会错位。
      if (_ipPattern.hasMatch(host)) {
        ips.add(host);
      } else if (_plausibleHost(host)) {
        domains.add(host);
      }
    }
    for (final match in _bareDomainPattern.allMatches(value)) {
      // 裸域名可能带端口或路径（`example.com:8080/x`），只保留主机名 ——
      // 一份「域名清单」里混着路径会让版本对比变成噪音。
      final raw = match.group(0)!;
      final cut = raw.indexOf(RegExp('[:/]'));
      final host = cut < 0 ? raw : raw.substring(0, cut);
      if (_plausibleHost(host)) domains.add(host);
    }
    for (final match in _ipPattern.allMatches(value)) {
      ips.add(match.group(0)!);
    }
  }

  /// 一次性把一串字符串归纳成 [NetworkFacts]（去重、限量、排序）。
  static NetworkFacts fromStrings(Iterable<String> values) {
    final domains = <String>{};
    final ips = <String>{};
    for (final value in values) {
      collect(value, domains, ips);
      if (domains.length >= maxEndpoints && ips.length >= maxEndpoints) break;
    }
    return NetworkFacts(
      domains: domains.take(maxEndpoints).toList()..sort(),
      ips: ips.take(maxEndpoints).toList()..sort(),
    );
  }
}
