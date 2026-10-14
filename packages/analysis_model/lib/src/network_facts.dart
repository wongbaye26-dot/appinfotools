/// 静态提取到的网络端点。
///
/// **静态提取不等于运行时访问过**：域名出现在字符串里可能是配置项、SDK 地址
/// 或从未连接的备用端点。措辞上必须守住这条界线 —— 它只说明「包里写了这些」。
class NetworkFacts {
  /// 从字符串里提取到的域名 / 主机名（去重、已排序）。
  final List<String> domains;

  /// 提取到的 IP 字面量（去重、已排序）。
  final List<String> ips;

  const NetworkFacts({this.domains = const [], this.ips = const []});

  bool get isEmpty => domains.isEmpty && ips.isEmpty;

  bool get isNotEmpty => !isEmpty;

  @override
  String toString() => 'NetworkFacts(${domains.length} domains, '
      '${ips.length} ips)';
}
