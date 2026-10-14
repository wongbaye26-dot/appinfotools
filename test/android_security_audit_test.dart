// Android 安全审计测试（V1.1 规格 3.1–3.4 与第五章规则 A–F）。
//
// 断言的重点是**措辞与定级是否守住了规格的红线**，而不是「有没有产出」：
// - 权限数量与风险无关：只有广泛存储访问时才给 P2，且措辞是「需人工复核」；
// - 未证实的数据流必须标 suspected 并在 relationship 里写出未证实的环节；
// - 规则 F 必须显式输出「未发现」，且不允许推导成「确认安全」；
// - 版本条件必须参与判定：带 maxSdkVersion=32 的 READ_EXTERNAL_STORAGE
//   在 targetSdk 34 上不生效，不得计入广泛访问。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
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

ApkMeta _meta({
  List<AndroidPermissionRequest> permissions = const [],
  int? targetSdk,
  int? minSdk,
  bool? usesCleartextTraffic,
  List<AndroidComponent> components = const [],
}) {
  final meta = ApkMeta()
    ..permissionRequests = List.of(permissions)
    ..permissions = permissions.map((p) => p.name).toList()
    ..targetSdkVersion = targetSdk
    ..minSdkVersion = minSdk
    ..applicationUsesCleartextTraffic = usesCleartextTraffic
    ..components = List.of(components);
  return meta;
}

AndroidPermissionRequest _perm(String name,
        {int? maxSdk, bool sdk23 = false}) =>
    AndroidPermissionRequest(name, maxSdkVersion: maxSdk, sdk23Only: sdk23);

SecurityFinding? _byId(SecurityAnalysisResult r, String ruleId) {
  for (final f in r.findings) {
    if (f.ruleId == ruleId) return f;
  }
  return null;
}

