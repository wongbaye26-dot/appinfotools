// iOS 侧「盗 U」风险：信号收集与判级。
//
// 与 Android 侧同构，但「通道」不同 —— iOS 没有无障碍/短信，只有剪贴板与
// 写死的地址。判级只在**组合**上做：正规钱包同样有钱包框架、剪贴板调用与
// 地址字面量，单独任何一项都不该被当成风险。

import 'dart:convert';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

/// 把若干字符串拼成一段「可执行文件字节」（NUL 分隔，全是 ASCII）。
Uint8List _bytes(List<String> strings) {
  final out = <int>[];
  for (final s in strings) {
    out.addAll(const Utf8Encoder().convert(s));
    out.add(0);
  }
  return Uint8List.fromList(out);
}

IosCryptoSignals _signals(List<String> strings) {
  final signals = IosCryptoSignals();
  for (final s in strings) {
    signals.collect(s, 'Payload/Example.app/Example');
  }
  return signals;
}

SecurityFinding? _crypto(SecurityAnalysisResult r) {
  for (final f in r.findings) {
    if (f.ruleId == 'IOS-CRYPTO-THEFT-RISK') return f;
  }
  return null;
}

const _plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
</dict></plist>
''';

SecurityAnalysisResult _audit(List<String> strings) {
  final bundle = const IosBundle(
    kind: IosBundleKind.mainApp,
    path: 'Payload/Example.app',
    name: 'Example.app',
    infoPlistPath: 'Payload/Example.app/Info.plist',
    infoPlistSize: 512,
    fileCount: 3,
    uncompressedBytes: 4096,
  );
  final archive = Archive();
  void add(String name, String content) {
    final bytes = const Utf8Encoder().convert(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('Payload/Example.app/Info.plist', _plist);
  final macho = _bytes(strings);
  archive
      .addFile(ArchiveFile('Payload/Example.app/Example', macho.length, macho));

  return IosPrivacyAudit.audit(
    infoPlist: IpaInfoPlistReader.read(archive, bundle),
    executableBytes: macho,
    executablePath: 'Payload/Example.app/Example',
  );
}

void main() {
  group('判级', () {
    test('钱包 + 剪贴板 + 写死地址 → P2（地址替换三件套）', () {
      final signals = _signals([
        'WalletConnect',
        'UIPasteboard',
        '0x52908400098527886E0F7030069857D2E4169EE7',
      ]);
      expect(iosCryptoIsHighRisk(signals), isTrue);
      final finding = buildIosCryptoFindings(signals).single;
      expect(finding.severity, SecuritySeverity.p2);
    });

    test('钱包 + 助记词 + 剪贴板 → P2：密钥材料落在钱包语境里', () {
      final signals = _signals(['WalletConnect', 'mnemonic', 'UIPasteboard']);
      expect(iosCryptoIsHighRisk(signals), isTrue);
    });

    test('只有助记词 + 剪贴板（没有钱包语境）→ P3', () {
      // iOS 上 `UIPasteboard` 几乎人人都有。只凭「有密钥材料 + 有剪贴板」
      // 判 P2，会把每个内嵌 OpenSSL 的应用都报成高风险。
      final signals = _signals(['mnemonic', 'UIPasteboard']);
      expect(iosCryptoIsHighRisk(signals), isFalse);
    });

    test('OpenSSL 的 privateKey 不算密钥材料（真实样本上的误报）', () {
      final signals = _signals([
        'SSL_CTX_use_PrivateKey',
        'SSL_CTX_use_PrivateKey_ASN1',
      ]);
      expect(signals.samples.containsKey('wallet-private-key'), isFalse);
    });

    test('钱包自己的 privateKey（小写 p）仍然算', () {
      final signals = _signals(['privateKey', 'WalletConnect']);
      expect(signals.samples.containsKey('wallet-private-key'), isTrue);
    });

    test('只有钱包框架 → P3，不判高风险', () {
      final signals = _signals(['WalletConnect']);
      expect(iosCryptoIsHighRisk(signals), isFalse);
      final finding = buildIosCryptoFindings(signals).single;
      expect(finding.severity, SecuritySeverity.p3);
    });

    test('只有剪贴板 → 不产出任何发现（复制按钮到处都是）', () {
      final signals = _signals(['UIPasteboard', 'generalPasteboard']);
      expect(signals.isEmpty, isFalse);
      expect(buildIosCryptoFindings(signals), isEmpty);
    });

    test('大小写不敏感：iOS 的字面量是 CamelCase', () {
      final signals = _signals(['UIPasteboard', 'WalletConnect', 'MetaMask']);
      final ids = buildIosCryptoFindings(signals).single.messageArgs['signals'];
      expect(ids, contains('ios-pasteboard'));
      expect(ids, contains('wallet-walletconnect'));
      expect(ids, contains('wallet-metamask'));
    });

    test('地址原文进证据（用户要能拿去链上查）', () {
      final signals = _signals(['TA4Y62o6YC2Zsck9rZVGTvqW1AQ7X9zTnj']);
      final finding = buildIosCryptoFindings(signals).single;
      expect(
        finding.evidence.any((e) => e.detail.contains('TA4Y62o6YC2Zsck9rZ')),
        isTrue,
      );
      expect(finding.messageArgs['addressCount'], 1);
    });

    test('没有信号时不编造结论', () {
      expect(buildIosCryptoFindings(_signals(['nothing here'])), isEmpty);
    });
  });

  group('接进审计', () {
    test('可执行文件里的信号会产出 IOS-CRYPTO-THEFT-RISK', () {
      final finding = _crypto(_audit([
        'WalletConnect',
        'UIPasteboard',
        'mnemonic',
      ]));
      expect(finding, isNotNull);
      expect(finding!.platform, SecurityPlatform.ios);
      expect(finding.category, SecurityCategory.cryptoAsset);
      expect(finding.severity, SecuritySeverity.p2);
    });

    test('干净的可执行文件不产出这条', () {
      expect(_crypto(_audit(['UIViewController', 'viewDidLoad'])), isNull);
    });
  });
}
