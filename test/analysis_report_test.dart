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
        permissions: const ['android.permission.INTERNET'],
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
}
