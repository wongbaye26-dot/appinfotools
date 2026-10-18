// 敏感数据来源的**扩展**：短信 / 定位 / 录音 / 剪贴板 → 上传，
// 以及三类**特殊访问能力**（无障碍 / 设备管理器 / 通知监听）。
//
// ## 为什么是这几类
//
// 审计报告 §4 P2-2 逐个 grep 了 13 个常见敏感 API，当时只补了
// `TelephonyManager` / `ContactsContract` / `DexClassLoader`。剩下这些是最常见、
// 也最容易造成实际损害的：
//
// | 来源 | 现实风险 |
// |---|---|
// | `SmsManager` | 验证码 / 短信内容 |
// | `LocationManager` | 行踪 |
// | `MediaRecorder` | 录音 |
// | `ClipboardManager` | 剪贴板（常含密码、验证码） |
// | `AccessibilityService` | 读屏 / 自动点击 / 盗取验证码 |
// | `DeviceAdminReceiver` | 防卸载 / 锁屏 / 抹除 |
// | `NotificationListenerService` | 通知里的验证码 |
//
// ## 分级原则（本文件守的就是这个）
//
// - **数据来源**只在「同时有上传能力」时才报（规则 G）—— 单看「读了短信」没有
//   意义，很多正常应用都读；
// - **特殊访问能力**单独报（不需要上传），因为「申请了无障碍/设备管理器」本身
//   就是需要用户知情的高权限事实。但等级只到 **P3 + confirmed**：
//   `confirmed` 指的是「声明事实已确认」，不是「风险已确认」。

import 'dart:typed_data';

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/utils/analysis_report.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ApkMeta _meta({List<AndroidComponent> components = const []}) => ApkMeta()
  ..permissionRequests = const []
  ..permissions = const []
  ..components = components;

/// 造一个「提供特殊访问能力」的组件：`android:permission` 是关键判据。
AndroidComponent _specialService(String name, String bindPermission) =>
    AndroidComponent(
      type: ComponentType.service,
      name: name,
      permission: bindPermission,
    );

Uint8List _blob(List<String> strings) {
  final parts = <int>[];
  for (final s in strings) {
    parts.addAll(s.codeUnits);
    parts.add(0);
  }
  return Uint8List.fromList(parts);
}

SecurityAnalysisResult _audit(
  List<String> strings, {
  List<AndroidComponent> components = const [],
}) =>
    AndroidSecurityAudit.audit(
      meta: _meta(components: components),
      dexEntries: [DexBytes('classes.dex', _blob(strings))],
    );

SecurityFinding? _byId(SecurityAnalysisResult r, String ruleId) {
  for (final f in r.findings) {
    if (f.ruleId == ruleId) return f;
  }
  return null;
}

