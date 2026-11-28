import 'package:analysis_model/analysis_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 敏感信息的「明文不落盘」是承诺，不是口号：这里把承诺钉成测试。
///
/// 覆盖三件事：
/// 1. `SecretMatch` 的序列化键集固定，没有 `value` / `plaintext` 这类字段；
/// 2. 扫描器返回的脱敏值与上下文里都不含原文；
/// 3. 指纹算法（`v1:`）与值哈希是唯一可对外标识。
void main() {
  const raw = 'AKIAIOSFODNN7EXAMPLE';

  test('SecretMatch.toJson 只有脱敏字段，没有明文字段', () {
    final match = SecretScanner.scanText(
      'key = "$raw"',
      location: 'assets/config.json',
    ).matches.single;
    final json = match.toJson();
    expect(
      json.keys.toSet(),
      {
        'id',
        'ruleId',
        'kind',
        'confidence',
        'redactedValue',
        'valueSha256',
        'location',
        'context',
        'extractorId',
      },
    );
    expect(json.values.whereType<String>(), isNot(contains(raw)));
  });

  test('脱敏值与上下文都不含原文', () {
    final match = SecretScanner.scanText(
      'aws_access_key_id=$raw',
      location: 'classes.dex',
    ).matches.single;
    expect(match.redactedValue, isNot(contains(raw)));
    expect(match.contextRedacted, isNot(contains(raw)));
    expect(match.valueSha256, isNot(contains(raw)));
    expect(match.id, startsWith('v1:'));
  });

  test('同一值的哈希稳定：显式查看时用它核对，而不是比字符串', () {
    final first =
        SecretScanner.scanText('k=$raw', location: 'a').matches.single;
    final second =
        SecretScanner.scanText('other=$raw', location: 'b').matches.single;
    expect(first.valueSha256, second.valueSha256);
    expect(first.id, isNot(second.id)); // 位置不同 → 指纹不同
  });
}
