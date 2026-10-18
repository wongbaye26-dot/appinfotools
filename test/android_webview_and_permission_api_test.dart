// 第二档三条规则：WebView JS 桥、权限 vs API 交叉核对、iOS 敏感来源 + 上传。
//
// ## 三条各自的判据与边界
//
// | 规则 | 判据 | 关键边界 |
// |---|---|---|
// | `ANDROID-WEBVIEW-BRIDGE` | 出现 `addJavascriptInterface` | 只证「用了」，不证「能从不可信内容到达」 |
// | `ANDROID-PERMISSION-WITHOUT-API` | 编目权限 + 代码里无对应标记 | **没扫过 DEX 就不判**；只判判据明确的权限 |
// | `IOS-RULE-G` | 通讯录/麦克风/定位 + 上传 | 只有定位时降为 P3（`-COMMON`） |
//
// ## 为什么「没扫过 DEX 就不判」必须单独测
//
// `unusedPermissionNames` 的语义是「在**扫描到的**代码里找不到」。没扫过
// DEX 时它是空的 —— 但如果没有 `hasDexContent` 这道闸，语义会滑成
// 「这个应用没用过这些权限」，而事实是「我们没看」。这是本项目反复踩到的
// 那一类错误（「没看到」被说成「没有」）。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Android：手搓 meta + 「DEX 风格」的字节
// ---------------------------------------------------------------------------

/// 把若干字符串拼成一段「DEX 风格的字节」—— 字符串扫描器只看字面量。
///
/// 与 `android_sensitive_source_rule_test.dart` 同一套做法：不造真 DEX，
/// 因为这个文件要验证的是**规则判定**，不是 DEX 解析。
Uint8List _blob(List<String> strings) {
  final parts = <int>[];
  for (final s in strings) {
    parts.addAll(s.codeUnits);
    parts.add(0);
  }
  return Uint8List.fromList(parts);
}

ApkMeta _meta({List<String> permissions = const []}) => ApkMeta()
  ..packageName = 'com.example.webtest'
  ..targetSdkVersion = 34
  ..permissions = List.of(permissions)
  ..permissionRequests = [
    for (final name in permissions) AndroidPermissionRequest(name),
  ];

SecurityAnalysisResult _audit(ApkMeta meta, List<String> strings) =>
    AndroidSecurityAudit.audit(
      meta: meta,
      dexEntries: [DexBytes('classes.dex', _blob(strings))],
    );

List<SecurityFinding> _byId(SecurityAnalysisResult r, String id) =>
    r.findings.where((f) => f.ruleId == id).toList();

