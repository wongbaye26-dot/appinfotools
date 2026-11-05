import 'package:analysis_model/analysis_model.dart';

import '../ipa_layout.dart';
import 'ios_crypto_audit.dart';
import 'ios_unicode_phrases.dart';

/// iOS 侧的证据链装配（Phase C）。
///
/// 输入是已有的 [IosCryptoSignals]（字符串/地址）与可选的布局/清单/加载链/
/// 载荷事实；判级只走 `analysis_model` 的 `CryptoTheftAssessor`。
class IosCryptoTheftChain {
  IosCryptoTheftChain._();

  static CryptoTheftAssessment assess({
    required IosCryptoSignals signals,
    IosUnicodePhraseSignals? phrases,
    IpaLayoutFacts? layout,
    ArtifactInventory? artifacts,
    LoadGraph? loadGraph,
    PayloadProbeResult? payloadProbe,
    SealCheck? seal,
    BaselineMatch? baseline,
  }) {
    final wallet = signals.hitsOf(walletSdkMarkers);
    final key = signals.hitsOf(keyMaterialMarkers);
    final pasteboard = signals.hitsOf(pasteboardMarkers);

    final injectionEvidence = <SecurityEvidence>[
      if (layout case final l? when l.hasDylibInjection)
        for (final path in l.dylibsAtBundleRoot)
          SecurityEvidence(
            source: SecurityEvidenceSource.zipEntry,
            location: path,
            detail: 'dylib at .app root (injection footprint)',
          ),
      if (loadGraph case final g?)
        for (final edge in g.edges)
          if (g.danglingEdgeIds.contains(edge.id))
            SecurityEvidence(
              source: SecurityEvidenceSource.loadGraph,
              location: edge.location,
              detail: '${edge.fromId} -> ${edge.toId} (${edge.kind.label})',
            ),
    ];

    final payloadSignals = payloadProbe?.signals ?? const <PayloadSignal>[];
    final payloadEvidence = <SecurityEvidence>[
      for (final signal in payloadSignals)
        SecurityEvidence(
          source: SecurityEvidenceSource.artifactEntry,
          location: signal.path,
          detail: '${signal.code}; kind=${signal.kind.name}',
        ),
    ];

    final suspiciousPayload = payloadSignals.any((signal) =>
            signal.code == 'payload.magicMismatch' ||
            signal.code == 'payload.nestedArchive' ||
            signal.code == 'payload.encrypted' ||
            signal.code == 'payload.executableInAssets') ||
        (artifacts?.entries.any((e) => e.suspicionCodes.isNotEmpty) ?? false);

    final coverageIncomplete =
        (payloadProbe != null && !payloadProbe.complete) ||
            (loadGraph != null && !loadGraph.complete) ||
            (artifacts != null && !artifacts.entriesComplete);

    final blindSpots = <String>[
      if (payloadProbe != null && !payloadProbe.complete) 'payloadUnavailable',
      if (loadGraph != null && !loadGraph.complete) 'artifactsPartial',
      if (artifacts != null && !artifacts.entriesComplete) 'artifactsPartial',
    ];

    // 中文话术只作为「来源」段的线索，命中原文进证据。
    // **不**把 phrases 折算成 walletContext / keyMaterial / networkSink：
    // 一句界面文案不构成能力事实，更不能凭它把等级推到 P2。
    final phraseEvidence = <SecurityEvidence>[
      if (phrases != null)
        for (final id in phrases.hitIds.take(8))
          for (final sample
              in (phrases.samples[id] ?? const <String>{}).take(2))
            SecurityEvidence(
              source: SecurityEvidenceSource.machoSymbol,
              location: (phrases.sources[id] ?? const <String>{}).join(', '),
              detail: 'unicode phrase $id: $sample',
            ),
    ];

    return CryptoTheftAssessor.assess(CryptoTheftFacts(
      platform: SecurityPlatform.ios,
      walletContext: wallet.isNotEmpty,
      keyMaterial: key.isNotEmpty,
      // iOS 上 UIPasteboard 的读/写无法从字符串层区分；两者都置 true，
      // 让 source 段有支撑，同时地址替换仍能由 wallet+write+address 判 P2。
      clipboardRead: pasteboard.isNotEmpty,
      clipboardWrite: pasteboard.isNotEmpty,
      addressLiteral: signals.addresses.isNotEmpty,
      // 中文「助记词 / 私钥」这类词是「有输入密钥材料的界面」的线索，
      // 只支撑 source 段；判级仍由 ASCII 侧的能力组合决定。
      seedInput: phrases?.hasSeedPhrase ?? false,
      dynamicLoading: false,
      danglingLoad: loadGraph?.danglingEdgeIds.isNotEmpty ?? false,
      injectedDylib: layout?.hasDylibInjection ?? false,
      suspiciousPayload: suspiciousPayload,
      sealMismatch: seal?.state == SealState.mismatch,
      baselineMismatch: baseline?.isMismatch ?? false,
      baselineEntryId: baseline?.entryId,
      coverageIncomplete: coverageIncomplete,
      blindSpots: blindSpots,
      evidence: {
        ChainStage.capability: [
          for (final id in [...wallet, ...key])
            for (final sample
                in (signals.samples[id] ?? const <String>{}).take(3))
              SecurityEvidence(
                source: SecurityEvidenceSource.machoSymbol,
                location: (signals.sources[id] ?? const <String>{}).join(', '),
                detail: '$id: $sample',
              ),
          for (final hit in signals.addresses.take(8))
            SecurityEvidence(
              source: SecurityEvidenceSource.machoSymbol,
              location:
                  (signals.addressSources[hit] ?? const <String>{}).join(', '),
              detail: '${hit.format.label} address literal: ${hit.address}',
            ),
        ],
        ChainStage.source: [
          for (final id in pasteboard)
            for (final sample
                in (signals.samples[id] ?? const <String>{}).take(3))
              SecurityEvidence(
                source: SecurityEvidenceSource.machoSymbol,
                location: (signals.sources[id] ?? const <String>{}).join(', '),
                detail: '$id: $sample',
              ),
          ...phraseEvidence,
        ],
        ChainStage.injection: injectionEvidence,
        ChainStage.payload: payloadEvidence,
      },
      noteCodes: {
        if (blindSpots.isNotEmpty) ChainStage.payload: blindSpots,
      },
    ));
  }
}
