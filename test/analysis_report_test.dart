// 解析报告渲染的测试（规范第七步「导出解析报告」）。
//
// 报告的价值不在于复述界面，而在于把**状态与来源**固定下来。因此断言集中在：
// - 每个字段都带 status / source，而不是只有一个值；
// - 「没做的检查」被单独列出 —— 报告里出现空白时，读者必须能分辨
//   「查了没有」与「根本没查」；
// - 结论是「无法确认」时，工具原始输出必须出现（原因只在那里）；
// - 值里含 `|` 或换行时不会把 Markdown 表格撑破。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show AndroidComponent, ComponentType, ContainerStructure, HardeningSignal;
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show
        IosBundle,
        IosBundleKind,
        IosIconResolution,
        IosSignatureMaterials,
        IpaContainer;

final DateTime _at = DateTime.utc(2026, 10, 13, 12, 0, 0);

PackageAnalysisResult _android({
  SignatureAnalysis? signature,
  bool withHash = true,
  List<HardeningHint> hints = const [],
  List<AnalysisDiagnostic> diagnostics = const [],
  SecurityAnalysisResult? security,
  SplitConsistency? splitConsistency,
}) =>
    PackageAnalysisResult(
      platform: PackagePlatform.android,
      fileName: const FieldValue<String>.extracted(
        'example.apk',
        source: FieldSource.fileSystem,
      ),
      fileSize: const FieldValue<int>.extracted(
        123456,
        source: FieldSource.fileSystem,
      ),
      sha256: withHash
          ? const FieldValue<String>.extracted(
              'abc123',
              source: FieldSource.fileSystem,
            )
          : const FieldValue<String>.notRequested(
              diagnostic: 'hashing is disabled in settings',
              source: FieldSource.fileSystem,
            ),
      appName: const FieldValue<String>.extracted(
        'Example',
        source: FieldSource.builtinParser,
      ),
      packageId: const FieldValue<String>.extracted(
        'com.example.app',
        source: FieldSource.builtinParser,
      ),
      version: const FieldValue<String>.extracted(
        '1.2.3',
        source: FieldSource.builtinParser,
      ),
      buildNumber: const FieldValue<String>.absent(
        source: FieldSource.builtinParser,
      ),
      signatureVerdict: PackageAnalysisResult.verdictFrom(signature),
      diagnostics: diagnostics,
      android: AndroidPackageInfo(
        minSdkVersion: const FieldValue<int>.extracted(
          21,
          source: FieldSource.builtinParser,
        ),
        maxSdkVersion: const FieldValue<int>.unsupported(
          diagnostic: 'aapt2 does not report maxSdkVersion',
        ),
        debuggable: const FieldValue<bool>.wrongType(
          diagnostic: 'android:debuggable is string, expected a boolean',
          source: FieldSource.builtinParser,
        ),
        permissions: const FieldValue<List<String>>.extracted(
          ['android.permission.INTERNET'],
          source: FieldSource.builtinParser,
        ),
        components: const FieldValue<List<AndroidComponent>>.extracted(
          [
            AndroidComponent(
              type: ComponentType.activity,
              name: 'com.example.app.MainActivity',
              exported: true,
            ),
          ],
          source: FieldSource.builtinParser,
        ),
        signature: signature,
        hardeningHints: hints,
        structure: const ContainerStructure(fileEntryCount: 12),
      ),
      security: security,
      splitConsistency: splitConsistency,
    );

