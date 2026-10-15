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
      final text = AnalysisReport.findingText(finding!, t);
      expect(text, contains('the user explicitly selected'));
      expect(text, isNot(contains('full library access (PhotoKit)')));
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
      // 迁移后要看**本地化后的正文**（B11），断言也跟着换成英文措辞。
      final ruleAText = AnalysisReport.findingText(ruleA, t);
      expect(ruleAText, contains('manual review'));
      // 不得出现任何绝对化措辞。
      expect(ruleAText, isNot(contains('malicious')));
      expect(ruleAText, isNot(contains('steal')));
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
      final expiredText = AnalysisReport.findingText(expired, t);
      expect(expiredText, contains('maxSdkVersion=32'));
      expect(expiredText, contains('no longer grants'));
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
      expect(
        AnalysisReport.findingText(ocr, t),
        contains('not a malicious verdict'),
      );
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
      expect(
        AnalysisReport.findingText(ruleB, t),
        contains('may correspond'),
      );
      expect(
        AnalysisReport.relationshipText(ruleB, t),
        contains('not proven'),
      );
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
      expect(
        AnalysisReport.relationshipText(ruleC, t),
        contains('is not proven'),
      );
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
      expect(
        AnalysisReport.findingText(ruleE, t),
        contains('further verification at runtime'),
      );

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
      final ruleFText = AnalysisReport.findingText(ruleF, t);
      expect(ruleFText, contains('No upload-related code characteristics'));
      // 规格红线：不得输出「确认不存在恶意行为」这类结论。
      expect(ruleFText, isNot(contains('is safe')));
      expect(ruleFText, isNot(contains('no malicious')));
      expect(ruleFText, contains('does not mean'));
    });

    test('完全没有 DEX 时「未发现」的置信度是不完整的', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(targetSdk: 34),
        dexEntries: const [],
      );

      final ruleF = _byId(result, 'ANDROID-RULE-F');
      expect(ruleF!.confidence, SecurityConfidence.unknown);
      expect(
        result.limitations.any((l) => l.code == 'android.dex.no_content'),
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
      expect(
        AnalysisReport.findingText(endpoints!, t),
        contains('does not mean these were actually visited'),
      );
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
        result.limitations.any((l) => l.code == 'android.dex.no_content'),
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
        result.limitations.any((l) => l.code == 'android.manifest.unparsed'),
        isTrue,
      );
    });
  });

  // DEX 结构是**第二层取证**：先看结构是否可信，再信它上面的字符串线索。
  //
  // 样本用 javac + d8 真实产出的 DEX 与它的手工畸变体
  // （见 test/fixtures/dex/README.md，期望值来自 dexdump）。
  group('DEX 结构异常进入覆盖说明', () {
    Uint8List fixture(String name) =>
        File('test/fixtures/dex/$name').readAsBytesSync();

    test('结构正常的 DEX 不产生结构相关说明', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('real-netprobe.dex'))],
      );

      expect(
        result.limitations
            .any((l) => l.code == 'android.dex.structure_anomaly'),
        isFalse,
        reason: '实际说明：${result.limitations}',
      );
      expect(
        result.limitations
            .any((l) => l.code == 'android.dex.structure_untrusted'),
        isFalse,
      );
    });

    test('结构畸形的 DEX 会写明是哪一项对不上', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('truncated.dex'))],
      );

      expect(
        result.limitations.any((l) =>
            l.code == 'android.dex.structure_anomaly' &&
            l.args['name'] == 'classes.dex' &&
            l.args['code'] == 'dex.file_size_mismatch'),
        isTrue,
        reason: '实际说明：${result.limitations}',
      );
      expect(
        result.limitations.any((l) =>
            l.code == 'android.dex.structure_anomaly' &&
            '${l.args['message']}'.contains('1624') &&
            '${l.args['message']}'.contains('800')),
        isTrue,
        reason: '要说清声明与实际各是多少，否则无从排查',
      );
    });

    test('结构不可信时明确说「字符串线索不构成完整结论」', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('bad-magic.dex'))],
      );

      expect(result.hasCoverageGaps, isTrue);
      expect(
        result.limitations
            .any((l) => l.code == 'android.dex.structure_untrusted'),
        isTrue,
        reason: '「没扫到」与「没有」结论相反，必须说清是前者：'
            '${result.limitations.map((l) => l.code).toList()}',
      );
    });

    test('一个文件坏了不影响另一个文件被正常扫描', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [
          DexBytes('classes.dex', fixture('real-netprobe.dex')),
          DexBytes('classes2.dex', fixture('bad-magic.dex')),
        ],
      );

      // 只有坏的那个进「结构不可信」名单。
      final summary = result.limitations.firstWhere(
        (l) => l.code == 'android.dex.structure_untrusted',
        orElse: () => const AnalysisNote('', ''),
      );
      expect('${summary.args['names']}', contains('classes2.dex'));
      expect('${summary.args['names']}', isNot(contains('classes.dex,')));
    });
  });

  // 第二层取证：把「代码引用了」与「字符串里提到了」分开陈述。
  group('DEX 方法引用进入发现项', () {
    Uint8List fixture(String name) =>
        File('test/fixtures/dex/$name').readAsBytesSync();

    test('代码引用以 dexMethodReference 作为证据来源', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('real-netprobe.dex'))],
      );

      final finding = _byId(result, 'ANDROID-NETWORK-CLIENT');
      expect(finding, isNotNull,
          reason: '实际发现项：${result.findings.map((f) => f.ruleId).toList()}');
      expect(
        finding!.evidence
            .any((e) => e.source == SecurityEvidenceSource.dexMethodReference),
        isTrue,
        reason: '代码引用必须用不同的证据来源标注，不能与字符串混为一谈',
      );
      expect(
        finding.evidence.any((e) =>
            e.source == SecurityEvidenceSource.dexMethodReference &&
            e.detail.contains('HttpURLConnection')),
        isTrue,
        reason: '实际证据：${finding.evidence.map((e) => e.detail).toList()}',
      );
    });

    test('只有字符串时明确说「没有任何 method_ids 条目引用它们」', () {
      // 这个 blob 不是合法 DEX（结构不可遍历），因此只可能有字符串线索。
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [
          DexBytes(
              'classes.dex', _blob(['com.google.mlkit', 'okhttp3 client'])),
        ],
      );

      final finding = _byId(result, 'ANDROID-NETWORK-CLIENT');
      expect(finding, isNotNull);
      expect(
        AnalysisReport.relationshipText(finding!, t),
        contains('only in strings'),
        reason: '实际 relationship：${finding.relationship}',
      );
      expect(
        finding.evidence
            .every((e) => e.source == SecurityEvidenceSource.dexString),
        isTrue,
      );
    });

    test('能力类发现项仍然不抬高置信度（证据来源与关联强度是两件事）', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('real-netprobe.dex'))],
      );

      final finding = _byId(result, 'ANDROID-NETWORK-CLIENT');
      expect(
        finding!.confidence,
        SecurityConfidence.independentCapability,
        reason: '「代码引用了网络库」不等于「数据流被追踪到」，'
            '不能借代码引用把置信度抬到 confirmed',
      );
    });

    test('写明「引用 ≠ 调用」这条局限', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('real-netprobe.dex'))],
      );

      // 措辞要同时覆盖两层：method_ids 的「引用」与 code_item 的「调用点」，
      // 两者都不等于「运行时执行过」。
      final note = result.limitations.firstWhere(
        (l) => l.code == 'android.dex.method_semantics',
        orElse: () => const AnalysisNote('', ''),
      );
      expect(note.code, isNotEmpty,
          reason: '实际局限：${result.limitations.map((l) => l.code).toList()}');
      expect(note.fallback, contains('invoke'));
      expect(
        note.fallback,
        contains('proves it ran at runtime'),
        reason: '不能只说「引用」，也不能让读者以为调用点等于执行',
      );
    });

    test('结构不可信的文件会写明「没做方法引用分析」', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('bad-magic.dex'))],
      );

      expect(
        result.limitations.any((l) =>
            l.code == 'android.dex.method_not_traversable' &&
            '${l.args['names']}'.contains('classes.dex')),
        isTrue,
        reason: '「没查到」与「没有」结论相反，必须说清：${result.limitations}',
      );
    });
  });
  // 第三层：调用点。规则 C 的关联强度因此有了一个**可核对**的说法 ——
  // 识别与上传的调用指令是否位于同一个方法体内。
  group('调用点：同方法内同现进入规则 C 的说明', () {
    Uint8List fixture(String name) =>
        File('test/fixtures/dex/$name').readAsBytesSync();

    SecurityAnalysisResult ruleCFor(String fixtureName) {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [_perm('android.permission.READ_MEDIA_IMAGES')],
        ),
        dexEntries: [DexBytes('classes.dex', fixture(fixtureName))],
      );
      final ruleC = _byId(result, 'ANDROID-RULE-C');
      expect(
        ruleC,
        isNotNull,
        reason: '$fixtureName 应当触发规则 C；实际发现项：'
            '${result.findings.map((f) => f.ruleId).toList()}',
      );
      return result;
    }

    test('识别与上传在同一个方法体内时，说明里点出这个方法', () {
      final result = ruleCFor('real-cooccurrence.dex');
      final ruleC = _byId(result, 'ANDROID-RULE-C')!;

      expect(
        AnalysisReport.relationshipText(ruleC, t),
        contains('in the same method body'),
        reason: 'dexdump -d 显示 recognizeText 在 0x254、uploadImage 在 0x25a，'
            '相邻且同属 Pipeline.run。实际说明：${ruleC.relationship}',
      );
      expect(ruleC.relationship, contains('run'));
      // 但必须同时说清「共现 ≠ 数据流」。
      expect(
        AnalysisReport.relationshipText(ruleC, t),
        contains('not proven'),
      );
    });

    test('识别与上传在不同方法里时，明确说「不在同一个方法体内」', () {
      final result = ruleCFor('real-separate.dex');
      final ruleC = _byId(result, 'ANDROID-RULE-C')!;

      expect(
        AnalysisReport.relationshipText(ruleC, t),
        contains('not in the same method body'),
        reason: 'dexdump -d 显示两者分别在 Separate.doOcr 与 Separate.doUpload。'
            '实际说明：${ruleC.relationship}',
      );
    });

    test('更强的证据**不**抬高置信度：仍然不是「已证实关联」', () {
      // 同一方法内共现是比「多标记同现」更强的证据，但它仍然没有证明
      // 「识别结果被送进了上传请求」—— 那要看寄存器与参数传递。
      // 因此等级与置信度都不能动。
      for (final name in const ['real-cooccurrence.dex', 'real-separate.dex']) {
        final ruleC = _byId(ruleCFor(name), 'ANDROID-RULE-C')!;
        expect(ruleC.severity, SecuritySeverity.p1, reason: name);
        expect(
          ruleC.confidence,
          SecurityConfidence.suspected,
          reason: '$name：共现不是数据流，不能升到 confirmed',
        );
      }
    });

    test('调用点写进证据链（可以核对到指令偏移）', () {
      final result = ruleCFor('real-cooccurrence.dex');
      final ruleC = _byId(result, 'ANDROID-RULE-C')!;

      final callSiteEvidence = ruleC.evidence.where(
        (e) => e.source == SecurityEvidenceSource.dexMethodReference,
      );
      expect(callSiteEvidence, isNotEmpty);
      expect(
        callSiteEvidence.any((e) => e.detail.contains('+0x')),
        isTrue,
        reason: '证据要能落到具体偏移：'
            '${callSiteEvidence.map((e) => e.detail).toList()}',
      );
    });
  });

  // B11 第七批：Android 剩余 6 条里**不需要改数据表**的那批
  // （OCR / UPLOAD / NETWORK-ENDPOINTS / NETWORK-CLIENT / RULE-B / RULE-C）。
  //
  // 这批的特点是：文案里嵌的不是数据表的中文，而是**引擎自己拼的中文标签**
  // （「代码引用」「字符串提及」「域名 N 个」「IP N 个」）。做法是把标签与
  // 分隔符全部挪进语言包，引擎只传名字列表。
  group('发现项文案本地化（B11 第七批：Android 标签类 6 条）', () {
    const cjk = r'[\u4e00-\u9fff]';

    /// 一次触发这 6 条：相册权限 + OCR 标记 + 上传标记 + 网络库 + 域名。
    SecurityAnalysisResult rich() => AndroidSecurityAudit.audit(
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
                  'okhttp3.OkHttpClient',
                  'https://cdn.example.com/api',
                ])),
          ],
        );

    const rules = [
      'ANDROID-OCR-CAPABILITY',
      'ANDROID-UPLOAD-API',
      'ANDROID-NETWORK-ENDPOINTS',
      'ANDROID-NETWORK-CLIENT',
      'ANDROID-RULE-B',
      'ANDROID-RULE-C',
    ];

    test('引擎真的把 code 挂上去了（否则等于没迁）', () {
      final result = rich();
      for (final rule in rules) {
        final f = _byId(result, rule);
        expect(f, isNotNull,
            reason: '测试输入没有触发 $rule：'
                '${result.findings.map((e) => e.ruleId).toList()}');
        expect(f!.messageCode, isNotNull, reason: rule);
        expect(f.recommendationCode, isNotNull, reason: rule);
        expect(RegExp(cjk).hasMatch(f.finding), isFalse,
            reason: '$rule 的英文回退里还有中文：${f.finding}');
        expect(RegExp(cjk).hasMatch(f.recommendation), isFalse,
            reason: '$rule 的建议没有一起迁移：${f.recommendation}');
        if (f.relationship != null) {
          expect(RegExp(cjk).hasMatch(f.relationship!), isFalse,
              reason: '$rule 的关联说明没有一起迁移：${f.relationship}');
        }
        if (f.limitation != null) {
          expect(RegExp(cjk).hasMatch(f.limitation!), isFalse,
              reason: '$rule 的局限没有一起迁移：${f.limitation}');
        }
      }
    });

    test('证据的位置也能本地化（「N 个 DEX 的字符串」）', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      final endpoints = _byId(rich(), 'ANDROID-NETWORK-ENDPOINTS')!;
      final evidence = endpoints.evidence.single;
      expect(evidence.locationCode, 'dex.strings');

      await LocaleSettings.setLocaleRaw('zh-CN');
      expect(AnalysisReport.locationText(evidence, t), contains('个 DEX 的字符串'));

      await LocaleSettings.setLocaleRaw('en');
      expect(
        AnalysisReport.locationText(evidence, t),
        contains('DEX file(s)'),
      );
    });

    test('四个维护中的语言包都能取到文案，且不留占位符', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      // (code, args) —— 逐条列出，避免「漏了一条没测」。
      const findings = [
        (
          rule: 'ANDROID-OCR-CAPABILITY',
          code: 'android.ocr_capability',
          args: <String, Object>{
            'parts': <String, Object>{
              'codeRefs': <String>['A'],
              'stringClues': <String>['B'],
            },
          },
        ),
        (
          rule: 'ANDROID-UPLOAD-API',
          code: 'android.upload_api',
          args: <String, Object>{
            'parts': <String, Object>{
              'codeRefs': <String>['A'],
            },
          },
        ),
        (
          rule: 'ANDROID-NETWORK-ENDPOINTS',
          code: 'android.network_endpoints',
          args: <String, Object>{
            'parts': <String, Object>{
              'domains': <String>['a.example.com'],
              'domainCount': 1,
            },
          },
        ),
        (
          rule: 'ANDROID-NETWORK-CLIENT',
          code: 'android.network_client',
          args: <String, Object>{
            'parts': <String, Object>{
              'codeRefs': <String>['A'],
              'stringCluesOnly': <String>['B'],
            },
          },
        ),
        (
          rule: 'ANDROID-RULE-B',
          code: 'android.rule_b',
          args: <String, Object>{
            'inputClues': <String>['A'],
            'ocrClues': <String>['B'],
          },
        ),
        (
          rule: 'ANDROID-RULE-C',
          code: 'android.rule_c',
          args: <String, Object>{},
        ),
      ];

      const relationships = [
        'android.ocr_capability.relationship_code_refs',
        'android.upload_api.relationship_strings_only',
        'android.network_client.relationship_code_refs',
        'android.rule_b.relationship',
        'android.rule_c.relationship_package',
      ];

      const limitations = [
        'android.ocr_capability.limitation',
        'android.network_endpoints.limitation',
        'android.network_client.limitation',
        'android.rule_b.limitation',
        'android.rule_c.limitation',
      ];

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await LocaleSettings.setLocaleRaw(locale);

        for (final m in findings) {
          final f = SecurityFinding(
            ruleId: m.rule,
            platform: SecurityPlatform.android,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.unknown,
            finding: 'fallback finding',
            evidence: const [],
            recommendation: 'fallback recommendation',
            messageCode: m.code,
            messageArgs: m.args,
            recommendationCode: 'android.rule_c.manual_review',
          );
          final text = AnalysisReport.findingText(f, t);
          expect(text, isNot('fallback finding'),
              reason: '$locale 下 ${m.code} 没取到本地化文案');
          expect(text, isNot(contains('{')), reason: '$locale / ${m.code}');
          expect(text, isNot(contains('}')), reason: '$locale / ${m.code}');
          if (locale != 'en') {
            expect(RegExp(cjk).hasMatch(text), isTrue,
                reason: '$locale 下 ${m.code} 不是中文：$text');
          }
        }

        for (final code in relationships) {
          final f = SecurityFinding(
            ruleId: 'X',
            platform: SecurityPlatform.android,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.unknown,
            finding: 'f',
            evidence: const [],
            relationship: 'fallback relationship',
            recommendation: 'r',
            relationshipCode: code,
          );
          final text = AnalysisReport.relationshipText(f, t);
          expect(text, isNot('fallback relationship'),
              reason: '$locale 下 $code 没取到本地化文案');
          expect(text, isNot(contains('{')));
        }

        for (final code in limitations) {
          final f = SecurityFinding(
            ruleId: 'X',
            platform: SecurityPlatform.android,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.unknown,
            finding: 'f',
            evidence: const [],
            limitation: 'fallback limitation',
            recommendation: 'r',
            limitationCode: code,
          );
          final text = AnalysisReport.limitationText(f, t);
          expect(text, isNot('fallback limitation'),
              reason: '$locale 下 $code 没取到本地化文案');
          expect(text, isNot(contains('{')));
        }
      }
    });

    test('标签与分隔符都来自语言包：英文冒号分号、中文顿号分号', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      final result = rich();
      final ocr = _byId(result, 'ANDROID-OCR-CAPABILITY')!;

      await LocaleSettings.setLocaleRaw('en');
      final en = AnalysisReport.findingText(ocr, t);
      expect(en, contains('string mentions: '));
      expect(en, isNot(contains('字符串提及')));
      expect(en, isNot(contains('、')));

      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.findingText(ocr, t);
      expect(zh, contains('字符串提及 '));
      expect(zh, isNot(contains('string mentions')));

      // 分项之间用语言包的分号，不是写死的。
      final endpoints = _byId(result, 'ANDROID-NETWORK-ENDPOINTS')!;
      await LocaleSettings.setLocaleRaw('zh-CN');
      final zhEndpoints = AnalysisReport.findingText(endpoints, t);
      expect(zhEndpoints, contains('域名 '));
      expect(zhEndpoints, contains(' 个：'));
      expect(zhEndpoints, isNot(contains('domains (')));

      await LocaleSettings.setLocaleRaw('en');
      final enEndpoints = AnalysisReport.findingText(endpoints, t);
      expect(enEndpoints, contains('domains ('));
      expect(enEndpoints, isNot(contains('域名')));
    });

    test('规则 C 的关联说明带参数：点出具体方法体', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      const f = SecurityFinding(
        ruleId: 'ANDROID-RULE-C',
        platform: SecurityPlatform.android,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p1,
        confidence: SecurityConfidence.suspected,
        finding: 'f',
        evidence: [],
        relationship: 'fallback relationship',
        recommendation: 'r',
        relationshipCode: 'android.rule_c.relationship_method',
        relationshipArgs: <String, Object>{'caller': 'Lcom/a/B;.run()V'},
      );

      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.relationshipText(f, t);
      expect(zh, contains('Lcom/a/B;.run()V'));
      expect(zh, contains('同一个方法体内'));
      expect(zh, isNot(contains('{caller}')));

      // 参数缺失时回退原文，绝不渲染出 `{caller}`。
      const noArgs = SecurityFinding(
        ruleId: 'ANDROID-RULE-C',
        platform: SecurityPlatform.android,
        category: SecurityCategory.dataExfiltration,
        severity: SecuritySeverity.p1,
        confidence: SecurityConfidence.suspected,
        finding: 'f',
        evidence: [],
        relationship: 'fallback relationship',
        recommendation: 'r',
        relationshipCode: 'android.rule_c.relationship_method',
      );
      expect(
          AnalysisReport.relationshipText(noArgs, t), 'fallback relationship');
    });
  });

  // B11 第五批：Android 侧**不依赖数据表中文描述**的 6 条。
  //
  // 剩下 10 条（权限目录的 `description` / `riskNote` / `verdict.note`、
  // 线索表与方法引用表的 `description`、`nativeSymbolMarkers`、
  // `_coOccurrenceNote`）都嵌了数据表的中文，要先把那些表改成暴露稳定 id，
  // 属另一批 —— 因此这里只覆盖能独立成立的部分。
  group('发现项文案本地化（B11 第五批：Android 6 条）', () {
    const cjk = r'[\u4e00-\u9fff]';

    const expected = [
      (
        rule: 'ANDROID-PERMISSION-UNCATEGORIZED',
        message: 'android.permission_uncategorized',
        recommendation: 'android.permission_uncategorized.manual_review',
        args: <String, Object>{
          'count': 2,
          'names': <String>['A', 'B'],
        },
      ),
      (
        rule: 'ANDROID-PERMISSION-SDK23-CONDITIONAL',
        message: 'android.permission_sdk23_conditional',
        recommendation: 'android.permission_sdk23_conditional.verify',
        args: <String, Object>{'name': 'READ_EXTERNAL_STORAGE'},
      ),
      (
        rule: 'ANDROID-RULE-A',
        message: 'android.rule_a',
        recommendation: 'android.rule_a.manual_review',
        args: <String, Object>{
          'names': <String>['MANAGE_EXTERNAL_STORAGE'],
        },
      ),
      (
        rule: 'ANDROID-RULE-D',
        message: 'android.rule_d',
        recommendation: 'android.rule_d.manual_review',
        args: <String, Object>{},
      ),
      (
        rule: 'ANDROID-RULE-E',
        message: 'android.rule_e',
        recommendation: 'android.rule_e.manual_review',
        args: <String, Object>{},
      ),
      (
        rule: 'ANDROID-RULE-F',
        message: 'android.rule_f',
        recommendation: 'android.rule_f.runtime_traffic',
        args: <String, Object>{},
      ),
    ];

    test('引擎真的把 code 挂上去了（否则等于没迁）', () {
      // 一轮输入尽量多触发：未编目权限 + sdk23 声明 + 明文流量 + 无上传线索。
      final broad = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          usesCleartextTraffic: true,
          permissions: [
            _perm('com.example.app.permission.CUSTOM'),
            _perm('com.example.app.permission.CUSTOM2'),
            _perm('android.permission.READ_EXTERNAL_STORAGE', sdk23: true),
          ],
        ),
        dexEntries: [
          DexBytes('classes.dex', _blob(['okhttp3.OkHttpClient']))
        ],
      );

      // 规则 A：只有全盘存储访问、没有图片业务线索。
      final ruleA = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [_perm('android.permission.MANAGE_EXTERNAL_STORAGE')],
        ),
        dexEntries: const [],
      );

      // 规则 E：后台 + 敏感 + 上传三项齐备。
      final ruleE = AndroidSecurityAudit.audit(
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

      SecurityFinding? find(String rule) =>
          _byId(broad, rule) ?? _byId(ruleA, rule) ?? _byId(ruleE, rule);

      for (final m in expected) {
        final f = find(m.rule);
        expect(f, isNotNull, reason: '测试输入没有触发 ${m.rule}');
        expect(f!.messageCode, m.message, reason: m.rule);
        expect(f.recommendationCode, m.recommendation, reason: m.rule);
        expect(
          RegExp(cjk).hasMatch(f.finding),
          isFalse,
          reason: '${m.rule} 的英文回退里还有中文：${f.finding}',
        );
        expect(
          RegExp(cjk).hasMatch(f.recommendation),
          isFalse,
          reason: '${m.rule} 的建议没有一起迁移：${f.recommendation}',
        );
      }

      // 局限与关联也要有 code（本批迁了 4 条局限 + 1 条关联）。
      expect(
          _byId(broad, 'ANDROID-PERMISSION-SDK23-CONDITIONAL')!.limitationCode,
          'android.permission_sdk23_conditional.limitation');
      expect(_byId(ruleA, 'ANDROID-RULE-A')!.limitationCode,
          'android.rule_a.limitation');
      expect(_byId(broad, 'ANDROID-RULE-D')!.limitationCode,
          'android.rule_d.limitation');
      expect(_byId(ruleE, 'ANDROID-RULE-E')!.relationshipCode,
          'android.rule_e.relationship');
      expect(_byId(ruleE, 'ANDROID-RULE-E')!.limitationCode,
          'android.rule_e.limitation');
    });

    test('四个维护中的语言包都能取到文案，且不留占位符', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await LocaleSettings.setLocaleRaw(locale);
        for (final m in expected) {
          final finding = SecurityFinding(
            ruleId: m.rule,
            platform: SecurityPlatform.android,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.unknown,
            finding: 'fallback finding',
            evidence: const [],
            recommendation: 'fallback recommendation',
            messageCode: m.message,
            messageArgs: m.args,
            recommendationCode: m.recommendation,
          );

          final text = AnalysisReport.findingText(finding, t);
          expect(text, isNot('fallback finding'),
              reason: '$locale 下 ${m.message} 没取到本地化文案');
          expect(text, isNot(contains('{')), reason: '$locale / ${m.message}');
          expect(text, isNot(contains('}')), reason: '$locale / ${m.message}');
          if (locale != 'en') {
            expect(RegExp(cjk).hasMatch(text), isTrue,
                reason: '$locale 下 ${m.message} 不是中文：$text');
          }

          final rec = AnalysisReport.recommendationText(finding, t);
          expect(rec, isNot('fallback recommendation'),
              reason: '$locale 下 ${m.recommendation} 没取到本地化文案');
          expect(rec, isNot(contains('{')),
              reason: '$locale / ${m.recommendation}');
        }
      }
    });

    test('名字列表用本地化分隔符：英文逗号、中文顿号', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      // 引擎此前直接 `join('、')`，于是英文界面里出现中文顿号。
      final result = AndroidSecurityAudit.audit(
        meta: _meta(
          targetSdk: 34,
          permissions: [
            _perm('android.permission.MANAGE_EXTERNAL_STORAGE'),
            _perm('android.permission.MANAGE_EXTERNAL_STORAGE_ALT'),
          ],
        ),
        dexEntries: const [],
      );
      final ruleA = _byId(result, 'ANDROID-RULE-A');
      expect(ruleA, isNotNull, reason: '两个广泛存储权限应当触发规则 A');

      await LocaleSettings.setLocaleRaw('en');
      final en = AnalysisReport.findingText(ruleA!, t);
      expect(en, contains(', '));
      expect(en, isNot(contains('、')));

      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.findingText(ruleA, t);
      expect(zh, contains('、'));
      expect(zh, isNot(contains(', ')));
    });
  });

  // B11 第八批：版本条件说明（`_Verdict.note`）+ EXPIRED / INERT。
  //
  // 这条链的特殊之处：版本说明是**嵌在发现项正文里的一句话**
  // （`"{name}: {note}"`），所以要做**两层**查表 —— 先把 noteCode 解析成
  // 一句本地化的话，再作为参数交给外层文案。少一层就会渲染出 `{note}`。
  group('发现项文案本地化（B11 第八批：版本条件）', () {
    const cjk = r'[\u4e00-\u9fff]';

    /// 声明了 maxSdkVersion 的权限在更高 targetSdk 上不生效 → EXPIRED。
    SecurityAnalysisResult expired() => AndroidSecurityAudit.audit(
          meta: _meta(
            targetSdk: 34,
            permissions: [
              _perm('android.permission.READ_EXTERNAL_STORAGE', maxSdk: 32),
            ],
          ),
          dexEntries: const [],
        );

    /// 生效但效果被削弱 → INERT（WRITE_EXTERNAL_STORAGE 在 API 29 后失效）。
    SecurityAnalysisResult inert() => AndroidSecurityAudit.audit(
          meta: _meta(
            targetSdk: 34,
            permissions: [_perm('android.permission.WRITE_EXTERNAL_STORAGE')],
          ),
          dexEntries: const [],
        );

    test('引擎把 code 与版本说明的 code 都挂上了（两层都要有）', () {
      final e = _byId(expired(), 'ANDROID-PERMISSION-EXPIRED');
      expect(e, isNotNull);
      expect(e!.messageCode, 'android.permission_expired');
      expect(e.recommendationCode, 'android.permission_expired.keep_observing');
      expect(e.limitationCode, 'android.permission_expired.limitation');
      expect(e.messageArgs['noteCode'], 'max_sdk');
      expect(RegExp(cjk).hasMatch(e.finding), isFalse,
          reason: '英文回退里还有中文：${e.finding}');
      expect(RegExp(cjk).hasMatch(e.limitation!), isFalse);
      expect(RegExp(cjk).hasMatch(e.recommendation), isFalse);

      final i = _byId(inert(), 'ANDROID-PERMISSION-INERT');
      expect(i, isNotNull);
      expect(i!.messageCode, 'android.permission_inert');
      expect(i.recommendationCode, 'android.permission_inert.check_legacy');
      expect(i.messageArgs['noteCode'], 'max_api_effective_above');
      expect(RegExp(cjk).hasMatch(i.finding), isFalse,
          reason: '英文回退里还有中文：${i.finding}');
    });

    test('两层查表都生效：中文界面下正文与版本说明都是中文', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      final e = _byId(expired(), 'ANDROID-PERMISSION-EXPIRED')!;

      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.findingText(e, t);
      expect(zh, contains('READ_EXTERNAL_STORAGE'));
      expect(zh, contains('系统不再授予'));
      expect(zh, isNot(contains('{note}')));
      expect(zh, isNot(contains('{')));
      expect(RegExp(cjk).hasMatch(zh), isTrue);

      await LocaleSettings.setLocaleRaw('en');
      final en = AnalysisReport.findingText(e, t);
      expect(en, contains('no longer grants'));
      expect(RegExp(cjk).hasMatch(en), isFalse, reason: 'en 不该有中文：$en');
    });

    test('三个版本说明在四个语言包里都能取到，且不留占位符', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      const notes = [
        (
          code: 'max_sdk',
          args: <String, Object>{'max': 32, 'targetSdk': 34, 'next': 33},
        ),
        (
          code: 'min_api',
          args: <String, Object>{'minApi': 33, 'targetSdk': 30},
        ),
        (
          code: 'max_api_effective_above',
          args: <String, Object>{'targetSdk': 34, 'maxApi': 28},
        ),
      ];

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await LocaleSettings.setLocaleRaw(locale);
        for (final n in notes) {
          final f = SecurityFinding(
            ruleId: 'ANDROID-PERMISSION-EXPIRED',
            platform: SecurityPlatform.android,
            category: SecurityCategory.other,
            severity: SecuritySeverity.info,
            confidence: SecurityConfidence.confirmed,
            finding: 'fallback finding',
            evidence: const [],
            recommendation: 'r',
            messageCode: 'android.permission_expired',
            messageArgs: <String, Object>{
              'name': 'READ_EXTERNAL_STORAGE',
              'noteCode': n.code,
              'noteArgs': n.args,
            },
          );
          final text = AnalysisReport.findingText(f, t);
          expect(text, isNot('fallback finding'),
              reason: '$locale 下 ${n.code} 没取到本地化文案');
          expect(text, isNot(contains('{')));
          expect(text, contains('READ_EXTERNAL_STORAGE'));
          if (locale != 'en') {
            expect(RegExp(cjk).hasMatch(text), isTrue,
                reason: '$locale 下 ${n.code} 不是中文：$text');
          }
        }
      }
    });

    test('版本说明的 code 认不出时整条回退，不渲染半句话', () {
      const f = SecurityFinding(
        ruleId: 'ANDROID-PERMISSION-EXPIRED',
        platform: SecurityPlatform.android,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: 'fallback finding',
        evidence: [],
        recommendation: 'r',
        messageCode: 'android.permission_expired',
        messageArgs: <String, Object>{
          'name': 'X',
          'noteCode': 'future_note',
        },
      );
      expect(AnalysisReport.findingText(f, t), 'fallback finding');
    });

    test('版本条件的局限也本地化，并带上 targetSdk', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      final e = _byId(expired(), 'ANDROID-PERMISSION-EXPIRED')!;
      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.limitationText(e, t);
      expect(zh, contains('targetSdk=34'));
      expect(zh, isNot(contains('{')));
      expect(RegExp(cjk).hasMatch(zh!), isTrue);
    });
  });

  // B11 第九批（最后一块）：权限目录 24 条规则 × 2 个字段。
  //
  // 这张表的 id 就是权限短名本身，所以**没有加 code 字段** —— 但代价是
  // 呈现层要有一张按短名查的表。下面这条「**每个目录条目都有文案**」
  // 是那张表的兜底：新增权限却忘了补文案时，它会红。
  group('发现项文案本地化（B11 第九批：权限目录）', () {
    const cjk = r'[\u4e00-\u9fff]';

    SecurityFinding ruleFinding(String name) => SecurityFinding(
          ruleId: 'ANDROID-PERMISSION-$name',
          platform: SecurityPlatform.android,
          category: SecurityCategory.other,
          severity: SecuritySeverity.info,
          confidence: SecurityConfidence.confirmed,
          finding: 'fallback finding',
          evidence: const [],
          limitation: 'fallback limitation',
          recommendation: 'fallback recommendation',
          messageCode: 'android.permission_rule',
          messageArgs: <String, Object>{'name': name},
          limitationCode: 'android.permission_rule.limitation',
          recommendationCode: 'android.permission_rule.risk_note',
        );

    test('目录里每一条规则在四个语言包里都有说明与风险说明', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      expect(PermissionCatalog.rules, isNotEmpty);

      for (final locale in ['en', 'zh-CN', 'zh-HK', 'zh-TW']) {
        await LocaleSettings.setLocaleRaw(locale);
        for (final rule in PermissionCatalog.rules) {
          final f = ruleFinding(rule.name);

          final text = AnalysisReport.findingText(f, t);
          expect(text, isNot('fallback finding'),
              reason: '$locale 下 ${rule.name} 的说明没取到本地化文案');
          expect(text, isNot(contains('{')), reason: '$locale / ${rule.name}');

          final rec = AnalysisReport.recommendationText(f, t);
          expect(rec, isNot('fallback recommendation'),
              reason: '$locale 下 ${rule.name} 的风险说明没取到本地化文案');
          expect(rec, isNot(contains('{')), reason: '$locale / ${rule.name}');

          expect(
              AnalysisReport.limitationText(f, t), isNot('fallback limitation'),
              reason: '$locale 下 ${rule.name} 的局限没取到本地化文案');

          if (locale != 'en') {
            // 与英文回退**不同**才说明真的走了查表；相同就是漏了这条。
            expect(text, isNot(rule.description),
                reason: '$locale 下 ${rule.name} 退回了英文回退');
            expect(rec, isNot(rule.riskNote),
                reason: '$locale 下 ${rule.name} 退回了英文回退');
            expect(RegExp(cjk).hasMatch(text), isTrue,
                reason: '$locale 下 ${rule.name} 不是中文：$text');
            expect(RegExp(cjk).hasMatch(rec), isTrue,
                reason: '$locale 下 ${rule.name} 的风险说明不是中文：$rec');
          }
        }
      }
    });

    test('带版本说明时用另一种句式，且说明本身也本地化', () async {
      addTearDown(() => LocaleSettings.setLocaleRaw('en'));

      const f = SecurityFinding(
        ruleId: 'ANDROID-PERMISSION-READ_EXTERNAL_STORAGE',
        platform: SecurityPlatform.android,
        category: SecurityCategory.other,
        severity: SecuritySeverity.info,
        confidence: SecurityConfidence.confirmed,
        finding: 'fallback finding',
        evidence: [],
        recommendation: 'r',
        messageCode: 'android.permission_rule_with_note',
        messageArgs: <String, Object>{
          'name': 'READ_EXTERNAL_STORAGE',
          'noteCode': 'max_sdk',
          'noteArgs': <String, Object>{'max': 32, 'targetSdk': 34, 'next': 33},
        },
      );

      await LocaleSettings.setLocaleRaw('zh-CN');
      final zh = AnalysisReport.findingText(f, t);
      expect(zh, contains('读取共享存储'));
      expect(zh, contains('系统不再授予'));
      expect(zh, isNot(contains('{')));
      expect(RegExp(cjk).hasMatch(zh), isTrue);

      await LocaleSettings.setLocaleRaw('en');
      final en = AnalysisReport.findingText(f, t);
      expect(en, contains('Read shared storage'));
      expect(en, contains('no longer grants'));
    });

    test('目录里认不出的权限名整条回退，不渲染半句话', () {
      final f = ruleFinding('NOT_IN_CATALOG');
      expect(AnalysisReport.findingText(f, t), 'fallback finding');
      expect(
          AnalysisReport.recommendationText(f, t), 'fallback recommendation');
    });
  });
}
