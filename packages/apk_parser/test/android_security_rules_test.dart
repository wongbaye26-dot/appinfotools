// Android 组合规则表（阶段 3.1 的验收测试）。
//
// 抽表的目的不只是「好看」：抽表前 `hasImageInput` 是在**规则 B 里**算出来、
// 再由 C / D / E 读的 —— 规则的书写顺序成了语义的一部分，调换两段就会
// 改变结论，而读代码看不出来。
//
// 现在每条规则只从 `AndroidRuleFacts` 取输入，因此可以**逐条驱动**：
// 给一份只命中某一条的输入，断言结果里恰好出现那一条。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

/// 造一份最小的 DEX 字节（内容只是可打印字符串，供字符串扫描命中）。
Uint8List _blob(List<String> strings) {
  final bytes = <int>[];
  for (final s in strings) {
    bytes.addAll(s.codeUnits);
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

ApkMeta _meta({
  int? targetSdk,
  bool? usesCleartextTraffic,
  List<AndroidPermissionRequest> permissions = const [],
}) {
  final meta = ApkMeta()
    ..permissionRequests = List.of(permissions)
    ..permissions = permissions.map((p) => p.name).toList()
    ..targetSdkVersion = targetSdk
    ..applicationUsesCleartextTraffic = usesCleartextTraffic;
  return meta;
}

AndroidPermissionRequest _perm(String name, {int? maxSdk}) =>
    AndroidPermissionRequest(name, maxSdkVersion: maxSdk);

SecurityAnalysisResult _audit({
  ApkMeta? meta,
  List<String> strings = const [],
}) =>
    AndroidSecurityAudit.audit(
      meta: meta ?? _meta(targetSdk: 34),
      dexEntries: strings.isEmpty
          ? const []
          : [DexBytes('classes.dex', _blob(strings))],
    );

List<String> _ids(SecurityAnalysisResult r) =>
    r.findings.map((f) => f.ruleId).toList();

void main() {
  group('组合规则表的结构', () {
    test('id 唯一、以 ANDROID-RULE- 开头，且每条都写了说明', () {
      final ids = androidSecurityRules.map((r) => r.id).toList();
      expect(ids.toSet(), hasLength(ids.length), reason: '规则 id 必须唯一');
      for (final rule in androidSecurityRules) {
        expect(rule.id, startsWith('ANDROID-RULE-'));
        expect(
          rule.summary.trim(),
          isNotEmpty,
          reason: '${rule.id} 没有说明 —— 抽表后说明是数据，不该只活在注释里',
        );
      }
    });

    test('表里的顺序就是报告里的输出顺序', () {
      // A → F：先具体（广泛访问、组合线索），再兜底（「未发现」）。
      expect(
        androidSecurityRules.map((r) => r.id).toList(),
        [
          'ANDROID-RULE-A',
          'ANDROID-RULE-B',
          'ANDROID-RULE-C',
          'ANDROID-RULE-D',
          'ANDROID-RULE-E',
          'ANDROID-RULE-F',
        ],
      );
    });
  });

  group('逐条驱动：每条规则都能被单独触发', () {
    /// 规则 → 只命中它的输入。
    final cases = <String, SecurityAnalysisResult Function()>{
      // 只有广泛存储权限、没有图片业务线索。
      'ANDROID-RULE-A': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [
                _perm('android.permission.MANAGE_EXTERNAL_STORAGE')
              ],
            ),
          ),
      // 相册权限 + OCR 线索，**没有**上传线索（否则会一并命中 C）。
      'ANDROID-RULE-B': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
            ),
            strings: ['Lcom/google/mlkit/vision/text/TextRecognizer;'],
          ),
      // 相册 + OCR + 上传三段齐备。
      'ANDROID-RULE-C': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
            ),
            strings: [
              'Lcom/google/mlkit/vision/text/TextRecognizer;',
              'multipart/form-data',
            ],
          ),
      // 只开明文流量，没有任何敏感线索 → 非升级版。
      'ANDROID-RULE-D': () => _audit(
            meta: _meta(targetSdk: 34, usesCleartextTraffic: true),
          ),
      // 后台入口 + 敏感数据 + 上传。
      'ANDROID-RULE-E': () => _audit(
            meta: _meta(
              targetSdk: 34,
              permissions: [
                _perm('android.permission.READ_MEDIA_IMAGES'),
                _perm('android.permission.RECEIVE_BOOT_COMPLETED'),
              ],
            ),
            strings: ['multipart/form-data'],
          ),
      // 没有任何上传线索 → 显式「未发现」。
      'ANDROID-RULE-F': () => _audit(strings: ['unrelated']),
    };

    test('表里的每一条都在这里有覆盖（新加规则时会红）', () {
      expect(
        cases.keys.toSet(),
        androidSecurityRules.map((r) => r.id).toSet(),
        reason: '新增规则却忘了在这里给它一个输入 —— 那就等于没被逐条驱动过',
      );
    });

    for (final entry in cases.entries) {
      test('${entry.key} 能被单独触发', () {
        final result = entry.value();
        expect(
          _ids(result),
          contains(entry.key),
          reason: '实际产出：${_ids(result)}',
        );
      });
    }

    test('规则 D 的升级变体：有敏感线索时 ruleId 加 -ESCALATED 并升到 P1', () {
      final plain = _audit(
        meta: _meta(targetSdk: 34, usesCleartextTraffic: true),
      );
      final escalated = _audit(
        meta: _meta(
          targetSdk: 34,
          usesCleartextTraffic: true,
          permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
        ),
        strings: ['Lcom/google/mlkit/vision/text/TextRecognizer;'],
      );

      expect(_ids(plain), contains('ANDROID-RULE-D'));
      expect(_ids(escalated), contains('ANDROID-RULE-D-ESCALATED'));
      expect(
        plain.findings.firstWhere((f) => f.ruleId == 'ANDROID-RULE-D').severity,
        SecuritySeverity.p2,
      );
      expect(
        escalated.findings
            .firstWhere((f) => f.ruleId == 'ANDROID-RULE-D-ESCALATED')
            .severity,
        SecuritySeverity.p1,
      );
    });
  });

  group('不回归：规则集合与等级与抽表前一致', () {
    test('一份「什么都沾一点」的输入产出确定的有序结论', () {
      final result = _audit(
        meta: _meta(
          targetSdk: 34,
          usesCleartextTraffic: true,
          permissions: [
            _perm('android.permission.MANAGE_EXTERNAL_STORAGE'),
            _perm('android.permission.READ_MEDIA_IMAGES'),
            _perm('android.permission.RECEIVE_BOOT_COMPLETED'),
          ],
        ),
        strings: [
          'Lcom/google/mlkit/vision/text/TextRecognizer;',
          'multipart/form-data',
          'okhttp3.OkHttpClient',
          'https://cdn.example.com/api',
        ],
      );

      // 只断言**组合规则**这一段（权限逐条审计与能力发现不在这张表里）。
      final combos = result.findings
          .where((f) => f.ruleId.startsWith('ANDROID-RULE-'))
          .map((f) => '${f.ruleId}:${f.severity.name}')
          .toList();

      expect(combos, [
        'ANDROID-RULE-A:p2',
        'ANDROID-RULE-B:p2',
        'ANDROID-RULE-C:p1',
        'ANDROID-RULE-D-ESCALATED:p1',
        'ANDROID-RULE-E:p1',
      ]);
      // 有上传线索 → 不该出现「未发现」。
      expect(_ids(result), isNot(contains('ANDROID-RULE-F')));
    });

    test('没有任何线索时只产出规则 F，且置信度是 unknown', () {
      final result = _audit();
      final combos = result.findings
          .where((f) => f.ruleId.startsWith('ANDROID-RULE-'))
          .toList();
      expect(combos.map((f) => f.ruleId), ['ANDROID-RULE-F']);
      expect(combos.single.confidence, SecurityConfidence.unknown);
    });
  });
}
