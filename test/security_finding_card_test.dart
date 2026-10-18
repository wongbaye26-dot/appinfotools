// 安全发现项卡片：**数据流三段**（来源 / 中间处理 / 去向）的呈现。
//
// ## 为什么单独一个文件
//
// `security_finding_card.dart` 此前全仓零 widget 测试。它的数据流区块在 B-5
// 之前是这样写的：
//
// ```dart
// label: 'Source: ${finding.dataSource}',
// label: 'Sink: ${finding.dataSink}',
// ```
//
// 两个标签是**硬编码英文**，中文界面里就长成「Source: 照片/媒体文件」。
// `i18n_coverage_test.dart` 抓不到这种「写在 Dart 里的文案」，而它恰恰是
// 本项目 i18n 铁律里最容易复发的一类。
//
// 本文件钉住三件事：
// 1. 三个标签都走 i18n（中文界面下不出现 `Source:` / `Sink:`）；
// 2. 中间处理这一段存在时确实显示（B-5 的增量）；
// 3. 某一段没有就**不显示** —— 不填「未知」占位。

import 'package:analysis_model/analysis_model.dart';
import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/widgets/security_finding_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SecurityFinding _finding({String? transform}) => SecurityFinding(
      ruleId: 'ANDROID-RULE-C',
      platform: SecurityPlatform.android,
      category: SecurityCategory.dataExfiltration,
      severity: SecuritySeverity.p1,
      confidence: SecurityConfidence.suspected,
      finding: 'Image input, text recognition and upload call clues all appear '
          'together.',
      evidence: const [
        SecurityEvidence(
          source: SecurityEvidenceSource.dexMethodReference,
          location: 'Lcom/example/Pipeline;.run()V +0x254',
          detail: 'recognizeText call site',
        ),
      ],
      dataSource: '照片/媒体文件与其中的识别文本',
      dataTransform: transform,
      dataSink: '上传请求（multipart / upload API）',
      relationship: '识别与上传出现在同一个方法体内，但未证实数据真的传过去。',
      recommendation: '人工核查。',
    );

