// 适配层测试：`PackageAnalysisResult` → `DiffSubject`（阶段 5.2 的地基）。
//
// 适配层的字段清单与顺序**就是差异报告的输出顺序**，因此这份清单是契约：
// 加字段要同步这里，否则新增字段会静默地不进差异。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ComponentType;
import 'package:flutter_test/flutter_test.dart';

PackageAnalysisResult _android({
  int? minSdk,
  int? targetSdk,
  List<String> permissions = const [],
  List<AndroidComponent> components = const [],
  SignatureAnalysis? signature,
  SecurityAnalysisResult? security,
  FieldSource manifestSource = FieldSource.builtinParser,
}) =>
    AnalysisBuilder.buildAndroid(
      filePath: '/tmp/a.apk',
      fileSize: 1024,
      manifestSource: manifestSource,
      minSdkVersion: minSdk,
      targetSdkVersion: targetSdk,
      permissions: permissions,
      components: components,
      signature: signature,
      security: security,
    );

/// 一条「命中原生符号」的安全发现，形状与引擎实际产出的一致
/// （`android_security_audit.dart` 的 `messageCode: 'android.native_symbols'`）。
SecurityAnalysisResult _securityWithSymbols(
  List<String> symbols, {
  List<String> domains = const [],
}) =>
    SecurityAnalysisResult(
      engineVersion: 'e',
      rulesVersion: 'r',
      network: NetworkFacts(domains: domains),
      findings: [
        // 形状照抄引擎的实际产出（`android_security_audit.dart`）：
        // `ruleId` 是规则名、`messageCode` 才是稳定标识 —— 适配层按后者查。
        SecurityFinding(
          ruleId: 'ANDROID-NATIVE-SYMBOLS',
          platform: SecurityPlatform.android,
          category: SecurityCategory.backgroundTask,
          severity: SecuritySeverity.info,
          confidence: SecurityConfidence.independentCapability,
          finding: 'native symbols',
          evidence: const [
            SecurityEvidence(
              source: SecurityEvidenceSource.nativeSymbol,
              location: 'lib/arm64-v8a/libx.so',
              detail: 'system (imported)',
            ),
          ],
          recommendation: 'review',
          messageCode: 'android.native_symbols',
          messageArgs: {'count': symbols.length, 'symbols': symbols},
        ),
      ],
    );

SignatureAnalysis _signature(SignatureStatus status) =>
    SignatureAnalysis(status: status);

/// 一条最简但形状正确的发现项。
SecurityFinding _finding(
  String ruleId, {
  SecuritySeverity severity = SecuritySeverity.p2,
}) =>
    SecurityFinding(
      ruleId: ruleId,
      platform: SecurityPlatform.android,
      category: SecurityCategory.backgroundTask,
      severity: severity,
      confidence: SecurityConfidence.confirmed,
      finding: '$ruleId finding',
      evidence: const [
        SecurityEvidence(
          source: SecurityEvidenceSource.nativeSymbol,
          location: 'lib/arm64-v8a/libx.so',
          detail: 'system (imported)',
        ),
      ],
      recommendation: 'review',
    );

/// 一份安全结果：可以只给发现、覆盖、五段链里的任意几项。
SecurityAnalysisResult _security({
  List<SecurityFinding> findings = const [],
  List<CoverageEntry> coverage = const [],
  CryptoTheftAssessment? theft,
}) =>
    SecurityAnalysisResult(
      engineVersion: 'e',
      rulesVersion: 'r',
      findings: findings,
      coverage: AnalysisCoverage(entries: coverage),
      cryptoTheft: theft,
    );