PackageAnalysisResult _ios({
  IosCodeSignResult? codeSign,
  IosSignatureMaterials? materials,
  List<String>? queriesSchemes,
  String? unavailableReason,
}) =>
    PackageAnalysisResult(
      platform: PackagePlatform.ios,
      fileName: const FieldValue<String>.extracted(
        'Example.ipa',
        source: FieldSource.fileSystem,
      ),
      fileSize: const FieldValue<int>.extracted(
        987654,
        source: FieldSource.fileSystem,
      ),
      sha256: const FieldValue<String>.extracted(
        'def456',
        source: FieldSource.fileSystem,
      ),
      appName: const FieldValue<String>.extracted(
        'Example',
        source: FieldSource.infoPlist,
      ),
      packageId: const FieldValue<String>.extracted(
        'com.example.app',
        source: FieldSource.infoPlist,
      ),
      version: const FieldValue<String>.extracted(
        '2.4.1',
        source: FieldSource.infoPlist,
      ),
      buildNumber: const FieldValue<String>.extracted(
        '241',
        source: FieldSource.infoPlist,
      ),
      signatureVerdict: PackageAnalysisResult.verdictFromIos(codeSign),
      ios: IosPackageInfo(
        container: const IpaContainer(),
        bundleIdentifier: const FieldValue<String>.extracted(
          'com.example.app',
          source: FieldSource.infoPlist,
        ),
        queriesSchemes: queriesSchemes == null
            ? const FieldValue<List<String>>.absent(
                source: FieldSource.infoPlist)
            : FieldValue<List<String>>.extracted(
                queriesSchemes,
                source: FieldSource.infoPlist,
              ),
        signatureMaterials: materials,
        codeSign: codeSign,
        icon: const IosIconResolution(),
        unavailableReason: unavailableReason,
      ),
    );

