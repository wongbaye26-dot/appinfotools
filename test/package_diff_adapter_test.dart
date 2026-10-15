// 适配层测试：`PackageAnalysisResult` → `DiffSubject`（阶段 5.2 的地基）。
//
// 适配层的字段清单与顺序**就是差异报告的输出顺序**，因此这份清单是契约：
// 加字段要同步这里，否则新增字段会静默地不进差异。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/analysis_builder.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/models/analysis/package_diff_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

PackageAnalysisResult _android({
  int? minSdk,
  int? targetSdk,
  List<String> permissions = const [],
  List<String> domains = const [],
}) =>
    AnalysisBuilder.buildAndroid(
      filePath: '/tmp/a.apk',
      fileSize: 1024,
      manifestSource: FieldSource.builtinParser,
      minSdkVersion: minSdk,
      targetSdkVersion: targetSdk,
      permissions: permissions,
      security: domains.isEmpty
          ? null
          : SecurityAnalysisResult(
              engineVersion: 'e',
              rulesVersion: 'r',
              network: NetworkFacts(domains: domains),
            ),
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
    });

    test('字段顺序是契约：先文件身份、再应用身份、再平台专属', () {
      final subject = diffSubjectOf(_android(minSdk: 21));
      final ids = subject.fields.map((f) => f.id).toList();

      expect(ids.indexOf('file.fileName'), lessThan(ids.indexOf('app.name')));
      expect(
        ids.indexOf('app.buildNumber'),
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
      final withDomains = diffSubjectOf(_android(domains: ['a.example']));
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
      expect(diff.unknownFieldCount, 1);
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
}
