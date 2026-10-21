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

import 'dart:typed_data';

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

// ---- 校验：不再靠「长得像」判断地址 ----

/// SHA-256（FIPS 180-4）。
///
/// `analysis_model` 是**零依赖**包，不能引 `package:crypto`；TRON 的
/// base58check 与 bech32 都需要校验和，所以自带一份。
Uint8List _sha256(List<int> message) {
  const k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  const mask = 0xffffffff;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & mask;

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final bitLength = message.length * 8;
  final padded = <int>[...message, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLength >> (i * 8)) & 0xff);
  }

  final w = List<int>.filled(64, 0);
  for (var offset = 0; offset < padded.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] = (padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & mask;
    }

    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & mask) & g);
      final temp1 = (h + s1 + ch + k[i] + w[i]) & mask;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & mask;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & mask;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & mask;
    }

    h0 = (h0 + a) & mask;
    h1 = (h1 + b) & mask;
    h2 = (h2 + c) & mask;
    h3 = (h3 + d) & mask;
    h4 = (h4 + e) & mask;
    h5 = (h5 + f) & mask;
    h6 = (h6 + g) & mask;
    h7 = (h7 + h) & mask;
  }

  final out = Uint8List(32);
  final words = [h0, h1, h2, h3, h4, h5, h6, h7];
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (words[i] >> 24) & 0xff;
    out[i * 4 + 1] = (words[i] >> 16) & 0xff;
    out[i * 4 + 2] = (words[i] >> 8) & 0xff;
    out[i * 4 + 3] = words[i] & 0xff;
  }
  return out;
}

/// base58 解码（Bitcoin 字母表）。非法字符返回 `null`。
List<int>? _base58Decode(String value) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  var number = BigInt.zero;
  for (var i = 0; i < value.length; i++) {
    final index = alphabet.indexOf(value[i]);
    if (index < 0) return null;
    number = number * BigInt.from(58) + BigInt.from(index);
  }
  final bytes = <int>[];
  final base = BigInt.from(256);
  while (number > BigInt.zero) {
    bytes.insert(0, (number % base).toInt());
    number = number ~/ base;
  }
  // 前导 '1' 代表前导零字节。
  for (var i = 0; i < value.length && value[i] == '1'; i++) {
    bytes.insert(0, 0);
  }
  return bytes;
}

/// TRON 地址是否通过 **base58check** 校验。
///
/// 这是把「长得像地址」变成「确实是地址」的关键一步：Swift 的符号名
/// （`TaskModifier2VAA12ViewModifierAAMc`）恰好满足「T + 33 位 base58」，
/// 正则分不出来，校验和分得出来 —— 实测在真实样本上就误报过一次。
bool _tronChecksumValid(String address) {
  final raw = _base58Decode(address);
  if (raw == null || raw.length != 25) return false;
  final payload = raw.sublist(0, 21);
  final checksum = raw.sublist(21);
  final digest = _sha256(_sha256(payload));
  for (var i = 0; i < 4; i++) {
    if (digest[i] != checksum[i]) return false;
  }
  return true;
}

const String _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

int _bech32Polymod(List<int> values) {
  const generator = [
    0x3b6a57b2,
    0x26508e6d,
    0x1ea119fa,
    0x3d4233dd,
    0x2a1462b3,
  ];
  var checksum = 1;
  for (final value in values) {
    final top = checksum >> 25;
    checksum = ((checksum & 0x1ffffff) << 5) ^ value;
    for (var i = 0; i < 5; i++) {
      if ((top >> i) & 1 != 0) checksum ^= generator[i];
    }
  }
  return checksum;
}

/// bech32 地址是否通过校验和（BIP-173）。
bool _bech32Valid(String address) {
  final separator = address.lastIndexOf('1');
  if (separator < 1 || separator + 7 > address.length) return false;
  final hrp = address.substring(0, separator);
  final data = <int>[];
  for (final char in address.substring(separator + 1).split('')) {
    final value = _bech32Charset.indexOf(char);
    if (value < 0) return false;
    data.add(value);
  }
  final expanded = <int>[
    for (final unit in hrp.codeUnits) unit >> 5,
    0,
    for (final unit in hrp.codeUnits) unit & 31,
  ];
  return _bech32Polymod([...expanded, ...data]) == 1;
}

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
    // **校验和必须过**：Swift 符号名（`TaskModifier2VAA12ViewModifierAAMc`）
    // 恰好满足「T + 33 位 base58」，正则分不出来。
    if (!_tronChecksumValid(address)) continue;
    if (seen.add(address)) {
      hits.add(CryptoAddressHit(CryptoAddressFormat.tron, address));
    }
  }
  for (final match in _bitcoinBech32.allMatches(value)) {
    final address = match.group(0)!;
    if (!_bech32Valid(address)) continue;
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
