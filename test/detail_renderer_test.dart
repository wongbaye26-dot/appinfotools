import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ApkInfo _apkInfo({
  bool? debuggable,
  List<AndroidComponent> components = const [],
}) {
  final info = ApkInfo();
  info.applicationDebuggable = debuggable;
  info.components = List.of(components);
  return info;
}

void main() {
  group('DetailRenderer.structure', () {
    const populated = ContainerStructure(
      fileEntryCount: 12,
      dexFiles: [DexEntry(name: 'classes.dex', size: 1024)],
      nativeLibraries: [
        NativeLibraryEntry(
          abi: 'arm64-v8a',
          name: 'liba.so',
          path: 'lib/arm64-v8a/liba.so',
          size: 10,
        ),
      ],
      abis: ['arm64-v8a'],
      topLevelDirectories: {
        'res': DirectoryStat(fileCount: 3, uncompressedBytes: 2048),
        'lib': DirectoryStat(fileCount: 1, uncompressedBytes: 10),
      },
      totalUncompressedBytes: 4096,
    );

    test('null 与空结构都渲染为空串', () {
      expect(DetailRenderer.structure(null, t), '');
      expect(DetailRenderer.structure(const ContainerStructure(), t), '');
    });

    test('列出条目数、DEX、ABI、原生库与顶层目录', () {
      final text = DetailRenderer.structure(populated, t);

      expect(text, contains(t.apk_info.structure_entries));
      expect(text, contains('12'));
      expect(text, contains('${t.apk_info.structure_dex}: 1'));
      expect(text, contains('${t.apk_info.abi}: arm64-v8a'));
      expect(text, contains('${t.apk_info.structure_native_libs}: 1'));
      expect(text, contains('res/'));
      expect(text, contains('lib/'));
    });

    test('没有 DEX / 原生库时不显示对应行，而不是显示 0', () {
      const onlyDirs = ContainerStructure(
        fileEntryCount: 2,
        topLevelDirectories: {
          'res': DirectoryStat(fileCount: 2, uncompressedBytes: 100),
        },
        totalUncompressedBytes: 100,
      );

      final text = DetailRenderer.structure(onlyDirs, t);

      expect(text, isNot(contains(t.apk_info.structure_dex)));
      expect(text, isNot(contains(t.apk_info.structure_native_libs)));
      expect(text, isNot(contains(t.apk_info.abi)));
      expect(text, contains('res/'));
    });

    test('目录按体积降序，只列前几个', () {
      final many = ContainerStructure(
        fileEntryCount: 20,
        topLevelDirectories: {
          for (var i = 0; i < 12; i++)
            'd$i':
                DirectoryStat(fileCount: 1, uncompressedBytes: (i + 1) * 100),
        },
        totalUncompressedBytes: 7800,
      );

      final text = DetailRenderer.structure(many, t);
      final lines = text.split('\n');

      // 12 个目录只列 8 个（默认 limit），且最大的在最前
      expect(lines.where((l) => l.trimLeft().startsWith('d')).length, 8);
      expect(text.indexOf('d11/'), lessThan(text.indexOf('d4/')));
    });
  });

  group('DetailRenderer.analysisNotes', () {
    test('null 分析结果渲染为空串（调用方据此隐藏整张卡片）', () {
      expect(DetailRenderer.analysisNotes(null, t), '');
    });

    test('既无加固线索也无诊断时为空串', () {
      const result = PackageAnalysisResult(android: AndroidPackageInfo());
      expect(DetailRenderer.analysisNotes(result, t), '');
    });

    test('加固线索带置信度与证据 —— 「可能被加固」必须能解释原因', () {
      const result = PackageAnalysisResult(
        android: AndroidPackageInfo(hardeningHints: [
          HardeningHint(
            signal: HardeningSignal.dexHeaderNotStandard,
            evidence: 'classes.dex: header is 0x9d 0x01',
            confidence: HintConfidence.strong,
          ),
        ]),
      );

      final text = DetailRenderer.analysisNotes(result, t);

      expect(text, contains(t.apk_info.hardening_summary));
      expect(text, contains('dexHeaderNotStandard'));
      expect(text, contains(t.apk_info.confidence_strong));
      expect(text, contains('classes.dex: header is 0x9d 0x01'));
    });

    test('弱线索用弱置信度措辞，与强线索区分开', () {
      const result = PackageAnalysisResult(
        android: AndroidPackageInfo(hardeningHints: [
          HardeningHint(
            signal: HardeningSignal.multipleDexFiles,
            evidence: '3 DEX entries',
            confidence: HintConfidence.weak,
          ),
        ]),
      );

      final text = DetailRenderer.analysisNotes(result, t);

      expect(text, contains(t.apk_info.confidence_weak));
      expect(text, isNot(contains(t.apk_info.confidence_strong)));
    });

    test('诊断记录带严重度与稳定 code', () {
      const result = PackageAnalysisResult(diagnostics: [
        AnalysisDiagnostic.warning('arsc.partial', 'resource table truncated'),
      ]);

      final text = DetailRenderer.analysisNotes(result, t);

      expect(text, contains('warning'));
      expect(text, contains('arsc.partial'));
      expect(text, contains('resource table truncated'));
    });

    test('两者都有时都呈现', () {
      const result = PackageAnalysisResult(
        android: AndroidPackageInfo(hardeningHints: [
          HardeningHint(
            signal: HardeningSignal.missingPrimaryDex,
            evidence: 'no classes.dex entry',
            confidence: HintConfidence.strong,
          ),
        ]),
        diagnostics: [
          AnalysisDiagnostic.info('parse.ok', 'parsed with builtin engine'),
        ],
      );

      final text = DetailRenderer.analysisNotes(result, t);

      expect(text, contains('missingPrimaryDex'));
      expect(text, contains('parse.ok'));
    });
  });

  group('DetailRenderer.parseStageLabel', () {
    test('每个阶段都有文案，且四个真实阶段互不相同', () {
      final labels = {
        for (final s in ApkParseStage.values)
          s: DetailRenderer.parseStageLabel(s, t),
      };

      for (final entry in labels.entries) {
        expect(entry.value, isNotEmpty, reason: '${entry.key} 缺少文案');
      }

      final distinct = {
        ApkParseStage.openContainer,
        ApkParseStage.manifest,
        ApkParseStage.resources,
        ApkParseStage.nativeLibraries,
      }.map((s) => labels[s]).toSet();

      expect(distinct, hasLength(4), reason: '进度文案必须能区分真实阶段，否则用户看不出在做什么');
    });
  });

  group('DetailRenderer.openFailure', () {
    test('四种失败原因互不相同，尤其安全拒绝不能与「损坏」同话术', () {
      final messages = {
        for (final r in ArchiveOpenResult.values)
          r: DetailRenderer.openFailure(r, t),
      };

      for (final entry in messages.entries) {
        expect(entry.value, isNotEmpty, reason: '${entry.key} 缺少文案');
      }
      expect(
        messages[ArchiveOpenResult.resourceBudgetExceeded],
        isNot(messages[ArchiveOpenResult.corrupt]),
      );
      expect(
        messages[ArchiveOpenResult.notArchive],
        isNot(messages[ArchiveOpenResult.ioError]),
      );
    });
  });

  group('DetailRenderer.signature', () {
    test('null 结果渲染为空串', () {
      expect(DetailRenderer.signature(null, t), '');
    });

    test('工具不可用：给出状态与提示，且绝不出现「验证失败」的措辞', () {
      final text = DetailRenderer.signature(
        SignatureAnalysis.toolUnavailable('apksigner not found'),
        t,
      );

      expect(text, contains(t.signature.status_tool_unavailable));
      expect(text, contains(t.signature.tool_hint));
      expect(text, isNot(contains(t.signature.status_failed)));
    });

    test('验证通过：列出方案与证书字段，且不展示诊断区', () {
      final analysis = SignatureAnalyzer.parseResult(
        exitCode: 0,
        stdout: 'Verifies\n'
            'Verified using v1 scheme (JAR signing): true\n'
            'Verified using v2 scheme (APK Signature Scheme v2): true\n'
            'Signer #1 certificate DN: CN=Android Debug\n'
            'Signer #1 certificate SHA-256 digest: aabbcc\n'
            'Signer #1 key algorithm: RSA\n'
            'Signer #1 key size (bits): 2048\n',
      );

      final text = DetailRenderer.signature(analysis, t);

      expect(text, contains(t.signature.status_verified));
      expect(text, contains('v1, v2'));
      expect(text, contains('CN=Android Debug'));
      expect(text, contains('aabbcc'));
      expect(text, contains(t.signature.key_size_bits(bits: 2048)));
      expect(text, isNot(contains(t.signature.diagnostics)));
    });

    test('结果未知：附上原始输出，便于排查', () {
      final analysis = SignatureAnalyzer.parseResult(
        exitCode: 2,
        stdout: 'usage: apksigner verify ...',
      );

      final text = DetailRenderer.signature(analysis, t);

      expect(text, contains(t.signature.status_unknown));
      expect(text, contains(t.signature.diagnostics));
      expect(text, contains('usage: apksigner verify'));
    });
  });

  group('DetailRenderer.components', () {
    test('null 与空列表都渲染为空串', () {
      expect(DetailRenderer.components(null, t), '');
      expect(DetailRenderer.components(_apkInfo(), t), '');
    });

    test('按类型分组并统计数量，未出现的类型不显示', () {
      final info = _apkInfo(components: const [
        AndroidComponent(type: ComponentType.activity, name: 'a.A'),
        AndroidComponent(type: ComponentType.service, name: 'a.S1'),
        AndroidComponent(type: ComponentType.service, name: 'a.S2'),
      ]);

      final text = DetailRenderer.components(info, t);

      expect(text, contains('activity (1)'));
      expect(text, contains('service (2)'));
      expect(text, isNot(contains('receiver')));
      expect(text, isNot(contains('provider')));
    });

    test('三种导出状态措辞不同', () {
      final info = _apkInfo(components: const [
        AndroidComponent(
            type: ComponentType.activity, name: 'a.On', exported: true),
        AndroidComponent(
            type: ComponentType.activity, name: 'a.Off', exported: false),
        // 未声明 exported，但有 intent-filter -> 按平台规则默认导出
        AndroidComponent(
            type: ComponentType.activity,
            name: 'a.Implied',
            hasIntentFilter: true),
        // 未声明且无 intent-filter -> 不导出，不给标记
        AndroidComponent(type: ComponentType.service, name: 'a.Plain'),
      ]);

      final text = DetailRenderer.components(info, t);

      expect(text, contains('a.On  [${t.apk_info.exported}]'));
      expect(text, contains('a.Off  [${t.apk_info.not_exported}]'));
      expect(text, contains('a.Implied  [${t.apk_info.exported_by_default}]'));

      final plainLine = text
          .split('\n')
          .firstWhere((line) => line.trim().startsWith('a.Plain'));
      expect(plainLine, isNot(contains('[')),
          reason: '未声明且无 intent-filter 的组件不应带任何标记');
    });

    test('permission 与 provider 的 authorities 被展示', () {
      final info = _apkInfo(components: const [
        AndroidComponent(
          type: ComponentType.service,
          name: 'a.Guarded',
          permission: 'a.permission.INTERNAL',
        ),
        AndroidComponent(
          type: ComponentType.provider,
          name: 'a.Provider',
          authorities: 'a.provider',
        ),
      ]);

      final text = DetailRenderer.components(info, t);

      expect(text, contains('permission=a.permission.INTERNAL'));
      expect(text, contains('authorities=a.provider'));
    });

    test('缺名的组件用占位文案，不留空白', () {
      final info = _apkInfo(components: const [
        AndroidComponent(type: ComponentType.service),
      ]);

      final text = DetailRenderer.components(info, t);

      expect(text, contains(t.apk_info.component_unnamed));
    });

    test('debuggable=true 时给出提示；false / 未声明不给', () {
      final on = DetailRenderer.components(
        _apkInfo(
          debuggable: true,
          components: const [
            AndroidComponent(type: ComponentType.activity, name: 'a.A'),
          ],
        ),
        t,
      );
      expect(on, contains('[${t.apk_info.debuggable}]'));

      final off = DetailRenderer.components(
        _apkInfo(
          debuggable: false,
          components: const [
            AndroidComponent(type: ComponentType.activity, name: 'a.A'),
          ],
        ),
        t,
      );
      expect(off, isNot(contains('[${t.apk_info.debuggable}]')));
    });
  });
}
