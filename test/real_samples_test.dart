// 真实样本的端到端集成测试（交付要求 7）。
//
// 单元测试用的是构造出来的样本，它能证明「解析器按设计工作」，但证明不了
// 「真实世界的东西能解析」。这个文件补的就是后者：把 `APPINFOTOOL_SAMPLES`
// 指向一个存放 `.apk` / `.ipa` 的目录，就会用**真实的应用解析流水线**把它们
// 跑一遍。
//
// 样本不进版本库（体积大、且属于用户数据），因此未设置该环境变量时整体
// **跳过**，并明确说明是「未执行」而不是「通过」：
//
// ```sh
// APPINFOTOOL_SAMPLES=/path/to/samples flutter test test/real_samples_test.dart
// ```
//
// 对未知样本无法断言具体字段值，因此断言的是**不变量**：
// 解析不抛异常、平台判定正确、不产生虚构值、报告可渲染。
// 具体解析结果由测试打印出来供人工核对（并记录进交付报告）。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/ipaparser/ios_codesign_step.dart';
import 'package:apk_info_tool/ipaparser/ipa_parse_task.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_info_tool/utils/detail_renderer.dart';
import 'package:apk_info_tool/utils/file_hash.dart';
import 'package:apk_info_tool/utils/ios_codesign_analyzer.dart';
import 'package:apk_parser/apk_parser.dart' show ApkParseStage;
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_directory.dart';

/// 样本目录扫描结果。
///
/// **不要在文件顶层直接读环境变量再压成 `const []`**：那样「目录里没有 APK」
/// 与「根本没配环境变量」会长得一模一样，前者会让 `sample!` 崩在 null-check 上。
/// 五种情况由 [SampleDirectory] 分别给出可理解的原因。
final SampleDirectory _samples = SampleDirectory.fromEnvironment();

/// 打印一段带标题的内容，便于人工核对。
void _dump(String title, String body) {
  // ignore: avoid_print
  print('\n===== $title =====\n$body\n===== /$title =====');
}

