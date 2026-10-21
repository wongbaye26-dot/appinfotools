/// 链上地址字面量的识别。
///
/// ## 为什么单独一件事
///
/// 「盗 U」类恶意代码最典型的手法不是偷助记词，而是**替换剪贴板里的收款地址**：
/// 用户复制自己的地址、粘贴到钱包里时，恶意代码把它换成攻击者的地址。这类样本
/// 里几乎必然有**硬编码的地址字面量** —— 而正常应用几乎没有理由在代码里写死
/// 一个链上地址（商户收款码除外）。
///
/// 所以「代码里有没有地址字面量」是一条**便宜且强**的信号，值得单独扫。
///
/// ## 只认三种，宁可漏也不误报
///
/// | 链 | 形态 |
/// |---|---|
/// | EVM（以太坊 / BSC / Polygon…） | `0x` + 40 位十六进制 |
/// | TRON（USDT 最常用） | `T` + 33 位 base58 |
/// | Bitcoin（bech32） | `bc1` + 25–62 位 bech32 字符 |
///
/// **不做 base58check 校验和验证**：那需要引入大数运算，而这里的用途只是
/// 「代码里出现了像地址的东西」。校验和留给人工核对 —— 报告里给的是原文，
/// 用户可以直接拿去链上查。
///
/// 反过来，**必须**要求严格的长度与字符集边界，否则 `0x1234...`（哈希、颜色值、
/// 内存地址）会被当成地址，规则就会在几乎所有应用上出现。
library;

/// 地址所属的链。报告里要区分 —— TRON 地址和 EVM 地址的处理方式不同。
enum CryptoAddressFormat {
  /// `0x` + 40 位十六进制。
  evm('EVM'),

  /// `T` + 33 位 base58（USDT-TRC20 的常见形态）。
  tron('TRON'),

  /// `bc1` 开头的 bech32。
  bitcoin('Bitcoin');

  const CryptoAddressFormat(this.label);

  /// 英文短名（报告里与地址并列显示）。
  final String label;
}

/// 一条地址字面量。
class CryptoAddressHit {
  final CryptoAddressFormat format;

  /// 地址原文（**不做任何改写** —— 用户要能拿去链上查）。
  final String address;

  const CryptoAddressHit(this.format, this.address);

  @override
  bool operator ==(Object other) =>
      other is CryptoAddressHit &&
      other.format == format &&
      other.address == address;

  @override
  int get hashCode => Object.hash(format, address);

  @override
  String toString() => '${format.label}: $address';
}

/// EVM：`0x` + 40 位十六进制。前后不能紧邻十六进制字符，否则是更长串的一部分。
final RegExp _evm = RegExp(r'(?<![0-9a-zA-Z])0x[0-9a-fA-F]{40}(?![0-9a-fA-F])');

/// TRON：`T` + 33 位 base58。base58 排除了 `0 O I l`。
final RegExp _tron =
    RegExp(r'(?<![0-9A-Za-z])T[1-9A-HJ-NP-Za-km-z]{33}(?![0-9A-Za-z])');

/// Bitcoin bech32：`bc1` + 25–62 位 bech32 字符（小写为主，大写地址存在但罕见）。
final RegExp _bitcoinBech32 =
    RegExp(r'(?<![0-9A-Za-z])bc1[02-9ac-hj-np-z]{25,62}');