const _upload = 'multipart/form-data';

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('四类数据来源 + 上传 → 规则 G', () {
    for (final (literal, label, severity) in const [
      // 通讯录 / 短信 / 录音 → P2：正常应用里「读这些 + 上传」并不常见。
      ('Landroid/telephony/SmsManager;', '短信', SecuritySeverity.p2),
      ('Landroid/media/MediaRecorder;', '录音', SecuritySeverity.p2),
      // 定位 / 剪贴板 → P3：几乎每个应用都有（地图、剪贴板同步），
      // 一律 P2 会让这条规则在九成应用上出现，读者会学会忽略它。
      ('Landroid/location/LocationManager;', '定位', SecuritySeverity.p3),
      ('Landroid/content/ClipboardManager;', '剪贴板', SecuritySeverity.p3),
    ]) {
      test('$label + 上传 → 一条 ${severity.name}，来源写「$label」', () {
        final result = _audit([literal, _upload]);
        final finding = _byId(result, 'ANDROID-RULE-G');
        expect(finding, isNotNull, reason: '$label 是常见外传来源，不该漏');
        expect(finding!.severity, severity);
        expect(finding.dataSource, contains(label));
      });

      test('$label 单独出现（没有上传）→ 不报规则 G', () {
        final result = _audit([literal]);
        expect(_byId(result, 'ANDROID-RULE-G'), isNull);
      });
    }

    test('多个来源同时命中 → **一条**发现，来源列出全部', () {
      final result = _audit([
        'Landroid/telephony/SmsManager;',
        'Landroid/location/LocationManager;',
        _upload,
      ]);
      final finding = _byId(result, 'ANDROID-RULE-G')!;
      expect(finding.dataSource, contains('短信'));
      expect(finding.dataSource, contains('定位'));
    });
  });

  group('三类特殊访问能力（不需要上传也要报）', () {
    for (final (permission, label) in const [
      ('android.permission.BIND_ACCESSIBILITY_SERVICE', '无障碍'),
      ('android.permission.BIND_DEVICE_ADMIN', '设备管理器'),
      ('android.permission.BIND_NOTIFICATION_LISTENER_SERVICE', '通知监听'),
    ]) {
      test('$label → 一条 P3/confirmed，且不误报规则 G', () {
        final result = _audit(
          const [],
          components: [_specialService('com.example.Svc', permission)],
        );
        final finding = _byId(result, 'ANDROID-SPECIAL-ACCESS');
        expect(finding, isNotNull, reason: '$label 是高权限事实，必须说出来');
        expect(
          finding!.severity,
          SecuritySeverity.p3,
          reason: 'P3 而不是 P1：这些能力本身合法，只是需要用户知情',
        );
        expect(
          finding.confidence,
          SecurityConfidence.confirmed,
          reason: 'confirmed 指「声明事实已确认」，不是「风险已确认」',
        );
        expect(_byId(result, 'ANDROID-RULE-G'), isNull,
            reason: '没有上传线索，不该命中外传规则');
      });
    }

    test('多个特殊能力 → 一条发现列出全部（不刷屏）', () {
      final result = _audit(
        const [],
        components: [
          _specialService('com.example.A11y',
              'android.permission.BIND_ACCESSIBILITY_SERVICE'),
          _specialService(
              'com.example.Admin', 'android.permission.BIND_DEVICE_ADMIN'),
        ],
      );
      final finding = _byId(result, 'ANDROID-SPECIAL-ACCESS')!;
      expect(finding.evidence, hasLength(2), reason: '每个组件一条证据，读者能回清单里核对');
      final text = AnalysisReport.findingText(finding, t);
      expect(text, contains('无障碍'));
      expect(text, contains('设备管理器'));
    });

    test('没有特殊能力 → 不产生这条', () {
      final result = _audit(['unrelated']);
      expect(_byId(result, 'ANDROID-SPECIAL-ACCESS'), isNull);
    });

    test('**DEX 里出现 AccessibilityServiceInfo 不算**（Material 组件的正常调用）', () {
      // 真实误报：飞牛TV 的「无障碍」来自 MaterialAutoCompleteTextView 查询
      // `AccessibilityServiceInfo`。字面量匹配把 UI 库算成了无障碍服务。
      final result = _audit([
        'Landroid/accessibilityservice/AccessibilityServiceInfo;',
        'Landroid/view/accessibility/AccessibilityManager;',
      ]);
      expect(_byId(result, 'ANDROID-SPECIAL-ACCESS'), isNull,
          reason: '查询无障碍设置不是「提供无障碍服务」');
    });

    test('有 BIND 权限但类型不是 service 也照报（按权限判，不按类型猜）', () {
      final result = _audit(
        const [],
        components: [
          AndroidComponent(
            type: ComponentType.receiver,
            name: 'com.example.Admin',
            permission: 'android.permission.BIND_DEVICE_ADMIN',
          ),
        ],
      );
      expect(_byId(result, 'ANDROID-SPECIAL-ACCESS'), isNotNull,
          reason: '设备管理器本来就是 receiver');
    });
  });

  group('动态加载的第二个入口', () {
    test('PathClassLoader 也进「覆盖不足」', () {
      final result = _audit(['Ldalvik/system/PathClassLoader;']);
      expect(
        result.limitations.any((n) => n.code == 'android.dex.dynamic_loading'),
        isTrue,
        reason: 'PathClassLoader 与 DexClassLoader 是同一类运行时加载',
      );
    });
  });

  group('措辞边界', () {
    test('特殊访问能力的正文是中文，且不宣称恶意', () {
      final result = _audit(
        const [],
        components: [
          _specialService('com.example.A11y',
              'android.permission.BIND_ACCESSIBILITY_SERVICE'),
        ],
      );
      final text = AnalysisReport.findingText(
          _byId(result, 'ANDROID-SPECIAL-ACCESS')!, t);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue,
          reason: '中文界面下不能显示英文回退：$text');
      expect(text, isNot(contains('恶意')));
    });

    test('规则 G 的关联说明仍然写「未证实」', () {
      final result = _audit(['Landroid/telephony/SmsManager;', _upload]);
      final relationship =
          AnalysisReport.relationshipText(_byId(result, 'ANDROID-RULE-G')!, t);
      expect(relationship, isNotNull);
      expect(
        relationship,
        anyOf(contains('未证实'), contains('并未成立'), contains('不是数据流')),
      );
    });
  });
}
