// 分包安装包的安全审计（缺陷 D1 的回归测试）。
//
// 背景：`AndroidSecurityAudit.audit` 的唯一生产调用点在只被**内置引擎**
// 使用的 worker 里，而 XAPK / APKM / APKS 走 aapt2 路径 —— 于是分包
// 安装包的 `securityResult` 恒为 `null`，规则 A–F、DEX 扫描、权限目录
// 全都不会运行。修复方式是在 XAPK 路径里对提取出的 base APK 补跑一次
// 内置解析器 + 审计。
//
// 这里钉住两件事：
// 1. `SecurityAnalysisResult.withLimitation` 追加而不改动原对象；
// 2. 分包路径即便拿不到审计结果也**不会让解析失败**（降级为 null）。

import 'dart:io';
import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/apkparser/apk_info.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('SecurityAnalysisResult.withLimitation', () {
    test('追加一条说明，原对象不受影响', () {
      const original = SecurityAnalysisResult(
        engineVersion: 'test-engine',
        rulesVersion: 'test-rules',
      );

      const note = AnalysisNote('test.note', '仅覆盖 base APK');
      final extended = original.withLimitation(note);

      expect(original.limitations, isEmpty, reason: '原对象必须保持不变');
      expect(extended.limitations, [note]);
      expect(extended.engineVersion, original.engineVersion);
      expect(extended.rulesVersion, original.rulesVersion);
      expect(extended.findings, original.findings);
      expect(
          extended.includesRuntimeEvidence, original.includesRuntimeEvidence);
    });

    test('多次追加按顺序累积', () {
      const base = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
        limitations: [AnalysisNote('t.1', '第一条')],
      );
      final result = base
          .withLimitation(const AnalysisNote('t.2', '第二条'))
          .withLimitation(const AnalysisNote('t.3', '第三条'));

      expect(result.limitations.map((l) => l.code), ['t.1', 't.2', 't.3']);
      expect(base.limitations.map((l) => l.code), ['t.1'],
          reason: 'base 不应被污染');
    });

    test('追加限制说明只增加「声明」，不伪造「实际缺口」', () {
      const noGaps = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
      );
      expect(noGaps.hasDeclaredLimitations, isFalse);
      expect(noGaps.hasActualGaps, isFalse);

      final withNote =
          noGaps.withLimitation(const AnalysisNote('t.gap', '覆盖不足'));
      expect(withNote.hasDeclaredLimitations, isTrue);
      // 加一句说明不会让结构化覆盖凭空多出一个缺口。
      expect(withNote.hasActualGaps, isFalse);
    });
  });

  group('分包路径的审计降级', () {
    /// 造一个最小 XAPK：**外层是合法 ZIP**，里面放一个不是合法 APK 的
    /// `base.apk`。
    ///
    /// 外层必须是真 ZIP，否则会在更早的 `zip.open` 就被拒（那测的是另一条
    /// 路径）。这里要验证的是「审计拿不到结果时不崩、也不伪造结果」。
    File makeXapkWithBrokenBase(Directory dir) {
      final broken = Uint8List.fromList(List<int>.filled(64, 0));
      final archive = Archive()
        ..addFile(ArchiveFile('base.apk', broken.length, broken));
      final xapk = File(path.join(dir.path, 'broken.xapk'));
      xapk.writeAsBytesSync(ZipEncoder().encode(archive));
      return xapk;
    }

    test('base APK 不可解析时，securityResult 为 null 且解析不抛异常', () async {
      final dir = Directory.systemTemp.createTempSync('xapk_audit');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final xapk = makeXapkWithBrokenBase(dir);

      // 不应抛异常 —— 审计失败是「未执行」，不是解析失败。
      final info = await getApkInfo(xapk.path);

      expect(info, isNotNull);
      expect(
        info!.securityResult,
        isNull,
        reason: '拿不到审计结果时应为 null（呈现为「未执行」），而不是伪造一个空结果',
      );
    });
  });

  group('分包一致性校验（阶段 2）', () {
    /// 造一个含 base.apk + 若干无法解析的分包的 XAPK。
    File makeXapkWithSplits(Directory dir, int splitCount) {
      final broken = Uint8List.fromList(List<int>.filled(64, 0));
      final archive = Archive()
        ..addFile(ArchiveFile('base.apk', broken.length, broken));
      for (var i = 0; i < splitCount; i++) {
        archive.addFile(ArchiveFile(
          'split_config.$i.apk',
          broken.length,
          broken,
        ));
      }
      final xapk = File(path.join(dir.path, 'multi.xapk'));
      xapk.writeAsBytesSync(ZipEncoder().encode(archive));
      return xapk;
    }

    test('分包无法解析时如实记录，不假装通过', () async {
      final dir = Directory.systemTemp.createTempSync('xapk_splits');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final xapk = makeXapkWithSplits(dir, 2);
      final info = await getApkInfo(xapk.path);

      expect(info, isNotNull);
      expect(info!.splitConsistency, isNotNull, reason: '多分包就必须查，不能是 null');
      expect(
        info.splitConsistency!.issues,
        isNotEmpty,
        reason: '分包读不出来时必须留下记录 —— 静默通过等于说「它们一致」',
      );
      // 每条都应指明是哪个分包出的问题。
      for (final issue in info.splitConsistency!.issues) {
        expect(issue, contains('split_config'));
      }
    });

    test('分包数超过抽检上限时，如实报告查了多少、共多少', () async {
      final dir = Directory.systemTemp.createTempSync('xapk_many');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final xapk = makeXapkWithSplits(dir, 12);
      final info = await getApkInfo(xapk.path);

      expect(info, isNotNull);
      final report = info!.splitConsistency!;
      expect(report.totalCount, 12);
      expect(report.checkedCount, 8, reason: '抽检上限是 8');
      expect(
        report.isTruncated,
        isTrue,
        reason: '截断必须可判定，否则读者会以为全部比对了',
      );
    });

    test('抽检结果会变成诊断，让「解析诊断」卡片不再恒为空', () async {
      final dir = Directory.systemTemp.createTempSync('xapk_diag');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final xapk = makeXapkWithSplits(dir, 12);
      final info = await getApkInfo(xapk.path);

      final codes = info!.diagnostics.map((d) => d.code).toList();
      expect(codes, contains('android.split_inconsistent'));
      expect(
        codes,
        contains('android.split_sampling_truncated'),
        reason: '截断是覆盖范围说明，不能与「发现不一致」混成同一条',
      );

      // 截断那条是 info，不一致那条是 warning —— 两者语义不同。
      final truncated = info.diagnostics
          .firstWhere((d) => d.code == 'android.split_sampling_truncated');
      expect(truncated.severity, DiagnosticSeverity.info);
      final inconsistent = info.diagnostics
          .firstWhere((d) => d.code == 'android.split_inconsistent');
      expect(inconsistent.severity, DiagnosticSeverity.warning);
    });

    test('单 APK 没查分包时 splitConsistency 为 null，不是空报告', () async {
      final dir = Directory.systemTemp.createTempSync('single_apk');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      // 一个不含 base.apk 的普通 APK：走不到分包分支。
      final archive = Archive()
        ..addFile(ArchiveFile(
            'AndroidManifest.xml',
            4,
            Uint8List.fromList(
              List<int>.filled(4, 0),
            )));
      final apk = File(path.join(dir.path, 'plain.apk'));
      apk.writeAsBytesSync(ZipEncoder().encode(archive));

      final info = await getApkInfo(apk.path);
      expect(info?.splitConsistency, isNull, reason: '「没查」与「查了没问题」必须分开');
    });
  });
}