/// 把卡片放进一棵最小可用的树，并**展开**（默认是收起的）。
Future<void> _pumpExpanded(WidgetTester tester, SecurityFinding finding) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SecurityFindingCard(finding: finding),
          ),
        ),
      ),
    ),
  );
  // 整张卡片的头部是 InkWell，点它展开。
  await tester.tap(find.text(finding.ruleId));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    // 语言包是 deferred。
    await LocaleSettings.setLocaleRaw('zh-CN');
  });

  tearDownAll(() async {
    await LocaleSettings.setLocaleRaw('en');
  });

  testWidgets('三个标签都是中文（不再有硬编码的 Source: / Sink:）', (tester) async {
    await _pumpExpanded(
        tester, _finding(transform: 'Lcom/example/Pipeline;.run()V'));

    expect(find.textContaining(t.security.data_flow_source), findsOneWidget);
    expect(find.textContaining(t.security.data_flow_transform), findsOneWidget);
    expect(find.textContaining(t.security.data_flow_sink), findsOneWidget);

    // 硬编码英文标签必须消失 —— 它们在中英文界面里都不该再出现。
    expect(find.textContaining('Source:'), findsNothing);
    expect(find.textContaining('Sink:'), findsNothing);
  });

  testWidgets('中间处理这一段真的显示出来（B-5 的增量）', (tester) async {
    await _pumpExpanded(
        tester, _finding(transform: 'Lcom/example/Pipeline;.run()V'));

    // 值本身要能看见 —— 只显示标签没有意义。
    // 断言「标签 + 值」这一整串：证据里也有 `Lcom/example/Pipeline;…`，
    // 只搜 `Pipeline` 会同时命中证据行。
    expect(
      find.textContaining('${t.security.data_flow_transform}: '),
      findsOneWidget,
    );
    expect(
      find.textContaining('Lcom/example/Pipeline;.run()V'),
      findsWidgets,
      reason: '中间跳的方法签名要显示出来',
    );
  });

  testWidgets('没有中间跳时不显示这一段，也不填「未知」', (tester) async {
    await _pumpExpanded(tester, _finding());

    expect(find.textContaining(t.security.data_flow_transform), findsNothing);
    // 另外两段仍然在。
    expect(find.textContaining(t.security.data_flow_source), findsOneWidget);
    expect(find.textContaining(t.security.data_flow_sink), findsOneWidget);
  });

  testWidgets('三段全空时整个数据流区块不出现', (tester) async {
    const bare = SecurityFinding(
      ruleId: 'ANDROID-RULE-X',
      platform: SecurityPlatform.android,
      category: SecurityCategory.configuration,
      severity: SecuritySeverity.p3,
      confidence: SecurityConfidence.independentCapability,
      finding: 'f',
      evidence: [
        SecurityEvidence(
          source: SecurityEvidenceSource.manifest,
          location: 'l',
          detail: 'd',
        ),
      ],
      recommendation: 'r',
    );
    await _pumpExpanded(tester, bare);

    expect(find.textContaining(t.security.data_flow_source), findsNothing);
    expect(find.textContaining(t.security.data_flow_sink), findsNothing);
    expect(find.textContaining(t.security.data_flow_transform), findsNothing);
  });

  // ---------------------------------------------------------------------
  // 规则 D 的证据：**必须指向真正生效的那份配置**。
  //
  // 这条卡片测试单独拿出来，是因为「证据行渲染成什么」和「引擎算了什么」
  // 是两件事：引擎侧（`network_security_config_test.dart`）已经钉住了
  // 「有 NSC 时证据是 NSC 文件」，但那是数据；这里钉的是**它真的显示出来**。
  //
  // 期望的字符串就是引擎实际产出的那种：
  //   location: 'network security config (res/xml/network_security_config.xml) / domain-config'
  //   detail:   'cleartextTrafficPermitted="true" for: api.example.com, legacy.example.org'
  group('明文流量规则 D 的证据', () {
    const nscFinding = SecurityFinding(
      ruleId: 'ANDROID-RULE-D',
      platform: SecurityPlatform.android,
      category: SecurityCategory.configuration,
      severity: SecuritySeverity.p2,
      confidence: SecurityConfidence.confirmed,
      finding: 'The app permits cleartext (non-TLS) traffic.',
      messageCode: 'android.rule_d',
      evidence: [
        SecurityEvidence(
          // 引擎产出的就是这一种来源（不是 manifest）—— 有 NSC 时
          // 清单属性被平台忽略，标签打「AndroidManifest.xml」会自相矛盾。
          source: SecurityEvidenceSource.networkSecurityConfig,
          location: 'network security config '
              '(res/xml/network_security_config.xml) / domain-config',
          detail: 'cleartextTrafficPermitted="true" for: '
              'api.example.com, legacy.example.org',
        ),
      ],
      limitation: 'l',
      recommendation: 'r',
      recommendationCode: 'android.rule_d.manual_review',
    );

    testWidgets('证据指向 NSC 文件与 domain-config，不是清单属性', (tester) async {
      await _pumpExpanded(tester, nscFinding);
      expect(find.textContaining('network security config'), findsWidgets);
      expect(
        find.textContaining('res/xml/network_security_config.xml'),
        findsWidgets,
      );
      expect(find.textContaining('domain-config'), findsWidgets);
      expect(
        find.textContaining('AndroidManifest.xml'),
        findsNothing,
        reason: '有 NSC 时清单属性被平台忽略，证据不该指向它',
      );
    });

    testWidgets('放行的域名在证据里点得出来', (tester) async {
      await _pumpExpanded(tester, nscFinding);
      expect(find.textContaining('api.example.com'), findsWidgets);
      expect(find.textContaining('legacy.example.org'), findsWidgets);
    });

    testWidgets('中文界面下正文是中文，不是英文回退', (tester) async {
      await _pumpExpanded(tester, nscFinding);
      expect(find.textContaining('明文'), findsWidgets);
      expect(find.textContaining('permits cleartext'), findsNothing);
    });
  });
}
