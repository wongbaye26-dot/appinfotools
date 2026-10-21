import 'package:analysis_model/analysis_model.dart';

/// iOS 侧的「盗 U」风险信号收集与判级。
///
/// ## 与 Android 侧的差别
///
/// iOS 没有无障碍服务、也没有「读短信」这种权限，盗 U 的静态形态只剩两条：
///
/// - **骗助记词**：假钱包应用把用户输入的助记词发走；
/// - **换地址**：读剪贴板里用户复制的收款地址，替换成自己的。
///
/// 所以这里的「通道」是 `UIPasteboard` 与**写死的链上地址**，而不是
/// 无障碍 / 短信。判级与 Android 保持一致的两条组合：
///
/// 1. 密钥材料 + 通道；
/// 2. 钱包 + 剪贴板 + 写死的地址（地址替换三件套）。
///
/// ## 为什么复用 Android 那次遍历
///
/// `IosPrivacyAudit` 本来就要把每个可执行文件的 ASCII 串过一遍（权限 API、
/// 域名、标记）。这里只往同一次遍历里挂一个收集器，**不额外解码一遍** ——
/// 主二进制常有几百 MB。
///
/// ## 大小写
///
/// iOS 的字面量是 CamelCase（`UIPasteboard`、`WalletConnect`），而 DEX 侧
/// 的标记是小写包名。为了两边共用一张表，这里**统一转小写再比**。
class IosCryptoSignals {
  /// 标记 id → 命中样本（最多保留几条，够做证据）。
  final Map<String, Set<String>> samples = {};

  /// 标记 id → 出现在哪些可执行文件里。
  final Map<String, Set<String>> sources = {};

  /// 字符串里出现的链上地址。
  final Set<CryptoAddressHit> addresses = {};

  /// 地址 → 出现在哪些可执行文件里。
  final Map<CryptoAddressHit, Set<String>> addressSources = {};

  static const int _maxSamplesPerMarker = 5;
  static const int _maxAddresses = 32;

  bool get isEmpty => samples.isEmpty && addresses.isEmpty;

  /// 从一段字符串里收集信号。[source] 是可执行文件路径（证据位置）。
  void collect(String text, String source) {
    final lower = text.toLowerCase();
    for (final marker in iosCryptoMarkers) {
      final haystack = marker.caseSensitive ? text : lower;
      if (!haystack.contains(marker.literal)) continue;
      final bucket = samples.putIfAbsent(marker.id, () => <String>{});
      if (bucket.length < _maxSamplesPerMarker) bucket.add(text);
      (sources[marker.id] ??= <String>{}).add(source);
    }
    if (addresses.length >= _maxAddresses) return;
    for (final hit in findCryptoAddresses(text)) {
      if (addresses.length >= _maxAddresses) return;
      if (addresses.add(hit)) {
        (addressSources[hit] ??= <String>{}).add(source);
      }
    }
  }

  /// 某个组里命中了哪些标记 id。
  List<String> hitsOf(Set<String> group) => [
        for (final id in group)
          if (samples.containsKey(id)) id,
      ];
}

/// 一个 iOS 侧标记。
class IosCryptoMarker {
  final String id;

  /// 小写字面量（匹配前会把字符串转小写）。
  final String literal;

  /// 是否**区分大小写**（默认不区分）。
  ///
  /// 给「字面量本身太泛」的标记用：`privateKey`（Swift / ObjC 属性）与
  /// OpenSSL 的 `PrivateKey`（大写 P，如 `SSL_CTX_use_PrivateKey`、
  /// `d2i_PrivateKey`）只差一个字母的大小写 —— 实测在一个内嵌 OpenSSL 的
  /// 微信改版包上，不区分大小写会把这条发现凭空造出来。
  final bool caseSensitive;

  const IosCryptoMarker(
    this.id,
    this.literal, {
    this.caseSensitive = false,
  });
}

/// 三组标记：钱包 SDK / 密钥材料 / 剪贴板。
///
/// 与 Android 侧的 `codeMarkers` 是两张表 —— 两边的生态不同（iOS 是
/// framework 名与 Swift 模块名，Android 是包名）。合并成一张会让每边都
/// 背上一半永远不命中的条目。
const Set<String> walletSdkMarkers = {
  'wallet-walletconnect',
  'wallet-trustwalletcore',
  'wallet-web3swift',
  'wallet-metamask',
  'wallet-imtoken',
  'wallet-tokenpocket',
  'wallet-bitcoinkit',
  'wallet-tronweb',
  'wallet-web3',
};

const Set<String> keyMaterialMarkers = {
  'wallet-mnemonic',
  'wallet-seed-phrase',
  'wallet-bip39',
  // **`wallet-private-key` 不在判级里**：`privateKey` 这个字面量在任何带
  // 加密库的应用里都有（实测：X.509 的 `privateKeyUsagePeriod`、OpenSSL 的
  // `PrivateKey`、各种 RSA 工具）。它作为「钱包证据」的精度太低，留着只会
  // 把「用了 OpenSSL」说成「在管私钥」。助记词 / BIP39 才是钱包特有的。
};

const Set<String> pasteboardMarkers = {
  'ios-pasteboard',
  'ios-general-pasteboard',
};