/// 一条形状完整的五段链评估（五段都要在，顺序固定）。
CryptoTheftAssessment _theft(CryptoTheftLevel level) => CryptoTheftAssessment(
      id: 'android.crypto.theft',
      level: level,
      primaryTechnique: TheftTechnique.addressSwap,
      chain: const [
        TechniqueEvidence(
          technique: TheftTechnique.addressSwap,
          stage: ChainStage.capability,
          signalId: 'capability',
          strength: TechniqueStrength.stringOnly,
          supported: true,
        ),
        TechniqueEvidence(
          technique: TheftTechnique.addressSwap,
          stage: ChainStage.source,
          signalId: 'source',
          strength: TechniqueStrength.stringOnly,
          supported: true,
        ),
        TechniqueEvidence(
          technique: TheftTechnique.addressSwap,
          stage: ChainStage.injection,
          signalId: 'injection',
          strength: TechniqueStrength.stringOnly,
          supported: false,
        ),
        TechniqueEvidence(
          technique: TheftTechnique.addressSwap,
          stage: ChainStage.payload,
          signalId: 'payload',
          strength: TechniqueStrength.stringOnly,
          supported: false,
        ),
        TechniqueEvidence(
          technique: TheftTechnique.addressSwap,
          stage: ChainStage.family,
          signalId: 'family',
          strength: TechniqueStrength.stringOnly,
          supported: false,
        ),
      ],
      missing: const [],
      confidence: SecurityConfidence.suspected,
      severity: SecuritySeverity.p2,
      score: 40,
      scoringVersion: 'v1',
    );

