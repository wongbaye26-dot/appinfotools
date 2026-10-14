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

      final extended = original.withLimitation('仅覆盖 base APK');

      expect(original.limitations, isEmpty, reason: '原对象必须保持不变');
      expect(extended.limitations, ['仅覆盖 base APK']);
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
        limitations: ['第一条'],
      );
      final result = base.withLimitation('第二条').withLimitation('第三条');

      expect(result.limitations, ['第一条', '第二条', '第三条']);
      expect(base.limitations, ['第一条'], reason: 'base 不应被污染');
    });

    test('追加后 hasCoverageGaps 变为 true', () {
      const noGaps = SecurityAnalysisResult(
        engineVersion: 'e',
        rulesVersion: 'r',
      );
      expect(noGaps.hasCoverageGaps, isFalse);

      expect(noGaps.withLimitation('覆盖不足').hasCoverageGaps, isTrue);
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
}
