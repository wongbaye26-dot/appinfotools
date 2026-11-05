import 'package:analysis_model/analysis_model.dart';
import 'package:ipa_parser/ipa_parser.dart';
import 'package:test/test.dart';

const _evmAddress = '0x1111111111111111111111111111111111111111';

IosCryptoSignals _signals(List<String> strings) {
  final signals = IosCryptoSignals();
  for (final text in strings) {
    signals.collect(text, 'Payload/App.app/App');
  }
  return signals;
}

void main() {
  test('无信号 → none，五段链齐全', () {
    final a = IosCryptoTheftChain.assess(signals: IosCryptoSignals());
    expect(a.id, 'ios.crypto.theft');
    expect(a.level, CryptoTheftLevel.none);
    expect(a.chain, hasLength(5));
    expect(a.missing, hasLength(5));
  });

  test('钱包 + 剪贴板 + 地址 → suspicious/P2（地址替换链）', () {
    final a = IosCryptoTheftChain.assess(
      signals: _signals([
        'MetaMask',
        'UIPasteboard.general',
        _evmAddress,
      ]),
    );
    expect(a.level, CryptoTheftLevel.suspicious);
    expect(a.severity, SecuritySeverity.p2);
    expect(a.primaryTechnique, TheftTechnique.addressSwap);
    expect(
        a.chain.firstWhere((e) => e.stage == ChainStage.capability).supported,
        isTrue);
    expect(a.chain.firstWhere((e) => e.stage == ChainStage.source).supported,
        isTrue);
  });

  test('只有钱包框架 → capabilityOnly/P3，不判 P2', () {
    final a = IosCryptoTheftChain.assess(signals: _signals(['MetaMask']));
    expect(a.level, CryptoTheftLevel.capabilityOnly);
    expect(a.severity, SecuritySeverity.p3);
  });

  test('注入 dylib + 可疑载荷 + 钱包 → strongEvidence/P1', () {
    final a = IosCryptoTheftChain.assess(
      signals: _signals(['MetaMask']),
      layout: const IpaLayoutFacts(
        bundlePath: 'Payload/App.app',
        dylibsAtBundleRoot: ['Payload/App.app/evil.dylib'],
      ),
      payloadProbe: const PayloadProbeResult(
        signals: [
          PayloadSignal(
            path: 'Payload/App.app/evil.dylib',
            kind: PayloadKind.machO,
            code: 'payload.encrypted',
          ),
        ],
      ),
    );
    expect(a.level, CryptoTheftLevel.strongEvidence);
    expect(a.severity, SecuritySeverity.p1);
    expect(a.chain.firstWhere((e) => e.stage == ChainStage.injection).supported,
        isTrue);
    expect(a.chain.firstWhere((e) => e.stage == ChainStage.payload).supported,
        isTrue);
  });

  test('悬空加载边 + 钱包 → suspicious/P2', () {
    final a = IosCryptoTheftChain.assess(
      signals: _signals(['MetaMask']),
      loadGraph: const LoadGraph(
        nodes: [
          LoadNode(
            id: 'artifact:Payload/App.app/App',
            kind: LoadNodeKind.machO,
            resolvedPath: 'Payload/App.app/App',
            presentInPackage: true,
          ),
          LoadNode(
            id: 'missing:@rpath/Missing.dylib',
            kind: LoadNodeKind.missing,
          ),
        ],
        edges: [
          LoadEdge(
            fromId: 'artifact:Payload/App.app/App',
            toId: 'missing:@rpath/Missing.dylib',
            kind: LoadEdgeKind.machoLinkedLibrary,
            source: SecurityEvidenceSource.loadGraph,
            location: 'LC_LOAD_DYLIB#3',
          ),
        ],
        danglingEdgeIds: [
          'artifact:Payload/App.app/App->missing:@rpath/Missing.dylib'
        ],
        complete: true,
      ),
    );
    expect(a.level, CryptoTheftLevel.suspicious);
    expect(a.severity, SecuritySeverity.p2);
  });

  test('覆盖不全且无信号 → unknown/unknown', () {
    final a = IosCryptoTheftChain.assess(
      signals: IosCryptoSignals(),
      payloadProbe: const PayloadProbeResult(
        entriesProbed: 1,
        entriesTotal: 10,
        complete: false,
        noteCodes: ['payload.entries_truncated'],
      ),
    );
    expect(a.level, CryptoTheftLevel.unknown);
    expect(a.severity, SecuritySeverity.unknown);
  });

  test('密封不一致 → strongEvidence/P1，即使没有钱包信号', () {
    final a = IosCryptoTheftChain.assess(
      signals: IosCryptoSignals(),
      seal: const SealCheck(
        scheme: 'ipa.codeResources.v2',
        state: SealState.mismatch,
      ),
    );
    expect(a.level, CryptoTheftLevel.strongEvidence);
    expect(a.severity, SecuritySeverity.p1);
    expect(a.confidence, SecurityConfidence.confirmed);
  });

  test('官方基线 mismatch → strongEvidence/P1/confirmed', () {
    final a = IosCryptoTheftChain.assess(
      signals: IosCryptoSignals(),
      baseline: const BaselineMatch(
        status: BaselineStatus.mismatch,
        entryId: 'ios.example.wallet',
        packageId: 'com.example.wallet',
        expectedFingerprintPrefixes: ['ABCDE12345'],
        actualFingerprintPrefixes: ['ZZZZZ99999'],
      ),
    );
    expect(a.level, CryptoTheftLevel.strongEvidence);
    expect(a.severity, SecuritySeverity.p1);
    expect(a.confidence, SecurityConfidence.confirmed);
    expect(a.baselineEntryId, 'ios.example.wallet');
  });
}