/// 公开的合约 / 路由 / 销毁地址 —— **它们不是收款地址**。
///
/// ## 为什么必须过滤
///
/// USDT-TRC20 的合约地址 `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t` 是公开常量：
/// 正规 TRON 钱包、DApp 浏览器、甚至收款页都会把它写死在代码里。不过滤的话，
/// 「钱包 + 剪贴板 + 写死地址」这条判据在**每一个正规钱包**上都会命中 ——
/// 那就不是「线索」而是噪音。
///
/// ## 收录标准
///
/// 只收**官方公开、且能在链上或官方文档核对**的地址：
/// 主流稳定币合约、主流 DEX 路由、多签/批量调用合约、销毁地址、零地址。
/// 拿不准的一律不收 —— 漏收只是少降一点噪音，**错收会掩盖真实线索**。
///
/// 匹配时 EVM 地址转小写比较（十六进制大小写不敏感），TRON / bech32 原样比较
/// （base58 / bech32 区分大小写）。
const Set<String> knownContractAddresses = {
  // ---- TRON ----
  // USDT-TRC20
  'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
  // USDC-TRC20
  'TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8',
  // ---- EVM（以太坊主网）----
  // USDT
  '0xdac17f958d2ee523a2206206994597c13d831ec7',
  // USDC
  '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  // DAI
  '0x6b175474e89094c44da98b954eedeac495271d0f',
  // WETH
  '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2',
  // Uniswap V2 Router02
  '0x7a250d5630b4cf539739df2c5dacb4c659f2488d',
  // Uniswap V3 SwapRouter
  '0xe592427a0aece92de3edee1f18e0157c05861564',
  // PancakeSwap V2 Router（BSC）
  '0x10ed43c718714eb63d5aa57b78b54704e256024e',
  // USDT（BSC）
  '0x55d398326f99059ff775485246999027b3197955',
  // Multicall3（部署在同地址的批量调用合约）
  '0xca11bde05977b3631167028862be2a173976ca11',
  // 零地址 / 销毁地址
  '0x0000000000000000000000000000000000000000',
  '0x000000000000000000000000000000000000dead',
};

/// 这条地址是不是公开常量（合约 / 路由 / 销毁）。
bool isKnownContractAddress(CryptoAddressHit hit) => switch (hit.format) {
      CryptoAddressFormat.evm =>
        knownContractAddresses.contains(hit.address.toLowerCase()),
      // TRON 的 base58 与 bech32 都区分大小写，原样比。
      CryptoAddressFormat.tron ||
      CryptoAddressFormat.bitcoin =>
        knownContractAddresses.contains(hit.address),
    };

/// 从一条字符串里挑出所有地址字面量。
///
/// 结果**按出现顺序**去重；调用方自己决定保留多少条。
List<CryptoAddressHit> findCryptoAddresses(String value) {
  // 最短的地址形态是 TRON 的 34 字符；比这短的不可能命中，直接返回省掉三次正则。
  if (value.length < 34) return const [];
  final hits = <CryptoAddressHit>[];
  final seen = <String>{};
  for (final match in _evm.allMatches(value)) {
    final address = match.group(0)!;
    if (seen.add(address)) {
      hits.add(CryptoAddressHit(CryptoAddressFormat.evm, address));
    }
  }
  for (final match in _tron.allMatches(value)) {
    final address = match.group(0)!;
    if (seen.add(address)) {
      hits.add(CryptoAddressHit(CryptoAddressFormat.tron, address));
    }
  }
  for (final match in _bitcoinBech32.allMatches(value)) {
    final address = match.group(0)!;
    if (seen.add(address)) {
      hits.add(CryptoAddressHit(CryptoAddressFormat.bitcoin, address));
    }
  }
  return hits;
}

/// 把地址收集进 [out]，上限 [max] 条。
///
/// **上限是必须的**：一个内置了「常见地址黑名单」的应用会有成百上千条字面量，
/// 全存进结果会让报告变成一份地址列表。超限只记「还有更多」，不静默截断。
/// [includeKnown] 为 `true` 时连公开合约地址一起收（诊断用）。
///
/// 默认**跳过** [knownContractAddresses]：那些不是收款地址，收进来只会让
/// 「写死地址」这条判据在正规钱包上稳定误报。
void collectCryptoAddresses(
  String value,
  Set<CryptoAddressHit> out, {
  int max = 32,
  bool includeKnown = false,
}) {
  if (out.length >= max) return;
  for (final hit in findCryptoAddresses(value)) {
    if (out.length >= max) return;
    if (!includeKnown && isKnownContractAddress(hit)) continue;
    out.add(hit);
  }
}
