import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/hardening.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart'
    show
        IosAuthorizationComparison,
        IosAuthorizationVerdict,
        IosBundle,
        IosBundleKind,
        IosEntitlement,
        IosIconCandidate,
        IosIconResolution,
        IosIconSource,
        IosImageFormat,
        IosProvisioningProfile,
        IosSignatureMaterials,
        IosUnresolvedIcon,
        IpaContainer,
        MachOFile,
        PlistString;

/// 一个最小可用的 IosPackageInfo，便于逐个断言各段渲染。
IosPackageInfo _iosInfo({
  IosSignatureMaterials? materials,
  IosAuthorizationComparison? authorization,
  IosCodeSignResult? codeSign,
  IpaContainer container = const IpaContainer(),
  MachOFile? executable,
}) =>
    IosPackageInfo(
      container: container,
      signatureMaterials: materials,
      authorization: authorization,
      codeSign: codeSign,
      executable: executable,
      icon: const IosIconResolution(),
    );

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

  group('DetailRenderer — iOS 阶段与设备类型', () {
    test('IPA 的每个阶段都有文案，且不留空', () {
      for (final stage in IpaParseStage.values) {
        expect(DetailRenderer.ipaParseStageLabel(stage, t), isNotEmpty,
            reason: '$stage 没有文案');
      }
    });

    test('设备类型按 UIDeviceFamily 映射，未知取值原样给出数字', () {
      expect(DetailRenderer.deviceFamily([1], t), t.ios_info.device_iphone);
      expect(DetailRenderer.deviceFamily([1, 2], t),
          '${t.ios_info.device_iphone}, ${t.ios_info.device_ipad}');

      // 关键：不把未知值映射到最近的一档 —— 猜错会让用户以为支持某类设备。
      final unknown = DetailRenderer.deviceFamily([99], t);
      expect(unknown, contains('99'));
    });

    test('设备类型为空或缺失时返回空串，而不是伪造一项', () {
      expect(DetailRenderer.deviceFamily(null, t), isEmpty);
      expect(DetailRenderer.deviceFamily(const [], t), isEmpty);
    });
  });

  group('DetailRenderer — iOS 容器与嵌套二进制', () {
    test('容器为空时不渲染', () {
      expect(DetailRenderer.iosContainer(const IpaContainer(), t), isEmpty);
    });

    test('容器列出每个 bundle 的种类与条目数', () {
      const bundle = IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/Example.app',
        name: 'Example.app',
        fileCount: 7,
      );
      const container = IpaContainer(
        bundles: [bundle],
        payloadApps: [bundle],
        fileEntryCount: 9,
      );

      final text = DetailRenderer.iosContainer(container, t);
      expect(text, contains('Payload/Example.app'));
      expect(text, contains(t.ios_info.bundle_kind_main_app));
      // 总数与每个 bundle 的条目数都要落在**插值后**的文案上，
      // 而不是只断言「出现过 7」—— 后者在下面的缺陷版本里也会通过。
      expect(text, contains(t.apk_info.structure_entries));
      expect(text, contains(t.apk_info.structure_file_count(count: 7)));
      expect(text, contains('9'));
    });

    test('容器不把函数对象当值渲染出来（回归：Closure: ...）', () {
      // `structure_file_count` 是带 `{count}` 的**方法**。漏传参数不会编译
      // 报错，但会把函数本身插进字符串，界面上出现
      // `Closure: (required Ordered object) => ...` —— 这一条真的出现在
      // iOS 的「容器」卡片里，而且分析器看不见。
      const bundle = IosBundle(
        kind: IosBundleKind.mainApp,
        path: 'Payload/Example.app',
        name: 'Example.app',
        fileCount: 7,
      );
      const container = IpaContainer(
        bundles: [bundle],
        payloadApps: [bundle],
        fileEntryCount: 9,
      );

      final text = DetailRenderer.iosContainer(container, t);
      expect(text, isNot(contains('Closure')));
      expect(text, isNot(contains('=>')));
    });

    test('嵌套二进制为空时不渲染', () {
      expect(DetailRenderer.iosNestedBinaries(const [], t), isEmpty);
    });

    test('解析失败的嵌套二进制给出原因，而不是显示成「没有架构」', () {
      const binary = IosNestedBinary(
        bundlePath: 'Payload/Example.app/Frameworks/Lib.framework',
        kind: IosBundleKind.framework,
        path: 'Payload/Example.app/Frameworks/Lib.framework/Lib',
        failure: 'entry missing or too large',
      );

      final text = DetailRenderer.iosNestedBinaries([binary], t);
      expect(text, contains('Lib.framework'));
      expect(text, contains('entry missing or too large'));
    });
  });

  group('DetailRenderer — iOS 图标清单', () {
    // 这些信息原先由 `IosIconPreview` 这个组件渲染。改成文本是为了让 iOS 页
    // 与 Android 页走同一套卡片版式 —— 组件只负责画图，文字归 DetailRenderer。

    test('候选要给出文件名、尺寸与归档路径', () {
      const candidate = IosIconCandidate(
        source: IosIconSource.primaryIconFiles,
        relativePath: 'AppIcon60x60@2x.png',
        archivePath: 'Payload/Example.app/AppIcon60x60@2x.png',
        size: 19881,
        format: IosImageFormat.png,
        pixelWidth: 120,
        pixelHeight: 120,
      );

      final text = DetailRenderer.iosIcon(
        const IosIconResolution(candidates: [candidate]),
        t,
      );
      expect(text, contains('AppIcon60x60@2x.png'));
      expect(text, contains('120x120'));
      expect(text, contains('19881 B'));
      // 归档路径也要给出来 —— 排查时要拿它比对 ZIP 条目名。
      expect(text, contains('Payload/Example.app/AppIcon60x60@2x.png'));
      expect(text, contains(t.ios_info.icon_source_primary));
    });

    test('尺寸读不出来时写出 ?，而不是留空', () {
      const candidate = IosIconCandidate(
        source: IosIconSource.primaryIconFiles,
        relativePath: 'Icon.png',
        archivePath: 'Payload/Example.app/Icon.png',
        size: 100,
        format: IosImageFormat.png,
      );

      final text = DetailRenderer.iosIcon(
        const IosIconResolution(candidates: [candidate]),
        t,
      );
      expect(text, contains('?x?'));
    });

    test('声明了但取不到的条目连同原因一起给出', () {
      const resolution = IosIconResolution(unresolved: [
        IosUnresolvedIcon(
          source: IosIconSource.assetCatalogName,
          declared: 'CFBundleIconName=AppIcon',
          reason: 'the icon lives in Assets.car and cannot be previewed',
        ),
      ]);

      final text = DetailRenderer.iosIcon(resolution, t);
      expect(text, contains(t.ios_info.icon_declared_unresolved));
      expect(text, contains('CFBundleIconName=AppIcon'));
      expect(text, contains('Assets.car'));
      expect(text, contains(t.ios_info.icon_source_asset_catalog));
    });

    test('多个候选全部列出，而不是只给最大的那个', () {
      const resolution = IosIconResolution(candidates: [
        IosIconCandidate(
          source: IosIconSource.primaryIconFiles,
          relativePath: 'AppIcon60x60@2x.png',
          archivePath: 'Payload/Example.app/AppIcon60x60@2x.png',
          size: 19881,
          format: IosImageFormat.png,
          pixelWidth: 120,
          pixelHeight: 120,
        ),
        IosIconCandidate(
          source: IosIconSource.primaryIconFilesIpad,
          relativePath: 'AppIcon76x76@2x~ipad.png',
          archivePath: 'Payload/Example.app/AppIcon76x76@2x~ipad.png',
          size: 31686,
          format: IosImageFormat.png,
          pixelWidth: 152,
          pixelHeight: 152,
        ),
      ]);

      final text = DetailRenderer.iosIcon(resolution, t);
      expect(text, contains('AppIcon60x60@2x.png'));
      expect(text, contains('AppIcon76x76@2x~ipad.png'));
      expect(text, contains('152x152'));
      expect(text, contains(t.ios_info.icon_source_ipad));
    });

    test('完全没有图标信息时说明「未找到」，而不是返回空串', () {
      // 返回空串会让卡片看起来像「这个包没有图标这一项」，而不是「我们没找到」。
      expect(DetailRenderer.iosIcon(null, t), t.ios_info.icon_unavailable);
      expect(DetailRenderer.iosIcon(const IosIconResolution(), t),
          t.ios_info.icon_unavailable);
    });
  });

  group('DetailRenderer — iOS 签名：材料与结论必须分开', () {
    test('只有材料、没有 codesign 结论时不出现「验证通过」', () {
      const materials = IosSignatureMaterials(
        bundle: IosBundle(
          kind: IosBundleKind.mainApp,
          path: 'Payload/Example.app',
          name: 'Example.app',
        ),
        hasCodeSignatureDirectory: true,
        codeSignatureEntries: ['CodeResources'],
      );

      final signature =
          DetailRenderer.iosSignature(_iosInfo(materials: materials), t);
      expect(signature, contains(t.ios_info.code_signature_dir));
      expect(signature, contains('CodeResources'));

      // 没跑 codesign —— 必须说「未执行」。
      final codeSign = DetailRenderer.iosCodeSign(null, t);
      expect(codeSign, contains(t.ios_info.codesign_not_run));
      expect(codeSign, isNot(contains(t.signature.status_verified)));
    });

    test('没有签名材料时如实说「不存在」，不渲染成「无效」', () {
      const materials = IosSignatureMaterials(
        bundle: IosBundle(
          kind: IosBundleKind.mainApp,
          path: 'Payload/Example.app',
          name: 'Example.app',
        ),
      );

      final signature =
          DetailRenderer.iosSignature(_iosInfo(materials: materials), t);
      expect(signature, contains(t.ios_info.presence_no));
      expect(signature, isNot(contains(t.signature.status_failed)));
    });

    test('codesign 没有明确结论时给出原始输出，否则用户无从判断', () {
      const result = IosCodeSignResult(
        status: SignatureStatus.verificationFailed,
        toolExecuted: true,
        exitCode: 3,
        stderr: 'does not satisfy its designated Requirement',
        error: 'the signature seal is intact',
      );

      final text = DetailRenderer.iosCodeSign(result, t);
      expect(text, contains(t.signature.status_failed));
      expect(text, contains('designated Requirement'));
      expect(text, contains(t.signature.diagnostics));
    });

    test('代码哈希不符 → 解释「砸壳 / 重打包」，而不是只丢一句英文', () {
      // 实机反馈：codesign 只说 `invalid signature (code or signature have
      // been modified)`，用户既不知道该怀疑什么，也怀疑是不是工具的误判。
      const result = IosCodeSignResult(
        status: SignatureStatus.verificationFailed,
        toolExecuted: true,
        exitCode: 1,
        stderr: 'Madrid.app: invalid signature '
            '(code or signature have been modified)',
        error: 'codesign reported that the signature is not valid',
      );

      final text = DetailRenderer.iosCodeSign(result, t);
      expect(text, contains(t.signature.failed_code_modified_hint));
      expect(text, isNot(contains(t.signature.failed_generic_hint)));
      // 原始输出仍然要在（用户可能想自己核对）。
      expect(text, contains('code or signature have been modified'));
    });

    test('资源封印不符 → 用通用解释，别把「文件被增删」说成「二进制被改」', () {
      const result = IosCodeSignResult(
        status: SignatureStatus.verificationFailed,
        toolExecuted: true,
        exitCode: 1,
        stderr: 'Example.app: a sealed resource is missing or invalid',
        error: 'codesign reported that the signature is not valid',
      );

      final text = DetailRenderer.iosCodeSign(result, t);
      expect(text, contains(t.signature.failed_generic_hint));
      expect(text, isNot(contains(t.signature.failed_code_modified_hint)));
    });

    test('codesign 通过时给出证书链', () {
      const result = IosCodeSignResult(
        status: SignatureStatus.verified,
        toolExecuted: true,
        exitCode: 0,
        info: IosCodeSignInfo(
          identifier: 'com.example.app',
          teamIdentifier: 'ABCDE12345',
          authorities: ['Developer ID Application', 'Apple Root CA'],
          entitlements: [
            IosEntitlement(key: 'get-task-allow', value: PlistString('false'))
          ],
          entitlementsRead: true,
        ),
      );

      final text = DetailRenderer.iosCodeSign(result, t);
      expect(text, contains(t.signature.status_verified));
      expect(text, contains('com.example.app'));
      expect(text, contains('ABCDE12345'));
      expect(text, contains('Apple Root CA'));
    });

    test('授权项读不到与「没有授权项」渲染不同', () {
      // 授权项渲染在「签名与授权」这一段里（它属于授权，不属于验证结论）。
      const unreadable = IosCodeSignResult(
        status: SignatureStatus.verified,
        info: IosCodeSignInfo(entitlementsRead: false),
      );
      expect(DetailRenderer.iosSignature(_iosInfo(codeSign: unreadable), t),
          contains(t.ios_info.entitlements_unreadable));

      const empty = IosCodeSignResult(
        status: SignatureStatus.verified,
        info: IosCodeSignInfo(entitlementsRead: true),
      );
      expect(DetailRenderer.iosSignature(_iosInfo(codeSign: empty), t),
          contains(t.ios_info.entitlements_empty));
    });

    test('没有 codesign 时退回静态描述文件里的授权项，并标明来源', () {
      const profile = IosProvisioningProfile(
        entitlements: [
          IosEntitlement(
              key: 'aps-environment', value: PlistString('production')),
        ],
      );
      const materials = IosSignatureMaterials(
        bundle: IosBundle(
          kind: IosBundleKind.mainApp,
          path: 'Payload/Example.app',
          name: 'Example.app',
        ),
        profile: FieldValue<IosProvisioningProfile>.extracted(
          profile,
          source: FieldSource.signatureMaterials,
        ),
      );

      final text =
          DetailRenderer.iosSignature(_iosInfo(materials: materials), t);
      expect(text, contains('aps-environment'));
      expect(text, contains('production'));
      expect(text, contains(t.ios_info.embedded_provision));
    });

    test('描述文件读不出来时说明原因，而不是显示成「没有描述文件」', () {
      const materials = IosSignatureMaterials(
        bundle: IosBundle(
          kind: IosBundleKind.mainApp,
          path: 'Payload/Example.app',
          name: 'Example.app',
        ),
        profile: FieldValue<IosProvisioningProfile>.failed(
          diagnostic: 'the CMS container could not be unwrapped',
          source: FieldSource.signatureMaterials,
        ),
      );

      final text =
          DetailRenderer.iosSignature(_iosInfo(materials: materials), t);
      expect(text, contains('failed'));
      expect(text, contains('CMS'));
    });

    test('不带表头的版本与带表头的版本只差表头那一行', () {
      const result = IosCodeSignResult(
        status: SignatureStatus.verified,
        toolExecuted: true,
        exitCode: 0,
        info: IosCodeSignInfo(
          identifier: 'com.example.app',
          teamIdentifier: 'ABCDE12345',
        ),
      );

      final withHeader = DetailRenderer.iosCodeSign(result, t);
      final body = DetailRenderer.iosCodeSignBody(result, t);

      // 详情页把「codesign 验证」放进卡片标题，正文再带一遍表头就成了
      // 「codesign 验证   codesign 验证: 验证通过」。
      expect(withHeader, startsWith('${t.ios_info.codesign_section}: '));
      expect(body, isNot(contains(t.ios_info.codesign_section)));
      expect(body, startsWith(t.signature.status_verified));

      // 去掉的**只能**是表头 —— 结论与细节一个都不能少。
      expect(withHeader, endsWith(body));
      expect(body, contains('com.example.app'));
      expect(body, contains('ABCDE12345'));
    });

    test('不带表头的版本同样如实说「未执行」，且不为空串', () {
      final body = DetailRenderer.iosCodeSignBody(null, t);

      expect(body, contains(t.ios_info.codesign_not_run));
      // 空串会被读成「没问题」—— 「没查」必须说出来。
      expect(body, isNotEmpty);
      expect(body, isNot(contains(t.signature.status_verified)));
    });

    test('验证失败时不带表头的版本仍然给出原始输出', () {
      const result = IosCodeSignResult(
        status: SignatureStatus.verificationFailed,
        toolExecuted: true,
        exitCode: 3,
        stderr: 'does not satisfy its designated Requirement',
      );

      final body = DetailRenderer.iosCodeSignBody(result, t);
      expect(body, contains(t.signature.status_failed));
      expect(body, contains('designated Requirement'));
    });

    test('授权比对四态各有独立文案', () {
      final labels = {
        for (final verdict in IosAuthorizationVerdict.values)
          verdict: DetailRenderer.authorizationVerdictLabel(verdict, t),
      };

      expect(labels.values.toSet(), hasLength(labels.length),
          reason: '四态必须给出不同的文案，否则用户分不清');
      for (final label in labels.values) {
        expect(label, isNotEmpty);
      }
    });

    test('平台中立的签名结论与 iOS 状态文案一致', () {
      expect(DetailRenderer.signatureVerdictLabel(SignatureVerdict.verified, t),
          t.signature.status_verified);
      expect(DetailRenderer.signatureVerdictLabel(SignatureVerdict.rejected, t),
          t.signature.status_failed);
      // 「无法确认」在两个平台上必须是同一句话。
      expect(
          DetailRenderer.signatureVerdictLabel(
              SignatureVerdict.inconclusive, t),
          t.signature.status_unknown);
    });
  });
}
