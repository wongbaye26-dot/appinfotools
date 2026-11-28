/// 静态提取到的网络端点。
///
/// **静态提取不等于运行时访问过**：域名出现在字符串里可能是配置项、SDK 地址
/// 或从未连接的备用端点。措辞上必须守住这条界线 —— 它只说明「包里写了这些」。
class NetworkFacts {
  /// 从字符串里提取到的域名 / 主机名（去重、已排序）。
  final List<String> domains;

  /// 提取到的 IP 字面量（去重、已排序）。
  final List<String> ips;

  /// 结构化线索：域名、IPv4、IPv6、URL、WebSocket。
  ///
  /// 与 [domains]/[ips] 并存是为了兼容旧报告和旧调用方；新 UI 读这里。
  final List<NetworkClue> clues;

  const NetworkFacts({
    this.domains = const [],
    this.ips = const [],
    this.clues = const [],
  });

  bool get isEmpty => domains.isEmpty && ips.isEmpty && clues.isEmpty;

  bool get isNotEmpty => !isEmpty;

  @override
  String toString() => 'NetworkFacts(${domains.length} domains, '
      '${ips.length} ips, ${clues.length} clues)';
}

/// 一条静态网络线索。只记录「包里写了什么」，不表示运行时访问。
enum NetworkClueType { domain, ipv4, ipv6, url, websocket }

class NetworkClue {
  /// 稳定 ID，由类型、值、来源路径派生；同一输入跨报告一致。
  final String id;
  final NetworkClueType type;

  /// 完整 URL，或 host / IP 字面量。
  final String value;

  /// 来源制品路径（DEX 文件名、Mach-O/文件路径）；未知时为 null。
  final String? sourcePath;

  /// 原始字符串的短上下文；只用于人工核对，不参与判级。
  final String? context;

  const NetworkClue({
    required this.id,
    required this.type,
    required this.value,
    this.sourcePath,
    this.context,
  });

  /// FNV-1a 64 位；与 Evidence ID 同一思路，避免依赖 `String.hashCode`。
  static String createId({
    required NetworkClueType type,
    required String value,
    String? sourcePath,
  }) {
    var hash = 0xcbf29ce484222325;
    void feed(String text) {
      for (final unit in text.codeUnits) {
        hash ^= unit;
        hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
    }

    feed(type.name);
    feed('|');
    feed(value);
    feed('|');
    feed(sourcePath ?? '');
    return 'nc_${hash.toRadixString(16).padLeft(16, '0')}';
  }

  @override
  String toString() => 'NetworkClue(${type.name}, $value, $sourcePath)';
}