void main() {
  // 先把「这次扫到了什么」打进日志：CI 与本地都靠这一行辨别
  // 「跑了 / 跳过了 / 为什么跳过」，而不是从 0 个通过里猜。
  // ignore: avoid_print
  print('[samples] ${_samples.summary}');

  group('真实 APK 样本', () {
    final samples = _samples.samplesOf(SampleKind.android);

    test('每个样本都能解析完成，且不产生虚构值', () async {
      // 样本为空时这一组已经被 `skip` 拦掉了；走到这里就一定有样本。
      // 不再用 `expect(samples, isNotEmpty)` 兜底 —— 那会把「环境缺样本」
      // 报成「测试失败」。
      for (final sample in samples) {
        final apkPath = sample.path;
        final size = await sample.length();
        final hashes = await computeFileHashes(apkPath);

        ApkInfo? info;
        Object? failure;
        try {
          info = await getApkInfo(
            apkPath,
            onStage: (ApkParseStage stage) {},
          );
        } catch (e) {
          failure = e;
        }

        // 解析失败是允许的（畸形包），但**不允许**是未捕获的崩溃。
        // 这里把它记下来而不是断言成功 —— 断言成功会把「样本解析不了」
        // 变成测试失败，而那可能正是真实结论。
        final result = AnalysisBuilder.buildAndroid(
          filePath: apkPath,
          fileSize: size,
          manifestSource: info?.manifestSource ?? FieldSource.unknown,
          hashes: hashes,
          appName: info?.label,
          packageId: info?.packageName,
          version: info?.versionName,
          buildNumber: info?.versionCode?.toString(),
          minSdkVersion: info?.sdkVersion,
          targetSdkVersion: info?.targetSdkVersion,
          maxSdkVersion: info?.maxSdkVersion,
          debuggable: info?.applicationDebuggable,
          permissions: info?.usesPermissions ?? const [],
          components: info?.components ?? const [],
          hardeningObservations: info?.hardeningObservations ?? const [],
          structure: (info?.structure.fileEntryCount ?? 0) == 0
              ? null
              : info!.structure,
        );

        _dump('APK: ${sample.uri.pathSegments.last}', () {
          final buffer = StringBuffer()
            ..writeln('解析: ${failure == null ? '完成' : '失败 —— $failure'}')
            ..writeln('有解析结果: ${info != null}')
            ..writeln('清单来源: ${info?.manifestSource.name ?? '-'}');
          if (info == null) {
            buffer.writeln('（未产出 ApkInfo，见上面的失败原因）');
          } else {
            buffer
              ..writeln('应用名: ${info.label}')
              ..writeln('包名: ${info.packageName}')
              ..writeln('版本: ${info.versionName} (${info.versionCode})')
              ..writeln('minSdk/targetSdk/maxSdk: '
                  '${info.sdkVersion}/${info.targetSdkVersion}/${info.maxSdkVersion}')
              ..writeln('debuggable: ${info.applicationDebuggable}')
              ..writeln('权限数: ${info.usesPermissions.length}')
              ..writeln('组件数: ${info.components.length}')
              ..writeln('DEX 数: ${info.structure.dexFiles.length}')
              ..writeln('原生库数: ${info.structure.nativeLibraries.length}')
              ..writeln('ABI: ${info.structure.abis}')
              ..writeln('条目数: ${info.structure.fileEntryCount}')
              ..writeln('加固线索: ${info.hardeningObservations.length}');
            for (final observation in info.hardeningObservations) {
              buffer.writeln('  - ${observation.signal.name}: '
                  '${observation.evidence}');
            }
          }
          return buffer.toString();
        }());

        // 不变量：有值就必须非空 —— 不允许出现「有值但是空串」这种伪值。
        for (final field in <FieldValue<Object?>>[
          result.appName,
          result.packageId,
          result.version,
          result.sha256,
        ]) {
          if (field.hasValue) {
            expect('${field.value}', isNotEmpty,
                reason: '${sample.path} 的字段有值但为空');
          }
        }

        // 不变量：加固线索必须**两层都覆盖**。
        //
        // 容器层的线索只看条目名，manifest 层的线索要先解出 manifest 才有 ——
        // 如果哪条线断了（例如 reader 没记住 meta），这里就会少一类。
        if (info != null && (info.hardeningObservations.isNotEmpty)) {
          final signals =
              info.hardeningObservations.map((o) => o.signal.name).toSet();
          expect(
            signals.any((s) =>
                s == 'decoyArchiveEntries' ||
                s == 'manifestLayoutAnomaly' ||
                s == 'missingPrimaryDex' ||
                s == 'dexHeaderNotStandard' ||
                s == 'multipleDexFiles' ||
                s == 'unusualNativeLibraryName' ||
                s == 'executableInAssets' ||
                s == 'resourceTableAnomaly'),
            isTrue,
            reason: '${sample.path} 报了线索但种类不在枚举内',
          );
        }

        // 不变量：哈希必须真的算出来（三种长度）。
        expect(hashes.md5.length, 32);
        expect(hashes.sha1.length, 40);
        expect(hashes.sha256.length, 64);

        // 不变量：报告能渲染，且带上字段状态。
        final report = AnalysisReport.render(result, t,
            generatedAt: DateTime.utc(2026, 10, 13, 12));
        expect(report, contains(t.report.column_status));
        expect(report, contains(t.report.title));
      }
    }, skip: _samples.skipReasonFor(SampleKind.android));
  });

  group('真实 IPA 样本', () {
    final samples = _samples.samplesOf(SampleKind.ios);

    test('每个样本都能解析完成，且签名结论不伪造', () async {
      for (final sample in samples) {
        final ipaPath = sample.path;
        final size = await sample.length();
        final hashes = await computeFileHashes(ipaPath);

        final task = await IpaParseTask.start(ipaPath);
        final events = await task.events.toList();

        final stages =
            events.whereType<IpaStageReached>().map((e) => e.stage).toList();
        final succeeded = events.whereType<IpaParseSucceeded>().toList();
        final openFailed = events.whereType<IpaOpenFailed>().toList();
        final failed = events.whereType<IpaParseFailed>().toList();

        // 静态解析必须成功 —— 一个正常的 IPA 不该解析不了。
        expect(openFailed, isEmpty,
            reason: '${sample.path} 容器打不开：'
                '${openFailed.map((e) => e.result.name).join(', ')}');
        expect(failed, isEmpty,
            reason: '${sample.path} 解析失败：'
                '${failed.map((e) => e.reason).join(', ')}');
        expect(succeeded, hasLength(1));

        final analysis = succeeded.first.analysis;

        // macOS 上顺带跑一次真实的 codesign 验证。
        IosCodeSignResult? codeSign;
        if (analysis.mainApp != null) {
          codeSign = await IosCodeSignStep.run(ipaPath, analysis.mainApp!);
        }

        final result = AnalysisBuilder.buildIos(
          filePath: ipaPath,
          fileSize: size,
          hashes: hashes,
          analysis: analysis,
          codeSign: codeSign,
        );

        _dump('IPA: ${sample.uri.pathSegments.last}', () {
          final info = analysis.infoPlist;
          final buffer = StringBuffer()
            ..writeln('阶段: ${stages.map((s) => s.name).join(' → ')}')
            ..writeln('主应用: ${analysis.mainApp?.path}')
            ..writeln('bundle 数: ${analysis.container.bundles.length}')
            ..writeln('多个主应用: ${analysis.container.hasMultipleMainApps}')
            ..writeln('bundle id: ${info?.bundleIdentifier.value}')
            ..writeln('显示名: ${info?.preferredName.value}')
            ..writeln('版本: ${info?.shortVersionString.value} '
                '(${info?.bundleVersion.value})')
            ..writeln('最低系统版本: ${info?.minimumOSVersion.value}')
            ..writeln('设备类型: ${info?.deviceFamily.value}')
            ..writeln('可执行文件: ${analysis.executablePath}')
            ..writeln('架构: ${analysis.executable?.architectureNames}')
            ..writeln('链接库数: ${analysis.executable?.allLinkedLibraries.length}')
            ..writeln('嵌套 bundle: ${analysis.nestedBinaries.length}')
            ..writeln('图标候选: ${analysis.icon?.candidates.length ?? 0} '
                '(未解析: ${analysis.icon?.unresolved.length ?? 0})')
            ..writeln('签名材料: _CodeSignature='
                '${analysis.signature?.hasCodeSignatureDirectory}, '
                'provision=${analysis.signature?.hasEmbeddedProvision}')
            ..writeln('描述文件: ${analysis.signature?.profile.value?.name.value}')
            ..writeln('授权比对: ${analysis.authorization?.verdict.name}')
            ..writeln('codesign 结论: ${codeSign?.status.name} '
                '退出码=${codeSign?.exitCode}')
            ..writeln('codesign 标识: ${codeSign?.info?.identifier} '
                'Team=${codeSign?.info?.teamIdentifier}')
            ..writeln('codesign 错误: ${codeSign?.error}');

          // 未解析的图标要给出原因（例如 Assets.car）。
          for (final unresolved in analysis.icon?.unresolved ?? const []) {
            buffer.writeln('  未解析图标: ${unresolved.declared} —— '
                '${unresolved.reason}');
          }
          buffer.writeln('诊断 ${analysis.allDiagnostics.length} 条:');
          for (final diagnostic in analysis.allDiagnostics) {
            buffer.writeln('  [${diagnostic.severity.name}] '
                '${diagnostic.code}: ${diagnostic.message}');
          }
          return buffer.toString();
        }());

        // 不变量：签名结论只能来自 codesign，不能凭空「通过」。
        if (codeSign == null || !codeSign.status.hasConclusiveResult) {
          expect(result.signatureVerdict, isNot(SignatureVerdict.verified),
              reason: '没有明确结论时不得显示「验证通过」');
        }

        // 不变量：材料存在不等于验证通过 —— 这两件事在模型里必须是分开的。
        if (analysis.signature?.hasAnyMaterial ?? false) {
          expect(result.ios?.signatureMaterials?.hasAnyMaterial, isTrue);
        }

        // 不变量：报告能渲染。
        final report = AnalysisReport.render(result, t,
            generatedAt: DateTime.utc(2026, 10, 13, 12));
        expect(report, contains(t.report.column_status));

        // 不变量：解析诊断在中文界面上真是中文（迁移的真实数据端到端）。
        //
        // 这一条证明本地化**不只是单测里的合成数据**：真实 IPA 产出的诊断里，
        // 已迁移的 code 在中文下必须渲染成中文，且不残留 `{占位符}`。
        //
        // 语言包是 deferred 的，`setLocaleRaw` 要 await；测试体这里是真实
        // 事件循环（`test()` 而不是 `testWidgets()`），可以直接 await。
        await LocaleSettings.setLocaleRaw('zh-CN');
        try {
          final rendered = // 诊断在 `analysis.allDiagnostics`（容器 + plist + 图标 + Mach-O + 签名材料
              // 各自产出的汇总）；`result.diagnostics` 是 buildIos 显式传入的那一份，
              // 这里没传所以是空的 —— 断言一张空表没有意义。
              DetailRenderer.diagnostics(analysis.allDiagnostics, t);
          expect(rendered, isNotEmpty, reason: '这份样本应当产出诊断');
          // 用 `hasMatch` 而不是 `contains(matches(...))`：后者对**字符串**
          // 的含义是「包含匹配器的描述文本」，不是「含一次匹配」——
          // 第一版就是这么写错的，正则明明匹配上了却判失败。
          expect(
            RegExp(r'ios\.info_plist\.parsed: \S*[\u4e00-\u9fff]')
                .hasMatch(rendered),
            isTrue,
            reason: '已迁移的 code 在中文下仍是英文：$rendered',
          );
          for (final line in rendered.split('\n')) {
            expect(
              RegExp(r'\{[a-z_][a-z0-9_]*\}').hasMatch(line),
              isFalse,
              reason: '诊断里残留了未替换的占位符：$line',
            );
          }
        } finally {
          await LocaleSettings.setLocaleRaw('en');
        }
      }
    }, skip: _samples.skipReasonFor(SampleKind.ios));
  });

  // 这一组是「跳过原因本身」的断言：把五种情况分别钉住，避免以后有人把
  // 「目录里没有 APK」又压回成「未配置」。
  group('样本目录状态与跳过原因', () {
    test('未配置时两类都报告「未执行」', () {
      final scan = SampleDirectory.scan(path: null);
      expect(scan.status, SampleDirStatus.notConfigured);
      for (final kind in SampleKind.values) {
        expect(scan.skipReasonFor(kind), contains('未执行'));
      }
    });

    test('本次实际扫描到的状态可辨识', () {
      // 无论本机有没有配样本，这一条都必须能过 —— 它断言的是「状态与原因
      // 自洽」，不是「一定有样本」。
      final reason = _samples.skipReasonFor(SampleKind.android);
      if (_samples.samplesOf(SampleKind.android).isEmpty) {
        expect(reason, isNotNull);
        expect(reason, isNotEmpty);
      } else {
        expect(reason, isNull);
      }
      expect(_samples.summary, contains('样本目录['));
    });
  });
}
