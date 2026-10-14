// FileState 的值语义测试（审计 5.9）。
//
// 两件事：`copyWith` 必须能**清空**字段（旧的 `??` 写法做不到），以及实现
// `==` 之后「内容没变」不再触发通知 —— Riverpod 的 `updateShouldNotify`
// 默认就是 `previous != next`，所以 `==` 直接决定了会不会多余重建。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:apk_info_tool/ipaparser/ipa_analysis.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/utils/signature_analyzer.dart';
import 'package:apk_parser/apk_parser.dart'
    show ReferenceCycle, ReferenceCycleReport;
import 'package:flutter_test/flutter_test.dart';
import 'package:ipa_parser/ipa_parser.dart' show IpaContainer;

void main() {
  group('FileState.copyWith 的置空语义', () {
    test('不传参数时保留原值', () {
      final base = FileState(filePath: '/a.apk', fileSize: 10, md5Hash: 'm');

      final copy = base.copyWith();

      expect(copy.filePath, '/a.apk');
      expect(copy.fileSize, 10);
      expect(copy.md5Hash, 'm');
    });

    test('显式传 null 能清空字段，未传的字段保持不变', () {
      final base = FileState(filePath: '/a.apk', md5Hash: 'm', sha1Hash: 's');

      final copy = base.copyWith(filePath: null, md5Hash: null);

      expect(copy.filePath, isNull);
      expect(copy.md5Hash, isNull);
      expect(copy.sha1Hash, 's', reason: '未传的字段应保留');
    });

    test('可以清空 signature —— 切文件时不会留下上一个文件的签名结果', () {
      final base = FileState(signature: SignatureAnalysis.toolUnavailable('x'));

      expect(base.copyWith(signature: null).signature, isNull);
      expect(base.copyWith().signature, isNotNull);
    });

    test('非空值正常覆盖', () {
      final base = FileState(md5Hash: 'old');

      expect(base.copyWith(md5Hash: 'new').md5Hash, 'new');
      expect(base.copyWith(fileSize: 42).fileSize, 42);
    });
  });

  group('FileState 值语义', () {
    test('字段相同的两个实例相等，hashCode 一致', () {
      final a = FileState(filePath: '/a.apk', fileSize: 1, md5Hash: 'm');
      final b = FileState(filePath: '/a.apk', fileSize: 1, md5Hash: 'm');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('任一字段不同即不相等', () {
      final base = FileState(filePath: '/a.apk', md5Hash: 'm');

      expect(base == base.copyWith(md5Hash: 'x'), isFalse);
      expect(base == base.copyWith(fileSize: 5), isFalse);
      expect(base == base.copyWith(sha256Hash: 'z'), isFalse);
    });

    test('apkInfo 按引用比较：实例不同即视为不同结果', () {
      expect(
        FileState(apkInfo: ApkInfo()) == FileState(apkInfo: ApkInfo()),
        isFalse,
        reason: '两次独立解析是两次不同的结果，即使字段看起来一样',
      );

      final shared = ApkInfo();
      expect(
        FileState(apkInfo: shared) == FileState(apkInfo: shared),
        isTrue,
      );
    });

    test('isComputingHash 的变化被识别，重复设同值则视为无变化', () {
      const computing = FileState(isComputingHash: true);
      final done = computing.copyWith(isComputingHash: false);

      expect(done == computing, isFalse);
      // 关键：没有变化时不应通知监听者，避免多余重建
      expect(done == done.copyWith(isComputingHash: false), isTrue);
    });

    test('默认构造与空副本相等（无变化时不通知监听者）', () {
      const empty = FileState();

      expect(empty == empty.copyWith(), isTrue);
    });
  });

  group('FileState.analysis — 诊断必须传到统一结果里', () {
    // 曾经漏了这一句：`buildIos` / `buildAndroid` 的 `diagnostics` 参数有默认值
    // `const []`，于是**不传也不会报错**，统一结果里的诊断永远是空的 ——
    // 详情页的「解析诊断」卡片与导出的报告里因此什么都看不到，
    // 而 iOS 侧其实产出了几十条诊断。
    //
    // 「读不到」与「没有可说的」必须分得开，这条链路断在这里就等于把前者
    // 说成了后者。
    test('iOS 的诊断出现在统一结果里', () {
      const diagnostic = AnalysisDiagnostic.warning(
        'ios.icons.asset_catalog',
        'CFBundleIconName resolves into Assets.car',
      );
      final state = FileState(
        filePath: 'Example.ipa',
        ipaAnalysis: const IpaAnalysis(
          container: IpaContainer(),
          diagnostics: [diagnostic],
        ),
      );

      final analysis = state.analysis!;
      expect(analysis.diagnostics, contains(diagnostic));
      // 同时也要能从 iOS 专属部分查到 —— 两处是同一批数据，不该只有一处有。
      expect(analysis.ios!.diagnostics, contains(diagnostic));
    });

    test('没有诊断时是空列表，而不是 null', () {
      final state = FileState(
        filePath: 'Example.ipa',
        ipaAnalysis: const IpaAnalysis(container: IpaContainer()),
      );

      expect(state.analysis!.diagnostics, isEmpty);
    });

    // Android 侧与 iOS 侧是**同一个**缺陷：`buildAndroid` 的 `diagnostics`
    // 参数同样有默认值 `const []`，同样漏传了很久。修 iOS 时没有一起修，
    // 于是 Android 的「解析诊断」卡片一直是空的。
    test('Android 的清单解析失败会出现在统一结果里', () {
      final info = ApkInfo()..parseFailureReason = 'manifest truncated';
      final state = FileState(filePath: 'Example.apk', apkInfo: info);

      final analysis = state.analysis!;
      final codes = analysis.diagnostics.map((d) => d.code);
      expect(codes, contains('android.manifest_unparsed'));
      // 原因必须带上 —— 只说「解析失败」等于没说。
      expect(
        analysis.diagnostics.first.message,
        contains('manifest truncated'),
      );
    });

    test('Android 的分包一致性结论会出现在统一结果里', () {
      final info = ApkInfo()
        ..splitConsistency = const SplitConsistencyReport(
          issues: ['分包 split_config.x.apk 解压失败，未能比对。'],
          checkedCount: 8,
          totalCount: 12,
        );
      final state = FileState(filePath: 'multi.xapk', apkInfo: info);

      final analysis = state.analysis!;
      final codes = analysis.diagnostics.map((d) => d.code).toList();
      expect(codes, contains('android.split_inconsistent'));
      expect(codes, contains('android.split_sampling_truncated'));
    });

    test('Android 没有可说的时是空列表，不编造诊断', () {
      final state = FileState(filePath: 'Example.apk', apkInfo: ApkInfo());

      expect(state.analysis!.diagnostics, isEmpty);
    });

    test('Android 的资源引用环会出现在统一结果里', () {
      final info = ApkInfo()
        ..resourceReferenceCycles = const ReferenceCycleReport(
          cycles: [
            ReferenceCycle([0x7f010000, 0x7f010001]),
          ],
        );
      final state = FileState(filePath: 'Example.apk', apkInfo: info);

      final diagnostics = state.analysis!.diagnostics;
      expect(
        diagnostics.map((d) => d.code),
        contains('android.resource_reference_cycle'),
      );
      // 描述必须能看出「回到起点」，否则读者不知道它是个环。
      expect(diagnostics.first.message, contains('0x7f010000'));
      expect(diagnostics.first.message, contains('0x7f010001'));
    });

    test('图标渲染的说明会进诊断，不只在日志里', () {
      final info = ApkInfo()
        ..iconResolutionNotes = ['color reference cycle: @a -> @b -> @a'];
      final state = FileState(filePath: 'Example.apk', apkInfo: info);

      expect(
        state.analysis!.diagnostics.map((d) => d.code),
        contains('android.icon_resolution'),
      );
    });
  });
}
