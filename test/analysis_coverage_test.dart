// 结构化分析覆盖（阶段 6）。
//
// 覆盖率此前散落在 `limitations` 的句子里、各扫描器的 `truncated` 标志、
// 以及个别发现项里 —— UI 与报告只能各自去猜。这一层把它收敛成**带稳定 id 的
// 数据**，两端（Android / iOS）用同一套模型。
//
// 断言的重点是**状态区分**：
// - `notApplicable` 不是缺口（「这件事在这个平台上不存在」≠「没查到」）；
// - `partial` 与 `notCovered` 分开（补救方式不同：扩大预算 vs 先跑起来）；
// - 合并同一维度时取**更差**的一条（覆盖是木桶）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:archive/archive.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart';

const String _dexDir = 'test/fixtures/dex';

Uint8List _fixture(String name) => File('$_dexDir/$name').readAsBytesSync();

void main() {
  group('AnalysisCoverage 的状态语义', () {
    test('notApplicable 不是缺口', () {
      const coverage = AnalysisCoverage(entries: [
        CoverageEntry(id: 'a', status: CoverageStatus.covered),
        CoverageEntry(id: 'b', status: CoverageStatus.notApplicable),
      ]);

      expect(
        coverage.hasGaps,
        isFalse,
        reason: '「本次不适用」是「这件事在这个平台上不存在」，不是「没查到」',
      );
      expect(coverage.applicable, hasLength(1));
      expect(coverage.gaps, isEmpty);
    });

    test('partial 与 notCovered 都算缺口，且分开', () {
      const coverage = AnalysisCoverage(entries: [
        CoverageEntry(id: 'a', status: CoverageStatus.partial),
        CoverageEntry(id: 'b', status: CoverageStatus.notCovered),
      ]);

      expect(coverage.hasGaps, isTrue);
      expect(coverage.gaps, hasLength(2));
      expect(
        coverage.entry('a')!.status,
        CoverageStatus.partial,
        reason: '两者补救方式不同：部分覆盖要扩大预算，没覆盖要先让它跑起来',
      );
      expect(coverage.entry('b')!.status, CoverageStatus.notCovered);
    });

    test('ratioText 只在两端都有值时给出，不编造 0', () {
      const withRatio = CoverageEntry(
          id: 'a', status: CoverageStatus.partial, covered: 3, limit: 10);
      const noLimit =
          CoverageEntry(id: 'b', status: CoverageStatus.covered, covered: 3);
      const zeroLimit = CoverageEntry(
          id: 'c', status: CoverageStatus.covered, covered: 3, limit: 0);

      expect(withRatio.ratioText, '3/10');
      expect(noLimit.ratioText, isNull);
      expect(zeroLimit.ratioText, isNull, reason: '0 作分母没有意义');
    });

    test('合并同一维度时保留更差的一条', () {
      const a = AnalysisCoverage(entries: [
        CoverageEntry(id: 'x', status: CoverageStatus.covered, covered: 10),
      ]);
      const b = AnalysisCoverage(entries: [
        CoverageEntry(id: 'x', status: CoverageStatus.partial, covered: 5),
      ]);

      final merged = a.merge(b);
      expect(merged.entries, hasLength(1));
      expect(
        merged.entry('x')!.status,
        CoverageStatus.partial,
        reason: '覆盖是木桶：两条路径里有一条没覆盖完，整体就没覆盖完',
      );
    });

    test('状态相同时保留覆盖量更小的一条', () {
      const a = AnalysisCoverage(entries: [
        CoverageEntry(id: 'x', status: CoverageStatus.covered, covered: 10),
      ]);
      const b = AnalysisCoverage(entries: [
        CoverageEntry(id: 'x', status: CoverageStatus.covered, covered: 3),
      ]);

      expect(a.merge(b).entry('x')!.covered, 3);
    });

    test('合并时不同 id 都保留', () {
      const a = AnalysisCoverage(entries: [
        CoverageEntry(id: 'x', status: CoverageStatus.covered),
      ]);
      const b = AnalysisCoverage(entries: [
        CoverageEntry(id: 'y', status: CoverageStatus.covered),
      ]);

      expect(a.merge(b).entries, hasLength(2));
    });

    test('空 coverage 不算缺口，但 isEmpty 为真（「没报」≠「全覆盖」）', () {
      const empty = AnalysisCoverage();
      expect(empty.isEmpty, isTrue);
      expect(empty.hasGaps, isFalse);
    });
  });

  group('Android 审计产出结构化覆盖', () {
    SecurityAnalysisResult auditWith({
      required List<DexBytes> dexEntries,
      bool manifestParsed = true,
      List<NativeLibraryBytes> nativeEntries = const [],
    }) =>
        AndroidSecurityAudit.audit(
          meta: ApkMeta()
            ..permissionRequests = const []
            ..locales = const ['en']
            ..densities = const [240],
          dexEntries: dexEntries,
          nativeEntries: nativeEntries,
          manifestParsed: manifestParsed,
          manifestFailureReason: manifestParsed ? null : 'manifest truncated',
        );

    test('结构正常的 DEX 下各维度都是 covered', () {
      final result = auditWith(
        dexEntries: [
          DexBytes('classes.dex', _fixture('real-netprobe.dex')),
        ],
      );

      final coverage = result.coverage;
      expect(coverage.isEmpty, isFalse);
      for (final id in const [
        'android.manifest',
        'android.permissions',
        'android.dex.structure',
        'android.dex.strings',
        'android.dex.methodReferences',
        'android.dex.callSites',
        'android.arsc',
      ]) {
        expect(
          coverage.entry(id)!.status,
          CoverageStatus.covered,
          reason: '$id 应当是 covered：${coverage.entry(id)}',
        );
      }
    });

    test('没有原生库时该维度是 notApplicable，不是缺口', () {
      final result = auditWith(
        dexEntries: [
          DexBytes('classes.dex', _fixture('real-netprobe.dex')),
        ],
      );

      final entry = result.coverage.entry('android.nativeSymbols')!;
      expect(entry.status, CoverageStatus.notApplicable);
      expect(
        result.coverage.gaps.any((e) => e.id == 'android.nativeSymbols'),
        isFalse,
        reason: '「没有原生库」不该被算成覆盖缺口',
      );
    });

    test('清单未解析时相关维度是 notCovered 并写明原因', () {
      final result = auditWith(dexEntries: const [], manifestParsed: false);

      final manifest = result.coverage.entry('android.manifest')!;
      expect(manifest.status, CoverageStatus.notCovered);
      expect(manifest.note, contains('manifest truncated'));

      expect(
        result.coverage.entry('android.permissions')!.status,
        CoverageStatus.notCovered,
      );
    });

    test('网络端点从 DEX 字符串里提取出来并单列成一级字段', () {
      final blob = Uint8List.fromList(
        'https://api.example.com/upload\n203.0.113.9\n'.codeUnits,
      );
      final result = auditWith(dexEntries: [DexBytes('classes.dex', blob)]);

      expect(
        result.network.domains,
        contains('api.example.com'),
        reason: '网络端点要单列，不该只藏在发现项的证据文本里',
      );
      expect(result.network.ips, contains('203.0.113.9'));
    });

    test('没有网络线索时 network 为空（不是「没有网络行为」）', () {
      final result = auditWith(dexEntries: const []);

      expect(result.network.isEmpty, isTrue);
    });

    test('DEX 结构不可信时结构维度降级为 partial，不是 covered', () {
      final result = auditWith(
        dexEntries: [
          DexBytes('classes.dex', _fixture('real-netprobe.dex')),
          DexBytes('classes2.dex', _fixture('bad-magic.dex')),
        ],
      );

      final structure = result.coverage.entry('android.dex.structure')!;
      expect(structure.status, CoverageStatus.partial);
      expect(structure.covered, 1);
      expect(structure.limit, 2);
      expect(structure.note, contains('1 个 DEX 结构不可信'));
    });
  });

  group('iOS 审计产出结构化覆盖', () {
    SecurityAnalysisResult auditWith({
      Uint8List? bytes,
      List<IosNestedExecutableInput> nested = const [],
    }) {
      final bundle = const IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/Example.app',
        name: 'Example.app',
      );
      final archive = Archive();
      final plist = const Utf8Encoder().convert(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<plist version="1.0"><dict>'
        '<key>NSPhotoLibraryUsageDescription</key><string>x</string>'
        '</dict></plist>',
      );
      archive.addFile(
          ArchiveFile('${bundle.path}/Info.plist', plist.length, plist));

      return IosPrivacyAudit.audit(
        infoPlist: IpaInfoPlistReader.read(archive, bundle),
        executableBytes: bytes,
        executablePath: '${bundle.path}/Example',
        nestedExecutables: nested,
      );
    }

    test('iOS 的维度 id 与 Android 不重叠，且各自成套', () {
      final result = auditWith(bytes: const Utf8Encoder().convert('nothing\n'));

      final ids = result.coverage.entries.map((e) => e.id).toList();
      expect(
          ids,
          containsAll(const [
            'ios.infoPlist',
            'ios.usageDescriptions',
            'ios.executables',
            'ios.macho.strings',
            'ios.nativeSymbols',
            'ios.signature',
          ]));
      expect(
        ids.any((id) => id.startsWith('android.')),
        isFalse,
        reason: '两个平台的维度不该混在一起',
      );
    });

    test('签名验证标 notApplicable —— 它由 codesign 单独执行', () {
      final result = auditWith(bytes: const Utf8Encoder().convert('x\n'));

      final signature = result.coverage.entry('ios.signature')!;
      expect(signature.status, CoverageStatus.notApplicable);
      expect(
        result.coverage.gaps.any((e) => e.id == 'ios.signature'),
        isFalse,
        reason: '避免报告凭空多出一个假缺口',
      );
    });

    test('一个可执行文件都读不到时该维度是 notCovered', () {
      final result = auditWith();

      expect(
        result.coverage.entry('ios.executables')!.status,
        CoverageStatus.notCovered,
      );
      expect(
        result.coverage.entry('ios.macho.strings')!.status,
        CoverageStatus.notCovered,
      );
    });

    test('部分可执行文件没扫到时是 partial，并给出覆盖量与上限', () {
      final result = auditWith(
        bytes: const Utf8Encoder().convert('nothing\n'),
        nested: const [
          IosNestedExecutableInput(
            path: 'Payload/Example.app/PlugIns/Big.appex/Big',
            bundlePath: 'Payload/Example.app/PlugIns/Big.appex',
            kind: IosBundleKind.appExtension,
            failure: 'budget',
          ),
        ],
      );

      final entry = result.coverage.entry('ios.executables')!;
      expect(entry.status, CoverageStatus.partial);
      expect(entry.ratioText, '1/2');
    });
  });

  group('报告与界面共用同一份覆盖数据', () {
    test('coverageSummary 在全部覆盖时说明「全部覆盖」', () {
      const coverage = AnalysisCoverage(entries: [
        CoverageEntry(id: 'a', status: CoverageStatus.covered),
        CoverageEntry(id: 'b', status: CoverageStatus.notApplicable),
      ]);

      final text = AnalysisReport.coverageSummary(coverage, t);
      expect(text, contains(t.coverage.all_covered));
      expect(
        text,
        contains('1'),
        reason: 'notApplicable 不计入「适用维度」',
      );
    });

    test('coverageSummary 在有缺口时给出缺口数', () {
      const coverage = AnalysisCoverage(entries: [
        CoverageEntry(id: 'a', status: CoverageStatus.covered),
        CoverageEntry(id: 'b', status: CoverageStatus.partial),
        CoverageEntry(id: 'c', status: CoverageStatus.notCovered),
      ]);

      final text = AnalysisReport.coverageSummary(coverage, t);
      expect(text, contains('2'));
      expect(text, isNot(contains(t.coverage.all_covered)));
    });

    test('coverageStatusText 覆盖四态且互不相同', () {
      final texts = [
        for (final status in CoverageStatus.values)
          AnalysisReport.coverageStatusText(status, t),
      ];

      expect(texts.toSet(), hasLength(4), reason: '四态必须能分开渲染');
      expect(texts, contains(t.coverage.not_applicable));
    });

    test('没有 coverage 时 summary 不崩、返回「没有缺口」', () {
      expect(AnalysisReport.coverageSummary(const AnalysisCoverage(), t),
          t.coverage.no_gaps);
    });
  });

  // 缺陷 COV-1 / COV-2 的回归测试（见 docs/plans/V2.4.0_PROGRESS.md §11.5）。
  //
  // 背景：`CoverageEntry.id` 是给程序用的**稳定标识**（`android.dex.strings`），
  // 而 UI 与 Markdown 都直接把它渲染给用户看。`CoverageEntry.id` 的注释写着
  // 「UI 用它映射到本地化文案」，但那个映射此前并不存在。
  // 另一处是汇总句用中文全角「；」硬拼接，英文报告里会出现中文标点。
  group('覆盖维度的呈现（COV-1 / COV-2 回归）', () {
    /// 引擎实际会产出的全部维度 id。
    ///
    /// 取自两个审计引擎：`android_security_audit.dart` 8 个、
    /// `ios_privacy_audit.dart` 7 个。**故意写死在这里** —— 新增维度时
    /// 这条断言会红，提醒补文案，而不是悄悄显示成机器标识。
    const allDimensionIds = <String>[
      'android.manifest',
      'android.permissions',
      'android.dex.structure',
      'android.dex.strings',
      'android.dex.methodReferences',
      'android.dex.callSites',
      'android.nativeSymbols',
      'android.arsc',
      'ios.infoPlist',
      'ios.usageDescriptions',
      'ios.privacyManifest',
      'ios.executables',
      'ios.macho.strings',
      'ios.nativeSymbols',
      'ios.signature',
    ];

    const sample = AnalysisCoverage(entries: [
      CoverageEntry(id: 'android.manifest', status: CoverageStatus.covered),
      CoverageEntry(
        id: 'android.dex.strings',
        status: CoverageStatus.partial,
        covered: 1024,
        limit: 2048,
      ),
      CoverageEntry(id: 'android.arsc', status: CoverageStatus.notCovered),
      CoverageEntry(id: 'ios.signature', status: CoverageStatus.notApplicable),
    ]);

    test('每一个引擎维度 id 都有本地化名字，且不等于 id 本身', () {
      for (final id in allDimensionIds) {
        final label = AnalysisReport.coverageDimensionLabel(id, t);
        expect(label, isNotEmpty, reason: '$id 没有文案');
        expect(label, isNot(id), reason: '$id 直接显示了机器标识');
      }
    });

    test('未知 id 原样回退，不抛异常也不显示空白', () {
      expect(AnalysisReport.coverageDimensionLabel('android.future.thing', t),
          'android.future.thing');
      expect(AnalysisReport.coverageDimensionLabel('', t), '');
    });

    test('UI 的单行格式用本地化维度名，不出现机器 id', () {
      final line = AnalysisReport.coverageEntryLine(sample.entries[1], t);
      expect(line, isNot(contains('android.dex.strings')),
          reason: '界面不该把机器标识给用户看');
      expect(
          line,
          contains(
              AnalysisReport.coverageDimensionLabel('android.dex.strings', t)));
      // 覆盖量与状态仍然照旧出现。
      expect(line, contains('1024/2048'));
      expect(
          line,
          contains(
              AnalysisReport.coverageStatusText(CoverageStatus.partial, t)));
    });

    test('Markdown 覆盖表用本地化维度名，不出现机器 id', () {
      final result = PackageAnalysisResult(
        platform: PackagePlatform.android,
        fileName: const FieldValue<String>.extracted(
          'x.apk',
          source: FieldSource.fileSystem,
        ),
        fileSize: const FieldValue<int>.extracted(
          1,
          source: FieldSource.fileSystem,
        ),
        security: const SecurityAnalysisResult(
          engineVersion: 'e',
          rulesVersion: 'r',
          coverage: sample,
        ),
      );

      final md = AnalysisReport.render(result, t,
          generatedAt: DateTime.utc(2026, 10, 15));
      final start = md.indexOf('## ${t.coverage.title}');
      expect(start, isNonNegative, reason: '报告里应当有覆盖一节');
      final section = md.substring(start);

      for (final id in [
        'android.manifest',
        'android.dex.strings',
        'android.arsc',
        'ios.signature',
      ]) {
        expect(section, isNot(contains('| $id |')), reason: '维度列不该是机器标识 $id');
        expect(section, contains(AnalysisReport.coverageDimensionLabel(id, t)),
            reason: '维度列缺少 $id 的本地化名字');
      }
    });

    test('汇总句的分隔符走 i18n，而不是写死的中文全角分号', () {
      final summary = AnalysisReport.coverageSummary(sample, t);

      expect(summary, contains(t.coverage.summary_join),
          reason: '分隔符必须来自 i18n');

      // 这条是这次缺陷的直接表现：英文报告里出现中文全角「；」。
      final enJson = jsonDecode(File('assets/i18n/en.json').readAsStringSync())
          as Map<String, dynamic>;
      final enJoin =
          (enJson['coverage'] as Map<String, dynamic>)['summary_join'];
      if (enJoin != '；') {
        expect(summary, isNot(contains('；')), reason: 'en 的汇总句里不该出现中文全角分号');
      }
    });

    test('维护中的语言包带齐维度名与分隔符', () {
      // 直接读 JSON：slang 生成物只暴露当前 locale，逐个切语言代价太大，
      // 而这里要验的恰恰是「语言文件里有没有这些键」。
      //
      // ja / ko 按 `fallback_strategy: base_locale` 回退到 en（它们的
      // `coverage` 段整体不存在），因此规则是：
      // - en 与三个中文变体**必须**带齐；
      // - 其余语言包要么整段缺失（走回退），要么带齐 —— 不能半吊子。
      const mustHave = ['en', 'zh-CN', 'zh-HK', 'zh-TW'];
      const mayFallback = ['ja', 'ko'];

      Map<String, dynamic> readCoverage(String locale) {
        final file = File('assets/i18n/$locale.json');
        expect(file.existsSync(), isTrue, reason: '缺少 $locale 语言包');
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        return (json['coverage'] as Map<String, dynamic>?) ?? const {};
      }

      for (final locale in [...mustHave, ...mayFallback]) {
        final coverage = readCoverage(locale);
        if (coverage.isEmpty) {
          expect(mayFallback, contains(locale),
              reason: '$locale 必须带 coverage 段，不允许回退');
          continue;
        }
        expect(coverage['summary_join'], isNotEmpty,
            reason: '$locale 缺 coverage.summary_join');
        final dimensions = coverage['dimensions'] as Map<String, dynamic>?;
        expect(dimensions, isNotNull, reason: '$locale 没有 coverage.dimensions');
        for (final id in allDimensionIds) {
          final key = id.replaceAll('.', '_');
          expect(dimensions![key], isNotEmpty, reason: '$locale 缺维度名 $key');
        }
      }
    });
  });
}
