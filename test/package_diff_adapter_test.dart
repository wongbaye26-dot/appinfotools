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
      expect(diff.unknownFieldCount, 2, reason: 'sha256 与「没查签名」都说不清');
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
}
