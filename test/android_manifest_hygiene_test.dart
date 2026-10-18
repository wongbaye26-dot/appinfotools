// 清单层的三个经典缺陷：`debuggable` / 导出组件无权限 / `allowBackup`。
//
// ## 为什么这三条重要
//
// 它们**完全可判定**（清单里写了就是写了），却一直是审计的盲区 ——
// `AndroidSecurityAudit` 此前只看权限、代码线索与组件数，从不看这三个属性。
//
// | 项 | 后果 |
// |---|---|
// | `android:debuggable="true"` | 任何拿到设备的人可以 `run-as` 进应用、读内存、替换代码 —— **发布包里出现就是 P1** |
// | 导出组件没有 `android:permission` | 其它应用可以直接调起它（activity 劫持、intent 注入、ContentProvider 数据泄露） |
// | `android:allowBackup="true"` | `adb backup` 能把应用私有数据整包导出 |
//
// ## 两个必须排除的误报
//
// 1. **启动页必须导出**（`MAIN` / `LAUNCHER`）—— 否则每个应用都会报一条；
// 2. 导出但**声明了 `android:permission`** 的组件是受保护的，不报。

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
  bool? debuggable,
  bool? allowBackup,
  bool? cleartext,
  String? networkSecurityConfig,
  List<AndroidComponent> components = const [],
  List<ActivityInfo> launchers = const [],
}) =>
    ApkMeta()
      ..permissionRequests = const []
      ..permissions = const []
      ..applicationDebuggable = debuggable
      ..applicationAllowBackup = allowBackup
      ..applicationUsesCleartextTraffic = cleartext
      ..networkSecurityConfig = networkSecurityConfig
      ..components = List.of(components)
      ..launchableActivities = List.of(launchers);

SecurityAnalysisResult _audit(ApkMeta meta) => AndroidSecurityAudit.audit(
      meta: meta,
      dexEntries: [
        DexBytes('classes.dex', _blob(['unrelated']))
      ],
    );

List<SecurityFinding> _byId(SecurityAnalysisResult r, String ruleId) =>
    r.findings.where((f) => f.ruleId == ruleId).toList();

