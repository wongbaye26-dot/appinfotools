// 权限去重（审计 P3-1）与 `ANDROID-RULE-F` 补证据（P3-2）。
//
// ## P3-1 为什么必须去重
//
// 抖音的 manifest 把 `ACCESS_COARSE_LOCATION` 声明了两次，审计产出**两张完全
// 一样**的卡片（ruleId / severity / confidence / evidence 全同）。用户会以为
// 「这里有两个问题」。
//
// 但去重只能去**精确重复**：同一个权限名、`maxSdkVersion` 不同时是两条不同的
// 声明（一条可能已过期、一条仍然生效），合并会把其中一条的版本条件吃掉。
//
// ## P3-2 为什么 RULE-F 必须有证据
//
// `SecurityFinding.evidence` 的文档写着「空列表意味着这条发现没有依据 ——
// 不允许出现」。RULE-F 是**否定结论**（「没发现上传特征」），语义上没有命中
// 的证据，但它仍然要给出「查了什么」——否则它与「根本没查」在数据上无法区分。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _blob(List<String> strings) {
  final parts = <int>[];
  for (final s in strings) {
    parts.addAll(s.codeUnits);
    parts.add(0);
  }
  return Uint8List.fromList(parts);
}

ApkMeta _meta(List<AndroidPermissionRequest> requests, {int? targetSdk}) {
  final meta = ApkMeta()
    ..permissionRequests = requests
    ..permissions = requests.map((r) => r.name).toList()
    ..components = const [];
  meta.targetSdkVersion = targetSdk;
  return meta;
}

List<SecurityFinding> _byId(SecurityAnalysisResult r, String ruleId) =>
    r.findings.where((f) => f.ruleId == ruleId).toList();

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('权限精确重复只审一次', () {
    test('同一个权限声明两次 → 一条发现，不是两张一样的卡片', () {
      const twice = [
        AndroidPermissionRequest('android.permission.ACCESS_COARSE_LOCATION'),
        AndroidPermissionRequest('android.permission.ACCESS_COARSE_LOCATION'),
      ];
      final result = AndroidSecurityAudit.audit(
        meta: _meta(twice, targetSdk: 34),
        dexEntries: const [],
      );
      final findings =
          _byId(result, 'ANDROID-PERMISSION-ACCESS_COARSE_LOCATION');
      expect(findings, hasLength(1), reason: '同一条权限出现两次，界面上会变成两张一模一样的卡片');
    });

    test('同名但 maxSdkVersion 不同 → **两条**（不是精确重复）', () {
      const different = [
        AndroidPermissionRequest('android.permission.READ_EXTERNAL_STORAGE',
            maxSdkVersion: 32),
        AndroidPermissionRequest('android.permission.READ_EXTERNAL_STORAGE'),
      ];
      final result = AndroidSecurityAudit.audit(
        meta: _meta(different, targetSdk: 34),
        dexEntries: const [],
      );
      // 一条已过期（maxSdk 32 < targetSdk 34）、一条仍然生效 —— 结论不同，
      // 合并会把版本条件吃掉。
      final expired = _byId(result, 'ANDROID-PERMISSION-EXPIRED');
      final normal = _byId(result, 'ANDROID-PERMISSION-READ_EXTERNAL_STORAGE');
      expect(expired.length + normal.length, 2,
          reason: '不同 maxSdkVersion 是两条不同的声明');
    });

    test('覆盖表的权限计数用去重后的数量', () {
      const twice = [
        AndroidPermissionRequest('android.permission.INTERNET'),
        AndroidPermissionRequest('android.permission.INTERNET'),
        AndroidPermissionRequest('android.permission.CAMERA'),
      ];
      final result = AndroidSecurityAudit.audit(
        meta: _meta(twice, targetSdk: 34),
        dexEntries: const [],
      );
      final entry = result.coverage.entries
          .firstWhere((e) => e.id == 'android.permissions');
      expect(entry.covered, 2, reason: '去重后是 2 条，不是 3 条');
    });
  });

  group('RULE-F 必须有证据', () {
    test('没有上传线索时：证据非空、指到扫描范围、带 DEX 与调用点数', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(const [], targetSdk: 34),
        dexEntries: [
          DexBytes('classes.dex', _blob(['unrelated']))
        ],
      );
      final ruleF = _byId(result, 'ANDROID-RULE-F').single;

      expect(ruleF.evidence, isNotEmpty, reason: '空证据让它与「根本没查」在数据上无法区分');
      final ev = ruleF.evidence.first;
      expect(ev.source, SecurityEvidenceSource.dexMethodReference);
      // 英文回退里也要有两个数（界面上优先用 detailCode 的本地化文本）。
      expect(ev.detail, contains('DEX'));
      expect(ev.detail, contains('call site'));
      // 结构化参数：本地化模板要用它们。
      expect(ev.detailArgs['dex'], isNotNull);
      expect(ev.detailArgs['callSites'], isNotNull);
      expect(ev.location, contains('DEX'));
    });

    test('中文界面下这条证据是中文（走 i18n，不是英文回退）', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(const [], targetSdk: 34),
        dexEntries: [
          DexBytes('classes.dex', _blob(['unrelated']))
        ],
      );
      final ruleF = _byId(result, 'ANDROID-RULE-F').single;
      final text = AnalysisReport.detailText(ruleF.evidence.first, t);

      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue,
          reason: '中文界面下不能显示英文回退：$text');
      expect(text, isNot(contains('{')), reason: '占位符必须被替换：$text');
    });

    test('没有 DEX 时证据仍在，但说明是 0（不假装查过）', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(const [], targetSdk: 34),
        dexEntries: const [],
      );
      final ruleF = _byId(result, 'ANDROID-RULE-F').single;
      expect(ruleF.evidence, isNotEmpty);
      expect(ruleF.confidence, SecurityConfidence.unknown,
          reason: '没读到 DEX 时「没发现」只能是 unknown');
    });
  });
}