void main() {
  group('权限逐条审计', () {
    test('现代相册权限只作事实记录，不因数量定级', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [
            _perm('android.permission.READ_MEDIA_IMAGES'),
            _perm('android.permission.READ_MEDIA_VIDEO'),
            _perm('android.permission.INTERNET'),
          ],
        ),
        dexEntries: const [],
      );

      final images = _byId(result, 'ANDROID-PERMISSION-READ_MEDIA_IMAGES');
      expect(images, isNotNull);
      expect(images!.severity, SecuritySeverity.info);
      expect(images.confidence, SecurityConfidence.confirmed);
      expect(images.evidence.single.source, SecurityEvidenceSource.manifest);
      expect(images.evidence.single.location, contains('READ_MEDIA_IMAGES'));
      // 三个权限都不该把结论推向风险档。
      expect(result.hasRiskFindings, isFalse);
    });

    test('READ_MEDIA_VISUAL_USER_SELECTED 与完整图库访问区分表述', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [
            _perm('android.permission.READ_MEDIA_VISUAL_USER_SELECTED'),
          ],
        ),
        dexEntries: const [],
      );

      final finding =
          _byId(result, 'ANDROID-PERMISSION-READ_MEDIA_VISUAL_USER_SELECTED');
      expect(finding, isNotNull);
      // 规格 3.1：不得与完整图库访问一概而论。
      expect(finding!.finding, contains('用户主动选中'));
      expect(finding.finding, isNot(contains('完整图库')));
      expect(finding.severity, SecuritySeverity.info);
    });

    test('MANAGE_EXTERNAL_STORAGE 单独出现即为需人工复核的中风险', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [_perm('android.permission.MANAGE_EXTERNAL_STORAGE')],
        ),
        dexEntries: const [],
      );

      final ruleA = _byId(result, 'ANDROID-RULE-A');
      expect(ruleA, isNotNull);
      expect(ruleA!.severity, SecuritySeverity.p2);
      expect(ruleA.finding, contains('人工复核'));
      // 不得出现任何绝对化措辞。
      expect(ruleA.finding, isNot(contains('恶意')));
      expect(ruleA.finding, isNot(contains('窃取')));
    });

    test('未编目权限汇总一条，不逐条刷屏', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [
            _perm('android.permission.VIBRATE'),
            _perm('com.example.app.permission.CUSTOM'),
            _perm('android.permission.INTERNET'),
          ],
        ),
        dexEntries: const [],
      );

      final summary = _byId(result, 'ANDROID-PERMISSION-UNCATEGORIZED');
      expect(summary, isNotNull);
      expect(summary!.finding, contains('VIBRATE'));
      expect(summary.finding, contains('com.example.app.permission.CUSTOM'));
      // 只有一条汇总，而不是每个未编目权限一条。
      expect(
        result.findings
            .where((f) => f.ruleId == 'ANDROID-PERMISSION-UNCATEGORIZED'),
        hasLength(1),
      );
    });
  });

  group('版本条件（规格 3.1：不混淆不同系统版本的访问模型）', () {
    test('带 maxSdkVersion=32 的 READ_EXTERNAL_STORAGE 在 targetSdk 34 上不生效', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [
            _perm('android.permission.READ_EXTERNAL_STORAGE', maxSdk: 32),
          ],
        ),
        dexEntries: const [],
      );

      final expired = _byId(result, 'ANDROID-PERMISSION-EXPIRED');
      expect(expired, isNotNull);
      expect(expired!.severity, SecuritySeverity.info);
      expect(expired.finding, contains('maxSdkVersion=32'));
      expect(expired.finding, contains('不再授予'));
      // 关键：不再生效的存储访问不得计入规则 A 的「广泛访问」。
      expect(_byId(result, 'ANDROID-RULE-A'), isNull);
      expect(result.hasRiskFindings, isFalse);
    });

    test('targetSdk ≤ 32 的 READ_EXTERNAL_STORAGE 计入广泛访问', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 30,
          permissions: [_perm('android.permission.READ_EXTERNAL_STORAGE')],
        ),
        dexEntries: const [],
      );

      expect(_byId(result, 'ANDROID-RULE-A'), isNotNull);
      expect(_byId(result, 'ANDROID-RULE-A')!.severity, SecuritySeverity.p2);
    });

    test('sdk-23 声明无法静态判定生效，输出 UNKNOWN 而不是猜', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [
            _perm('android.permission.WRITE_SETTINGS', sdk23: true)
          ],
        ),
        dexEntries: const [],
      );

      final conditional = _byId(result, 'ANDROID-PERMISSION-SDK23-CONDITIONAL');
      expect(conditional, isNotNull);
      expect(conditional!.severity, SecuritySeverity.unknown);
      expect(conditional.confidence, SecurityConfidence.unknown);
      expect(result.hasCoverageGaps, isTrue);
    });
  });

  group('规则 B / C：OCR 组合（规格 3.3 的判断规则）', () {
    test('仅 OCR：记录能力，不判恶意', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(targetSdk: 34),
        dexEntries: [
          DexBytes('classes.dex',
              _blob(['Lcom/google/mlkit/vision/text/TextRecognizer;'])),
        ],
      );

      final ocr = _byId(result, 'ANDROID-OCR-CAPABILITY');
      expect(ocr, isNotNull);
      expect(ocr!.severity, SecuritySeverity.info);
      expect(ocr.confidence, SecurityConfidence.independentCapability);
      expect(ocr.finding, contains('不判定恶意'));
      // 没有相册访问 → 不触发规则 B/C。
      expect(_byId(result, 'ANDROID-RULE-B'), isNull);
      expect(_byId(result, 'ANDROID-RULE-C'), isNull);
    });

    test('相册 + OCR：P2，措辞为「可能」，且写明未证实的环节', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
        ),
        dexEntries: [
          DexBytes('classes.dex',
              _blob(['Lcom/google/mlkit/vision/text/TextRecognizer;'])),
        ],
      );

      final ruleB = _byId(result, 'ANDROID-RULE-B');
      expect(ruleB, isNotNull);
      expect(ruleB!.severity, SecuritySeverity.p2);
      expect(ruleB.confidence, SecurityConfidence.suspected);
      expect(ruleB.finding, contains('可能'));
      expect(ruleB.relationship, contains('未被证实'));
      expect(ruleB.evidence.length, greaterThanOrEqualTo(2));
    });

    test('相册 + OCR + 上传：P1 且列出未证实的数据流环节', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
        ),
        dexEntries: [
          DexBytes(
              'classes.dex',
              _blob([
                'Lcom/google/mlkit/vision/text/TextRecognizer;',
                'multipart/form-data',
              ])),
        ],
      );

      final ruleC = _byId(result, 'ANDROID-RULE-C');
      expect(ruleC, isNotNull);
      expect(ruleC!.severity, SecuritySeverity.p1);
      expect(ruleC.confidence, SecurityConfidence.suspected);
      expect(ruleC.dataSource, contains('照片'));
      expect(ruleC.dataSink, contains('上传'));
      expect(ruleC.relationship, contains('未被证实'));
      expect(result.highestRiskFinding!.ruleId, 'ANDROID-RULE-C');
    });
  });

  group('规则 D / E / F', () {
    test('明文开关单独出现为 P2；与敏感线索同现升级为 P1', () {
      final alone = AndroidSecurityAudit.audit(
        meta: _meta(targetSdk: 34, usesCleartextTraffic: true),
        dexEntries: const [],
      );
      expect(_byId(alone, 'ANDROID-RULE-D')!.severity, SecuritySeverity.p2);

      final withSensitive = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          usesCleartextTraffic: true,
          permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
        ),
        dexEntries: [
          DexBytes('classes.dex', _blob(['multipart/form-data'])),
        ],
      );
      final escalated = _byId(withSensitive, 'ANDROID-RULE-D-ESCALATED');
      expect(escalated, isNotNull);
      expect(escalated!.severity, SecuritySeverity.p1);
    });

    test('规则 E：后台 + 敏感 + 上传三项齐备才升级', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [
            _perm('android.permission.READ_MEDIA_IMAGES'),
            _perm('android.permission.RECEIVE_BOOT_COMPLETED'),
          ],
        ),
        dexEntries: [
          DexBytes('classes.dex', _blob(['multipart/form-data'])),
        ],
      );
      final ruleE = _byId(result, 'ANDROID-RULE-E');
      expect(ruleE, isNotNull);
      expect(ruleE!.severity, SecuritySeverity.p1);
      expect(ruleE.finding, contains('需在运行时进一步验证'));

      // 去掉上传线索：不得升级（规格规则 E 的关键前提）。
      final withoutUpload = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [
            _perm('android.permission.READ_MEDIA_IMAGES'),
            _perm('android.permission.RECEIVE_BOOT_COMPLETED'),
          ],
        ),
        dexEntries: const [],
      );
      expect(_byId(withoutUpload, 'ANDROID-RULE-E'), isNull);
    });

    test('规则 F：未发现上传特征时显式输出「未发现」措辞', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(targetSdk: 34, permissions: const []),
        dexEntries: [
          DexBytes('classes.dex', _blob(['okhttp3.OkHttpClient'])),
        ],
      );

      final ruleF = _byId(result, 'ANDROID-RULE-F');
      expect(ruleF, isNotNull);
      expect(ruleF!.severity, SecuritySeverity.info);
      expect(ruleF.finding, contains('未发现'));
      // 规格红线：不得输出「确认不存在恶意行为」这类结论。
      expect(ruleF.finding, isNot(contains('确认安全')));
      expect(ruleF.finding, isNot(contains('不存在恶意')));
      expect(ruleF.finding, contains('这不表示'));
    });

    test('完全没有 DEX 时「未发现」的置信度是不完整的', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(targetSdk: 34),
        dexEntries: const [],
      );

      final ruleF = _byId(result, 'ANDROID-RULE-F');
      expect(ruleF!.confidence, SecurityConfidence.unknown);
      expect(
        result.limitations.any((l) => l.contains('未读取到任何 classes.dex')),
        isTrue,
      );
    });
  });

  group('域名提取的措辞', () {
    test('静态提取的域名必须声明「不等于实际访问」', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(targetSdk: 34),
        dexEntries: [
          DexBytes('classes.dex', _blob(['https://cdn.example.com/x'])),
        ],
      );

      final endpoints = _byId(result, 'ANDROID-NETWORK-ENDPOINTS');
      expect(endpoints, isNotNull);
      expect(endpoints!.finding, contains('不等于运行时实际访问'));
      expect(endpoints.finding, contains('cdn.example.com'));
      expect(endpoints.severity, SecuritySeverity.info);
    });
  });

  group('真实样本：加固 APK 的 manifest', () {
    // test/fixtures/apk/hardened-manifest.axml —— 来自真实加固 APK，
    // 40 条 uses-permission，其中 READ_EXTERNAL_STORAGE 带 maxSdkVersion=32，
    // targetSdkVersion=34（期望值由独立 Python 解码器核对，见该目录 README）。
    late ApkMeta meta;

    setUpAll(() {
      final file = File('test/fixtures/apk/hardened-manifest.axml');
      meta = ManifestParser.parse(file.readAsBytesSync());
    });

    test('样本能跑完整审计且不抛异常', () {
      final result = AndroidSecurityAudit.audit(
        meta: meta,
        dexEntries: const [],
        containerAnomalies: const ['decoyArchiveEntries: 78 entries'],
      );

      expect(result.findings, isNotEmpty);
      // 除规则 F（「未发现」类）外，每条发现都必须带证据 ——
      // 没有证据的结论不允许出现。
      for (final finding in result.findings) {
        if (finding.ruleId == 'ANDROID-RULE-F') continue;
        expect(finding.evidence, isNotEmpty, reason: '${finding.ruleId} 缺少证据');
      }
      expect(
        result.limitations.any((l) => l.contains('未读取到任何 classes.dex')),
        isTrue,
      );
    });

    test('样本的 READ_EXTERNAL_STORAGE 因 maxSdkVersion=32 不生效', () {
      final request = meta.permissionRequests.firstWhere(
        (r) => r.name.endsWith('READ_EXTERNAL_STORAGE'),
      );
      expect(request.maxSdkVersion, 32);

      final result = AndroidSecurityAudit.audit(
        meta: meta,
        dexEntries: const [],
      );
      final expired = result.findings.where(
        (f) =>
            f.ruleId == 'ANDROID-PERMISSION-EXPIRED' &&
            f.finding.contains('READ_EXTERNAL_STORAGE'),
      );
      expect(expired, hasLength(1));
    });

    test('样本含 MANAGE_EXTERNAL_STORAGE，规则 A 触发', () {
      final result = AndroidSecurityAudit.audit(
        meta: meta,
        dexEntries: const [],
      );
      final ruleA = _byId(result, 'ANDROID-RULE-A');
      expect(ruleA, isNotNull);
      expect(
          ruleA!.evidence
              .any((e) => e.detail.contains('MANAGE_EXTERNAL_STORAGE')),
          isTrue);
    });

    test('manifest 未被成功解析时记录覆盖不足而不是给全绿', () {
      final result = AndroidSecurityAudit.audit(
        meta: ApkMeta(),
        dexEntries: const [],
        manifestParsed: false,
        manifestFailureReason: 'binary XML chunk out of range',
      );

      expect(result.findings.any((f) => f.severity.isRisk), isFalse);
      expect(result.hasCoverageGaps, isTrue);
      expect(
        result.limitations.any((l) => l.contains('未能解析')),
        isTrue,
      );
    });
  });
}