AndroidComponent _component(
  ComponentType type,
  String name, {
  bool? exported,
  String? permission,
}) =>
    AndroidComponent(
      type: type,
      name: name,
      exported: exported,
      permission: permission,
    );

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  group('debuggable', () {
    test('debuggable=true → 一条 P1/confirmed', () {
      final result = _audit(_meta(debuggable: true));
      final finding = _byId(result, 'ANDROID-DEBUGGABLE');
      expect(finding, hasLength(1), reason: '发布包里开 debuggable 是硬缺陷');
      expect(finding.single.severity, SecuritySeverity.p1);
      expect(finding.single.confidence, SecurityConfidence.confirmed);
    });

    test('debuggable=false / 未声明 → 不报', () {
      expect(_byId(_audit(_meta(debuggable: false)), 'ANDROID-DEBUGGABLE'),
          isEmpty);
      expect(_byId(_audit(_meta()), 'ANDROID-DEBUGGABLE'), isEmpty,
          reason: '未声明时平台默认 false，不能当成 true');
    });
  });

  group('导出组件没有权限保护', () {
    test('导出的 activity 无 permission → P3，并点名', () {
      final result = _audit(_meta(components: [
        _component(ComponentType.activity, 'com.example.Exported',
            exported: true),
      ]));
      final finding = _byId(result, 'ANDROID-EXPORTED-COMPONENT');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p3);
      expect(AnalysisReport.findingText(finding.single, t),
          contains('com.example.Exported'));
    });

    test('导出的 provider 无 permission → **P2**（数据暴露风险最高）', () {
      final result = _audit(_meta(components: [
        _component(ComponentType.provider, 'com.example.Provider',
            exported: true),
      ]));
      final finding = _byId(result, 'ANDROID-EXPORTED-COMPONENT');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p2,
          reason: 'ContentProvider 直接暴露数据，比 activity 更危险');
    });

    test('导出但声明了 android:permission → 不报（受保护）', () {
      final result = _audit(_meta(components: [
        _component(ComponentType.service, 'com.example.Guarded',
            exported: true, permission: 'com.example.permission.CALL'),
      ]));
      expect(_byId(result, 'ANDROID-EXPORTED-COMPONENT'), isEmpty);
    });

    test('启动页（MAIN/LAUNCHER）虽然导出，但**不报**', () {
      const name = 'com.example.MainActivity';
      final result = _audit(_meta(
        components: [
          _component(ComponentType.activity, name, exported: true),
        ],
        launchers: [ActivityInfo(name: name)],
      ));
      expect(_byId(result, 'ANDROID-EXPORTED-COMPONENT'), isEmpty,
          reason: '启动页必须导出，报它等于每个应用都报一条');
    });

    test('exported 未声明（null）→ 不报（不替平台猜默认值）', () {
      final result = _audit(_meta(components: [
        _component(ComponentType.activity, 'com.example.Unknown'),
      ]));
      expect(_byId(result, 'ANDROID-EXPORTED-COMPONENT'), isEmpty,
          reason: 'exported 的默认值取决于有没有 intent-filter 与 targetSdk，'
              '静态猜它就是在编造');
    });

    test('多个导出组件 → 一条发现列出全部（不刷屏）', () {
      final result = _audit(_meta(components: [
        _component(ComponentType.activity, 'com.example.A', exported: true),
        _component(ComponentType.receiver, 'com.example.B', exported: true),
        _component(ComponentType.service, 'com.example.C', exported: true),
      ]));
      final finding = _byId(result, 'ANDROID-EXPORTED-COMPONENT');
      expect(finding, hasLength(1));
      final text = AnalysisReport.findingText(finding.single, t);
      expect(text, contains('com.example.A'));
      expect(text, contains('com.example.B'));
      expect(text, contains('com.example.C'));
    });
  });

  group('allowBackup', () {
    test('allowBackup=true → 一条 P3/confirmed', () {
      final result = _audit(_meta(allowBackup: true));
      final finding = _byId(result, 'ANDROID-ALLOW-BACKUP');
      expect(finding, hasLength(1));
      expect(finding.single.severity, SecuritySeverity.p3);
    });

    test('allowBackup=false → 不报', () {
      expect(_byId(_audit(_meta(allowBackup: false)), 'ANDROID-ALLOW-BACKUP'),
          isEmpty);
    });
  });

  group('明文流量与 networkSecurityConfig 的优先级', () {
    // AOSP `ApplicationInfo`：API 24 起，只要声明了 networkSecurityConfig，
    // `android:usesCleartextTraffic` **就不再生效**，一切由 NSC 决定。
    // 所以「有 NSC + cleartext=true」时不能说「允许明文流量」——
    // 那不是说重了，是说错了。实测 5 个真实包里 4 个 cleartext=true，
    // 其中 3 个同时有 NSC；不做这个区分，规则 D 会在 80% 的应用上以 P1 出现。
    test('cleartext=true 且**没有** NSC → 规则 D 触发', () {
      final result = _audit(_meta(cleartext: true));
      expect(
        result.findings.where((f) => f.ruleId.startsWith('ANDROID-RULE-D')),
        hasLength(1),
      );
    });

    test('cleartext=true 但**声明了** NSC → 不判定（不是「安全」，是「没看」）', () {
      final result = _audit(_meta(
        cleartext: true,
        networkSecurityConfig: '@res/0x7f010000',
      ));
      expect(
        result.findings.where((f) => f.ruleId.startsWith('ANDROID-RULE-D')),
        isEmpty,
        reason: 'NSC 存在时 usesCleartextTraffic 被平台忽略，不能拿它下结论',
      );
    });

    test('不判定时覆盖率里必须写清楚，不能静默消失', () {
      final result = _audit(_meta(
        cleartext: true,
        networkSecurityConfig: '@res/0x7f010000',
      ));
      final entry = result.coverage.entry('android.cleartextPolicy');
      expect(entry, isNotNull);
      expect(entry!.status, CoverageStatus.partial);
      expect(entry.noteCode, 'android.cleartext_policy_unknown');
    });

    test('没有 NSC 时这条覆盖率是 covered，不带 note', () {
      final result = _audit(_meta(cleartext: true));
      final entry = result.coverage.entry('android.cleartextPolicy');
      expect(entry, isNotNull);
      expect(entry!.status, CoverageStatus.covered);
      expect(entry.note, isNull);
    });
  });

  group('导出组件列表不能刷屏', () {
    // 真实样本：抖音有 159 个导出且无 permission 的组件。全列出来是一段
    // 6 KB 的正文 + 159 行证据，读者只会跳过 —— 而「读者跳过」正是安全面板
    // 最该避免的结局。截断是显示层取舍，count 永远是真实总数。
    List<AndroidComponent> many(int n) => [
          for (var i = 0; i < n; i++)
            _component(ComponentType.activity, 'com.example.A$i',
                exported: true),
        ];

    test('20 个组件 → 正文只点名 12 个，并明写省略了几个', () {
      final result = _audit(_meta(components: many(20)));
      final finding = _byId(result, 'ANDROID-EXPORTED-COMPONENT').single;
      expect(finding.messageCode, 'android.exported_component_many');
      expect(finding.messageArgs['count'], 20, reason: '总数不能缩水');
      expect((finding.messageArgs['names']! as List).length, 12);
      expect(finding.messageArgs['more'], 8);
    });

    test('组件数不超过上限时用原措辞，不带 more', () {
      final result = _audit(_meta(components: many(3)));
      final finding = _byId(result, 'ANDROID-EXPORTED-COMPONENT').single;
      expect(finding.messageCode, 'android.exported_component');
      expect(finding.messageArgs.containsKey('more'), isFalse);
    });

    test('证据行也有上限（159 行证据没人看）', () {
      final result = _audit(_meta(components: many(40)));
      final finding = _byId(result, 'ANDROID-EXPORTED-COMPONENT').single;
      expect(finding.evidence.length, lessThanOrEqualTo(20));
    });

    test('provider 排在点名列表最前面（它最危险）', () {
      final result = _audit(_meta(components: [
        ...many(12),
        _component(ComponentType.provider, 'com.example.ZProvider',
            exported: true),
      ]));
      final finding = _byId(result, 'ANDROID-EXPORTED-COMPONENT').single;
      expect((finding.messageArgs['names']! as List).first,
          'com.example.ZProvider');
    });
  });

  group('措辞', () {
    test('debuggable 的正文是中文，且说清后果而不是「有风险」', () {
      final result = _audit(_meta(debuggable: true));
      final text = AnalysisReport.findingText(
          _byId(result, 'ANDROID-DEBUGGABLE').single, t);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue,
          reason: '中文界面下不能显示英文回退：$text');
      expect(text, contains('调试'));
    });
  });
}