void main() {
  // 与 detail_renderer_test 一致：直接用 slang 的全局 `t`（基准语言 en）。

  group('AnalysisReport — 字段的状态与来源必须保留', () {
    test('报告里每个字段都带 status 与 source 列', () {
      final report = AnalysisReport.render(_android(), t, generatedAt: _at);

      expect(report, contains(t.report.column_status));
      expect(report, contains(t.report.column_source));
      // 有值的字段
      expect(report, contains('extracted'));
      expect(report, contains('builtinParser'));
      // 类型不符的字段：状态必须出现，而不是只留一个空白
      expect(report, contains('wrongType'));
      expect(report, contains('android:debuggable is string'));
      // 来源不报的字段：与「文件里没有」区分开
      expect(report, contains('unsupported'));
      expect(report, contains('aapt2 does not report maxSdkVersion'));
    });

    test('缺失的字段值是破折号，而不是伪造的默认值', () {
      final report = AnalysisReport.render(_android(), t, generatedAt: _at);

      // 构建号是 absent，值列应为破折号。
      final line = report
          .split('\n')
          .firstWhere((l) => l.startsWith('| ${t.apk_info.version_code} '));
      expect(line, contains('—'));
      expect(line, contains('absent'));
    });

    test('组件用可读文本渲染，不出现 Dart 对象转储', () {
      final report = AnalysisReport.render(_android(), t, generatedAt: _at);

      expect(report, contains('com.example.app.MainActivity'));
      // `AndroidComponent{activity, name: ..., permission: null}` 这种
      // 对象转储不该出现在给人看的报告里。
      expect(report, isNot(contains('AndroidComponent{')));
      expect(report, isNot(contains('permission: null')));
      expect(report, isNot(contains('hasIntentFilter')));
    });

    test('头部含文件名、平台、大小与生成时间', () {
      final report = AnalysisReport.render(_android(), t, generatedAt: _at);

      expect(report, startsWith('# ${t.report.title}'));
      expect(report, contains('example.apk'));
      expect(report, contains('Android'));
      expect(report, contains('123456'));
      expect(report, contains('2026-10-13T12:00:00.000Z'));
    });
  });

  group('AnalysisReport — 没做的检查必须单独列出', () {
    test('未算哈希时在「未执行」一节说明', () {
      final report = AnalysisReport.render(
        _android(withHash: false),
        t,
        generatedAt: _at,
      );

      expect(report, contains(t.report.limitations));
      expect(report, contains(t.report.limitation_hash));
    });

    test('未启用签名检查时说明', () {
      final report = AnalysisReport.render(_android(), t, generatedAt: _at);

      expect(report, contains(t.report.limitation_signature));
    });

    test('iOS 没跑 codesign 时明确说「材料不等于验证通过」', () {
      const materials = IosSignatureMaterials(
        bundle: IosBundle(
          kind: IosBundleKind.mainApp,
          path: 'Payload/Example.app',
          name: 'Example.app',
        ),
        hasCodeSignatureDirectory: true,
        codeSignatureEntries: ['CodeResources'],
      );
      final report = AnalysisReport.render(
        _ios(materials: materials),
        t,
        generatedAt: _at,
      );

      expect(report, contains(t.report.limitation_codesign));
      expect(report, contains('do NOT prove the signature is valid'));
      // 结论也必须是「无法确认」，不是「有效」。
      expect(report, contains(t.signature.status_unknown));
      expect(report, isNot(contains(t.signature.status_verified)));
    });

    test('全部检查都做了且都有结论时不出现「未执行」一节', () {
      const signature = SignatureAnalysis(
        status: SignatureStatus.verified,
        toolExecuted: true,
        exitCode: 0,
      );
      final report = AnalysisReport.render(
        _android(
          signature: signature,
          security: const SecurityAnalysisResult(
            engineVersion: 'test',
            rulesVersion: 'test',
            findings: [],
            limitations: [],
          ),
        ),
        t,
        generatedAt: _at,
      );

      expect(report, isNot(contains(t.report.limitations)));
    });
  });

  group('AnalysisReport — 结论与原始输出', () {
    test('Android 签名通过时结论是「通过」', () {
      const signature = SignatureAnalysis(
        status: SignatureStatus.verified,
        toolExecuted: true,
        exitCode: 0,
      );
      final report = AnalysisReport.render(
        _android(signature: signature),
        t,
        generatedAt: _at,
      );

      expect(report, contains(t.signature.status_verified));
    });

    test('codesign 没有明确结论时原始输出必须出现', () {
      const result = IosCodeSignResult(
        status: SignatureStatus.verificationFailed,
        toolExecuted: true,
        exitCode: 3,
        stderr: 'Adhoc.app: does not satisfy its designated Requirement',
        error: 'the signature seal is intact',
      );
      final report = AnalysisReport.render(
        _ios(codeSign: result),
        t,
        generatedAt: _at,
      );

      expect(report, contains('designated Requirement'));
      expect(report, contains(t.signature.status_failed));
    });

    test('iOS 分析整体不可用时说明原因，而不是留空', () {
      final report = AnalysisReport.render(
        _ios(unavailableReason: 'the archive could not be opened'),
        t,
        generatedAt: _at,
      );

      expect(report, contains('the archive could not be opened'));
      expect(report, contains(t.report.limitation_ios_analysis));
    });

    test('加固线索连同置信度一起列出', () {
      final report = AnalysisReport.render(
        _android(hints: const [
          HardeningHint(
            signal: HardeningSignal.dexHeaderNotStandard,
            evidence: 'classes.dex: header is 0x9d',
            confidence: HintConfidence.strong,
          ),
        ]),
        t,
        generatedAt: _at,
      );

      expect(report, contains('dexHeaderNotStandard'));
      expect(report, contains('classes.dex: header is 0x9d'));
      expect(report, contains(t.apk_info.confidence_strong));
    });

    test('没有诊断时明确说「没有」，而不是留一节空白', () {
      final report = AnalysisReport.render(_android(), t, generatedAt: _at);

      expect(report, contains(t.report.no_diagnostics));
    });

    test('诊断以表格列出，含级别与稳定标识', () {
      final report = AnalysisReport.render(
        _android(diagnostics: const [
          AnalysisDiagnostic.warning(
            'ios.signature.no_code_signature_dir',
            'no _CodeSignature directory',
          ),
        ]),
        t,
        generatedAt: _at,
      );

      expect(report, contains('warning'));
      expect(report, contains('ios.signature.no_code_signature_dir'));
      expect(report, contains('no _CodeSignature directory'));
    });
  });

  group('AnalysisReport — Markdown 结构不被撑破', () {
    test('值里含竖线时被转义', () {
      final report = AnalysisReport.render(
        PackageAnalysisResult(
          platform: PackagePlatform.android,
          fileName: const FieldValue<String>.extracted(
            'a|b.apk',
            source: FieldSource.fileSystem,
          ),
          appName: const FieldValue<String>.extracted(
            'A | B',
            source: FieldSource.builtinParser,
          ),
        ),
        t,
        generatedAt: _at,
      );

      expect(report, contains(r'A \| B'));
      // 数**未转义**的竖线：被 `\|` 转义的那个不算分隔符。
      // 5 列的行应当正好有 6 个未转义竖线，多出来就说明表格被撑破了。
      final row = report
          .split('\n')
          .firstWhere((l) => l.startsWith('| ${t.apk_info.app_name} '));
      expect(RegExp(r'(?<!\\)\|').allMatches(row).length, 6,
          reason: '5 列的行应当正好有 6 个未转义竖线：$row');
    });

    test('多值字段用 <br> 分隔，行内不出现裸换行', () {
      final report = AnalysisReport.render(
        _ios(
          queriesSchemes: const ['weixin', 'alipay'],
        ),
        t,
        generatedAt: _at,
      );

      final row = report
          .split('\n')
          .firstWhere((l) => l.startsWith('| ${t.ios_info.queries_schemes} '));
      expect(row, contains('weixin<br>alipay'));
      // 行内不能有裸换行 —— 那会把表格从中间截断。
      expect(row, isNot(contains('\n')));
    });

    test('列表值用 <br> 连接', () {
      final report = AnalysisReport.render(
        PackageAnalysisResult(
          platform: PackagePlatform.ios,
          fileName: const FieldValue<String>.extracted(
            'x.ipa',
            source: FieldSource.fileSystem,
          ),
          ios: IosPackageInfo(
            container: const IpaContainer(),
            deviceFamily: const FieldValue<List<int>>.extracted(
              [1, 2],
              source: FieldSource.infoPlist,
            ),
            icon: const IosIconResolution(),
          ),
        ),
        t,
        generatedAt: _at,
      );

      expect(report, contains('iPhone, iPad'));
    });
  });

  group('AnalysisReport — 文件名', () {
    test('含原名、平台与时间戳，便于同一包的多个版本各存一份', () {
      final name = AnalysisReport.suggestedFileName(_android(), _at);

      expect(name, 'example_android_20261013T120000.md');
    });

    test('iOS 的文件名带上 ios 与 .ipa 原名的主干', () {
      final name = AnalysisReport.suggestedFileName(_ios(), _at);

      expect(name, 'Example_ios_20261013T120000.md');
    });

    test('没有文件名时用 package 兜底，不产生空文件名', () {
      final name = AnalysisReport.suggestedFileName(
        const PackageAnalysisResult(platform: PackagePlatform.unknown),
        _at,
      );

      expect(name, isNotEmpty);
      expect(name, endsWith('.md'));
      expect(name, contains('unknown'));
    });
  });
  // ---- 阶段 6：结构化覆盖进报告 ----
  group('AnalysisReport — 逐维度的分析覆盖', () {
    const coverage = AnalysisCoverage(entries: [
      CoverageEntry(id: 'android.manifest', status: CoverageStatus.covered),
      CoverageEntry(
        id: 'android.dex.strings',
        status: CoverageStatus.partial,
        covered: 1024,
        limit: 2048,
        note: '1 个 DEX 未完整扫描',
      ),
      CoverageEntry(
          id: 'android.arsc', status: CoverageStatus.notCovered, note: '资源表缺失'),
      CoverageEntry(id: 'ios.signature', status: CoverageStatus.notApplicable),
    ]);
    const security = SecurityAnalysisResult(
      engineVersion: 'e',
      rulesVersion: 'r',
      coverage: coverage,
    );

    test('Markdown 里有覆盖一节，逐维度列出状态与覆盖量', () {
      final report = AnalysisReport.render(
        _android(security: security),
        t,
        generatedAt: _at,
      );

      expect(report, contains('## ${t.coverage.title}'));
      // 维度列是**本地化名字**，不是机器标识 —— 机器标识留给 JSON（见下一条）。
      // 这条断言此前写的是 `contains('android.manifest')` 等，等于把缺陷
      // （把 `android.dex.strings` 直接摆给用户看）当成了正确行为。
      for (final id in [
        'android.manifest',
        'android.dex.strings',
        'android.arsc',
      ]) {
        expect(report, isNot(contains(id)),
            reason: 'Markdown 不该把机器标识 $id 呈现给用户');
        expect(report, contains(AnalysisReport.coverageDimensionLabel(id, t)),
            reason: 'Markdown 缺 $id 的本地化名字');
      }
      expect(report, contains(t.coverage.covered));
      expect(report, contains(t.coverage.partial));
      expect(report, contains('1024/2048'), reason: '覆盖量要能看到');
      expect(report, contains(t.coverage.not_covered));
      expect(report, contains('资源表缺失'), reason: '「为什么没覆盖」要带上');
      expect(report, contains(t.coverage.not_applicable));
      expect(report, contains(t.coverage.hint));
    });

    test('JSON 的 coverage 带结构化 entries，而不是只有一句 hasGaps', () {
      final json = AnalysisReport.renderJson(
        _android(security: security),
        generatedAt: _at,
        t: t,
      );

      expect(json, contains('"coverage"'));
      expect(json, contains('"entries"'));
      expect(json, contains('"id": "android.dex.strings"'));
      expect(json, contains('"status": "partial"'));
      expect(json, contains('"covered": 1024'));
      expect(json, contains('"limit": 2048'));
      // 与既有 severity / confidence 一致：用 Dart 枚举名（camelCase）。
      expect(json, contains('"status": "notApplicable"'));
      // 旧的字段不能丢 —— 已有消费者依赖它。
      expect(json, contains('"hasGaps"'));
      expect(json, contains('"limitations"'));
    });

    test('schema 版本随结构变化递增，且本版新增的字段确实在', () {
      // 自带一条**带全部 code 的**发现项：上面那个 `security` 夹具没有发现项，
      // 拿它断言只会测到「没有 findings 时也不崩」。
      const withCodes = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        findings: [
          SecurityFinding(
            ruleId: 'X',
            platform: SecurityPlatform.android,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.confirmed,
            finding: 'f',
            evidence: [
              SecurityEvidence(
                source: SecurityEvidenceSource.manifest,
                location: 'loc',
                detail: 'd',
                locationCode: 'loc.code',
                detailCode: 'detail.code',
              ),
            ],
            recommendation: 'rec',
            messageCode: 'msg.code',
            recommendationCode: 'rec.code',
            relationshipCode: 'rel.code',
            limitationCode: 'lim.code',
          ),
        ],
      );

      final json = AnalysisReport.renderJson(
        _android(security: withCodes),
        generatedAt: _at,
        t: t,
      );

      // v4：B11 给 findings[] 与 evidence[] 补了稳定 code。
      // 版本号与字段**必须一起断言** —— 只改号不加字段（或反之）都会让
      // 消费脚本的判断落空。
      expect(json, contains('"reportSchemaVersion": 7'));
      for (final field in [
        '"messageCode"',
        '"recommendationCode"',
        '"relationshipCode"',
        '"limitationCode"',
        '"locationCode"',
        '"detailCode"',
      ]) {
        expect(json, contains(field), reason: 'v4 声明的字段 $field 不在输出里');
      }
    });

    // 阶段 4.3：证据位置 / 详情的**可读化**。
    //
    // 只改呈现 —— JSON 与引擎数据保留原始描述符，那是能逐字对上
    // `dexdump -d` 输出的形式。
    group('证据可读化', () {
      test('类型描述符展开成包名形式', () {
        expect(
          AnalysisReport.readableEvidenceText('Lcom/foo/Bar;'),
          'com.foo.Bar',
        );
        expect(
          AnalysisReport.readableEvidenceText('[Ljava/lang/String;'),
          'java.lang.String[]',
        );
      });

      test('方法引用与调用点的整条样本都可读', () {
        expect(
          AnalysisReport.readableEvidenceText(
            'Lcom/foo/Bar;.baz(Ljava/lang/String;)V '
            '@ Lcom/foo/Other;.open +0x10',
          ),
          'com.foo.Bar.baz(java.lang.String)V '
          '@ com.foo.Other.open +16',
        );
      });

      test('偏移标成十进制（十六进制只是 DEX 里的写法）', () {
        expect(AnalysisReport.readableEvidenceText('+0x254'), '+596');
        expect(AnalysisReport.readableEvidenceText('+0x0'), '+0');
      });

      test('没有描述符的文本原样返回', () {
        const plain = 'AndroidManifest.xml / manifest / uses-permission';
        expect(AnalysisReport.readableEvidenceText(plain), plain);
        expect(
            AnalysisReport.readableEvidenceText('classes.dex'), 'classes.dex');
      });
    });

    test('没有 coverage 时不出现覆盖一节，也不崩', () {
      final report = AnalysisReport.render(_android(), t, generatedAt: _at);

      expect(report, isNot(contains('## ${t.coverage.title}')));
    });

    test('「仅安全检测」范围下覆盖一节仍然保留', () {
      final report = AnalysisReport.render(
        _android(security: security),
        t,
        generatedAt: _at,
        securityOnly: true,
      );

      expect(
        report,
        contains('## ${t.coverage.title}'),
        reason: '覆盖是安全结论可信度的一部分，不该被「仅安全」裁掉',
      );
    });
  });
  // ---- 阶段 6b：报告八部分里的「网络」与 JSON 平台事实 ----
  group('AnalysisReport — 网络一节与 JSON 平台事实', () {
    const network = SecurityAnalysisResult(
      engineVersion: 'e',
      rulesVersion: 'r',
      network: NetworkFacts(
        domains: ['api.example.com', 'cdn.example.net'],
        ips: ['203.0.113.7'],
      ),
    );
    const emptyNetwork = SecurityAnalysisResult(
      engineVersion: 'e',
      rulesVersion: 'r',
    );

    test('有端点时 Markdown 有独立一节，域名与 IP 分开列出', () {
      final report = AnalysisReport.render(
        _android(security: network),
        t,
        generatedAt: _at,
      );

      expect(report, contains('## ${t.report.network_section}'));
      expect(report, contains('### ${t.report.network_domains} (2)'));
      expect(report, contains('api.example.com'));
      expect(report, contains('cdn.example.net'));
      expect(report, contains('### ${t.report.network_ips} (1)'));
      expect(report, contains('203.0.113.7'));
      expect(
        report,
        contains(t.report.network_hint),
        reason: '「静态提取 ≠ 实际访问过」必须写在旁边',
      );
    });

    test('没有端点时整节不出现，而不是留一节空白', () {
      final report = AnalysisReport.render(
        _android(security: emptyNetwork),
        t,
        generatedAt: _at,
      );

      expect(report, isNot(contains('## ${t.report.network_section}')));
    });

    test('JSON 有 network 一级字段', () {
      final json = AnalysisReport.renderJson(
        _android(security: network),
        generatedAt: _at,
        t: t,
      );

      expect(json, contains('"network"'));
      expect(json, contains('"api.example.com"'));
      expect(json, contains('"203.0.113.7"'));
    });

    test('JSON 的 application 带权限数组', () {
      final json = AnalysisReport.renderJson(
        _android(),
        generatedAt: _at,
        t: t,
      );

      expect(json, contains('"permissions"'));
      expect(
        json,
        contains('"android.permission.INTERNET"'),
        reason: '权限是「声明了什么能力」的一等事实，'
            '不该要求消费者去解析 findings',
      );
    });

    test('JSON 的 signatureSummary 带平台详情（不只是结论）', () {
      const signature = SignatureAnalysis(
        status: SignatureStatus.verified,
        toolExecuted: true,
        exitCode: 0,
        verifiedSchemes: {'v2'},
      );
      final json = AnalysisReport.renderJson(
        _android(signature: signature),
        generatedAt: _at,
        t: t,
      );

      expect(json, contains('"signatureSummary"'));
      expect(json, contains('"verdict"'));
      expect(
        json,
        contains('"v2"'),
        reason: '只给结论不给详情时，JSON 消费者看不到用的是哪个签名方案',
      );
      expect(json, contains('"toolExecuted"'));
    });
  });

  group('AnalysisReport — 分包一致性（RPT）', () {
    test('没查分包时不渲染空章节（空章节会被读成「查了没问题」）', () {
      final report = AnalysisReport.render(_android(), t, generatedAt: _at);
      expect(report, isNot(contains('## ${t.report.split_section}')));
    });

    test('查过且有分包时单列一节，给出比对数量与结论', () {
      final report = AnalysisReport.render(
        _android(
          splitConsistency: const SplitConsistency(
            checkedCount: 2,
            totalCount: 2,
          ),
        ),
        t,
        generatedAt: _at,
      );

      expect(report, contains('## ${t.report.split_section}'));
      expect(report, contains(t.report.split_all_checked));
      expect(report, contains(t.report.split_no_issues));
      expect(report, contains(t.report.split_note));
    });

    test('抽检没查完时明确说明未比对数量，而不是说「没问题」', () {
      final report = AnalysisReport.render(
        _android(
          splitConsistency:
              const SplitConsistency(checkedCount: 1, totalCount: 4),
        ),
        t,
        generatedAt: _at,
      );

      expect(report, contains(t.report.split_unchecked(count: 3)));
      expect(report, isNot(contains(t.report.split_all_checked)));
    });

    test('发现不一致时逐条列出', () {
      final report = AnalysisReport.render(
        _android(
          splitConsistency: const SplitConsistency(
            issues: ['split_config.en: packageName differs from base'],
            checkedCount: 1,
            totalCount: 1,
          ),
        ),
        t,
        generatedAt: _at,
      );

      expect(report, contains(t.report.split_issue_count(count: 1)));
      expect(
          report, contains('split_config.en: packageName differs from base'));
      expect(report, isNot(contains(t.report.split_no_issues)));
    });

    test('JSON 里 splitConsistency 是结构化的，没查时为 null', () {
      final notChecked = AnalysisReport.renderJson(
        _android(),
        generatedAt: _at,
        t: t,
      );
      expect(notChecked, contains('"splitConsistency": null'));

      final checked = AnalysisReport.renderJson(
        _android(
          splitConsistency: const SplitConsistency(
            issues: ['a differs'],
            checkedCount: 1,
            totalCount: 3,
          ),
        ),
        generatedAt: _at,
        t: t,
      );
      expect(checked, contains('"checkedCount": 1'));
      expect(checked, contains('"totalCount": 3'));
      expect(checked, contains('"isFullyChecked": false'));
      expect(checked, contains('"uncheckedCount": 2'));
      expect(checked, contains('"a differs"'));
    });

    test('「仅安全检测」范围不含分包章节（它是结构事实，不是安全结论）', () {
      final report = AnalysisReport.render(
        _android(
          splitConsistency: const SplitConsistency(
            checkedCount: 1,
            totalCount: 1,
          ),
        ),
        t,
        generatedAt: _at,
        securityOnly: true,
      );
      expect(report, isNot(contains('## ${t.report.split_section}')));
    });
  });
}