void main() {
  group('WebView JS 桥', () {
    test('出现 addJavascriptInterface → 一条 P3、independentCapability', () {
      final result = _audit(
          _meta(), ['Landroid/webkit/WebView;', 'addJavascriptInterface']);
      final finding = _byId(result, 'ANDROID-WEBVIEW-BRIDGE');
      expect(finding, hasLength(1));
      // P3 而不是 P2：真实样本上 4/5 个包命中，且调用点全部来自第三方 SDK
      // （验证码 / 统计 / 分享）。P2 会让读者学会忽略整块面板。
      expect(finding.single.severity, SecuritySeverity.p3);
      expect(
          finding.single.confidence, SecurityConfidence.independentCapability,
          reason: '确认的是「暴露了桥」这个能力事实，不是「已被利用」');
    });

    test('正文说明「第三方 SDK 普遍如此」，避免误以为是应用自己的设计', () {
      final result = _audit(_meta(), ['addJavascriptInterface']);
      final finding = _byId(result, 'ANDROID-WEBVIEW-BRIDGE').single;
      expect(finding.finding.toLowerCase(), contains('sdk'));
      expect(finding.limitation!.toLowerCase(), contains('third-party'));
    });

    test('只开 JS、没有桥 → 不报这条', () {
      final result = _audit(_meta(), ['setJavaScriptEnabled']);
      expect(_byId(result, 'ANDROID-WEBVIEW-BRIDGE'), isEmpty);
    });

    test('同时开了 JS 与 file 跨域 → 正文里带出这两个附加事实', () {
      final result = _audit(_meta(), [
        'addJavascriptInterface',
        'setJavaScriptEnabled',
        'setAllowUniversalAccessFromFileURLs',
      ]);
      final finding = _byId(result, 'ANDROID-WEBVIEW-BRIDGE').single;
      final extras = (finding.messageArgs['extras']! as List).cast<String>();
      expect(extras, contains('JavaScript enabled'));
      expect(extras, contains('file:// pages may access any origin'));
      // 附加事实要写进正文，不能只在 messageArgs 里
      expect(finding.finding, contains('JavaScript enabled'));
    });

    test('完全没有 WebView 线索 → 不报', () {
      expect(_byId(_audit(_meta(), ['unrelated']), 'ANDROID-WEBVIEW-BRIDGE'),
          isEmpty);
    });
  });

  group('权限 vs API 交叉核对', () {
    test('声明通讯录、代码里没有 ContactsContract → 一条 P3', () {
      final result = _audit(
        _meta(permissions: ['android.permission.READ_CONTACTS']),
        ['unrelated'],
      );
      final finding = _byId(result, 'ANDROID-PERMISSION-WITHOUT-API');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p3);
      expect(finding.single.confidence, SecurityConfidence.suspected,
          reason: '代码可能在没扫到的地方，不能给 confirmed');
      expect(finding.single.messageArgs['names'], contains('READ_CONTACTS'));
    });

    test('声明了通讯录、代码里确实有 ContactsContract → 不报', () {
      final result = _audit(
        _meta(permissions: ['android.permission.READ_CONTACTS']),
        ['Landroid/provider/ContactsContract;'],
      );
      expect(_byId(result, 'ANDROID-PERMISSION-WITHOUT-API'), isEmpty);
    });

    test('RECORD_AUDIO 用 AudioRecord 实现 → 也算「用过」', () {
      // 这是本轮的另一个修正：此前只认 MediaRecorder，用 AudioRecord 直读
      // PCM 的应用会被误判成「声明了没用」。
      final result = _audit(
        _meta(permissions: ['android.permission.RECORD_AUDIO']),
        ['Landroid/media/AudioRecord;'],
      );
      expect(_byId(result, 'ANDROID-PERMISSION-WITHOUT-API'), isEmpty,
          reason: 'AudioRecord 是合法的录音入口，漏了它就会误报');
    });

    test('RECORD_AUDIO 用 MediaRecorder 实现 → 也算', () {
      final result = _audit(
        _meta(permissions: ['android.permission.RECORD_AUDIO']),
        ['Landroid/media/MediaRecorder;'],
      );
      expect(_byId(result, 'ANDROID-PERMISSION-WITHOUT-API'), isEmpty);
    });

    test('未编目的权限不判（判据不明确的宁可不说）', () {
      // WRITE_EXTERNAL_STORAGE 可能只走 java.io.File，硬判会误报。
      final result = _audit(
        _meta(permissions: ['android.permission.WRITE_EXTERNAL_STORAGE']),
        ['unrelated'],
      );
      expect(_byId(result, 'ANDROID-PERMISSION-WITHOUT-API'), isEmpty);
    });

    test('没扫过 DEX → 不判（"没看到"不是"没有"）', () {
      final result = AndroidSecurityAudit.audit(
        meta: _meta(permissions: ['android.permission.READ_CONTACTS']),
        dexEntries: const [],
      );
      expect(_byId(result, 'ANDROID-PERMISSION-WITHOUT-API'), isEmpty,
          reason: '没有 DEX 时「找不到调用」只说明我们没看');
    });

    test('多条命中时一次列全，且去重', () {
      final result = _audit(
        _meta(permissions: [
          'android.permission.READ_CONTACTS',
          'android.permission.READ_CONTACTS', // 重复声明
          'android.permission.READ_SMS',
        ]),
        ['unrelated'],
      );
      final names = (_byId(result, 'ANDROID-PERMISSION-WITHOUT-API')
              .single
              .messageArgs['names']! as List)
          .cast<String>();
      expect(names, hasLength(2), reason: '重复声明不该产生两条');
      expect(names, containsAll(['READ_CONTACTS', 'READ_SMS']));
    });
  });
}
