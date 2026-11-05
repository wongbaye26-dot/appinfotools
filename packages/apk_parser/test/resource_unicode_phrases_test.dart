import 'package:analysis_model/analysis_model.dart';
import 'package:apk_parser/apk_parser.dart';
import 'package:test/test.dart';

void main() {
  test('资源字符串命中话术时产出 info 元发现项', () {
    final signals = scanAndroidResourcePhrases([
      '资金冻结',
      '请联系人工客服解冻',
      '刷单返利',
      'MetaMask',
    ]);
    final findings = buildAndroidResourceUnicodePhraseFindings(signals);
    expect(findings, hasLength(1));
    final f = findings.single;
    expect(f.ruleId, 'ANDROID-RESOURCE-UNICODE-PHRASE');
    expect(f.severity, SecuritySeverity.info);
    expect(f.isMeta, isTrue);
    expect(f.evidence.map((e) => e.detail).join('\n'), contains('资金冻结'));
  });

  test('只有一两条普通钱包词时不报告', () {
    final signals = scanAndroidResourcePhrases(['助记词', '收款地址', '登录']);
    expect(buildAndroidResourceUnicodePhraseFindings(signals), isEmpty);
  });

  test('纯 ASCII 资源不产出发现项', () {
    final signals = scanAndroidResourcePhrases(['hello', 'world']);
    expect(signals.isEmpty, isTrue);
  });
}
