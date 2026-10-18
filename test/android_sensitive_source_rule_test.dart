// 「敏感数据来源 + 上传」组合规则（审计报告 P2-2）。
//
// ## 为什么加这条
//
// 6 条组合规则里 4 条是图片链（相册 / OCR / 上传）。而现实中最常见的外传模式
// 是「设备标识 / 通讯录 → 上传」—— 此前只有一条 INFO 级权限条目，
// **没有任何「能力 + 去向」的关联**。
//
// 本文件钉住：
// 1. 三个新标记能被字符串扫描命中（`DexClassLoader` / `TelephonyManager` /
//    `ContactsContract`）；
// 2. 有敏感来源 + 有上传 → 一条 P2/suspected，`dataSource` 说清是哪一类；
// 3. **只有来源、没有上传 → 不报**（这是最容易误报的方向）；
// 4. 只有字符串线索时**不给中间跳**（没定位到方法就留 null，不编造）；
// 5. 动态加载线索进「覆盖不足」，说明静态分析看不到被加载的代码。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ApkMeta _meta() => ApkMeta()
  ..permissionRequests = const []
  ..permissions = const []
  ..components = const [];

/// 把若干字符串拼成一段「DEX 风格的字节」—— 字符串扫描器只看字面量。
Uint8List _blob(List<String> strings) {
  final parts = <int>[];
  for (final s in strings) {
    parts.addAll(s.codeUnits);
    parts.add(0);
  }
  return Uint8List.fromList(parts);
}

SecurityAnalysisResult _audit(List<String> strings) =>
    AndroidSecurityAudit.audit(
      meta: _meta(),
      dexEntries: [DexBytes('classes.dex', _blob(strings))],
    );

SecurityFinding? _byId(SecurityAnalysisResult r, String ruleId) {
  for (final f in r.findings) {
    if (f.ruleId == ruleId) return f;
  }
  return null;
}

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('三个新标记能被命中', () {
    test('DexClassLoader 进「覆盖不足」而不是静默丢弃', () {
      final result = _audit(['Ldalvik/system/DexClassLoader;']);
      expect(
        result.limitations.any((n) => n.code == 'android.dex.dynamic_loading'),
        isTrue,
        reason: '动态加载意味着静态分析看不到被加载的代码，必须说出来',
      );
    });

    test('没有动态加载时不产生这条说明', () {
      final result = _audit(['Landroid/app/Activity;']);
      expect(
        result.limitations.any((n) => n.code == 'android.dex.dynamic_loading'),
        isFalse,
      );
    });
  });

  group('设备标识 / 通讯录 + 上传', () {
    test('设备标识 + 上传 → 一条 P2/suspected，来源写清是设备标识', () {
      final result = _audit([
        'Landroid/telephony/TelephonyManager;',
        'multipart/form-data',
      ]);
      final finding = _byId(result, 'ANDROID-RULE-G');
      expect(finding, isNotNull, reason: '这是最常见的外传模式，不该漏');
      expect(finding!.severity, SecuritySeverity.p2);
      expect(
        finding.confidence,
        SecurityConfidence.suspected,
        reason: '同现不是数据流，不能升到 confirmed',
      );
      expect(finding.dataSource, contains('设备标识'));
      expect(finding.dataSink, isNotNull);
    });

    test('通讯录 + 上传 → 同样命中，来源写通讯录', () {
      final result = _audit([
        'Landroid/provider/ContactsContract;',
        'multipart/form-data',
      ]);
      final finding = _byId(result, 'ANDROID-RULE-G');
      expect(finding, isNotNull);
      expect(finding!.dataSource, contains('通讯录'));
    });

    test('只有来源、没有上传 → **不报**（最容易误报的方向）', () {
      final result = _audit(['Landroid/telephony/TelephonyManager;']);
      expect(_byId(result, 'ANDROID-RULE-G'), isNull);
    });

    test('只有上传、没有敏感来源 → 不报', () {
      final result = _audit(['multipart/form-data']);
      expect(_byId(result, 'ANDROID-RULE-G'), isNull);
    });

    test('没有 DEX 内容时什么都不报（不能凭空推断）', () {
      final result =
          AndroidSecurityAudit.audit(meta: _meta(), dexEntries: const []);
      expect(_byId(result, 'ANDROID-RULE-G'), isNull);
    });

    test('只有字符串线索时不给中间跳（没定位到方法就留 null）', () {
      final result = _audit([
        'Landroid/telephony/TelephonyManager;',
        'multipart/form-data',
      ]);
      final finding = _byId(result, 'ANDROID-RULE-G')!;
      expect(
        finding.dataTransform,
        isNull,
        reason: '字符串线索没有方法上下文，编一个中间跳等于把猜测写成事实',
      );
    });
  });

  group('文案与措辞', () {
    test('中文界面下正文是中文，且点明「未证实」', () {
      final result = _audit([
        'Landroid/telephony/TelephonyManager;',
        'multipart/form-data',
      ]);
      final finding = _byId(result, 'ANDROID-RULE-G')!;

      final text = AnalysisReport.findingText(finding, t);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue,
          reason: '中文界面下不能显示英文回退：$text');

      final relationship = AnalysisReport.relationshipText(finding, t);
      expect(relationship, isNotNull);
      expect(
        relationship,
        anyOf(contains('未证实'), contains('并未成立'), contains('不等于')),
        reason: '同现必须说明「未证实数据流」：$relationship',
      );
    });

    test('局限里说明「同现不是数据流」', () {
      final result = _audit([
        'Landroid/telephony/TelephonyManager;',
        'multipart/form-data',
      ]);
      final limitation =
          AnalysisReport.limitationText(_byId(result, 'ANDROID-RULE-G')!, t);
      expect(limitation, isNotNull);
      expect(limitation, anyOf(contains('同现'), contains('数据流')));
    });
  });
}