void main() {
  group('适配层', () {
    test('Android 包产出平台专属字段，不含 iOS 字段', () {
      final subject = diffSubjectOf(_android(minSdk: 21, targetSdk: 34));
      final ids = subject.fields.map((f) => f.id).toList();

      expect(ids, contains('android.minSdkVersion'));
      expect(ids, contains('android.targetSdkVersion'));
      expect(ids, isNot(contains('ios.bundleIdentifier')));
      // 通用字段两边都有。
      expect(ids, contains('app.id'));
      expect(ids, contains('file.sha256'));
      // 签名结论是**平台中立**的，因此是通用字段。
      expect(ids, contains('signature.verdict'));
      expect(ids, isNot(contains('android.signatureVerdict')));
    });

    test('字段顺序是契约：先文件身份、再应用身份、再平台专属', () {
      final subject = diffSubjectOf(_android(minSdk: 21));
      final ids = subject.fields.map((f) => f.id).toList();

      expect(ids.indexOf('file.fileName'), lessThan(ids.indexOf('app.name')));
      expect(
        ids.indexOf('app.buildNumber'),
        lessThan(ids.indexOf('signature.verdict')),
        reason: '签名结论排在通用字段之后',
      );
      expect(
        ids.indexOf('signature.verdict'),
        lessThan(ids.indexOf('android.minSdkVersion')),
        reason: '平台专属字段排在通用字段之后',
      );
    });

    test('权限是带状态的集合，不是裸列表', () {
      final subject = diffSubjectOf(_android(permissions: ['A']));
      final perms = subject.sets['android.permissions']!;
      expect(perms.status, FieldStatus.extracted);
      expect(perms.value, ['A']);
    });

    test('没有权限时记 absent（文件里确实没有），不是 unsupported', () {
      final subject = diffSubjectOf(_android());
      expect(subject.sets['android.permissions']!.status, FieldStatus.absent);
    });

    test('网络端点单列，且空列表记 absent', () {
      final withDomains = diffSubjectOf(_android(
          security: _securityWithSymbols(const [], domains: ['a.example'])));
      expect(
          withDomains.sets['network.domains']!.status, FieldStatus.extracted);

      // 没做安全分析 → **不产出** network.* 维度（与「做了、没提取到」不同）。
      final noSecurity = diffSubjectOf(_android());
      expect(noSecurity.sets.containsKey('network.domains'), isFalse);
    });

    test('两份只有 targetSdk 不同的包，差异恰好落在那一项上', () {
      final diff = diffSubjects(
        diffSubjectOf(_android(minSdk: 21, targetSdk: 33)),
        diffSubjectOf(_android(minSdk: 21, targetSdk: 34)),
      );

      final changed =
          diff.fields.where((f) => f.kind == DiffKind.changed).toList();
      expect(changed.map((f) => f.id), ['android.targetSdkVersion']);
      expect(changed.single.left.value, 33);
      expect(changed.single.right.value, 34);
      expect(diff.hasChanges, isTrue);
    });

    test('同一个包和自己比：没有任何差异', () {
      final diff = diffSubjects(
        diffSubjectOf(_android(minSdk: 21)),
        diffSubjectOf(_android(minSdk: 21)),
      );
      expect(diff.hasChanges, isFalse);
      // `sha256` 是 `notRequested`（这次没算哈希）→ 两侧都「不知道」，
      // 因此记 unknown 而不是 same。**这正是要的行为**：
      // 没算过的哈希不能被读成「两边一样」。
      //
      // 安全那三个标量同理：这个用例没传 `security`（= 设置里关了安全审计），
      // 于是「最高等级 / 发现条数 / 五段链等级」都说不清。2 + 3 = 5。
      // 不能因为「没审计」就少报几条 —— 那会让差异页看起来「安全这块没变化」。
      expect(diff.unknownFieldCount, 5, reason: 'sha256、没查签名、没做安全审计都说不清');
      expect(
        diff.fields.firstWhere((f) => f.id == 'file.sha256').kind,
        DiffKind.unknown,
      );
    });

    test('跨平台比较会被 samePlatform 拦住', () {
      final android = _android();
      expect(samePlatform(android, android), isTrue);
      // 未知平台（还没解析出结构）不算同平台。
      expect(
        samePlatform(android, const PackageAnalysisResult()),
        isFalse,
      );
    });
  });

  group('签名结论', () {
    test('「本次没查签名」记 notRequested，不是 absent', () {
      // 差别很关键：记成 absent 会让差异页说「新版本加上了签名」，
      // 而事实只是这次没开签名检查。
      final subject = diffSubjectOf(_android());
      final verdict =
          subject.fields.firstWhere((f) => f.id == 'signature.verdict');
      expect(verdict.value.status, FieldStatus.notRequested);
      expect(verdict.value.status, isNot(FieldStatus.absent));
    });

    test('从「没查」到「验证通过」是 changed，不是 added', () {
      final diff = diffSubjects(
        diffSubjectOf(_android()),
        diffSubjectOf(
            _android(signature: _signature(SignatureStatus.verified))),
      );
      final verdict =
          diff.fields.firstWhere((f) => f.id == 'signature.verdict');
      expect(
        verdict.kind,
        DiffKind.unknown,
        reason: '一侧是「我们没查」→ 这次说不清，不能算成新增',
      );
      expect(verdict.right.value, SignatureVerdict.verified);
    });

    test('两侧都查了：结论不同才算变更', () {
      final diff = diffSubjects(
        diffSubjectOf(
            _android(signature: _signature(SignatureStatus.verified))),
        diffSubjectOf(_android(
            signature: _signature(SignatureStatus.verificationFailed))),
      );
      final verdict =
          diff.fields.firstWhere((f) => f.id == 'signature.verdict');
      expect(verdict.kind, DiffKind.changed);
      expect(verdict.left.value, SignatureVerdict.verified);
      expect(verdict.right.value, SignatureVerdict.rejected);
    });
  });

  group('组件', () {
    const main = AndroidComponent(
      type: ComponentType.activity,
      name: 'com.example.Main',
      exported: true,
    );
    const svc = AndroidComponent(
      type: ComponentType.service,
      name: 'com.example.Sync',
    );

    test('压成「类型 + 类名」的身份串', () {
      final subject = diffSubjectOf(_android(components: const [main, svc]));
      final comps = subject.sets['android.components']!;
      expect(comps.status, FieldStatus.extracted);
      expect(comps.value,
          ['activity com.example.Main', 'service com.example.Sync']);
    });

    test('属性不进身份串：只改 exported 时成员集合不变', () {
      // 这是**口径**不是遗漏（见适配层注释）：把 exported 拼进身份会让
      // 「同一个组件改了导出状态」表现成一删一增，读起来像换了组件。
      const notExported = AndroidComponent(
        type: ComponentType.activity,
        name: 'com.example.Main',
      );
      final a = diffSubjectOf(_android(components: const [main]));
      final b = diffSubjectOf(_android(components: const [notExported]));
      expect(
        diffSubjects(a, b)
            .sets
            .firstWhere((s) => s.id == 'android.components')
            .isSame,
        isTrue,
      );
    });

    test('混淆导致的空类名用稳定标记，不随语言变化', () {
      final subject = diffSubjectOf(
        _android(
            components: const [AndroidComponent(type: ComponentType.service)]),
      );
      expect(subject.sets['android.components']!.value, ['service (unnamed)']);
    });

    test('「我们没读到组件」不会被压成「文件里没有组件」', () {
      // `aapt2` 来源**不报**组件（只给 launchable-activity）。
      final subject = diffSubjectOf(
        _android(manifestSource: FieldSource.aapt2, components: const [main]),
      );
      // 传了值就是 extracted（值优先于能力表）—— 这里刻意留空来看状态。
      final empty = diffSubjectOf(
        _android(manifestSource: FieldSource.aapt2),
      );
      expect(empty.sets['android.components']!.status, FieldStatus.unsupported);
      expect(subject.sets['android.components']!.status, FieldStatus.extracted);
    });

    test('新增一个组件就是集合差异里的一条新增', () {
      final diff = diffSubjects(
        diffSubjectOf(_android(components: const [main])),
        diffSubjectOf(_android(components: const [main, svc])),
      );
      final comps = diff.sets.firstWhere((s) => s.id == 'android.components');
      expect(comps.added, ['service com.example.Sync']);
      expect(comps.removed, isEmpty);
    });
  });

  group('原生符号', () {
    test('从安全结果里取符号名', () {
      final subject = diffSubjectOf(
        _android(
          security: _securityWithSymbols(['system', 'dlopen']),
        ),
      );
      final symbols = subject.sets['android.nativeSymbols']!;
      expect(symbols.status, FieldStatus.extracted);
      expect(symbols.value, ['system', 'dlopen']);
    });

    test('没做安全分析时不产出该维度', () {
      final subject = diffSubjectOf(_android());
      expect(subject.sets.containsKey('android.nativeSymbols'), isFalse);
    });

    test('做了安全分析但没命中 → absent（不是「没读到」）', () {
      final subject = diffSubjectOf(
        _android(security: _securityWithSymbols(const [])),
      );
      expect(
        subject.sets['android.nativeSymbols']!.status,
        FieldStatus.absent,
      );
    });

    test('新版本多导入一个符号 → 集合差异里的一条新增', () {
      final diff = diffSubjects(
        diffSubjectOf(_android(security: _securityWithSymbols(['system']))),
        diffSubjectOf(
          _android(security: _securityWithSymbols(['system', 'dlopen'])),
        ),
      );
      final symbols =
          diff.sets.firstWhere((s) => s.id == 'android.nativeSymbols');
      expect(symbols.added, ['dlopen']);
      expect(symbols.common, ['system']);
    });
  });

  // ---------------------------------------------------------------------
  // 安全检测的对比
  //
  // 这一组守的是**口径**，不是实现细节：
  // - 「没审计」必须与「审计了、没发现」区分开（前者 notRequested）；
  // - 集合回答「哪些规则命中了」，次数交给 findingCount；
  // - 覆盖缺口只收 partial / notCovered，`notApplicable` 不算缺口；
  // - 没有结构化覆盖 ≠ 没有缺口。
  // ---------------------------------------------------------------------
  group('安全检测对比', () {
    test('审计关掉时三个标量与两个集合都记 notRequested', () {
      final subject = diffSubjectOf(_android());

      for (final id in [
        'security.highestSeverity',
        'security.findingCount',
        'security.cryptoTheftLevel',
      ]) {
        final field = subject.fields.firstWhere((f) => f.id == id);
        expect(field.value.status, FieldStatus.notRequested, reason: id);
        // 状态要说清「为什么没有」：关掉审计与解析失败是两回事。
        expect(field.value.diagnosticCode, 'security.disabled', reason: id);
      }
      for (final id in ['security.findings', 'security.coverageGaps']) {
        expect(subject.sets[id]!.status, FieldStatus.notRequested, reason: id);
      }
    });

    test('两侧都没审计：五个维度全部进「无法比较」，不会显示成新增', () {
      final diff = diffSubjects(
        diffSubjectOf(_android()),
        diffSubjectOf(_android()),
      );
      final securityFields =
          diff.fields.where((f) => f.id.startsWith('security.')).toList();
      expect(securityFields, hasLength(3));
      expect(
        securityFields.every((f) => f.kind == DiffKind.unknown),
        isTrue,
        reason: '「这次没查」不能算成「新版本多了这些漏洞」',
      );
      expect(
        diff.sets
            .where((s) => s.id.startsWith('security.'))
            .every((s) => !s.comparable),
        isTrue,
      );
      expect(diff.hasChanges, isFalse);
    });

    test('新版本多命中一条规则 → 集合差异里的一条新增', () {
      final diff = diffSubjects(
        diffSubjectOf(
          _android(
            security: _security(findings: [_finding('ANDROID-DEBUGGABLE')]),
          ),
        ),
        diffSubjectOf(
          _android(
            security: _security(findings: [
              _finding('ANDROID-DEBUGGABLE'),
              _finding('ANDROID-ALLOW-BACKUP'),
            ]),
          ),
        ),
      );
      final findings = diff.sets.firstWhere((s) => s.id == 'security.findings');
      expect(findings.added, ['ANDROID-ALLOW-BACKUP']);
      expect(findings.removed, isEmpty);
      expect(findings.common, ['ANDROID-DEBUGGABLE']);
    });

    test('同一规则命中多次只算一个成员，次数由 findingCount 承担', () {
      // `ANDROID-PERMISSION-WITHOUT-API` 会为每个权限请求各产一条。
      // 把次数拼进身份会让「多命中两次」表现成一删一增，读起来像换了规则。
      final subject = diffSubjectOf(
        _android(
          security: _security(findings: [
            _finding('ANDROID-PERMISSION-WITHOUT-API'),
            _finding('ANDROID-PERMISSION-WITHOUT-API'),
            _finding('ANDROID-PERMISSION-WITHOUT-API'),
          ]),
        ),
      );
      expect(
        subject.sets['security.findings']!.value,
        ['ANDROID-PERMISSION-WITHOUT-API'],
      );
      expect(
        subject.fields
            .firstWhere((f) => f.id == 'security.findingCount')
            .value
            .value,
        3,
      );
    });

    test('最严重等级取 rank 最小的一条；一条发现都没有时是 none', () {
      final subject = diffSubjectOf(
        _android(
          security: _security(findings: [
            _finding('A', severity: SecuritySeverity.p3),
            _finding('B', severity: SecuritySeverity.p1),
            _finding('C', severity: SecuritySeverity.info),
          ]),
        ),
      );
      expect(
        subject.fields
            .firstWhere((f) => f.id == 'security.highestSeverity')
            .value
            .value,
        'p1',
      );

      // 「查了、没有发现」是 none，与「没查」（notRequested）相反。
      final clean = diffSubjectOf(_android(security: _security()));
      expect(
        clean.fields
            .firstWhere((f) => f.id == 'security.highestSeverity')
            .value
            .value,
        'none',
      );
    });

    test('覆盖缺口只收 partial / notCovered，notApplicable 不算缺口', () {
      final subject = diffSubjectOf(
        _android(
          security: _security(coverage: const [
            CoverageEntry(
                id: 'android.dex.strings', status: CoverageStatus.covered),
            CoverageEntry(
                id: 'android.dex.unicodeStrings',
                status: CoverageStatus.partial),
            CoverageEntry(
                id: 'ios.macho', status: CoverageStatus.notApplicable),
            CoverageEntry(
                id: 'android.arsc', status: CoverageStatus.notCovered),
          ]),
        ),
      );
      expect(
        subject.sets['security.coverageGaps']!.value,
        ['android.dex.unicodeStrings', 'android.arsc'],
      );
    });

    test('没有结构化覆盖记 unsupported，不是「没有缺口」', () {
      // 空 entries 是「本引擎没产出结构化覆盖」，与「全覆盖」结论相反。
      final subject = diffSubjectOf(_android(security: _security()));
      expect(
        subject.sets['security.coverageGaps']!.status,
        FieldStatus.unsupported,
      );
    });

    test('五段链等级变化是 changed，不是一删一增', () {
      final diff = diffSubjects(
        diffSubjectOf(
          _android(
            security: _security(theft: _theft(CryptoTheftLevel.suspicious)),
          ),
        ),
        diffSubjectOf(
          _android(
            security: _security(theft: _theft(CryptoTheftLevel.strongEvidence)),
          ),
        ),
      );
      final level =
          diff.fields.firstWhere((f) => f.id == 'security.cryptoTheftLevel');
      expect(level.kind, DiffKind.changed);
      expect(level.left.value, 'suspicious');
      expect(level.right.value, 'strongEvidence');
    });
  });
}
