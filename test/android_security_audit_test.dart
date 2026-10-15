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
        result.limitations.any((l) => l.contains('结构异常')),
        isFalse,
        reason: '实际说明：${result.limitations}',
      );
      expect(result.limitations.any((l) => l.contains('结构不可信')), isFalse);
    });

    test('结构畸形的 DEX 会写明是哪一项对不上', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('truncated.dex'))],
      );

      expect(
        result.limitations.any((l) =>
            l.contains('classes.dex') && l.contains('dex.file_size_mismatch')),
        isTrue,
        reason: '实际说明：${result.limitations}',
      );
      expect(
        result.limitations.any((l) => l.contains('1624') && l.contains('800')),
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
        result.limitations.any((l) => l.contains('结构不可信')),
        isTrue,
        reason: '「没扫到」与「没有」结论相反，必须说清是前者：'
            '${result.limitations}',
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
      final summary = result.limitations
          .firstWhere((l) => l.contains('结构不可信'), orElse: () => '');
      expect(summary, contains('classes2.dex'));
      expect(summary, isNot(contains('classes.dex 的结构')));
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
        finding!.relationship,
        contains('只出现在字符串里'),
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
      final note = result.limitations
          .firstWhere((l) => l.contains('method_ids'), orElse: () => '');
      expect(note, isNotEmpty, reason: '实际局限：${result.limitations}');
      expect(note, contains('invoke'));
      expect(
        note,
        contains('不证明运行时执行过'),
        reason: '不能只说「引用」，也不能让读者以为调用点等于执行',
      );
    });

    test('结构不可信的文件会写明「没做方法引用分析」', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(),
        dexEntries: [DexBytes('classes.dex', fixture('bad-magic.dex'))],
      );

      expect(
        result.limitations
            .any((l) => l.contains('未做方法引用分析') && l.contains('classes.dex')),
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
        ruleC.relationship,
        contains('同一个方法体内'),
        reason: 'dexdump -d 显示 recognizeText 在 0x254、uploadImage 在 0x25a，'
            '相邻且同属 Pipeline.run。实际说明：${ruleC.relationship}',
      );
      expect(ruleC.relationship, contains('run'));
      // 但必须同时说清「共现 ≠ 数据流」。
      expect(ruleC.relationship, contains('未被证实'));
    });

    test('识别与上传在不同方法里时，明确说「不在同一个方法体内」', () {
      final result = ruleCFor('real-separate.dex');
      final ruleC = _byId(result, 'ANDROID-RULE-C')!;

      expect(
        ruleC.relationship,
        contains('不在同一个方法体内'),
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
}