const List<IosCryptoMarker> iosCryptoMarkers = [
  // ---- 钱包 SDK / 框架 ----
  IosCryptoMarker('wallet-walletconnect', 'walletconnect'),
  IosCryptoMarker('wallet-trustwalletcore', 'trustwalletcore'),
  IosCryptoMarker('wallet-web3swift', 'web3swift'),
  IosCryptoMarker('wallet-metamask', 'metamask'),
  IosCryptoMarker('wallet-imtoken', 'imtoken'),
  IosCryptoMarker('wallet-tokenpocket', 'tokenpocket'),
  IosCryptoMarker('wallet-bitcoinkit', 'bitcoinkit'),
  IosCryptoMarker('wallet-tronweb', 'tronweb'),
  IosCryptoMarker('wallet-web3', 'web3'),
  // ---- 密钥材料 ----
  IosCryptoMarker('wallet-mnemonic', 'mnemonic'),
  IosCryptoMarker('wallet-seed-phrase', 'seedphrase'),
  // `privateKey` **只作为线索收集，不参与判级**（见 `keyMaterialMarkers`
  // 的注释）。保留这一条是为了在证据里能看到它 —— 但一条命中不足以说明
  // 这个应用在管钱包私钥。
  IosCryptoMarker(
    'wallet-private-key',
    'privateKey',
    caseSensitive: true,
  ),
  IosCryptoMarker('wallet-bip39', 'bip39'),
  // ---- 剪贴板 ----
  //
  // iOS 上「复制」用得极广（复制链接、复制验证码），所以剪贴板**只是通道的
  // 一半**，单独出现绝不判级。
  IosCryptoMarker('ios-pasteboard', 'uipasteboard'),
  IosCryptoMarker('ios-general-pasteboard', 'generalpasteboard'),
];

/// 判级：`true` 表示达到 P2（需要人工核对）。
///
/// 两条组合，与 Android 侧同构：
/// 1. 密钥材料 + 通道（剪贴板或写死的地址）；
/// 2. 钱包 + 剪贴板 + 写死的地址。
bool iosCryptoIsHighRisk(IosCryptoSignals s) {
  final key = s.hitsOf(keyMaterialMarkers).isNotEmpty;
  final wallet = s.hitsOf(walletSdkMarkers).isNotEmpty;
  final pasteboard = s.hitsOf(pasteboardMarkers).isNotEmpty;
  final addresses = s.addresses.isNotEmpty;

  // **密钥材料必须落在钱包语境里**。iOS 上 `UIPasteboard` 几乎人人都有，
  // 只凭「有 privateKey 字样 + 有剪贴板」判 P2，会把每个内嵌 OpenSSL 的
  // 应用都报成高风险 —— 实测在真实样本上就是这么误报的。
  if (wallet && key && (pasteboard || addresses)) return true;
  // 地址替换三件套。
  if (wallet && pasteboard && addresses) return true;
  return false;
}

/// 产出发现项。没有信号时返回空列表（不编造「未发现」的结论 —— 那是 UI 的事）。
List<SecurityFinding> buildIosCryptoFindings(IosCryptoSignals s) {
  final wallet = s.hitsOf(walletSdkMarkers);
  final key = s.hitsOf(keyMaterialMarkers);
  final pasteboard = s.hitsOf(pasteboardMarkers);

  // **剪贴板单独出现不报**：iOS 上「复制」用得极广（复制链接、复制验证码），
  // 只凭它就出一条发现等于给每个应用挂一条。与 Android 侧同一取舍。
  if (wallet.isEmpty && key.isEmpty && s.addresses.isEmpty) return const [];
  final highRisk = iosCryptoIsHighRisk(s);

  final signals = <String>[
    ...wallet,
    ...key,
    ...pasteboard,
  ];

  return [
    SecurityFinding(
      ruleId: 'IOS-CRYPTO-THEFT-RISK',
      platform: SecurityPlatform.ios,
      category: SecurityCategory.cryptoAsset,
      severity: highRisk ? SecuritySeverity.p2 : SecuritySeverity.p3,
      // 与 Android 侧一致：说的是「这些能力同现」，不是「我们看见它偷了」。
      confidence: SecurityConfidence.independentCapability,
      finding: 'Crypto-wallet capabilities that theft samples combine are '
          'present: ${signals.join(', ')}'
          '${s.addresses.isNotEmpty ? ' (plus ${s.addresses.length} '
              'on-chain address literal'
              '${s.addresses.length == 1 ? '' : 's'})' : ''}. '
          'A legitimate wallet has the same capabilities, so this is a '
          '**triage lead, not a verdict**.',
      messageCode: 'crypto.theft_risk',
      messageArgs: {
        'signals': signals,
        'addresses': [
          for (final hit in s.addresses.take(8))
            '${hit.format.label}: ${hit.address}',
        ],
        'addressCount': s.addresses.length,
      },
      evidence: [
        for (final id in signals)
          for (final sample in (s.samples[id] ?? const <String>{}).take(3))
            SecurityEvidence(
              source: SecurityEvidenceSource.machoSymbol,
              location: (s.sources[id] ?? const <String>{}).join(', '),
              detail: '$id: $sample',
            ),
        for (final hit in s.addresses.take(8))
          SecurityEvidence(
            source: SecurityEvidenceSource.machoSymbol,
            location: (s.addressSources[hit] ?? const <String>{}).join(', '),
            detail: '${hit.format.label} address literal: ${hit.address}',
          ),
      ],
      limitation: 'Static evidence only: these strings exist in the '
          'executables. Whether they run, and what they do with the data, is '
          'not visible here. Legitimate wallets contain the same wallet '
          'frameworks, the same pasteboard calls and the same address '
          'literals (merchant or contract addresses), so **presence is not '
          'theft**. Strings beyond the scan budget were not examined.',
      limitationCode: 'crypto.theft_risk.limitation',
      recommendation: 'Check the wallet flow by hand: does the app ever '
          'replace an address in the pasteboard, does it ask for the seed '
          'phrase outside its own wallet UI, and where do the address '
          'literals come from? Dynamic analysis on an isolated device settles '
          'it.',
      recommendationCode: 'crypto.theft_risk.review',
    ),
  ];
}
